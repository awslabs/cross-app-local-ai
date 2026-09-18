import Testing
@testable import FastLang

@Suite("TextCleanup.stripCodeFences")
struct StripCodeFencesTests {

    @Test("unfenced text is returned trimmed")
    func unfencedText() {
        #expect(TextCleanup.stripCodeFences("  hello world  ") == "hello world")
    }

    @Test("empty string stays empty")
    func emptyString() {
        #expect(TextCleanup.stripCodeFences("").isEmpty)
    }

    @Test("whitespace-only string collapses to empty")
    func whitespaceOnly() {
        #expect(TextCleanup.stripCodeFences("   \n\n  ").isEmpty)
    }

    @Test("fully wrapped text is unwrapped")
    func wrappedText() {
        let input = """
        ```
        The user prefers short replies.
        ```
        """
        #expect(TextCleanup.stripCodeFences(input) == "The user prefers short replies.")
    }

    @Test("language tag on the opening fence is discarded")
    func languageTag() {
        let input = """
        ```markdown
        The user prefers short replies.
        ```
        """
        #expect(TextCleanup.stripCodeFences(input) == "The user prefers short replies.")
    }

    @Test("leading whitespace before the fence still unwraps")
    func leadingWhitespaceBeforeFence() {
        let input = "\n  ```\ninner\n```\n"
        #expect(TextCleanup.stripCodeFences(input) == "inner")
    }

    @Test("multiline fence contents keep their newlines")
    func multilineContents() {
        let input = "```\nfirst line\nsecond line\n```"
        #expect(TextCleanup.stripCodeFences(input) == "first line\nsecond line")
    }

    @Test("fence appearing mid-text is left alone")
    func inlineFence() {
        let input = "Prose before ```code``` and after"
        #expect(TextCleanup.stripCodeFences(input) == input)
    }

    @Test("bare opening fence with no closing fence is left alone")
    func unclosedFence() {
        let input = "```\ncontent with no closer"
        #expect(TextCleanup.stripCodeFences(input) == input)
    }

    @Test("lone fence marker is left alone")
    func loneFenceMarker() {
        #expect(TextCleanup.stripCodeFences("```") == "```")
    }

    @Test("adjacent fence markers with no newline are left alone")
    func adjacentFenceMarkers() {
        #expect(TextCleanup.stripCodeFences("``````") == "``````")
    }

    @Test("fence wrapping only whitespace yields empty")
    func fenceWrappingWhitespace() {
        #expect(TextCleanup.stripCodeFences("```\n   \n```").isEmpty)
    }
}

@Suite("TextCleanup.stripListMarker")
struct StripListMarkerTests {

    @Test("hyphen bullet is removed")
    func hyphenBullet() {
        #expect(TextCleanup.stripListMarker("- first item") == "first item")
    }

    @Test("asterisk bullet is removed")
    func asteriskBullet() {
        #expect(TextCleanup.stripListMarker("* first item") == "first item")
    }

    @Test("unicode bullet glyph is removed")
    func unicodeBullet() {
        #expect(TextCleanup.stripListMarker("\u{2022} first item") == "first item")
    }

    @Test("dotted ordered marker is removed")
    func dottedOrderedMarker() {
        #expect(TextCleanup.stripListMarker("1. first item") == "first item")
    }

    @Test("parenthesized ordered marker is removed")
    func parenthesizedOrderedMarker() {
        #expect(TextCleanup.stripListMarker("2) second item") == "second item")
    }

    @Test("multi-digit ordered marker is removed")
    func multiDigitOrderedMarker() {
        #expect(TextCleanup.stripListMarker("12. twelfth item") == "twelfth item")
    }

    @Test("indented marker is removed along with the indentation")
    func indentedMarker() {
        #expect(TextCleanup.stripListMarker("    - nested item") == "nested item")
    }

    @Test("only the first marker is removed")
    func onlyFirstMarker() {
        #expect(TextCleanup.stripListMarker("- - doubled") == "- doubled")
    }

