import Foundation

// MARK: - WordTokenizer

/// Tokenizes text into words with character offset ranges.
///
/// The actual word-level timing is computed from the model's `pred_dur`
/// output tensor in `KokoroSynthesizer.synthesize()`. This type provides
/// only the text-to-word-range tokenization that maps model-derived time
/// offsets back to character positions in the source text.
enum WordTokenizer {

    /// Splits text into words and computes character offset ranges.
    ///
    /// Skips whitespace runs and produces one `WordTiming` per contiguous
    /// non-whitespace sequence. Offsets are relative to the original full text
    /// (shifted by `baseOffset`).
    ///
    /// - Parameters:
    ///   - text: The text to tokenize.
    ///   - baseOffset: Character offset in the original full text where `text` begins.
    /// - Returns: An array of `WordTiming` with ranges relative to the original text.
    static func tokenize(_ text: String, baseOffset: Int) -> [WordTiming] {
        var result: [WordTiming] = []
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            while currentIndex < text.endIndex, text[currentIndex].isWhitespace {
                currentIndex = text.index(after: currentIndex)
            }
            guard currentIndex < text.endIndex else { break }

            let wordStart = currentIndex
            while currentIndex < text.endIndex, !text[currentIndex].isWhitespace {
                currentIndex = text.index(after: currentIndex)
            }

            let startOffset = baseOffset + text.distance(from: text.startIndex, to: wordStart)
            let endOffset = baseOffset + text.distance(from: text.startIndex, to: currentIndex)
            result.append(WordTiming(range: startOffset ..< endOffset))
        }

        return result
    }
}
