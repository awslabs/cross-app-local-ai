import AppKit
import Foundation
import OSLog
import ServiceManagement

private let logger = Logger(subsystem: "com.aws.fastlang", category: "appstate.services")

/// Minimum recording duration in seconds; shorter recordings are discarded as accidental taps.
private let minSttDurationSeconds = 0.3

/// Delay after focusing the target app before simulating Cmd+V.
private let sttFocusSettleDelayNanoseconds: UInt64 = 50_000_000

/// Delay after paste before restoring the original clipboard content.
private let sttPasteRestoreDelayNanoseconds: UInt64 = 50_000_000

// MARK: - STT, Download, Settings, Preferences, Prompts, History

extension AppState {

    // MARK: - Push-to-Talk STT

    /// Called when push-to-talk hotkey is pressed.
    func handleSttHotkeyPressed() async {
        logger.debug(
            "PTT key down: stt.enabled=\(self.config.stt.enabled), isRecording=\(self.isRecording)"
        )
        guard config.stt.enabled, !isRecording else { return }

        // STT can't transcribe until the provider is loaded. WhisperKit's
        // CoreML load/prewarm takes ~10-30s after launch, during which the
        // service holds a `.startingUp` placeholder (or is still nil). Check
        // readiness at key-down and surface it in the STT indicator pill now —
        // otherwise the user records a full phrase that gets discarded and
        // only learns at key-up.
        if let unavailable = await sttUnavailability() {
            logger.info("PTT down but STT not ready: \(unavailable.userMessage, privacy: .public)")
            sttIndicatorNotice = Self.sttNotice(for: unavailable)
            return
        }

        do {
            let activeApp = try await platformService.getActiveApp()
            sttTargetApp = activeApp

            _ = try await audioRecorder.start()
            isRecording = true
            recordTelemetryFeature(.pushToTalk)
            logger.info("PTT recording started")
        } catch {
            isRecording = false
            logger.error("Failed to start recording: \(error.localizedDescription, privacy: .public)")
            presentSttAlert(for: error)
        }
    }

    /// Called when push-to-talk hotkey is released.
    func handleSttHotkeyReleased() async {
        guard isRecording else { return }

        await audioRecorder.stop()
        isRecording = false

        guard let buffer = await audioRecorder.recordedBuffer() else {
            logger.debug("No audio recorded")
            return
        }

        let sampleCount = buffer.data.count / MemoryLayout<Float>.size
        let durationSeconds = Double(sampleCount) / 16000.0
        guard durationSeconds >= minSttDurationSeconds else {
            logger.debug("Recording too short (\(durationSeconds)s), discarding")
            return
        }

        guard let sttService else {
            logger.warning("STT service not initialized")
            presentSttAlert(for: SttError.startingUp)
            sttTargetApp = nil
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let transcription = try await sttService.transcribe(buffer)
            guard !transcription.text.isEmpty else { return }

            recordTelemetryFeature(.sttTranscribe)
            logger.info("Transcribed: \(transcription.text.prefix(50))...")
            await injectTranscribedText(transcription.text)
        } catch {
            recordTelemetryError(.sttTranscribeFailed)
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            presentSttAlert(for: error)
        }

        sttTargetApp = nil
    }

    /// The reason STT can't transcribe right now, or `nil` if it's ready.
    ///
    /// A nil service means initialization hasn't finished (treated as still
    /// starting up); otherwise the service reports whether its provider is a
    /// failed-init placeholder and why.
    private func sttUnavailability() async -> SttError? {
        guard let sttService else { return .startingUp }
        return await sttService.unavailableError
    }

    /// Builds an STT indicator notice for a not-ready error. `.startingUp`
    /// (model warming up) is a neutral `.info` status; everything else is a
    /// genuine `.error`. The message appends the suggested action when present.
    private static func sttNotice(for error: SttError) -> SttIndicatorNotice {
        let text = error.suggestedAction.map { "\(error.userMessage). \($0)" } ?? error.userMessage
        let kind: SttIndicatorNotice.Kind = error == .startingUp ? .info : .error
        return SttIndicatorNotice(text: text, kind: kind)
    }

    private func presentSttAlert(for error: Error) {
        let sttError = error as? SttError
        let message = sttError?.userMessage ?? error.localizedDescription
        let suggestion = sttError?.suggestedAction
        let body = suggestion.map { "\(message). \($0)." } ?? "\(message)."
        presentAlert(title: "Speech Recognition", body: body)
    }

