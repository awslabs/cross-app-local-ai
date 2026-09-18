import Foundation

/// Deterministic mock TTS provider for testing and first-launch fallback.
///
/// Emits word-boundary events by splitting the input text on whitespace
/// and yielding one `WordTiming` per word with a short simulated delay.
/// No actual audio is produced.
struct MockTtsProvider: TtsProvider {
    let providerName = "Mock TTS"

    func speak(_ request: TtsSynthesisRequest) async throws -> AsyncThrowingStream<TtsEvent, Error> {
        let text = request.text
        let startOffset = request.startOffset

        return AsyncThrowingStream { continuation in
            let task = Task {
                let substring = text[text.index(text.startIndex, offsetBy: min(startOffset, text.count))...]
                let words = Self.tokenize(String(substring), baseOffset: startOffset)

                for timing in words {
                    guard !Task.isCancelled else {
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    }
                    continuation.yield(.wordBoundary(timing))
                    try await Task.sleep(nanoseconds: 150_000_000)
                }

                guard !Task.isCancelled else {
                    continuation.yield(.cancelled)
                    continuation.finish()
                    return
                }
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}

    func availableVoices() async -> [TtsVoice] {
        [TtsVoice(id: "mock-default", name: "Mock Voice", language: "en-US")]
    }

    func validate() async throws {}

    /// Splits text into words and computes character offset ranges.
    ///
    /// - Parameters:
    ///   - text: The text to tokenize.
    ///   - baseOffset: Character offset in the original full text where `text` begins.
    /// - Returns: An array of `WordTiming` with ranges relative to the original text.
    static func tokenize(_ text: String, baseOffset: Int) -> [WordTiming] {
        var result: [WordTiming] = []
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            // Skip whitespace
            while currentIndex < text.endIndex, text[currentIndex].isWhitespace {
                currentIndex = text.index(after: currentIndex)
            }
            guard currentIndex < text.endIndex else { break }

            let wordStart = currentIndex
            // Advance through non-whitespace
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
