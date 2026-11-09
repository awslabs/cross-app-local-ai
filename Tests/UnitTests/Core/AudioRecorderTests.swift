import Foundation
import Testing
@testable import FastLang

@Suite("AudioRecorder")
struct AudioRecorderTests {

    // MARK: - MockAudioRecorder

    @Test("mock recorder yields preconfigured chunks")
    func mockYieldsChunks() async throws {
        let recorder = MockAudioRecorder()
        let sampleData = Data(repeating: 42, count: 640)
        await recorder.setChunks([
            AudioChunk(data: sampleData, timestamp: 0.0),
            AudioChunk(data: sampleData, timestamp: 0.04),
        ])

        let stream = try await recorder.start()
        var chunks: [AudioChunk] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        #expect(chunks.count == 2)
        #expect(chunks[0].data.count == 640)
        #expect(chunks[1].timestamp == 0.04)
    }

    @Test("mock recorder returns accumulated buffer")
    func mockReturnsBuffer() async throws {
        let recorder = MockAudioRecorder()
        let sampleData = Data(repeating: 1, count: 320)
        await recorder.setChunks([
            AudioChunk(data: sampleData, timestamp: 0.0),
        ])

        let stream = try await recorder.start()
        for await _ in stream {}

        let buffer = await recorder.recordedBuffer()
        #expect(buffer != nil)
        #expect(buffer?.data.count == 320)
        #expect(buffer?.meta.sampleRate == .wideband)
        #expect(buffer?.meta.channels == .mono)
        #expect(buffer?.meta.format == .pcm)
    }

    @Test("mock recorder returns nil buffer when no chunks")
    func mockReturnsNilBufferWhenEmpty() async throws {
        let recorder = MockAudioRecorder()
        let stream = try await recorder.start()
        for await _ in stream {}

        let buffer = await recorder.recordedBuffer()
        #expect(buffer == nil)
    }

