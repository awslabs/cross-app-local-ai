import Foundation
import Testing
@testable import FastLang

@Suite("HighlightedTextBuilder")
struct HighlightedTextBuilderTests {

    // MARK: - Tokenization

    @Test("tokenize splits words on whitespace")
    func tokenizeSplitsWords() {
        let tokens = HighlightedTextBuilder.tokenize("hello world")
        #expect(tokens.count == 2)
        #expect(tokens[0].text == "hello")
        #expect(tokens[0].offset == 0)
        #expect(tokens[1].text == "world")
        #expect(tokens[1].offset == 6)
    }

    @Test("tokenize handles multiple spaces between words")
    func tokenizeMultipleSpaces() {
        let tokens = HighlightedTextBuilder.tokenize("a   b")
        #expect(tokens.count == 2)
        #expect(tokens[0].text == "a")
        #expect(tokens[0].offset == 0)
        #expect(tokens[1].text == "b")
        #expect(tokens[1].offset == 4)
    }

    @Test("tokenize returns empty array for empty string")
    func tokenizeEmpty() {
        let tokens = HighlightedTextBuilder.tokenize("")
        #expect(tokens.isEmpty)
    }

    @Test("tokenize returns empty array for whitespace-only string")
    func tokenizeWhitespaceOnly() {
        let tokens = HighlightedTextBuilder.tokenize("   ")
        #expect(tokens.isEmpty)
    }

    @Test("tokenize preserves punctuation attached to words")
    func tokenizeWithPunctuation() {
        let tokens = HighlightedTextBuilder.tokenize("hello, world!")
        #expect(tokens.count == 2)
        #expect(tokens[0].text == "hello,")
        #expect(tokens[1].text == "world!")
    }

    // MARK: - Paragraph Splitting

