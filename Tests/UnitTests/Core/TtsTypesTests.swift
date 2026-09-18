import Foundation
import Testing
@testable import FastLang

@Suite("TextChunking")
struct TextChunkingTests {

    // MARK: - splitIntoSentences

    @Test("splits text into sentences preserving offsets")
    func splitIntoSentencesBasic() {
        let text = "Hello world. Goodbye world."
        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 0)
        #expect(chunks.count == 2)
        #expect(chunks[0].text == "Hello world. ")
        #expect(chunks[0].offset == 0)
        #expect(chunks[1].text == "Goodbye world.")
        #expect(chunks[1].offset == 13)
    }

    @Test("splitIntoSentences with non-zero base offset")
    func splitIntoSentencesWithBaseOffset() {
        let text = "First. Second."
        let chunks = TextChunking.splitIntoSentences(text, baseOffset: 100)
        #expect(chunks.count == 2)
        #expect(chunks[0].offset == 100)
        #expect(chunks[1].offset == 107)
    }

    @Test("splitIntoSentences with empty text returns empty")
    func splitIntoSentencesEmpty() {
        let chunks = TextChunking.splitIntoSentences("", baseOffset: 0)
        #expect(chunks.isEmpty)
    }

    // MARK: - waterfallChunk

    /// Simple token counter: counts words (split by whitespace).
    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    @Test("waterfallChunk returns single chunk when text fits budget")
    func waterfallChunkFitsBudget() {
        let text = "Hello world"
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 10
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Hello world")
        #expect(chunks[0].offset == 0)
    }

    @Test("waterfallChunk splits at sentence-ending punctuation")
    func waterfallChunkSplitsAtSentenceEnd() {
        let text = "First sentence. Second sentence here. Third part."
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 5
        )
        // "First sentence." = 2 words, "Second sentence here." = 3, "Third part." = 2
        // With max 5, "First sentence. Second sentence here." = 5 words fits
        // Adding "Third part." = 7 exceeds -> split
        #expect(chunks.count >= 2)
        for chunk in chunks {
            let tokens = wordCount(chunk.text)
            #expect(tokens <= 5, "Chunk '\(chunk.text)' has \(tokens) tokens, exceeds budget of 5")
        }
    }

    @Test("waterfallChunk splits at comma when sentence-enders absent")
    func waterfallChunkSplitsAtComma() {
        let text = "one two three, four five six, seven eight nine"
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 5
        )
        #expect(chunks.count >= 2)
        for chunk in chunks {
            let tokens = wordCount(chunk.text)
            #expect(tokens <= 5, "Chunk '\(chunk.text)' has \(tokens) tokens, exceeds budget of 5")
        }
    }

    @Test("waterfallChunk falls back to greedy word split when no punctuation")
    func waterfallChunkGreedyFallback() {
        let text = "alpha bravo charlie delta echo foxtrot golf hotel india"
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 4
        )
        #expect(chunks.count >= 2)
        for chunk in chunks {
            let tokens = wordCount(chunk.text)
            #expect(tokens <= 4, "Chunk '\(chunk.text)' has \(tokens) tokens, exceeds budget of 4")
        }
    }

    @Test("waterfallChunk preserves base offset in chunk offsets")
    func waterfallChunkPreservesBaseOffset() {
        let text = "Hello world, this is a longer test text"
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 50, tokenCount: wordCount, maxTokens: 4
        )
        #expect(chunks.count >= 2)
        #expect(chunks[0].offset >= 50)
        // Each chunk offset should point to the correct position in the original text
        for chunk in chunks {
            let localOffset = chunk.offset - 50
            #expect(localOffset >= 0)
            #expect(localOffset < text.count)
        }
    }

    @Test("waterfallChunk returns empty for empty text")
    func waterfallChunkEmpty() {
        let chunks = TextChunking.waterfallChunk(
            "", baseOffset: 0, tokenCount: wordCount, maxTokens: 10
        )
        #expect(chunks.isEmpty)
    }

    @Test("waterfallChunk prefers latest break point (maximizes fill)")
    func waterfallChunkMaximizesFill() {
        // With budget of 6 words, text has commas at various positions.
        // The algorithm should find the LATEST comma that keeps the chunk under budget.
        let text = "a, b, c, d, e, f, g, h"
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 6
        )
        // First chunk should contain as many words as possible up to a comma boundary
        #expect(chunks.count >= 2)
        let firstTokens = wordCount(chunks[0].text)
        #expect(firstTokens >= 4, "First chunk should maximize fill, got \(firstTokens) words")
        #expect(firstTokens <= 6)
    }

    @Test("waterfallChunk handles bump characters after break")
    func waterfallChunkBumpCharacters() {
        // Closing quote after a period should stay with the preceding chunk
        let text = "She said \"hello.\" Then she left quickly afterwards"
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 5
        )
        #expect(chunks.count >= 2)
        for chunk in chunks {
            let tokens = wordCount(chunk.text)
            // Allow slight budget overshoot from bump character inclusion
            #expect(tokens <= 6, "Chunk '\(chunk.text)' has \(tokens) tokens, exceeds budget + bump")
        }
    }

    @Test("waterfallChunk concatenation reconstructs original text")
    func waterfallChunkLossless() {
        let text = "The quick brown fox, jumps over the lazy dog. And then it ran away quickly."
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 5
        )
        let reconstructed = chunks.map(\.text).joined(separator: " ")
        // Waterfall trims whitespace from chunks, so reconstruction may differ in spacing.
        // Verify all words are preserved.
        let originalWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let reconstructedWords = reconstructed.split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(originalWords == reconstructedWords, "Word content should be preserved")
    }

    @Test("waterfallChunk handles semicolons and colons")
    func waterfallChunkClauseSeparators() {
        let text = "introduction here; main point follows: the conclusion wraps up everything"
        let chunks = TextChunking.waterfallChunk(
            text, baseOffset: 0, tokenCount: wordCount, maxTokens: 5
        )
        #expect(chunks.count >= 2)
        for chunk in chunks {
            let tokens = wordCount(chunk.text)
            #expect(tokens <= 5, "Chunk '\(chunk.text)' has \(tokens) tokens")
        }
    }
}