    private func injectTranscribedText(_ text: String) async {
        guard let target = sttTargetApp else { return }
        let savedClipboard = await platformService.getClipboard()

        do {
            try await platformService.setClipboard(text)
            try await platformService.focusApp(target)
            try await Task.sleep(nanoseconds: sttFocusSettleDelayNanoseconds)
            try await platformService.injectText(text, target: target)
            try await Task.sleep(nanoseconds: sttPasteRestoreDelayNanoseconds)
            if let saved = savedClipboard {
                try? await platformService.setClipboard(saved)
            }
            sttIndicatorNotice = nil
        } catch let error as PlatformError where error.isPermissionDenied {
            if let saved = savedClipboard {
                try? await platformService.setClipboard(saved)
            }
            logger.warning("STT injection blocked: \(error.localizedDescription)")
            PermissionChecker.openAccessibilitySettings()
            sttIndicatorNotice = SttIndicatorNotice(
                text: "\(error.userMessage). Opening Accessibility settings\u{2026}",
                kind: .error
            )
        } catch {
            if let saved = savedClipboard {
                try? await platformService.setClipboard(saved)
            }
            logger.error("STT injection failed: \(error.localizedDescription, privacy: .public)")
            sttIndicatorNotice = SttIndicatorNotice(
                text: "Injection failed: \(error.localizedDescription)",
                kind: .error
            )
        }
    }

    // MARK: - AI Search (Voice to Google AI)