    @Test("splitParagraphs splits on newlines")
    func splitParagraphsOnNewlines() {
        let paragraphs = HighlightedTextBuilder.splitParagraphs("line one\nline two")
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].text == "line one\n")
        #expect(paragraphs[0].offset == 0)
        #expect(paragraphs[1].text == "line two")
        #expect(paragraphs[1].offset == 9)
    }

    @Test("splitParagraphs returns empty for empty string")
    func splitParagraphsEmpty() {
        let paragraphs = HighlightedTextBuilder.splitParagraphs("")
        #expect(paragraphs.isEmpty)
    }

    @Test("splitParagraphs handles single paragraph without newline")
    func splitParagraphsSingle() {
        let paragraphs = HighlightedTextBuilder.splitParagraphs("just one line")
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].text == "just one line")
        #expect(paragraphs[0].offset == 0)
    }

    @Test("splitParagraphs handles trailing newline")
    func splitParagraphsTrailingNewline() {
        let paragraphs = HighlightedTextBuilder.splitParagraphs("hello\n")
        #expect(paragraphs.count == 1)
        #expect(paragraphs[0].text == "hello\n")
        #expect(paragraphs[0].offset == 0)
    }

    // MARK: - Paragraph ID

    @Test("paragraphID returns correct paragraph for character offset")
    func paragraphIDFindsCorrectParagraph() {
        let paragraphs = [
            HighlightedTextBuilder.Paragraph(text: "first\n", offset: 0),
            HighlightedTextBuilder.Paragraph(text: "second\n", offset: 6),
            HighlightedTextBuilder.Paragraph(text: "third", offset: 13),
        ]

        #expect(HighlightedTextBuilder.paragraphID(containing: 0, in: paragraphs) == 0)
        #expect(HighlightedTextBuilder.paragraphID(containing: 3, in: paragraphs) == 0)
        #expect(HighlightedTextBuilder.paragraphID(containing: 6, in: paragraphs) == 6)
        #expect(HighlightedTextBuilder.paragraphID(containing: 15, in: paragraphs) == 13)
    }

    @Test("paragraphID returns first offset for empty paragraphs")
    func paragraphIDEmptyFallback() {
        let id = HighlightedTextBuilder.paragraphID(containing: 5, in: [])
        #expect(id == 0)
    }

    // MARK: - Attributed String Building

    @Test("buildAttributedString produces correct character count")
    func buildAttributedStringLength() {
        let text = "hello world"
        let words = HighlightedTextBuilder.tokenize(text)
        let result = HighlightedTextBuilder.buildAttributedString(
            sourceText: text,
            words: words,
            highlightRange: nil,
            paragraphOffset: 0
        )

        #expect(String(result.characters) == text)
    }

    @Test("buildAttributedString preserves text with highlight active")
    func buildAttributedStringWithHighlight() {
        let text = "one two three"
        let words = HighlightedTextBuilder.tokenize(text)
        let result = HighlightedTextBuilder.buildAttributedString(
            sourceText: text,
            words: words,
            highlightRange: 4 ..< 7,
            paragraphOffset: 0
        )

        #expect(String(result.characters) == text)
    }

    @Test("highlighted word does not receive a bold font override")
    func highlightedWordHasNoFontOverride() {
        let text = "one two three"
        let words = HighlightedTextBuilder.tokenize(text)
        let result = HighlightedTextBuilder.buildAttributedString(
            sourceText: text,
            words: words,
            highlightRange: 4 ..< 7,
            paragraphOffset: 0
        )

        let twoStart = result.characters.index(result.startIndex, offsetBy: 4)
        let container = result[twoStart ..< result.characters.index(twoStart, offsetBy: 3)]
        #expect(container.font == nil)
    }

    @Test("highlighted word receives white foreground and accent background")
    func highlightedWordColors() {
        let text = "one two three"
        let words = HighlightedTextBuilder.tokenize(text)
        let result = HighlightedTextBuilder.buildAttributedString(
            sourceText: text,
            words: words,
            highlightRange: 4 ..< 7,
            paragraphOffset: 0
        )

        let twoStart = result.characters.index(result.startIndex, offsetBy: 4)
        let container = result[twoStart ..< result.characters.index(twoStart, offsetBy: 3)]
        #expect(container.foregroundColor == .white)
        #expect(container.backgroundColor != nil)
    }

    @Test("words carry seek links")
    func wordsHaveSeekLinks() {
        let text = "alpha beta"
        let words = HighlightedTextBuilder.tokenize(text)
        let result = HighlightedTextBuilder.buildAttributedString(
            sourceText: text,
            words: words,
            highlightRange: nil,
            paragraphOffset: 0
        )

        let alphaStart = result.startIndex
        let alphaSlice = result[alphaStart ..< result.characters.index(alphaStart, offsetBy: 5)]
        #expect(alphaSlice.link == URL(string: "seek://0"))

        let betaStart = result.characters.index(result.startIndex, offsetBy: 6)
        let betaSlice = result[betaStart ..< result.characters.index(betaStart, offsetBy: 4)]
        #expect(betaSlice.link == URL(string: "seek://6"))
    }

    @Test("buildAttributedString handles paragraph offset correctly")
    func buildAttributedStringWithParagraphOffset() {
        let fullText = "first paragraph\nsecond paragraph"
        let allWords = HighlightedTextBuilder.tokenize(fullText)
        let paragraphs = HighlightedTextBuilder.splitParagraphs(fullText)

        let secondParagraph = paragraphs[1]
        let wordsInSecond = allWords.filter { word in
            word.offset >= secondParagraph.offset
                && word.offset < secondParagraph.offset + secondParagraph.text.count
        }

        let result = HighlightedTextBuilder.buildAttributedString(
            sourceText: secondParagraph.text,
            words: wordsInSecond,
            highlightRange: 16 ..< 22,
            paragraphOffset: secondParagraph.offset
        )

        #expect(String(result.characters) == "second paragraph")
    }
}
