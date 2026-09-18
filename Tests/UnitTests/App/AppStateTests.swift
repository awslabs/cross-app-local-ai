import Testing
@testable import FastLang

@Suite("AppState")
@MainActor
struct AppStateTests {

    // MARK: - UIEvent Handling

    @Test("handleEvent showOverlay sets overlay visible in input state")
    func showOverlayEvent() {
        let state = AppState()
        state.handleEvent(.showOverlay)
        #expect(state.isOverlayVisible)
        #expect(state.overlayState == .input)
        #expect(state.generatedText.isEmpty)
        #expect(state.errorMessage == nil)
        #expect(!state.isGenerating)
    }

    @Test("handleEvent hideOverlay resets all overlay state")
    func hideOverlayEvent() {
        let state = AppState()
        state.isOverlayVisible = true
        state.promptText = "test"
        state.selectedText = "selected"
        state.generatedText = "generated"
        state.isGenerating = true
        state.errorMessage = "error"

        state.handleEvent(.hideOverlay)
        #expect(!state.isOverlayVisible)
        #expect(state.promptText.isEmpty)
        #expect(state.selectedText == nil)
        #expect(state.generatedText.isEmpty)
        #expect(!state.isGenerating)
        #expect(state.errorMessage == nil)
        #expect(state.overlayState == .input)
    }

    @Test("handleEvent streamChunk accumulates text and sets generating state")
    func streamChunkEvent() {
        let state = AppState()
        state.handleEvent(.streamChunk("Hello "))
        #expect(state.generatedText == "Hello ")
        #expect(state.isGenerating)
        #expect(state.overlayState == .generating)

        state.handleEvent(.streamChunk("world"))
        #expect(state.generatedText == "Hello world")
    }

    @Test("handleEvent streamComplete transitions to approval")
    func streamCompleteEvent() {
        let state = AppState()
        state.isGenerating = true
        state.handleEvent(.streamComplete)
        #expect(!state.isGenerating)
        #expect(state.overlayState == .approval)
    }

    @Test("handleEvent streamError presents alert")
    func streamErrorEvent() {
        let state = AppState()
        state.isGenerating = true
        state.handleEvent(.streamError("timeout"))
        #expect(!state.isGenerating)
        #expect(state.isAlertPresented)
        #expect(state.alertTitle == "Generation")
        #expect(state.alertBody == "timeout")
    }

    // MARK: - Reset

    @Test("reset clears all state")
    func resetClearsAll() {
        let state = AppState()
        state.isOverlayVisible = true
        state.isRecording = true
        state.promptText = "test"
        state.generatedText = "gen"
        state.isGenerating = true
        state.errorMessage = "err"

        state.reset()
        #expect(!state.isOverlayVisible)
        #expect(!state.isRecording)
        #expect(state.promptText.isEmpty)
        #expect(state.generatedText.isEmpty)
        #expect(!state.isGenerating)
        #expect(state.errorMessage == nil)
        #expect(state.overlayState == .input)
    }

    // MARK: - hideOverlay

    @Test("hideOverlay resets overlay state")
    func hideOverlayResetsState() async {
        let state = AppState()
        state.isOverlayVisible = true
        state.generatedText = "text"
        state.isGenerating = true

        await state.hideOverlay()
        #expect(!state.isOverlayVisible)
        #expect(state.generatedText.isEmpty)
        #expect(!state.isGenerating)
    }

    // MARK: - Config and Data Integrity

    @Test("default config loads with expected values")
    func defaultConfig() {
        let state = AppState()
        #expect(state.config.llm.defaultProvider == "local_llamacpp")
        #expect(state.config.hotkeys.triggerOverlay == "Option+Space")
        #expect(state.config.hotkeys.pushToTalk == "Cmd+Shift+Z")
    }

    @Test("default quickPrompts has expected count")
    func defaultQuickPrompts() {
        #expect(QuickPrompts.defaults.prompts.count == 3)
    }

    // MARK: - Download State

    @Test("cancelDownload clears download state")
    func cancelDownloadClearsState() {
        let state = AppState()
        state.downloadState = .active(modelId: "test", percent: 50)
        state.cancelDownload()
        #expect(state.downloadState == nil)
    }

    // MARK: - Event Handling Sequence

    @Test("full event sequence: show -> stream chunks -> complete -> hide")
    func fullEventSequence() {
        let state = AppState()

        state.handleEvent(.showOverlay)
        #expect(state.isOverlayVisible)
        #expect(state.overlayState == .input)

        state.handleEvent(.streamChunk("token1 "))
        #expect(state.isGenerating)
        #expect(state.overlayState == .generating)

        state.handleEvent(.streamChunk("token2"))
        #expect(state.generatedText == "token1 token2")

        state.handleEvent(.streamComplete)
        #expect(!state.isGenerating)
        #expect(state.overlayState == .approval)

        state.handleEvent(.hideOverlay)
        #expect(!state.isOverlayVisible)
        #expect(state.overlayState == .input)
    }

