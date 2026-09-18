import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "agent")

/// The heart of FastLang. Orchestrates the user flow as a deterministic state machine.
///
/// `actor` guarantees serial access to mutable state. Callers `await` every method call.
/// The `@MainActor` `AppState` observes agent state changes and updates the UI.
actor BackgroundAgent {
    private(set) var state: AgentState = .idle
    private var originalClipboard: String?

    // MARK: - Hotkey

    /// Called when the overlay hotkey is pressed.
    ///
    /// Only transitions from `.idle` to `.contextCapture`. Ignored in all other states
    /// (debounce behavior -- prevents double-tap from triggering duplicate flows).
    ///
    /// - Returns: `true` if the transition succeeded, `false` if ignored.
    @discardableResult
    func onHotkeyPressed() -> Bool {
        guard case .idle = state else {
            logger.debug("Hotkey ignored, agent is in \(String(describing: self.state))")
            return false
        }
        state = .contextCapture
        logger.info("State: idle -> contextCapture")
        return true
    }

    // MARK: - Context Capture

    /// Called after the platform layer captures the active app and selection.
    ///
    /// Transitions from `.contextCapture` to `.awaitingPrompt`.
    ///
    /// - Parameters:
    ///   - contextType: The resolved context type for the active app.
    ///   - selectedText: The text selected in the target app, if any.
    ///   - originalApp: The app context at the time of hotkey activation.
    /// - Returns: A `UIEvent` to show the overlay, or `nil` if the state was invalid.
    func onContextCaptured(
        contextType: ContextType,
        selectedText: String?,
        originalApp: AppContext
    ) -> UIEvent? {
        guard case .contextCapture = state else {
            logger.warning("onContextCaptured called in invalid state: \(String(describing: self.state))")
            return nil
        }
        state = .awaitingPrompt(
            contextType: contextType,
            selectedText: selectedText,
            originalApp: originalApp
        )
        logger.info("State: contextCapture -> awaitingPrompt")
        return .showOverlay
    }

    // MARK: - UI Messages

    /// Handles a message from the UI layer.
    ///
    /// - Parameter message: The UI event to process.
    /// - Returns: A `UIEvent` if the UI should update, or `nil` for invalid transitions.
    func handleUIMessage(_ message: UIMessage) -> UIEvent? {
        switch message {
        case .promptSubmitted:
            handlePromptSubmitted()
        case .generationCancelled:
            handleCancellation()
        case .textAccepted:
            handleTextAccepted()
        case .textRejected:
            handleTextRejected()
        case .refinementSubmitted:
            handleRefinementSubmitted()
        }
    }

    private func handlePromptSubmitted() -> UIEvent? {
        guard case let .awaitingPrompt(contextType, _, originalApp) = state else {
            logger.warning("promptSubmitted in invalid state: \(String(describing: self.state))")
            return nil
        }
        state = .generating(
            contextType: contextType,
            originalApp: originalApp,
            generatedText: ""
        )
        logger.info("State: awaitingPrompt -> generating")
        return nil
    }

    private func handleCancellation() -> UIEvent? {
        switch state {
        case .awaitingPrompt, .generating:
            state = .idle
            logger.info("State: \(String(describing: self.state)) -> idle (cancelled)")
            return .hideOverlay
        default:
            logger.warning("generationCancelled in invalid state: \(String(describing: self.state))")
            return nil
        }
    }

    private func handleTextAccepted() -> UIEvent? {
        guard case let .awaitingAction(_, originalApp, generatedText) = state else {
            logger.warning("textAccepted in invalid state: \(String(describing: self.state))")
            return nil
        }
        state = .injecting(originalApp: originalApp, text: generatedText)
        logger.info("State: awaitingAction -> injecting")
        return .hideOverlay
    }

    private func handleTextRejected() -> UIEvent? {
        guard case .awaitingAction = state else {
            logger.warning("textRejected in invalid state: \(String(describing: self.state))")
            return nil
        }
        state = .idle
        logger.info("State: awaitingAction -> idle (rejected)")
        return .hideOverlay
    }

    private func handleRefinementSubmitted() -> UIEvent? {
        guard case let .awaitingAction(contextType, originalApp, _) = state else {
            logger.warning("refinementSubmitted in invalid state: \(String(describing: self.state))")
            return nil
        }
        state = .generating(
            contextType: contextType,
            originalApp: originalApp,
            generatedText: ""
        )
        logger.info("State: awaitingAction -> generating (refinement)")
        return nil
    }

    // MARK: - LLM Stream Events

    /// Called when the LLM emits a text chunk during streaming.
    ///
    /// Accumulates text in the `.generating` state.
    ///
    /// - Parameter text: The new text chunk from the LLM.
    /// - Returns: A `.streamChunk` event, or `nil` if not in the generating state.
    func onStreamChunk(_ text: String) -> UIEvent? {
        guard case .generating(let contextType, let originalApp, var accumulated) = state else {
            logger.warning("onStreamChunk in invalid state: \(String(describing: self.state))")
            return nil
        }
        accumulated += text
        state = .generating(
            contextType: contextType,
            originalApp: originalApp,
            generatedText: accumulated
        )
        return .streamChunk(text)
    }

    /// Called when the LLM stream completes successfully.
    ///
    /// Transitions from `.generating` to `.awaitingAction`.
    ///
    /// - Parameter usage: Token consumption for this generation.
    /// - Returns: A `.streamComplete` event, or `nil` if not in the generating state.
    func onStreamComplete(usage: TokenUsage) -> UIEvent? {
        guard case let .generating(contextType, originalApp, generatedText) = state else {
            logger.warning("onStreamComplete in invalid state: \(String(describing: self.state))")
            return nil
        }
        state = .awaitingAction(
            contextType: contextType,
            originalApp: originalApp,
            generatedText: generatedText
        )
        let input = usage.inputTokens
        let output = usage.outputTokens
        logger.info("State: generating -> awaitingAction (input: \(input), output: \(output) tokens)")
        return .streamComplete
    }

    /// Called when the LLM stream fails.
    ///
    /// Resets to `.idle`.
    ///
    /// - Parameter message: The error message.
    /// - Returns: A `.streamError` event, or `nil` if not in the generating state.
    func onStreamError(_ message: String) -> UIEvent? {
        guard case .generating = state else {
            logger.warning("onStreamError in invalid state: \(String(describing: self.state))")
            return nil
        }
        state = .idle
        logger.error("State: generating -> idle (error: \(message, privacy: .public))")
        return .streamError(message)
    }

    // MARK: - Injection

    /// Called after text injection into the target app completes.
    ///
    /// - Parameter success: Whether the injection succeeded.
    func onInjectionComplete(success: Bool) {
        guard case .injecting = state else {
            logger.warning("onInjectionComplete in invalid state: \(String(describing: self.state))")
            return
        }
        state = .idle
        if success {
            logger.info("State: injecting -> idle (injection succeeded)")
        } else {
            logger.warning("State: injecting -> idle (injection failed)")
        }
    }

    // MARK: - Clipboard Preservation

    /// Stores the original clipboard content before capture replaces it.
    func storeClipboard(_ content: String?) {
        originalClipboard = content
    }

    /// Returns the stored clipboard content, if any.
    var storedClipboard: String? {
        originalClipboard
    }

    /// Clears the stored clipboard.
    func clearStoredClipboard() {
        originalClipboard = nil
    }

    // MARK: - Reset

    /// Forces the agent back to idle. Used for error recovery.
    func forceReset() {
        let previous = state
        state = .idle
        originalClipboard = nil
        logger.warning("Force reset from \(String(describing: previous)) -> idle")
    }
}
