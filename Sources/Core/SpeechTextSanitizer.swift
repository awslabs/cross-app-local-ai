import Foundation

/// Prepares captured text for speech synthesis in the read-aloud panel.
///
/// This is the deterministic, no-model-call preprocessing tier
/// (`TtsPreprocessing.deterministic`). It deliberately follows the opposite
/// policy from `AppState.sanitizeLearnedText`: line breaks and paragraph
/// structure are preserved rather than flattened, because read-aloud
/// scroll-follow highlights words by character offset into the displayed
/// text -- collapsing paragraphs into one line would desynchronize the
/// highlight from the spoken audio. It also never truncates; length limits
/// are handled upstream by chunking (`TextMapReduce`), not by dropping
/// content here.
enum SpeechTextSanitizer {
    /// Removes markdown code fences and list markers, collapses excess
    /// whitespace, and preserves line breaks and paragraph structure.
    ///
    /// - Parameter raw: The captured text, as selected from the source app.
    /// - Returns: Text safe to hand to a TTS engine, with newlines intact.
    static func sanitize(_ raw: String) -> String {
        let unfenced = TextCleanup.stripCodeFences(raw)
        let lines = unfenced
            .components(separatedBy: .newlines)
            .map(TextCleanup.stripListMarker)
        let joined = lines.joined(separator: "\n")
        let collapsed = TextCleanup.collapseInteriorSpaces(TextCleanup.collapseBlankLines(joined))
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
