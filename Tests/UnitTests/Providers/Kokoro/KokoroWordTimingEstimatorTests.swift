import Testing
@testable import FastLang

// MARK: - Tokenization

@Suite("WordTokenizer")
struct TokenizationTests {

    @Test("tokenizes simple words")
    func simpleWords() {
        let words = WordTokenizer.tokenize("Hello world", baseOffset: 0)

        #expect(words.count == 2)
        #expect(words[0].range == 0 ..< 5)
        #expect(words[1].range == 6 ..< 11)
    }

    @Test("applies base offset to all ranges")
    func baseOffsetApplied() {
        let words = WordTokenizer.tokenize("Hello world", baseOffset: 50)

        #expect(words.count == 2)
        #expect(words[0].range == 50 ..< 55)
        #expect(words[1].range == 56 ..< 61)
    }

    @Test("skips leading whitespace")
    func leadingWhitespace() {
        let words = WordTokenizer.tokenize("   Hello", baseOffset: 0)

        #expect(words.count == 1)
        #expect(words[0].range == 3 ..< 8)
    }

    @Test("skips trailing whitespace")
    func trailingWhitespace() {
        let words = WordTokenizer.tokenize("Hello   ", baseOffset: 0)

        #expect(words.count == 1)
        #expect(words[0].range == 0 ..< 5)
    }

    @Test("handles multiple spaces between words")
    func multipleSpaces() {
        let words = WordTokenizer.tokenize("A    B", baseOffset: 0)

        #expect(words.count == 2)
        #expect(words[0].range == 0 ..< 1)
        #expect(words[1].range == 5 ..< 6)
    }

    @Test("empty text returns empty array")
    func emptyText() {
        let words = WordTokenizer.tokenize("", baseOffset: 0)
        #expect(words.isEmpty)
    }

    @Test("whitespace-only text returns empty array")
    func whitespaceOnly() {
        let words = WordTokenizer.tokenize("   \t  ", baseOffset: 0)
        #expect(words.isEmpty)
    }

    @Test("single word is tokenized correctly")
    func singleWord() {
        let words = WordTokenizer.tokenize("Hello", baseOffset: 0)

        #expect(words.count == 1)
        #expect(words[0].range == 0 ..< 5)
    }

    @Test("punctuation stays attached to words")
    func punctuation() {
        let words = WordTokenizer.tokenize("Hello, world!", baseOffset: 0)

        #expect(words.count == 2)
        #expect(words[0].range == 0 ..< 6)
        #expect(words[1].range == 7 ..< 13)
    }
}
