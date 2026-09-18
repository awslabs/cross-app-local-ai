import AppKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "appstate.pipelines")

/// Delay after focusing the target app before simulating Cmd+C for selection capture.
private let captureDelayNanoseconds: UInt64 = 200_000_000

/// Delay after focusing the target app before simulating Cmd+V.
/// 200ms matches the capture delay and gives Electron-based apps (Slack, VS Code)
/// enough time to become the key responder after `NSRunningApplication.activate()`.
private let focusSettleDelayNanoseconds: UInt64 = 200_000_000

/// Delay after paste before restoring the original clipboard content.
private let pasteRestoreDelayNanoseconds: UInt64 = 50_000_000

// MARK: - Overlay Toggle, Generation, Injection, Refinement

extension AppState {
    /// Full overlay toggle flow per 07-system-integration.md Section 3.1.
    func toggleOverlay() async {
        if isOverlayVisible {
            guard config.behavior.dismissOnHotkey else { return }
            await hideOverlay()
            return
        }

        let accepted = await agent.onHotkeyPressed()
        guard accepted else { return }

        do {
            let activeApp = try await platformService.getActiveApp()
            originalClipboard = await platformService.getClipboard()

            let identity = appResolver.resolve(
                bundleId: activeApp.bundleId,
                appName: activeApp.appName,
                windowTitle: activeApp.windowTitle
            )

            var selection: String?
            if config.behavior.autoCaptureSelection {
                selection = try await captureSelectionFromApp(activeApp)
            }

            let hasSelection = selection.map { !$0.isEmpty } ?? false
            promptMode = hasSelection ? .replace : .insert

            if let event = await agent.onContextCaptured(
                contextType: identity.contextType,
                selectedText: selection,
                originalApp: activeApp
            ) {
                handleEvent(event)
            }

            self.contextType = identity.contextType
            self.selectedText = selection
            self.originalApp = activeApp
            recordTelemetryFeature(.overlayTrigger)

        } catch let error as PlatformError where error.isPermissionDenied {
            recordTelemetryError(.permissionDenied)
            logger.warning("Accessibility permission not granted during overlay activation")
            await agent.forceReset()
            PermissionChecker.openAccessibilitySettings()
            presentAlert(
                title: "Accessibility Permission Required",
                body: "FastLang needs Accessibility permission to capture text. "
                    + "Please enable it in the System Settings window that just opened."
            )
        } catch {
            logger.error("Context capture failed: \(error.localizedDescription, privacy: .public)")
            self.selectedText = nil
            isOverlayVisible = true
            overlayState = .input
        }
    }

    private func captureSelectionFromApp(_ activeApp: AppContext) async throws -> String? {
        try await platformService.focusApp(activeApp)
        try await Task.sleep(nanoseconds: captureDelayNanoseconds)
        let initialChangeCount = NSPasteboard.general.changeCount
        let selection = try await platformService.captureSelection()
        capturedViaClipboard = NSPasteboard.general.changeCount != initialChangeCount
        return selection
    }

    /// Hides the overlay and resets session state, including the agent.
    func hideOverlay() async {
        isOverlayVisible = false
        generationTask?.cancel()
        generationTask = nil

        if config.behavior.restoreClipboard {
            restoreClipboard()
        }
        await agent.forceReset()
        resetSessionState()
    }

    // MARK: - Generation Pipeline

    /// Starts LLM generation from the user's prompt.
    ///
    /// Builds system and user prompts, streams tokens from the LLM service,
    /// and updates overlay state through the agent state machine.
    func handleGenerate(prompt: String) async {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        promptText = trimmed
        logger.info("Generation requested, prompt length: \(trimmed.count)")

        if sessionOriginalPrompt.isEmpty {
            sessionOriginalPrompt = trimmed
        }

        if let event = await agent.handleUIMessage(.promptSubmitted(trimmed)) {
            handleEvent(event)
        }

        overlayState = .generating
        generatedText = ""
        isGenerating = true
        errorMessage = nil

        let systemPrompt = buildSystemPrompt()
        let userPrompt = buildUserPrompt()
        logger.debug("System prompt length: \(systemPrompt.count), user prompt length: \(userPrompt.count)")

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.streamGeneration(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        }
    }