    /// Opens Google AI in Chrome and starts recording.
    func handleAiSearchPressed() async {
        logger.info("AI search hotkey pressed")
        guard config.stt.enabled else {
            logger.warning("AI search: STT is not enabled, ignoring")
            return
        }
        guard !isRecording else {
            logger.warning("AI search: already recording, ignoring")
            return
        }

        // Surface STT readiness before opening Chrome and recording, so a
        // still-warming-up model shows the indicator pill instead of losing
        // the user's dictation. See `handleSttHotkeyPressed`.
        if let unavailable = await sttUnavailability() {
            logger.info("AI search down but STT not ready: \(unavailable.userMessage, privacy: .public)")
            sttIndicatorNotice = Self.sttNotice(for: unavailable)
            return
        }

        aiSearchReleasedEarly = false

        // Open Google AI in Chrome via /usr/bin/open
        logger.info("AI search: opening Chrome to google.com/ai")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Google Chrome", "https://www.google.com/ai"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            logger.info("AI search: open command exited with status \(process.terminationStatus)")
        } catch {
            logger.error("AI search: failed to run open command: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Wait for Chrome to load and focus
        logger.info("AI search: waiting for Chrome to load...")
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // If the user already released the hotkey during the wait, don't start recording
        if aiSearchReleasedEarly {
            logger.info("AI search: hotkey released early, skipping recording")
            aiSearchReleasedEarly = false
            return
        }

        do {
            let activeApp = try await platformService.getActiveApp()
            logger.info("AI search: active app is \(activeApp.appName) (pid \(activeApp.processId))")
            sttTargetApp = activeApp

            _ = try await audioRecorder.start()
            isRecording = true
            logger.info("AI search: recording started")
        } catch {
            isRecording = false
            logger.error("AI search: failed to start recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops recording, transcribes, and types the question into Chrome.
    func handleAiSearchReleased() async {
        logger.info("AI search hotkey released")
        guard isRecording else {
            // Released before recording started (during Chrome load delay) — set flag
            logger.info("AI search: released before recording started, flagging early release")
            aiSearchReleasedEarly = true
            return
        }

        await audioRecorder.stop()
        isRecording = false

        guard let buffer = await audioRecorder.recordedBuffer() else {
            logger.debug("No audio recorded for AI search")
            return
        }

        let sampleCount = buffer.data.count / MemoryLayout<Float>.size
        let durationSeconds = Double(sampleCount) / 16000.0
        guard durationSeconds >= minSttDurationSeconds else {
            logger.debug("AI search recording too short (\(durationSeconds)s), discarding")
            return
        }

        guard let sttService else {
            logger.warning("STT service not initialized")
            presentSttAlert(for: SttError.startingUp)
            sttTargetApp = nil
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let transcription = try await sttService.transcribe(buffer)
            guard !transcription.text.isEmpty else { return }

            logger.info("AI search transcribed: \(transcription.text.prefix(50))...")

            guard let target = sttTargetApp else { return }
            let savedClipboard = await platformService.getClipboard()

            try await platformService.setClipboard(transcription.text)
            try await platformService.focusApp(target)
            try await Task.sleep(nanoseconds: sttFocusSettleDelayNanoseconds)
            try await platformService.injectText(transcription.text, target: target)

            // Press Enter to submit the query
            try await Task.sleep(nanoseconds: 100_000_000)
            try await platformService.simulateKeyPress(keyCode: 36, flags: [])

            try await Task.sleep(nanoseconds: sttPasteRestoreDelayNanoseconds)
            if let saved = savedClipboard {
                try? await platformService.setClipboard(saved)
            }

            logger.info("AI search query submitted")
        } catch {
            logger.error("AI search failed: \(error.localizedDescription, privacy: .public)")
            presentSttAlert(for: error)
        }

        sttTargetApp = nil
    }

    // MARK: - Deferred Download

    /// Shows download confirmation for an uncached model.
    func showDownloadConfirmation(modelId: String) {
        guard let entry = LlamaCppModels.findModel(modelId) else { return }
        downloadState = .confirming(
            modelId: modelId,
            displayName: entry.displayName,
            sizeBytes: entry.sizeBytes
        )
    }

    /// Confirms and starts a model download.
    func confirmDownload() async {
        guard case let .confirming(modelId, _, _) = downloadState else { return }

        logger.info("User confirmed download for model '\(modelId)'")

        downloadState = .active(modelId: modelId, percent: 0)

        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            var lastReportedMilestone = -1
            do {
                let (stream, cancelFn) = try LlamaCppModels.startModelDownload(modelId: modelId)
                self.cancelDownloadFn = cancelFn
                logger.info("Download stream created for '\(modelId)', awaiting progress...")

                for await progress in stream {
                    guard !Task.isCancelled else {
                        logger.info("Download cancelled for '\(modelId)'")
                        return
                    }
                    switch progress {
                    case let .progress(downloaded, total):
                        guard total > 0 else { continue }
                        let percent = Int(Double(downloaded) / Double(total) * 100)
                        let milestone = percent / 10 * 10
                        if milestone > lastReportedMilestone {
                            lastReportedMilestone = milestone
                            self.downloadState = .active(modelId: modelId, percent: milestone)
                        }
                    case .complete:
                        logger.info("Model '\(modelId)' download complete, reconfiguring LLM service...")
                        self.downloadState = nil
                        self.downloadTask = nil
                        self.cancelDownloadFn = nil
                        self.modelCacheVersion &+= 1
                        await self.reconstructLlmService()
                        logger.info("LLM service reconfigured with downloaded model '\(modelId)'")
                        return
                    case let .error(message):
                        self.downloadState = .failed(modelId: modelId, message: message)
                        self.downloadTask = nil
                        self.cancelDownloadFn = nil
                        self.recordTelemetryError(.modelDownloadFailed)
                        logger.error("Download stream error for '\(modelId)': \(message, privacy: .public)")
                        return
                    }
                }
                if self.downloadState != nil, case .active = self.downloadState {
                    self.downloadState = nil
                    self.downloadTask = nil
                    self.cancelDownloadFn = nil
                    await self.reconstructLlmService()
                    logger.info("Download stream ended for '\(modelId)', service reconfigured")
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.downloadState = .failed(modelId: modelId, message: error.localizedDescription)
                self.downloadTask = nil
                self.cancelDownloadFn = nil
                self.recordTelemetryError(.modelDownloadFailed)
                logger.error("Download failed for '\(modelId)': \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Cancels an in-progress download.
    func cancelDownload() {
        cancelDownloadFn?()
        cancelDownloadFn = nil
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = nil
        logger.info("Download cancelled by user")
    }

    /// Dismisses a download error.
    func dismissDownloadError() {
        downloadState = nil
    }

    /// Retries a failed download.
    func retryDownload(modelId: String) {
        showDownloadConfirmation(modelId: modelId)
    }

    // MARK: - Model Deletion

    /// Deletes a cached model. If the deleted model was the active one,
    /// reconstructs the LLM service so subsequent generations surface
    /// `modelNotInstalled` errors (via `FailedInitLlmProvider`) instead of
    /// continuing to use the freed real provider.
    func deleteModel(modelId: String) async {
        downloadState = .deleting(modelId: modelId)
        do {
            try LlamaCppModels.deleteModel(dirs: dirs, modelId: modelId)
            logger.info("Deleted model '\(modelId)'")

            let activeModelId = config.llm.localModelId
            if modelId == activeModelId {
                await reconstructLlmService()
                logger.info("Active model deleted, LLM service reconstructed")
            }
            modelCacheVersion &+= 1
        } catch {
            logger.error("Failed to delete model '\(modelId)': \(error.localizedDescription, privacy: .public)")
        }
        downloadState = nil
    }

    // MARK: - STT Model Download

    /// Shows download confirmation for a WhisperKit model.
    func showSttDownloadConfirmation(modelId: String) {
        guard let entry = WhisperKitModels.findModel(modelId) else { return }
        sttDownloadState = .confirming(
            modelId: modelId,
            displayName: entry.displayName,
            sizeBytes: entry.sizeBytes
        )
    }

    /// Confirms and starts a WhisperKit model download.
    func confirmSttDownload() async {
        guard case let .confirming(modelId, _, _) = sttDownloadState else { return }

        let stream = WhisperKitModelManager.startModelDownload(modelId: modelId)

        for await progress in stream {
            switch progress {
            case let .progress(downloaded, total):
                let sttPercent = total > 0 ? Int(Double(downloaded) / Double(total) * 100) / 10 * 10 : 0
                sttDownloadState = .active(modelId: modelId, percent: sttPercent)
            case .complete:
                // Order matters: reconstruct the live service BEFORE
                // flipping the UI to "installed." WhisperKit's CoreML
                // load inside `reconstructSttService` can take several
                // seconds. If we flip the UI first, a user who
                // immediately triggers PTT still hits the stale
                // `FailedInitSttProvider(.modelNotInstalled)` because
                // `self.sttService` hasn't been swapped yet. Keep the
                // progress UI up while the model finishes loading into
                // memory.
                await reconstructSttService()

                sttDownloadState = nil
                // Manual engagement with the auto-prefetch target counts as
                // acknowledgement; we shouldn't later silently re-pull
                // after a successful explicit download.
                if modelId == Self.sttAutoPrefetchModelId {
                    acknowledgeSttPrefetch()
                } else {
                    modelCacheVersion &+= 1
                }
                logger.info("WhisperKit model download complete, STT service reconfigured")
            case let .error(message):
                // Clear the state so the download UI resets and a retry is
                // possible (the STT status section doesn't render `.failed`),
                // and surface the failure so it isn't silent.
                sttDownloadState = nil
                logger.error("STT download error: \(message, privacy: .public)")
                presentAlert(title: "Speech Recognition", body: "Model download failed: \(message)")
            }
        }
    }

    /// Cancels an in-progress STT model download.
    func cancelSttDownload() {
        sttDownloadState = nil
    }

    /// Deletes a cached WhisperKit model.
    ///
    /// Async so we can reconstruct the STT service *before* the UI flips
    /// to "not installed". If we bumped the cache counter first, a user
    /// who triggered PTT during the gap would hit the stale real provider
    /// pointing at files that had just been removed from disk.
    func deleteSttModel(modelId: String) async {
        do {
            try WhisperKitModelManager.deleteModel(modelId)
            logger.info("Deleted WhisperKit model '\(modelId)'")

            if modelId == config.stt.whisperModelId {
                logger.info("Active STT model deleted; reconstructing STT service")
                await reconstructSttService()
            }
            // Manual delete of the auto-prefetch target counts as
            // acknowledgement; without this, a user who deletes the
            // prefetched model would have it silently re-pulled on the
            // next launch.
            if modelId == Self.sttAutoPrefetchModelId {
                acknowledgeSttPrefetch()
            } else {
                modelCacheVersion &+= 1
            }
        } catch {
            logger.error("Failed to delete STT model '\(modelId)': \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - TTS Model Download

    /// Shows download confirmation for the Kokoro TTS model.
    func showTtsDownloadConfirmation() {
        let entry = KokoroModelManager.modelEntry
        ttsDownloadState = .confirming(
            modelId: entry.id,
            displayName: entry.displayName,
            sizeBytes: entry.sizeBytes
        )
    }

    /// Confirms and starts a Kokoro model download.
    func confirmTtsDownload() async {
        guard case .confirming = ttsDownloadState else { return }

        let stream = KokoroModelManager.startModelDownload()
        let modelId = KokoroModelManager.modelEntry.id

        for await progress in stream {
            switch progress {
            case let .progress(downloaded, total):
                let ttsPercent = total > 0 ? Int(Double(downloaded) / Double(total) * 100) / 10 * 10 : 0
                ttsDownloadState = .active(modelId: modelId, percent: ttsPercent)
            case .complete:
                // Reconstruct the live service so it picks up the now-cached
                // model, mirroring the STT path. Without this the TTS service
                // keeps whatever provider it was built with at launch.
                await reconstructTtsService()
                ttsDownloadState = nil
                // Only one Kokoro model exists, so any manual download
                // acknowledges the auto-prefetch.
                acknowledgeTtsPrefetch()
                logger.info("Kokoro model download complete, TTS service reconfigured")
            case let .error(message):
                // See confirmSttDownload: clear state (TTS status section
                // doesn't render `.failed`) and surface the failure.
                ttsDownloadState = nil
                logger.error("TTS download error: \(message, privacy: .public)")
                presentAlert(title: "Text-to-Speech", body: "Model download failed: \(message)")
            }
        }
    }

    /// Cancels an in-progress TTS model download.
    func cancelTtsDownload() {
        ttsDownloadState = nil
    }

    /// Deletes the cached Kokoro TTS model.
    ///
    /// Async so we can reconstruct the TTS service after removing the
    /// on-disk files. Without the reconstruction the previously-loaded
    /// `KokoroSynthesizer` stays resident in memory inside the provider
    /// actor — CoreML models aren't invalidated by removing the source
    /// files — and subsequent `speak()` calls succeed with the already-
    /// loaded model, masking the delete.
    func deleteTtsModel() async {
        do {
            try KokoroModelManager.deleteModel()
            logger.info("Deleted Kokoro TTS model")
            KokoroSynthesizerCache.invalidate()
            await reconstructTtsService()
            acknowledgeTtsPrefetch()
        } catch {
            logger.error("Failed to delete Kokoro model: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Login Item

    /// Registers or unregisters the app as a login item to match the
    /// persisted `launchAtLogin` preference. Safe to call repeatedly;
    /// register/unregister are no-ops when the state already matches.
    func syncLoginItem() {
        let service = SMAppService.mainApp
        if config.behavior.launchAtLogin {
            do {
                try service.register()
                logger.info("Registered as login item")
            } catch {
                logger.error("Failed to register login item: \(error.localizedDescription, privacy: .public)")
            }
        } else if service.status == .enabled {
            do {
                try service.unregister()
                logger.info("Unregistered login item")
            } catch {
                logger.error("Failed to unregister login item: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Settings Save

    /// Persists config and selectively reconstructs only changed services.
    func saveSettings() async {
        do {
            try config.save(to: dirs.settingsPath)
            logger.info("Config saved")
        } catch {
            logger.error("Failed to save config: \(error.localizedDescription, privacy: .public)")
        }

        syncLoginItem()

        let currentLlm = buildLlmServiceConfig()
        let currentStt = buildSttServiceConfig()
        let currentTts = buildTtsServiceConfig()

        if currentLlm != activeLlmConfig { await reconstructLlmService() }
        if currentStt != activeSttConfig { await reconstructSttService() }
        if currentTts != activeTtsConfig { await reconstructTtsService() }
    }

    /// Reconstructs just the LLM service from current config.
    func reconstructLlmService() async {
        let llmConfig = buildLlmServiceConfig()
        let newLlm = await LlmService(config: llmConfig)
        self.llmService = newLlm
        self.activeLlmConfig = llmConfig
        let name = await newLlm.providerName
        logger.info("LLM service reconstructed (provider: \(name))")
    }

    /// Reconstructs the STT service from the current config.
    ///
    /// Call this whenever the STT model cache state changes on disk
    /// (silent prefetch complete, manual download complete, or delete of
    /// the active model) so the service's provider matches what's
    /// actually available. Without this, `SttService` keeps its initial
    /// provider choice — e.g. a `FailedInitSttProvider(.modelNotInstalled)`
    /// bound at startup when the model wasn't yet cached — and later
    /// transcription requests keep throwing even though the real model
    /// is now on disk.
    ///
    /// ## Intermediate placeholder
    ///
    /// Constructing the real provider runs WhisperKit's CoreML prewarm,
    /// which can take 10–30 seconds. If the user hits PTT during that
    /// window, they'd hit the previous service — often a
    /// `FailedInitSttProvider(.modelNotInstalled)` from a moment when
    /// the cache was empty. That produces the misleading "model not
    /// installed" message even though the model IS on disk and simply
    /// loading.
    ///
    /// We fix this by swapping the old service for a transient
    /// `FailedInitSttProvider(.startingUp)` before the `await`. During
    /// CoreML load, PTT gets the honest "still starting up" message
    /// instead of the wrong install prompt.
    func reconstructSttService() async {
        let sttConfig = buildSttServiceConfig()

        // If the model is cached and STT is enabled, install a
        // "starting up" placeholder first so the gap between old and
        // new service produces the correct message. When STT is
        // disabled or the model is missing, we skip the placeholder —
        // `createProvider` will produce the appropriate failure
        // (notConfigured or modelNotInstalled) synchronously, which is
        // faster than the CoreML path and not worth placeholdering.
        if !sttConfig.mockMode,
           sttConfig.provider == "whisper",
           WhisperKitModelManager.isModelCached(sttConfig.whisperModelId) {
            self.sttService = await SttService(
                config: sttConfig,
                overridingProvider: FailedInitSttProvider(error: .startingUp)
            )
        }

        let newStt = await SttService(config: sttConfig)
        self.sttService = newStt
        self.activeSttConfig = sttConfig
        let name = await newStt.providerName
        logger.info("STT service reconstructed (provider: \(name))")
    }

    /// Reconstructs the TTS service from the current config.
    ///
    /// Call this whenever the TTS model cache state changes on disk
    /// (silent prefetch complete, manual download complete, or delete of
    /// the active model) so the in-memory `KokoroSynthesizer` is dropped
    /// and the next `speak()` loads fresh state from disk. Without this,
    /// a delete leaves the loaded model resident inside the actor and
    /// `speak()` keeps working even after the files are gone.
    ///
    /// Stops any in-flight playback first so the audio engine doesn't
    /// outlive its provider.
    func reconstructTtsService() async {
        if readAloudPlaybackState != .idle {
            await stopSpeaking()
        }
        let ttsConfig = buildTtsServiceConfig()
        let newTts = TtsService(config: ttsConfig)
        self.ttsService = newTts
        self.activeTtsConfig = ttsConfig
        readAloudRate = config.tts.rate
        let name = await newTts.providerName
        logger.info("TTS service reconstructed (provider: \(name))")
    }

    // MARK: - Sleep/Wake Resource Management

    /// Delay before reconstructing services after wake, giving the system
    /// time to stabilize GPU/ANE resources.
    private static let wakeReconstructionDelayNanoseconds: UInt64 = 2_000_000_000

    /// Releases heavy GPU/ANE-resident models to reduce memory footprint
    /// before system sleep. Without this, the app's ~3-5 GB Metal memory
    /// makes it a prime Jetsam target during sleep.
    ///
    /// Cancels any in-flight generation and nils the LLM and STT services.
    /// Their backing `LlamaClient` and WhisperKit CoreML models are freed
    /// via `deinit` when the last reference drops.
    func suspendForSleep() async {
        guard !isSuspendedForSleep else { return }
        isSuspendedForSleep = true

        if isGenerating {
            await cancelGeneration()
            logger.info("Cancelled in-flight generation before sleep")
        }

        if readAloudPlaybackState != .idle {
            await stopSpeaking()
            logger.info("Stopped read-aloud playback before sleep")
        }

        llmService = nil
        sttService = nil
        logger.info("Services suspended for sleep (LLM + STT released)")
    }

    /// Reconstructs LLM and STT services after waking from sleep.
    ///
    /// Adds a short delay to let the system stabilize GPU/ANE contexts
    /// after wake before loading multi-GB models back into memory.
    func resumeFromWake() async {
        guard isSuspendedForSleep else { return }

        try? await Task.sleep(nanoseconds: Self.wakeReconstructionDelayNanoseconds)

        await reconstructLlmService()
        await reconstructSttService()

        isSuspendedForSleep = false
        logger.info("Services resumed after wake")
    }

    // MARK: - Preferences Persistence

    /// Persists preferences to disk.
    func savePreferences() {
        do {
            try preferences.save(to: dirs.appRulesPath)
        } catch {
            logger.error("Failed to save preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persists quick prompts to disk.
    func saveQuickPrompts() {
        do {
            try quickPrompts.save(to: dirs.quickPromptsPath)
        } catch {
            logger.error("Failed to save quick prompts: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Preference Extraction

    /// Minimum number of completed sessions before an app is eligible
    /// for preference extraction. Prevents generating a "preference
    /// summary" from one or two sessions of noise.
    private static let minSessionsForExtraction = 3

    /// Maximum sessions included in a single extraction. Caps the
    /// input tokens so the call completes in a reasonable time on
    /// local models.
    private static let maxSessionsPerExtraction = 10

    /// Per-session character cap for extraction input. Long prompts/
    /// responses get truncated so a single enormous session can't
    /// consume the entire prompt budget.
    private static let maxSessionCharsForExtraction = 600

    /// Total character cap across all sessions in a single extraction.
    /// Conservative against the 4096-token context window: ~4 chars
    /// per token, with headroom for the instructions, the model's
    /// response, and the chat template overhead.
    private static let maxTotalCharsForExtraction = 6000

    /// Runs preference extraction for every app whose preferences are
    /// stale and whose session count meets the minimum threshold.
    ///
    /// Called from `initializeAsync` on launch, from
    /// `schedulePeriodicExtraction` every 4 hours, and from the UI's
    /// "Regenerate" button (via `regeneratePreferences(for:)`). Extraction
    /// writes the model's prose output directly to
    /// `AppPreference.learnedText` — there is no JSON parsing step.
    ///
    /// Does nothing if:
    /// - No apps are stale
    /// - The LLM service isn't ready
    /// - An app has fewer than `minSessionsForExtraction` sessions
    func maybeExtractPreferences() async {
        let staleKeys = preferences.staleAppKeys(from: history)
        guard !staleKeys.isEmpty else { return }
        guard let llmService else { return }

        for appKey in staleKeys {
            let sessions = history.sessionsForApp(appKey)
            guard sessions.count >= Self.minSessionsForExtraction else {
                logger.debug(
                    "Skipping extraction for '\(appKey)': only \(sessions.count) session(s), need \(Self.minSessionsForExtraction)"
                )
                continue
            }

            await extractPreferences(for: appKey, sessions: sessions, using: llmService)
        }
    }

    /// Immediately extracts preferences for a single app, bypassing the
    /// staleness check. Exposed for the Memory UI's "Regenerate"
    /// button. Safe to call while the periodic loop is running — the
    /// two paths write the same `AppPreference` atomically on the main
    /// actor.
    func regeneratePreferences(for appKey: String) async {
        guard let llmService else {
            logger.warning("Regenerate requested for '\(appKey)' but LLM service not ready")
            return
        }
        let sessions = history.sessionsForApp(appKey)
        guard sessions.count >= Self.minSessionsForExtraction else {
            logger.info(
                "Regenerate declined for '\(appKey)': only \(sessions.count) session(s), need \(Self.minSessionsForExtraction)"
            )
            return
        }
        await extractPreferences(for: appKey, sessions: sessions, using: llmService)
    }

    /// Core extraction for a single app. Deliberately narrow:
    ///
    /// 1. Build a prose-only prompt (no JSON, no structure). Small local
    ///    models produce natural language reliably; asking them to emit
    ///    JSON is where the pre-rewrite system routinely failed.
    /// 2. Call the LLM.
    /// 3. Trim and truncate the result.
    /// 4. Write to disk only if the result is non-empty.
    ///
    /// A failed or empty extraction leaves `lastGenerated` unchanged, so
    /// the app stays stale and is retried on the next extraction cycle.
    /// This is the fix for "preferences stop getting generated": the
    /// previous code stamped `lastGenerated = now` even on parse failure,
    /// locking the app into a 24-hour no-retry window.
    private func extractPreferences(
        for appKey: String,
        sessions: [Session],
        using llmService: LlmService
    ) async {
        let appName = appKeyDisplayName(appKey)
        let extractionPrompt = buildExtractionPrompt(
            appName: appName,
            sessions: Array(sessions.prefix(Self.maxSessionsPerExtraction))
        )

        do {
            let raw = try await llmService.generate(
                systemPrompt: Self.extractionSystemPrompt,
                userPrompt: extractionPrompt
            )
            let cleaned = Self.sanitizeLearnedText(raw)
            guard !cleaned.isEmpty else {
                logger.warning("Extraction for '\(appKey)' produced empty output; leaving stale for retry")
                return
            }
            preferences.setLearnedText(
                appKey,
                learnedText: cleaned,
                sessionsAnalyzed: sessions.count
            )
            try? preferences.save(to: dirs.appRulesPath)
            logger.info("Extracted preferences for '\(appKey)' (\(cleaned.count) chars, \(sessions.count) sessions)")
        } catch {
            let desc = error.localizedDescription
            logger.error("Preference extraction failed for \(appKey, privacy: .public): \(desc, privacy: .public)")
            // Do not mark as generated; app stays stale and retries
            // on the next tick.
        }
    }

    /// System prompt for preference extraction. Short and plain — we
    /// want the model to think about style, not about formatting.
    private static let extractionSystemPrompt = """
    You are an assistant that writes short, plain summaries of a user's \
    writing style. Output only prose. Do not use JSON, bullet points, \
    numbered lists, headers, or markdown formatting of any kind.
    """

    /// Builds the per-extraction user prompt. Keeps session context
    /// compact: just prompt, response, any refinements, and an accepted/
    /// rejected flag. Everything else (timestamps, token counts, etc.)
    /// is noise for a style-summary task.
    private func buildExtractionPrompt(appName: String, sessions: [Session]) -> String {
        let sessionBlocks = sessions.map { session -> String in
            var part = "Prompt: \(session.originalPrompt)\nResponse: \(session.originalResponse)"
            for refinement in session.refinements {
                part += "\nFeedback: \(refinement.feedback)\nRevised: \(refinement.response)"
            }
            if !session.accepted {
                part += "\n(User rejected this output)"
            }
            return part
        }

        return """
        Read these writing sessions from the app "\(appName)" and write a \
        short paragraph (3 to 5 sentences) describing this user's writing \
        preferences for this app. Cover tone, length, formatting habits, \
        and any patterns in what they reject or refine. Write in plain \
        prose. Do not use bullets, numbers, headers, or any markdown.

        Sessions:
        \(sessionBlocks.joined(separator: "\n---\n"))
        """
    }

    /// Trims whitespace, strips obvious formatting artifacts (leading
    /// bullet/number markers, surrounding markdown code fences), and
    /// caps length. Never parses the content — if the model ignored
    /// the "prose only" instruction and emitted bullets, we keep the
    /// text but strip the leading marker characters so the prompt
    /// template renders cleanly.
    static func sanitizeLearnedText(_ raw: String) -> String {
        var text = TextCleanup.stripCodeFences(raw)

        // Flatten to a single prose line. The prompt template injects this
        // verbatim, so a bullet-list fallback still has to read as sentences.
        text = text.components(separatedBy: .newlines)
            .map(TextCleanup.stripListMarker)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > maxLearnedTextLength {
            // Truncate on a word boundary when possible so we don't
            // end mid-word.
            let end = text.index(text.startIndex, offsetBy: maxLearnedTextLength)
            if let lastSpace = text[..<end].lastIndex(where: { $0.isWhitespace }) {
                text = String(text[..<lastSpace])
            } else {
                text = String(text[..<end])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return text
    }

    // MARK: - Prompt Building

    func buildSystemPrompt() -> String {
        guard let originalApp else {
            return "You are a helpful writing assistant."
        }

        let identity = appResolver.resolve(
            bundleId: originalApp.bundleId,
            appName: originalApp.appName,
            windowTitle: originalApp.windowTitle
        )

        let userRules = preferences.userRulesText(identity.appKey)
        let inferred = preferences.getSummary(identity.appKey)

        let context = PromptRenderContext(
            explainMode: explainMode,
            mode: promptMode,
            contextType: identity.contextType,
            appKey: identity.appKey,
            appName: appKeyDisplayName(identity.appKey),
            userRules: userRules,
            inferredPreferences: inferred,
            refinementFeedback: sessionRefinements.map(\.feedback)
        )

        guard let promptStore else {
            return "You are a helpful writing assistant."
        }

        do {
            return try promptStore.render(context: context)
        } catch {
            logger.error("Template render failed: \(error.localizedDescription, privacy: .public)")
            return "You are a helpful writing assistant."
        }
    }

    func buildUserPrompt() -> String {
        guard let selected = selectedText, !selected.isEmpty else {
            return promptText
        }

        switch promptMode {
        case .insert:
            return """
            Context (selected text):
            \"\"\"\
            \(selected)
            \"\"\"

            Instruction: \(promptText)
            """
        case .replace:
            return """
            Selected text:
            \"\"\"\
            \(selected)
            \"\"\"

            Instruction: \(promptText)
            """
        }
    }

    // MARK: - Session History

    func saveSession(accepted: Bool) {
        guard !sessionOriginalPrompt.isEmpty else { return }

        let appKey: String = {
            guard let app = originalApp else { return "unknown" }
            return appResolver.resolve(
                bundleId: app.bundleId,
                appName: app.appName,
                windowTitle: app.windowTitle
            ).appKey
        }()

        // Don't persist sessions for unresolved apps
        guard appKey != "unknown" else { return }

        let session = Session(
            originalPrompt: sessionOriginalPrompt,
            originalResponse: sessionOriginalResponse,
            finalResponse: generatedText,
            accepted: accepted,
            refinements: sessionRefinements,
            appName: originalApp?.appName ?? "Unknown",
            appKey: appKey
        )

        history.addSession(session)
        do {
            try history.save(to: dirs.sessionsPath)
        } catch {
            logger.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }

        // Kick off preference extraction in the background if this app
        // now meets the threshold. `maybeExtractPreferences` re-checks
        // staleness per app, so this is cheap and safe to call after
        // every session — no-op if the app was just extracted.
        //
        // This closes the "preferences stop getting generated" gap:
        // the periodic 4-hour loop alone meant that new apps waited up
        // to 4 hours for their first extraction.
        Task { [weak self] in
            await self?.maybeExtractPreferences()
        }
    }

    // MARK: - Telemetry

    /// Records a feature usage event (fire-and-forget).
    func recordTelemetryFeature(_ feature: TelemetryFeature) {
        guard let telemetryService else { return }
        Task {
            await telemetryService.recordFeature(feature)
        }
    }

    /// Records an error event (fire-and-forget).
    func recordTelemetryError(_ error: TelemetryError) {
        guard let telemetryService else { return }
        Task {
            await telemetryService.recordError(error)
        }
    }

    /// Dismisses the update notification banner and records the dismissal
    /// with the update checker so it won't re-appear for the cooldown period.
    func dismissUpdateNotification() {
        guard let update = availableUpdate, let version = update.latestVersion else {
            availableUpdate = nil
            return
        }
        availableUpdate = nil
        guard let updateChecker else { return }
        Task {
            await updateChecker.dismissVersion(version)
        }
    }

    /// Called when user toggles telemetry off; purges local data.
    func handleTelemetryOptOut() {
        guard let telemetryService else { return }
        Task {
            await telemetryService.purgeLocalData()
        }
    }

    // MARK: - Clipboard Restore

    func restoreClipboard() {
        guard capturedViaClipboard || originalClipboard != nil else { return }

        if let original = originalClipboard {
            Task {
                try? await platformService.setClipboard(original)
            }
        }
        originalClipboard = nil
        capturedViaClipboard = false
    }
}
