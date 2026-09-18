import Foundation
import Testing
@testable import FastLang

/// Builds a race-free `AppState` for tests that `await` mid-test: unlike the
/// production `init()`, this skips `initializeAsync()` / `initializeTelemetry()`,
/// so no background `Task` can race with test assertions or overwrite
/// `llmService` after injection.
@MainActor
private func makeTestAppState() -> AppState {
    let dirs = AppDirs.withRoot(URL(fileURLWithPath: "/tmp/qg-readaloud-tests"))
    return AppState(
        config: Config(),
        dirs: dirs,
        platformService: MacPlatformService(),
        audioRecorder: AudioRecorder(),
        agent: BackgroundAgent(),
        appResolver: AppResolver(mappings: AppMappingsData.defaultMappings),
        promptStore: nil
    )
}

@Suite("AppState.setReadAloudText")
@MainActor
struct SetReadAloudTextTests {

    @Test("sets the read-aloud text")
    func setsText() {
        let state = AppState()
        state.setReadAloudText("Hello world.")
        #expect(state.readAloudText == "Hello world.")
    }

    @Test("resets playback state to idle")
    func resetsPlaybackState() {
        let state = AppState()
        state.readAloudPlaybackState = .playing
        state.setReadAloudText("New text.")
        #expect(state.readAloudPlaybackState == .idle)
    }

    @Test("clears the highlight range from the previous text")
    func clearsHighlightRange() {
        let state = AppState()
        state.readAloudHighlightRange = 0 ..< 5
        state.setReadAloudText("New text.")
        #expect(state.readAloudHighlightRange == nil)
    }

    @Test("cancels and clears any in-flight read-aloud task")
    func cancelsInFlightTask() {
        let state = AppState()
        state.readAloudTask = Task {}
        state.setReadAloudText("New text.")
        #expect(state.readAloudTask == nil)
    }

    @Test("leaves the read-aloud rate untouched so mid-session adjustments survive a swap")
    func leavesRateUntouched() {
        let state = AppState()
        state.readAloudRate = 0.9
        state.setReadAloudText("New text.")
        #expect(state.readAloudRate == 0.9)
    }
}

@Suite("AppState.summarizeReadAloudText")
@MainActor
struct SummarizeReadAloudTextTests {

    @Test("no-ops when rendition is already summarized")
    func noOpWhenAlreadySummarized() async {
        let state = makeTestAppState()
        state.readAloudOriginalText = "Hello world."
        state.readAloudRendition = .summarized
        state.summarizeReadAloudText()
        #expect(state.readAloudPreprocessTask == nil)
        #expect(state.readAloudSummarizeState == .idle)
    }

    @Test("no-ops when a summarize is already in progress")
    func noOpWhenAlreadyInProgress() async {
        let state = makeTestAppState()
        state.readAloudOriginalText = "Hello world."
        state.readAloudSummarizeState = .inProgress(completed: 0, total: 1)
        state.summarizeReadAloudText()
        #expect(state.readAloudPreprocessTask == nil)
    }

    @Test("no-ops when there is no original text")
    func noOpWhenOriginalTextNil() async {
        let state = makeTestAppState()
        state.readAloudOriginalText = nil
        state.summarizeReadAloudText()
        #expect(state.readAloudPreprocessTask == nil)
    }

    @Test("no-ops when the original text is empty")
    func noOpWhenOriginalTextEmpty() async {
        let state = makeTestAppState()
        state.readAloudOriginalText = ""
        state.summarizeReadAloudText()
        #expect(state.readAloudPreprocessTask == nil)
    }

    @Test("fails with a clear message when the LLM service is not initialized")
    func failsWhenLlmServiceMissing() async {
        let state = makeTestAppState()
        state.readAloudOriginalText = "Hello world."
        state.llmService = nil

        state.summarizeReadAloudText()
        await state.readAloudPreprocessTask?.value

        #expect(state.readAloudSummarizeState == .failed("LLM service not initialized. Check model settings."))
        #expect(state.readAloudRendition == .original)
    }

    @Test("replaces the read-aloud text with the mock summary on success")
    func succeedsWithMockLlmService() async {
        let state = makeTestAppState()
        state.readAloudOriginalText = "Hello world."
        state.llmService = await LlmService(config: LlmServiceConfig(mockMode: true))

        state.summarizeReadAloudText()
        await state.readAloudPreprocessTask?.value

        #expect(state.readAloudText == "Mock response to: Hello world.")
        #expect(state.readAloudRendition == .summarized)
        #expect(state.readAloudSummarizeState == .idle)
    }
}

@Suite("AppState.restoreOriginalReadAloudText")
@MainActor
struct RestoreOriginalReadAloudTextTests {

    @Test("swaps back to the original text and rendition")
    func restoresOriginalText() {
        let state = makeTestAppState()
        state.readAloudOriginalText = "Hello world."
        state.readAloudRendition = .summarized
        state.setReadAloudText("A summary.")

        state.restoreOriginalReadAloudText()

        #expect(state.readAloudText == "Hello world.")
        #expect(state.readAloudRendition == .original)
    }

    @Test("resets the summarize state to idle")
    func resetsSummarizeState() {
        let state = makeTestAppState()
        state.readAloudOriginalText = "Hello world."
        state.readAloudRendition = .summarized
        state.readAloudSummarizeState = .inProgress(completed: 1, total: 2)

        state.restoreOriginalReadAloudText()

        #expect(state.readAloudSummarizeState == .idle)
    }

    @Test("cancels and clears any in-flight preprocess task")
    func cancelsInFlightPreprocessTask() {
        let state = makeTestAppState()
        state.readAloudPreprocessTask = Task {}

        state.restoreOriginalReadAloudText()

        #expect(state.readAloudPreprocessTask == nil)
    }

    @Test("no-ops on text/rendition when rendition is already original")
    func noOpWhenAlreadyOriginal() {
        let state = makeTestAppState()
        state.readAloudOriginalText = "Hello world."
        state.readAloudRendition = .original
        state.setReadAloudText("Untouched.")

        state.restoreOriginalReadAloudText()

        #expect(state.readAloudText == "Untouched.")
        #expect(state.readAloudRendition == .original)
    }

    @Test("no-ops when there is no original text to restore")
    func noOpWhenOriginalTextNil() {
        let state = makeTestAppState()
        state.readAloudOriginalText = nil
        state.readAloudRendition = .summarized
        state.setReadAloudText("A summary.")

        state.restoreOriginalReadAloudText()

        #expect(state.readAloudText == "A summary.")
        #expect(state.readAloudRendition == .summarized)
    }
}