    @Test("mock recorder throws on start when configured to fail")
    func mockThrowsOnStart() async {
        let recorder = MockAudioRecorder()
        await recorder.setShouldFailOnStart(true)

        await #expect(throws: SttError.self) {
            _ = try await recorder.start()
        }
    }

    @Test("mock recorder stop is safe to call")
    func mockStopIsSafe() async {
        let recorder = MockAudioRecorder()
        await recorder.stop()
    }

    // MARK: - AudioRecorderState

    @Test("AudioRecorderState has expected cases")
    func stateHasCases() {
        let idle: AudioRecorderState = .idle
        let recording: AudioRecorderState = .recording
        let stopping: AudioRecorderState = .stopping

        #expect(idle != recording)
        #expect(recording != stopping)
    }

    // MARK: - updatePreferredDevice

    /// Regression test for the bug where picking a different microphone in
    /// Settings (e.g. a Bluetooth headset that connected after launch) had
    /// no effect until the app restarted: `AudioRecorder` was constructed
    /// once at startup with whatever device was configured at that moment,
    /// and `start()` kept using the stale device forever after. The fix
    /// moved `preferredDeviceUID` into lock-protected mutable state so
    /// `updatePreferredDevice` can change it live.
    ///
    /// Sets `prewarmOverride` first so the real detached `prewarm()` never
    /// fires — without it, this call would spawn an unawaited `Task`
    /// touching real `AVAudioEngine`/CoreAudio hardware, which is flaky on
    /// CI runners with no input device and can trigger a real Bluetooth
    /// profile switch on a dev machine.
    @Test("updatePreferredDevice persists the new device UID")
    func updatePreferredDevicePersistsUID() {
        let recorder = AudioRecorder(preferredDeviceUID: "original-uid")
        recorder.prewarmOverride = {}
        recorder.updatePreferredDevice(uid: "bluetooth-headset-uid")
        #expect(recorder.currentPreferredDeviceUID == "bluetooth-headset-uid")
    }

    @Test("updatePreferredDevice can clear back to the system default")
    func updatePreferredDeviceClearsToSystemDefault() {
        let recorder = AudioRecorder(preferredDeviceUID: "original-uid")
        recorder.prewarmOverride = {}
        recorder.updatePreferredDevice(uid: nil)
        #expect(recorder.currentPreferredDeviceUID == nil)
    }

    /// Regression test for the "Unsynchronized Prewarm" review finding:
    /// `updatePreferredDevice` used to spawn a detached `prewarm()`
    /// unconditionally, including while a recording was in progress.
    /// `prewarm()` opens a second `AVAudioEngine`/AUHAL against the same
    /// hardware a live session is using, risking an unwanted Bluetooth
    /// profile renegotiation mid-capture — the exact glitch this feature
    /// exists to avoid. The fix skips the re-warm while `state != .idle`.
    @Test("updatePreferredDevice skips the re-warm while a recording is in progress")
    func updatePreferredDeviceSkipsPrewarmWhileRecording() {
        let recorder = AudioRecorder(preferredDeviceUID: "original-uid")
        recorder.setStateForTesting(.recording)

        var prewarmCallCount = 0
        recorder.prewarmOverride = { prewarmCallCount += 1 }

        recorder.updatePreferredDevice(uid: "bluetooth-headset-uid")

        #expect(recorder.currentPreferredDeviceUID == "bluetooth-headset-uid")
        #expect(prewarmCallCount == 0)
    }

    @Test("updatePreferredDevice skips the re-warm when the UID hasn't changed")
    func updatePreferredDeviceSkipsPrewarmWhenUnchanged() {
        let recorder = AudioRecorder(preferredDeviceUID: "same-uid")

        var prewarmCallCount = 0
        recorder.prewarmOverride = { prewarmCallCount += 1 }

        recorder.updatePreferredDevice(uid: "same-uid")

        #expect(prewarmCallCount == 0)
    }

    @Test("updatePreferredDevice re-warms when idle and the UID changed")
    func updatePreferredDeviceRewarmsWhenIdleAndChanged() {
        let recorder = AudioRecorder(preferredDeviceUID: "original-uid")

        var prewarmCallCount = 0
        recorder.prewarmOverride = { prewarmCallCount += 1 }

        recorder.updatePreferredDevice(uid: "bluetooth-headset-uid")

        #expect(prewarmCallCount == 1)
    }

    // MARK: - shouldRewarmNow

    /// Regression test for the "Unsynchronized Prewarm" follow-up review
    /// finding: the detached re-warm task re-checks idle state immediately
    /// before calling `prewarm()`, narrowing the window where a concurrent
    /// `start()` could have begun recording between `updatePreferredDevice`'s
    /// initial check and the detached task actually running. This tests the
    /// recheck's logic directly (no `Task.detached` timing involved).
    @Test("shouldRewarmNow is true while idle")
    func shouldRewarmNowTrueWhileIdle() {
        let recorder = AudioRecorder()
        #expect(recorder.shouldRewarmNow())
    }

    @Test("shouldRewarmNow is false while recording")
    func shouldRewarmNowFalseWhileRecording() {
        let recorder = AudioRecorder()
        recorder.setStateForTesting(.recording)
        #expect(!recorder.shouldRewarmNow())
    }

    @Test("shouldRewarmNow is false while stopping")
    func shouldRewarmNowFalseWhileStopping() {
        let recorder = AudioRecorder()
        recorder.setStateForTesting(.stopping)
        #expect(!recorder.shouldRewarmNow())
    }

    // MARK: - recordingDuration

    @Test("recordingDuration is nil before any session completes")
    func recordingDurationNilBeforeAnySession() async {
        let recorder = AudioRecorder()
        let duration = await recorder.recordingDuration()
        #expect(duration == nil)
    }

    @Test("recordingDuration reflects a forced test value")
    func recordingDurationReflectsForcedValue() async {
        let recorder = AudioRecorder()
        recorder.setRecordingDurationForTesting(0.04)
        let duration = await recorder.recordingDuration()
        #expect(duration == 0.04)
    }
}

// MARK: - Test Helpers

extension MockAudioRecorder {
    func setChunks(_ newChunks: [AudioChunk]) {
        chunks = newChunks
    }

    func setShouldFailOnStart(_ shouldFail: Bool) {
        shouldFailOnStart = shouldFail
    }
}
