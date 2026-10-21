import Foundation

// MARK: - Reset, Alert Presentation

extension AppState {

    // MARK: - Reset

    /// Resets session-scoped state. Called when overlay hides.
    func resetSessionState() {
        promptText = ""
        selectedText = nil
        generatedText = ""
        isGenerating = false
        isRefining = false
        errorMessage = nil
        errorSuggestedAction = nil
        overlayState = .input
        sessionOriginalPrompt = ""
        sessionOriginalResponse = ""
        sessionRefinements = []
        previousGeneratedText = ""
        originalApp = nil
        contextType = .generic
        originalClipboard = nil
        capturedViaClipboard = false
        promptMode = .insert
        explainMode = false
    }

    /// Sets the text to be read aloud and resets playback so a stale
    /// word-highlight range from the previous text can't survive the swap.
    ///
    /// The single choke point for updating `readAloudText`. Used both for
    /// the initially captured selection and, later, for swapping in a
    /// preprocessed or summarized rendition -- it intentionally leaves
    /// `readAloudRate` untouched so a mid-session rate adjustment survives
    /// a rendition swap.
    ///
    /// - Parameter text: The text to display and speak.
    func setReadAloudText(_ text: String) {
        readAloudTask?.cancel()
        readAloudTask = nil
        readAloudPlaybackState = .idle
        readAloudHighlightRange = nil
        readAloudText = text
    }

    /// Resets read-aloud session state.
    func resetReadAloudState() {
        readAloudTask?.cancel()
        readAloudTask = nil
        readAloudPreprocessTask?.cancel()
        readAloudPreprocessTask = nil
        readAloudText = nil
        readAloudOriginalText = nil
        readAloudRendition = .original
        readAloudSummarizeState = .idle
        readAloudHighlightRange = nil
        readAloudPlaybackState = .idle
        readAloudErrorMessage = nil
        isReadAloudVisible = false
    }

    /// Full reset including services. Used for error recovery.
    func reset() {
        isOverlayVisible = false
        isRecording = false
        resetSessionState()
        resetReadAloudState()
        Task {
            // resetReadAloudState() cancels the read-aloud task and clears the
            // UI, but it does not stop the audio engine or finish the playback
            // stream. Explicitly stop TTS so audio doesn't keep playing after
            // an error-recovery reset and the session continuation isn't leaked.
            await ttsService?.stop()
            await agent.forceReset()
        }
    }

    // MARK: - Alert Presentation

    /// Shows a native macOS alert dialog with a title and body message.
    ///
    /// - Parameters:
    ///   - title: Short heading for the alert (e.g. "Speech Recognition").
    ///   - body: Descriptive message explaining the issue and any suggested action.
    func presentAlert(title: String, body: String) {
        alertTitle = title
        alertBody = body
        isAlertPresented = true
    }
}
