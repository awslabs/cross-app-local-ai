import Testing
@testable import FastLang

// MARK: - Sentence Splitting

@Suite("TextChunking")
struct SentenceSplittingTests {

    @Test("splits simple sentences with correct offsets")
    func simpleSentences() {
        let text = "Hello world. This is a test."
        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 0)

        #expect(chunks.count == 2)
        #expect(chunks[0].text == "Hello world. ")
        #expect(chunks[0].offset == 0)
        #expect(chunks[1].text == "This is a test.")
        #expect(chunks[1].offset == 13)
    }

    @Test("offsets are global when baseOffset is non-zero")
    func baseOffsetApplied() {
        let text = "First sentence. Second sentence."
        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 100)

        #expect(chunks.count == 2)
        #expect(chunks[0].offset == 100)
        #expect(chunks[1].offset == 100 + 16)
    }

    @Test("empty text returns empty array")
    func emptyText() {
        let chunks = TextChunking.splitIntoSentences("", baseOffset: 0)
        #expect(chunks.isEmpty)
    }

    @Test("text without punctuation falls back to single chunk")
    func noPunctuation() {
        let text = "hello world without any punctuation"
        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 0)

        #expect(chunks.count == 1)
        #expect(chunks[0].text == text)
        #expect(chunks[0].offset == 0)
    }

    @Test("preserves newlines in sentence boundaries")
    func preservesNewlines() {
        let text = "First sentence.\nSecond sentence.\n"
        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 0)

        #expect(chunks.count >= 2)

        let reconstructed = chunks.map(\.text).joined()
        #expect(reconstructed == text)
    }

    @Test("reconstruction is lossless")
    func losslessReconstruction() {
        let text = """
        The quick brown fox jumped. Over the lazy dog.

        A new paragraph begins here. And continues with more text.
        Final thoughts follow.
        """

        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 0)
        let reconstructed = chunks.map(\.text).joined()

        #expect(reconstructed == text)
    }

    @Test("handles many sentences for large text")
    func manyChunks() {
        let text = (0 ..< 100).map { "This is sentence number \($0). " }.joined()

        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 0)

        #expect(chunks.count >= 90)
        #expect(chunks[0].offset == 0)

        let lastChunk = chunks[chunks.count - 1]
        #expect(lastChunk.offset > 0)
        #expect(lastChunk.offset < text.count)
    }

    @Test("offsets increase monotonically")
    func monotonicOffsets() {
        let text = "Alpha. Beta. Gamma. Delta. Epsilon."
        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 50)

        for i in 1 ..< chunks.count {
            #expect(chunks[i].offset > chunks[i - 1].offset)
        }
    }
}

// MARK: - Rate Mapping

@Suite("AVSpeechTtsProvider Rate Mapping")
struct RateMappingTests {

    @Test("zero maps to minimum speech rate")
    func zeroRate() {
        let rate = AVSpeechTtsProvider.mapRate(0.0)
        #expect(rate >= 0.0)
        #expect(rate < 0.1)
    }

    @Test("one maps to maximum speech rate")
    func maxRate() {
        let rate = AVSpeechTtsProvider.mapRate(1.0)
        #expect(rate > 0.5)
    }

    @Test("0.5 maps to midpoint")
    func midRate() {
        let low = AVSpeechTtsProvider.mapRate(0.0)
        let high = AVSpeechTtsProvider.mapRate(1.0)
        let mid = AVSpeechTtsProvider.mapRate(0.5)

        let expectedMid = (low + high) / 2.0
        #expect(abs(mid - expectedMid) < 0.001)
    }

    @Test("values outside 0..1 are clamped")
    func clampedRate() {
        let belowZero = AVSpeechTtsProvider.mapRate(-0.5)
        let aboveOne = AVSpeechTtsProvider.mapRate(1.5)
        let atZero = AVSpeechTtsProvider.mapRate(0.0)
        let atOne = AVSpeechTtsProvider.mapRate(1.0)

        #expect(belowZero == atZero)
        #expect(aboveOne == atOne)
    }
}
