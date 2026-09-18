import Foundation

// MARK: - TextCleanup

/// Narrow, composable primitives for making raw text safe to hand to another
/// consumer -- a prompt template, a speech synthesizer, an on-screen panel.
///
/// Each function performs exactly one removal and nothing else. Callers own
/// the surrounding policy, because that policy genuinely differs: the
/// preference extractor flattens everything into one prose line and truncates
/// to a prompt budget, while a speech sanitizer has to preserve newlines so
/// read-aloud scroll-follow can key off paragraph offsets. Folding either
/// policy in here would make the primitives useless to the other caller.
enum TextCleanup {

    /// Leading list marker: a bullet glyph or an ordered-list number, plus the
    /// whitespace separating it from the content.
    private static let listMarkerPattern = #"^[\-\*•]\s+|^\d+[\.\)]\s+"#

    /// Three or more consecutive newlines: two or more blank lines in a row.
    /// A single blank line is exactly two newlines (one paragraph break) and
    /// is left untouched.
    private static let blankLineRunPattern = #"\n{3,}"#

    /// Two or more consecutive plain spaces.
    private static let interiorSpaceRunPattern = " {2,}"

    /// Trims surrounding whitespace and unwraps a fenced code block when the
    /// text is wrapped in one.
    ///
    /// Small local models frequently default to "code mode" and wrap prose in
    /// triple backticks. Only a fence opening at the very start is unwrapped;
    /// an inline fence partway through is left alone, since treating it as the
    /// opener would silently drop everything before it.
    ///
    /// - Parameter text: Raw text, typically straight from a model.
    /// - Returns: The fence contents when the text is wrapped, otherwise the
    ///   input with surrounding whitespace trimmed.
    static func stripCodeFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        guard let closing = trimmed.range(of: "```", options: .backwards),
              closing.lowerBound > trimmed.startIndex
        else { return trimmed }

        // The opening fence and its optional language tag run to the end of
        // the first line, so content starts after that newline. `offsetBy: 3`
        // is safe: `hasPrefix("```")` guarantees at least three characters.
        let afterOpen = trimmed.index(trimmed.startIndex, offsetBy: 3)
        guard let newlineAfterOpen = trimmed[afterOpen...].firstIndex(where: { $0.isNewline })
        else { return trimmed }

        let contentStart = trimmed.index(after: newlineAfterOpen)
        return String(trimmed[contentStart ..< closing.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a leading bullet or ordered-list marker from a single line.
    ///
    /// - Parameter line: One line of text.
    /// - Returns: The line trimmed of surrounding whitespace, with any leading
    ///   list marker removed.
    static func stripListMarker(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespaces)
        if let marker = cleaned.range(of: listMarkerPattern, options: .regularExpression) {
            cleaned.removeSubrange(marker)
        }
        return cleaned
    }

    /// Collapses runs of two or more blank lines down to exactly one.
    ///
    /// A single blank line is a paragraph break and is preserved -- only
    /// runs of two or more are excessive whitespace worth removing.
    ///
    /// - Parameter text: Raw text, may contain any number of blank lines.
    /// - Returns: `text` with every run of 2+ blank lines collapsed to 1.
    static func collapseBlankLines(_ text: String) -> String {
        text.replacingOccurrences(of: blankLineRunPattern, with: "\n\n", options: .regularExpression)
    }

    /// Collapses runs of two or more plain spaces down to exactly one.
    ///
    /// Only the ASCII space character is targeted -- tabs and newlines are
    /// left alone, so this never merges separate lines.
    ///
    /// - Parameter text: Raw text, may contain repeated interior spaces.
    /// - Returns: `text` with every run of 2+ spaces collapsed to 1.
    static func collapseInteriorSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: interiorSpaceRunPattern, with: " ", options: .regularExpression)
    }
}