    @Test("plain prose is returned trimmed")
    func plainProse() {
        #expect(TextCleanup.stripListMarker("  just a sentence  ") == "just a sentence")
    }

    @Test("marker without trailing whitespace is not a marker")
    func markerWithoutSpace() {
        #expect(TextCleanup.stripListMarker("-nodash") == "-nodash")
    }

    @Test("mid-line hyphen is preserved")
    func midLineHyphen() {
        #expect(TextCleanup.stripListMarker("well-known phrase") == "well-known phrase")
    }

    @Test("decimal number mid-sentence is preserved")
    func decimalMidSentence() {
        #expect(TextCleanup.stripListMarker("costs 1.50 total") == "costs 1.50 total")
    }

    @Test("empty line stays empty")
    func emptyLine() {
        #expect(TextCleanup.stripListMarker("").isEmpty)
    }
}

@Suite("TextCleanup.collapseBlankLines")
struct CollapseBlankLinesTests {

    @Test("a single blank line between paragraphs is preserved")
    func singleBlankLinePreserved() {
        let input = "First paragraph.\n\nSecond paragraph."
        #expect(TextCleanup.collapseBlankLines(input) == input)
    }

    @Test("two blank lines collapse to one")
    func twoBlankLinesCollapse() {
        let input = "First paragraph.\n\n\nSecond paragraph."
        #expect(TextCleanup.collapseBlankLines(input) == "First paragraph.\n\nSecond paragraph.")
    }

    @Test("many consecutive blank lines collapse to one")
    func manyBlankLinesCollapse() {
        let input = "First paragraph.\n\n\n\n\n\nSecond paragraph."
        #expect(TextCleanup.collapseBlankLines(input) == "First paragraph.\n\nSecond paragraph.")
    }

    @Test("a single newline with no blank line is left alone")
    func singleNewlineUnaffected() {
        let input = "First line.\nSecond line."
        #expect(TextCleanup.collapseBlankLines(input) == input)
    }

    @Test("multiple blank-line runs in the same text are each collapsed")
    func multipleRunsCollapse() {
        let input = "One.\n\n\nTwo.\n\n\n\nThree."
        #expect(TextCleanup.collapseBlankLines(input) == "One.\n\nTwo.\n\nThree.")
    }

    @Test("empty string stays empty")
    func emptyString() {
        #expect(TextCleanup.collapseBlankLines("").isEmpty)
    }

    @Test("text without any newlines is unaffected")
    func noNewlines() {
        #expect(TextCleanup.collapseBlankLines("just one line") == "just one line")
    }
}

@Suite("TextCleanup.collapseInteriorSpaces")
struct CollapseInteriorSpacesTests {

    @Test("a single space between words is preserved")
    func singleSpacePreserved() {
        let input = "one two three"
        #expect(TextCleanup.collapseInteriorSpaces(input) == input)
    }

    @Test("two consecutive spaces collapse to one")
    func twoSpacesCollapse() {
        #expect(TextCleanup.collapseInteriorSpaces("one  two") == "one two")
    }

    @Test("many consecutive spaces collapse to one")
    func manySpacesCollapse() {
        #expect(TextCleanup.collapseInteriorSpaces("one          two") == "one two")
    }

    @Test("multiple separate runs in the same text are each collapsed")
    func multipleRunsCollapse() {
        #expect(TextCleanup.collapseInteriorSpaces("one  two   three") == "one two three")
    }

    @Test("newlines are left alone, so lines are never merged")
    func newlinesUnaffected() {
        let input = "first line\nsecond line"
        #expect(TextCleanup.collapseInteriorSpaces(input) == input)
    }

    @Test("tabs are left alone")
    func tabsUnaffected() {
        let input = "one\ttwo"
        #expect(TextCleanup.collapseInteriorSpaces(input) == input)
    }

    @Test("empty string stays empty")
    func emptyString() {
        #expect(TextCleanup.collapseInteriorSpaces("").isEmpty)
    }
}
