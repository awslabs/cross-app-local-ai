import Foundation
import Testing
@testable import FastLang

@Suite("MockSttProvider")
struct MockSttProviderTests {

    @Test("providerName is Mock STT")
    func providerNameIsMockStt() {
        let provider = MockSttProvider()
        #expect(provider.providerName == "Mock STT")
    }

    @Test("transcribe returns text containing byte count")
    func transcribeReturnsByteCount() async throws {
        let provider = MockSttProvider()
        let audio = AudioBuffer(
            meta: AudioMeta(format: .pcm, sampleRate: .wideband, channels: .mono),
            data: Data(repeating: 0, count: 1600)
        )

        let result = try await provider.transcribe(audio)
        #expect(result.text.contains("1600"))
        #expect(result.language == "en")
        #expect(result.confidence == 0.95)
    }

    @Test("transcribeStream yields partial and final events")
    func transcribeStreamYieldsEvents() async throws {
        let provider = MockSttProvider()

        let (audioStream, continuation) = AsyncStream<AudioChunk>.makeStream()

        // Send two chunks then finish
        continuation.yield(AudioChunk(data: Data([1, 2, 3]), timestamp: 0.0))
        continuation.yield(AudioChunk(data: Data([4, 5, 6]), timestamp: 0.1))
        continuation.finish()

        let eventStream = try await provider.transcribeStream(audio: audioStream)

        var partialCount = 0
        var finalEvent: Transcription?

        for try await event in eventStream {
            switch event {
            case .partial:
                partialCount += 1
            case let .final(transcription):
                finalEvent = transcription
            }
        }

        #expect(partialCount == 2)
        let final = try #require(finalEvent)
        #expect(final.text.contains("2 chunks"))
        #expect(final.language == "en")
    }

    @Test("supportedLanguages returns expected languages")
    func supportedLanguagesReturnsExpected() {
        let provider = MockSttProvider()
        let languages = provider.supportedLanguages()
        #expect(languages.count == 5)
        #expect(languages.contains("en"))
        #expect(languages.contains("ja"))
    }

    @Test("validate does not throw")
    func validateSucceeds() async throws {
        let provider = MockSttProvider()
        try await provider.validate()
    }
}
