import Testing
@testable import FastLang

@Suite("SpeechTextSanitizer.sanitize")
struct SpeechTextSanitizerTests {

    @Test("plain prose is returned trimmed")
    func plainProse() {
        #expect(SpeechTextSanitizer.sanitize("  The quick brown fox.  ") == "The quick brown fox.")
    }

    @Test("empty input yields empty output")
    func emptyInput() {
        #expect(SpeechTextSanitizer.sanitize("").isEmpty)
    }

    @Test("whitespace-only input yields empty output")
    func whitespaceOnlyInput() {
        #expect(SpeechTextSanitizer.sanitize("  \n\n \t ").isEmpty)
    }

    @Test("wrapping code fence is unwrapped")
    func codeFenceUnwrapped() {
        let raw = """
        ```
        The quick brown fox.
        ```
        """
        #expect(SpeechTextSanitizer.sanitize(raw) == "The quick brown fox.")
    }

    @Test("newlines between paragraphs are preserved, not flattened")
    func newlinesPreserved() {
        let raw = "First paragraph.\nSecond paragraph."
        #expect(SpeechTextSanitizer.sanitize(raw) == "First paragraph.\nSecond paragraph.")
    }

    @Test("blank lines between paragraphs are preserved as paragraph breaks")
    func blankLinesPreserved() {
        let raw = "First paragraph.\n\nSecond paragraph."
        #expect(SpeechTextSanitizer.sanitize(raw) == "First paragraph.\n\nSecond paragraph.")
    }

    @Test("bullet list markers are stripped but lines stay separate")
    func bulletListMarkersStripped() {
        let raw = "- First item.\n- Second item."
        #expect(SpeechTextSanitizer.sanitize(raw) == "First item.\nSecond item.")
    }

    @Test("numbered list markers are stripped but lines stay separate")
    func numberedListMarkersStripped() {
        let raw = "1. First item.\n2) Second item."
        #expect(SpeechTextSanitizer.sanitize(raw) == "First item.\nSecond item.")
    }

    @Test("leading and trailing blank lines are trimmed")
    func leadingTrailingBlankLinesTrimmed() {
        let raw = "\n\nContent here.\n\n"
        #expect(SpeechTextSanitizer.sanitize(raw) == "Content here.")
    }

    @Test("multiline fenced content keeps its internal newlines")
    func multilineFencedContentKeepsNewlines() {
        let raw = "```\nfirst line\nsecond line\n```"
        #expect(SpeechTextSanitizer.sanitize(raw) == "first line\nsecond line")
    }

    @Test("a fence wrapping a list preserves line breaks between items")
    func fencedListPreservesLineBreaks() {
        let raw = "```\n- one\n- two\n```"
        #expect(SpeechTextSanitizer.sanitize(raw) == "one\ntwo")
    }

    @Test("excess blank lines between paragraphs collapse to one")
    func excessBlankLinesCollapsed() {
        let raw = "First paragraph.\n\n\n\nSecond paragraph."
        #expect(SpeechTextSanitizer.sanitize(raw) == "First paragraph.\n\nSecond paragraph.")
    }

    @Test("repeated interior spaces collapse to one")
    func repeatedInteriorSpacesCollapsed() {
        let raw = "The   quick brown    fox."
        #expect(SpeechTextSanitizer.sanitize(raw) == "The quick brown fox.")
    }

    @Test("repeated interior spaces collapse independently on each line")
    func repeatedInteriorSpacesCollapsedAcrossLines() {
        let raw = "First  line.\nSecond   line."
        #expect(SpeechTextSanitizer.sanitize(raw) == "First line.\nSecond line.")
    }
}
