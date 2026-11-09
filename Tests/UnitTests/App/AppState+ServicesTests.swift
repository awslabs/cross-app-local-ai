import Foundation
import Testing
@testable import FastLang

/// Builds a race-free `AppState` for tests that `await` mid-test: unlike the
/// production `init()`, this skips `initializeAsync()` / `initializeTelemetry()`,
/// so no background `Task` can race with test assertions or overwrite
/// `sttService` after injection. Mirrors `AppState+ReadAloudTests.swift`.
@MainActor
private func makeTestAppState() -> AppState {
    let dirs = AppDirs.withRoot(URL(fileURLWithPath: "/tmp/qg-appstate-services-tests"))
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

@Suite("AppState.handleSttHotkeyReleased")
@MainActor
struct HandleSttHotkeyReleasedTests {

    /// Regression test for the bug where a push-to-talk session whose every
    /// audio buffer stayed below the warmup silence threshold (e.g. a
    /// Bluetooth input mid-codec-switch) left `AudioRecorder.recordedBuffer()`
    /// nil, and the transcribing pill simply vanished with no feedback. A
    /// never-started real `AudioRecorder` deterministically returns `nil`
    /// from `recordedBuffer()`, so setting `isRecording = true` directly
    /// (bypassing the real mic-start flow) reproduces the exact branch
    /// without needing a mock.
    @Test("surfaces a noAudioCaptured notice when no audio was recorded")
    func surfacesNoAudioCapturedNotice() async {
        let state = makeTestAppState()
        state.isRecording = true

        await state.handleSttHotkeyReleased()

        #expect(state.sttIndicatorNotice?.kind == .error)
        #expect(state.sttIndicatorNotice?.text.contains("No audio was captured") == true)
        #expect(!state.isRecording)
        #expect(state.sttTargetApp == nil)
    }

    @Test("does nothing when not recording")
    func noOpWhenNotRecording() async {
        let state = makeTestAppState()
        state.isRecording = false

        await state.handleSttHotkeyReleased()

        #expect(state.sttIndicatorNotice == nil)
    }

    /// Regression test for the "Possible False Error Notice" review finding:
    /// a nil `recordedBuffer()` used to always show the `noAudioCaptured`
    /// notice, even for a trivial accidental tap released before the first
    /// tap callback ever fires. Forcing a short `recordingDuration()` on the
    /// same never-started `AudioRecorder` reproduces that case without real
    /// mic hardware, and the handler must now discard it silently instead.
    @Test("discards silently when the hold was shorter than the minimum duration")
    func discardsSilentlyOnTrivialTap() async {
        let state = makeTestAppState()
        state.isRecording = true
        state.audioRecorder.setRecordingDurationForTesting(0.04)

        await state.handleSttHotkeyReleased()

        #expect(state.sttIndicatorNotice == nil)
        #expect(!state.isRecording)
        #expect(state.sttTargetApp == nil)
    }
}

@Suite("AppState.handleAiSearchReleased")
@MainActor
struct HandleAiSearchReleasedTests {

    /// Same zero-audio regression as `handleSttHotkeyReleased`, but for the
    /// voice-to-Google-AI path, which has its own independent recorded-buffer
    /// check and notice-surfacing logic.
    @Test("surfaces a noAudioCaptured notice when no audio was recorded")
    func surfacesNoAudioCapturedNotice() async {
        let state = makeTestAppState()
        state.isRecording = true

        await state.handleAiSearchReleased()

        #expect(state.sttIndicatorNotice?.kind == .error)
        #expect(state.sttIndicatorNotice?.text.contains("No audio was captured") == true)
        #expect(!state.isRecording)
        #expect(state.sttTargetApp == nil)
    }

    @Test("flags an early release when the hotkey is released before recording started")
    func flagsEarlyReleaseWhenNotRecording() async {
        let state = makeTestAppState()
        state.isRecording = false

        await state.handleAiSearchReleased()

        #expect(state.aiSearchReleasedEarly)
    }

    /// Same short-tap regression as `handleSttHotkeyReleased`, exercised
    /// against the independent AI-search nil-buffer branch.
    @Test("discards silently when the hold was shorter than the minimum duration")
    func discardsSilentlyOnTrivialTap() async {
        let state = makeTestAppState()
        state.isRecording = true
        state.audioRecorder.setRecordingDurationForTesting(0.04)

        await state.handleAiSearchReleased()

        #expect(state.sttIndicatorNotice == nil)
        #expect(!state.isRecording)
        #expect(state.sttTargetApp == nil)
    }
}
