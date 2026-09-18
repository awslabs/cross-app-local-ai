import Foundation
import Testing
@testable import FastLang

@Suite("MockTtsProvider")
struct MockTtsProviderTests {

    @Test("providerName is Mock TTS")
    func providerNameIsMockTts() {
        let provider = MockTtsProvider()
        #expect(provider.providerName == "Mock TTS")
    }

    @Test("speak emits word boundaries then finished")
    func speakEmitsWordBoundaries() async throws {
        let provider = MockTtsProvider()
        let request = TtsSynthesisRequest(
            text: "Hello world",
            voice: nil,
            rate: 0.5,
            startOffset: 0
        )

        let stream = try await provider.speak(request)

        var wordEvents: [WordTiming] = []
        var didFinish = false

        for try await event in stream {
            switch event {
            case let .wordBoundary(timing):
                wordEvents.append(timing)
            case .finished:
                didFinish = true
            case .cancelled:
                break
            }
        }

        #expect(wordEvents.count == 2)
        #expect(didFinish)
    }

    @Test("speak with startOffset skips leading text")
    func speakWithStartOffset() async throws {
        let provider = MockTtsProvider()
        let request = TtsSynthesisRequest(
            text: "Hello world test",
            voice: nil,
            rate: 0.5,
            startOffset: 6
        )

        let stream = try await provider.speak(request)
        var wordEvents: [WordTiming] = []

        for try await event in stream {
            if case let .wordBoundary(timing) = event {
                wordEvents.append(timing)
            }
        }

        #expect(wordEvents.count == 2)
        #expect(wordEvents[0].range.lowerBound == 6)
    }

    @Test("tokenize splits text and computes correct offsets")
    func tokenizeComputesCorrectOffsets() {
        let timings = MockTtsProvider.tokenize("Hello world", baseOffset: 0)
        #expect(timings.count == 2)
        #expect(timings[0].range == 0 ..< 5)
        #expect(timings[1].range == 6 ..< 11)
    }

    @Test("tokenize applies baseOffset to ranges")
    func tokenizeAppliesBaseOffset() {
        let timings = MockTtsProvider.tokenize("world test", baseOffset: 6)
        #expect(timings.count == 2)
        #expect(timings[0].range == 6 ..< 11)
        #expect(timings[1].range == 12 ..< 16)
    }

    @Test("tokenize handles empty string")
    func tokenizeEmptyString() {
        let timings = MockTtsProvider.tokenize("", baseOffset: 0)
        #expect(timings.isEmpty)
    }

    @Test("tokenize handles multiple whitespace")
    func tokenizeMultipleWhitespace() {
        let timings = MockTtsProvider.tokenize("  hello   world  ", baseOffset: 0)
        #expect(timings.count == 2)
        #expect(timings[0].range == 2 ..< 7)
        #expect(timings[1].range == 10 ..< 15)
    }

    @Test("availableVoices returns one mock voice")
    func availableVoicesReturnsMockVoice() async {
        let provider = MockTtsProvider()
        let voices = await provider.availableVoices()
        #expect(voices.count == 1)
        #expect(voices[0].id == "mock-default")
        #expect(voices[0].language == "en-US")
    }

    @Test("validate does not throw")
    func validateSucceeds() async throws {
        let provider = MockTtsProvider()
        try await provider.validate()
    }
}
