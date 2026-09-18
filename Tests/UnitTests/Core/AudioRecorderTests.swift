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