@Suite("ReadAloudRendition")
struct ReadAloudRenditionTests {

    @Test("original equals original")
    func originalEqualsOriginal() {
        #expect(ReadAloudRendition.original == .original)
    }

    @Test("summarized equals summarized")
    func summarizedEqualsSummarized() {
        #expect(ReadAloudRendition.summarized == .summarized)
    }

    @Test("original does not equal summarized")
    func originalNotEqualSummarized() {
        #expect(ReadAloudRendition.original != .summarized)
    }
}

@Suite("ReadAloudSummarizeState")
struct ReadAloudSummarizeStateTests {

    @Test("idle equals idle")
    func idleEqualsIdle() {
        #expect(ReadAloudSummarizeState.idle == .idle)
    }

    @Test("inProgress states with matching counts are equal")
    func inProgressEqualWithMatchingCounts() {
        #expect(ReadAloudSummarizeState.inProgress(completed: 1, total: 3) == .inProgress(completed: 1, total: 3))
    }

    @Test("inProgress states with different counts are not equal")
    func inProgressNotEqualWithDifferentCounts() {
        #expect(ReadAloudSummarizeState.inProgress(completed: 1, total: 3) != .inProgress(completed: 2, total: 3))
    }

    @Test("failed states with matching messages are equal")
    func failedEqualWithMatchingMessage() {
        #expect(ReadAloudSummarizeState.failed("oops") == .failed("oops"))
    }

    @Test("failed states with different messages are not equal")
    func failedNotEqualWithDifferentMessage() {
        #expect(ReadAloudSummarizeState.failed("oops") != .failed("different"))
    }

    @Test("different cases are not equal")
    func differentCasesNotEqual() {
        #expect(ReadAloudSummarizeState.idle != .inProgress(completed: 0, total: 1))
        #expect(ReadAloudSummarizeState.idle != .failed("oops"))
    }
}