    private func streamGeneration(systemPrompt: String, userPrompt: String) async {
        guard let llmService else {
            // Overlay may not be visible yet for this edge case — use the
            // system alert rather than the overlay error path.
            presentAlert(
                title: "Generation",
                body: "LLM service not initialized. Check model settings."
            )
            isGenerating = false
            return
        }

        // If the service is holding a failed-init stub (e.g. BedrockProvider
        // construction failed because the user's credential_process tool
        // needed a fresh corporate SSO session at startup), silently try to
        // reconstruct before the first generation attempt. The user doesn't
        // need to open Settings; we just try once and proceed.
        if await llmService.isUnavailable {
            logger.info("LLM service unavailable; attempting silent reconstruction before generation")
            await reconstructLlmService()
        }

        do {
            let stream = try await llmService.generateStream(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )

            for try await token in stream {
                guard !Task.isCancelled else { break }
                if let event = await agent.onStreamChunk(token) {
                    handleEvent(event)
                }
            }

            guard !Task.isCancelled else { return }

            logger.info("Generation complete, text length: \(self.generatedText.count)")
            if generatedText.isEmpty {
                logger.warning("Generation produced empty text")
            }

            if sessionOriginalResponse.isEmpty {
                sessionOriginalResponse = generatedText
            }

            recordTelemetryFeature(.llmGenerate)

            let usage = TokenUsage()
            if let event = await agent.onStreamComplete(usage: usage) {
                handleEvent(event)
            } else if isGenerating {
                // Defensive: the agent wasn't in `.generating` (a reset or
                // cancellation raced the stream), so it emitted no event. Don't
                // leave `isGenerating` stuck on — that keeps the menu-bar icon
                // spinning and the overlay in a limbo state forever.
                logger.warning("Stream completed but agent emitted no event; clearing generating state")
                isGenerating = false
                overlayState = generatedText.isEmpty ? .input : .approval
            }
        } catch {
            guard !Task.isCancelled else { return }
            isGenerating = false
            logger.error("Generation failed: \(error.localizedDescription, privacy: .public)")

            recordTelemetryError(.llmGenerateFailed)

            // Keep the agent's state machine in sync with the UI. Without this
            // the agent stays in `.generating` after a stream error, so later
            // UI messages (accept, refine, new prompt) hit its invalid-state
            // guards and are silently dropped — the overlay wedges until a full
            // reset. We only sync the agent here; the user-facing error is
            // shown via the overlay below, not the modal alert that
            // handleEvent(.streamError) would produce.
            _ = await agent.onStreamError(error.localizedDescription)

            // Show the error in the overlay (which is visible during generation)
            // rather than popping a system alert behind it. The overlay's
            // error state also exposes a suggested action (e.g. "refresh your
            // corporate SSO session") that the system alert path discards.
            let llmError = error as? LlmError
            errorSuggestedAction = llmError?.suggestedAction
            overlayState = .error(error.localizedDescription)
        }
    }

    /// Cancels the current generation.
    func cancelGeneration() async {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        generatedText = ""
        overlayState = .input

        if let event = await agent.handleUIMessage(.generationCancelled) {
            handleEvent(event)
        }
    }

    // MARK: - Injection Pipeline

    /// Accepts the generated text: saves session, hides overlay, injects into target app.
    func acceptGeneration() async {
        let textToInject = generatedText
        logger.info("Accepting generation, text length: \(textToInject.count)")
        if textToInject.isEmpty {
            logger.warning("Accepting empty generated text -- nothing will be injected")
        }

        saveSession(accepted: true)

        if let event = await agent.handleUIMessage(.textAccepted) {
            handleEvent(event)
        }

        isOverlayVisible = false

        await performInject(text: textToInject)
        resetSessionState()
    }

    /// Rejects the generated text: saves session, hides overlay.
    func rejectGeneration() async {
        saveSession(accepted: false)

        if let event = await agent.handleUIMessage(.textRejected) {
            handleEvent(event)
        }

        await hideOverlay()
    }

    /// Copies generated text to clipboard without injecting or hiding.
    func copyToClipboard() async {
        do {
            try await platformService.setClipboard(generatedText)
            logger.info("Copied generated text to clipboard")
        } catch {
            logger.error("Failed to copy to clipboard: \(error.localizedDescription, privacy: .public)")
        }
    }

    func performInject(text: String) async {
        guard let target = originalApp else {
            logger.error("performInject called with no originalApp -- aborting injection")
            return
        }

        logger.info("Injecting \(text.count) chars into \(target.appName) (pid \(target.processId))")

        let savedClipboard = await platformService.getClipboard()

        do {
            try await platformService.setClipboard(text)
            logger.debug("Clipboard set, focusing \(target.appName)")
            try await platformService.focusApp(target)
            logger.debug("Focus requested, waiting \(focusSettleDelayNanoseconds / 1_000_000)ms before paste")
            try await Task.sleep(nanoseconds: focusSettleDelayNanoseconds)

            if let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
               UInt32(frontPid) != target.processId {
                logger.warning(
                    "Focus verification failed: frontmost PID \(frontPid) != target PID \(target.processId)"
                )
            }

            try await platformService.injectText(text, target: target)
            logger
                .debug(
                    "Paste simulated, waiting \(pasteRestoreDelayNanoseconds / 1_000_000)ms before clipboard restore"
                )

            try await Task.sleep(nanoseconds: pasteRestoreDelayNanoseconds)

            if config.behavior.restoreClipboard, let saved = savedClipboard {
                try? await platformService.setClipboard(saved)
                logger.debug("Clipboard restored")
            }

            await agent.onInjectionComplete(success: true)
            logger.info("Text injected into \(target.appName)")
        } catch let error as PlatformError where error.isPermissionDenied {
            await agent.onInjectionComplete(success: false)
            logger.warning("Injection blocked: \(error.localizedDescription)")
            let suggestion = error.suggestedAction.map { " \($0)." } ?? ""
            presentAlert(title: "Accessibility", body: "\(error.userMessage).\(suggestion)")
        } catch {
            await agent.onInjectionComplete(success: false)
            logger.error("Injection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Refinement

    /// Submits a refinement: records feedback, rebuilds prompt, re-generates.
    func submitRefinement(feedback: String) async {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        sessionRefinements.append(Refinement(
            feedback: trimmed,
            response: generatedText,
            timestamp: String(Int(Date().timeIntervalSince1970))
        ))

        if let event = await agent.handleUIMessage(.refinementSubmitted(trimmed)) {
            handleEvent(event)
        }

        let refinedPrompt = """
        \(sessionOriginalPrompt)

        Previous output:
        \"\"\"\
        \(generatedText)
        \"\"\"

        User feedback: \(trimmed)
        """

        previousGeneratedText = generatedText
        await handleGenerate(prompt: refinedPrompt)
    }
}