    @Test("error event sequence: show -> stream chunks -> error")
    func errorEventSequence() {
        let state = AppState()

        state.handleEvent(.showOverlay)
        state.handleEvent(.streamChunk("partial"))
        state.handleEvent(.streamError("connection reset"))

        #expect(!state.isGenerating)
        #expect(state.isAlertPresented)
        #expect(state.alertTitle == "Generation")
        #expect(state.alertBody == "connection reset")
        #expect(state.generatedText == "partial")
    }

    // MARK: - STT Indicator Notice

    @Test("sttIndicatorNotice defaults to nil")
    func sttIndicatorNoticeDefaultsToNil() {
        let state = AppState()
        #expect(state.sttIndicatorNotice == nil)
    }

    @Test("sttIndicatorNotice can be set and cleared")
    func sttIndicatorNoticeCanBeSetAndCleared() {
        let state = AppState()
        state.sttIndicatorNotice = SttIndicatorNotice(
            text: "Accessibility permission is required. Grant access in System Settings",
            kind: .error
        )
        #expect(state.sttIndicatorNotice != nil)
        #expect(state.sttIndicatorNotice?.text.contains("Accessibility") == true)
        #expect(state.sttIndicatorNotice?.kind == .error)

        state.sttIndicatorNotice = nil
        #expect(state.sttIndicatorNotice == nil)
    }

    @Test("resetSessionState does not clear sttIndicatorNotice")
    func resetSessionStatePreservesSttNotice() {
        let state = AppState()
        let notice = SttIndicatorNotice(text: "Error message", kind: .error)
        state.sttIndicatorNotice = notice
        state.resetSessionState()
        #expect(state.sttIndicatorNotice == notice)
    }
}

// MARK: - sanitizeLearnedText

/// Characterization coverage for the learned-preference sanitizer. It shares
/// `TextCleanup` primitives with other consumers but keeps its own policy:
/// flatten every line into a single prose blob and truncate to the prompt
/// budget. These tests pin that policy so the shared primitives can evolve
/// without silently changing what gets injected into prompts.
@Suite("AppState.sanitizeLearnedText")
@MainActor
struct SanitizeLearnedTextTests {

    @Test("plain prose is returned trimmed")
    func plainProse() {
        let result = AppState.sanitizeLearnedText("  The user prefers short replies.  ")
        #expect(result == "The user prefers short replies.")
    }

    @Test("empty input yields empty output")
    func emptyInput() {
        #expect(AppState.sanitizeLearnedText("").isEmpty)
    }

    @Test("whitespace-only input yields empty output")
    func whitespaceOnlyInput() {
        #expect(AppState.sanitizeLearnedText("  \n\n \t ").isEmpty)
    }

    @Test("wrapping code fence is unwrapped")
    func codeFenceUnwrapped() {
        let raw = """
        ```
        The user prefers short replies.
        ```
        """
        #expect(AppState.sanitizeLearnedText(raw) == "The user prefers short replies.")
    }

    @Test("newlines are flattened into spaces")
    func newlinesFlattened() {
        let raw = "First sentence.\nSecond sentence."
        #expect(AppState.sanitizeLearnedText(raw) == "First sentence. Second sentence.")
    }

    @Test("bullet list is flattened into a single prose line")
    func bulletListFlattened() {
        let raw = """
        - Prefers terse replies.
        - Avoids exclamation marks.
        """
        #expect(AppState.sanitizeLearnedText(raw) == "Prefers terse replies. Avoids exclamation marks.")
    }

    @Test("numbered list markers are stripped")
    func numberedListStripped() {
        let raw = "1. Terse replies.\n2) No emoji."
        #expect(AppState.sanitizeLearnedText(raw) == "Terse replies. No emoji.")
    }

    @Test("blank lines between paragraphs do not leave double spaces")
    func blankLinesCollapsed() {
        let raw = "First paragraph.\n\nSecond paragraph."
        #expect(AppState.sanitizeLearnedText(raw) == "First paragraph. Second paragraph.")
    }

    @Test("text within the length cap is not truncated")
    func withinLengthCap() {
        let raw = String(repeating: "word ", count: 10)
        let result = AppState.sanitizeLearnedText(raw)
        #expect(result.count < maxLearnedTextLength)
        #expect(result.hasSuffix("word"))
    }

    @Test("overlong text is truncated on a word boundary")
    func truncatedOnWordBoundary() {
        let raw = String(repeating: "word ", count: 400)
        let result = AppState.sanitizeLearnedText(raw)
        #expect(result.count <= maxLearnedTextLength)
        #expect(result.hasSuffix("word"))
        #expect(!result.hasSuffix(" "))
    }

    @Test("overlong text with no whitespace is hard-cut at the cap")
    func truncatedWithoutWordBoundary() {
        let raw = String(repeating: "a", count: maxLearnedTextLength + 500)
        let result = AppState.sanitizeLearnedText(raw)
        #expect(result.count == maxLearnedTextLength)
    }
}
