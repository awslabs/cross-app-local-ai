import Foundation

// MARK: - TtsVoice

/// Represents a voice available for text-to-speech synthesis.
struct TtsVoice: Identifiable, Equatable {
    /// Opaque identifier used by the provider to select this voice.
    let id: String
    /// Human-readable voice name for the settings UI.
    let name: String
    /// BCP-47 language tag (e.g. "en-US", "fr-FR").
    let language: String
}

// MARK: - TtsSynthesisRequest

/// Parameters for a text-to-speech synthesis request.
struct TtsSynthesisRequest {
    /// The full text to synthesize.
    let text: String
    /// Voice to use. `nil` means the provider's default.
    let voice: TtsVoice?
    /// Speech rate normalized to 0.0 (slowest) .. 1.0 (fastest).
    /// Providers map this to their native rate scale.
    let rate: Float
    /// Character offset in `text` at which to begin speaking.
    /// Used for seek: the provider synthesizes from this offset onward.
    let startOffset: Int
}

// MARK: - WordTiming

/// Identifies the word currently being spoken and its position in the source text.
struct WordTiming: Equatable {
    /// Character offset range within the original `TtsSynthesisRequest.text`.
    let range: Range<Int>
}

// MARK: - TtsEvent

/// Events emitted by a `TtsProvider` during synthesis.
///
/// The event stream carries word-boundary notifications that drive the UI's
/// word-by-word highlighting. Audio playback is handled internally by the
/// provider -- no audio data flows through this stream.
enum TtsEvent {
    /// The synthesizer is about to speak the word at this character range.
    case wordBoundary(WordTiming)
    /// Synthesis completed and all audio has been played.
    case finished
    /// Synthesis was cancelled via `stop()`.
    case cancelled
}

// MARK: - PlaybackState

/// Transport state exposed to the UI.
enum PlaybackState: Equatable {
    case idle
    case playing
    case paused
}

// MARK: - ReadAloudRendition

/// Which version of the captured text the read-aloud panel is currently
/// displaying and speaking.
enum ReadAloudRendition: Equatable {
    /// The captured (and, if configured, deterministically sanitized) text.
    case original
    /// An LLM-generated summary produced by `AppState.summarizeReadAloudText()`.
    case summarized
}

// MARK: - ReadAloudSummarizeState

/// Progress of the LLM-powered summarize action in the read-aloud panel.
enum ReadAloudSummarizeState: Equatable {
    case idle
    case inProgress(completed: Int, total: Int)
    case failed(String)
}

// MARK: - TimedWord

/// A word with its playback time offset (from the model's pred_dur tensor).
struct TimedWord: Equatable {
    let timing: WordTiming
    let timeOffset: TimeInterval
}

// MARK: - SentenceChunk

/// A sentence-sized piece of text with its character offset in the original full text.
struct SentenceChunk {
    let text: String
    let offset: Int
}

// MARK: - TextChunking

/// Shared text-chunking utilities used by TTS providers.
enum TextChunking {

    /// Splits text into sentence chunks with offsets relative to the original full text.
    ///
    /// Uses Foundation's linguistic sentence detection (`enumerateSubstrings`
    /// with `.bySentences`) which handles punctuation, abbreviations, and Unicode
    /// correctly. Each chunk preserves trailing whitespace so reconstructing the
    /// original text by concatenation is lossless.
    ///
    /// - Parameters:
    ///   - text: The text to split.
    ///   - baseOffset: Character offset in the original full text where `text` begins.
    /// - Returns: An array of sentence chunks with global character offsets.
    static func splitIntoSentences(_ text: String, baseOffset: Int) -> [SentenceChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [SentenceChunk] = []
        text.enumerateSubstrings(
            in: text.startIndex...,
            options: .bySentences
        ) { substring, substringRange, _, _ in
            guard let substring, !substring.isEmpty else { return }
            let localOffset = text.distance(from: text.startIndex, to: substringRange.lowerBound)
            chunks.append(SentenceChunk(
                text: substring,
                offset: baseOffset + localOffset
            ))
        }

        if chunks.isEmpty {
            chunks.append(SentenceChunk(text: text, offset: baseOffset))
        }

        return chunks
    }

    // MARK: - Waterfall Chunking

    /// Punctuation tiers for waterfall break-point selection, ordered by priority.
    /// Sentence-enders are tried first (strongest prosodic boundary), then
    /// semicolons/colons, then commas/dashes (weakest).
    private static let waterfallTiers: [[Character]] = [
        ["!", ".", "?", "\u{2026}"], // sentence-enders
        [":", ";"], // clause separators
        [",", "\u{2014}", "\u{2013}"], // commas, em-dash, en-dash
    ]

    /// Characters that "bump" onto the preceding chunk when they immediately
    /// follow a waterfall break point (closing quotes, parentheses).
    private static let bumpCharacters: Set<Character> = [")", "\u{201D}", "\""]

    /// Splits text into chunks that each fit within a token budget, using a
    /// backwards waterfall scan to find the latest natural break point.
    ///
    /// Ported from Kokoro's `en_tokenize` + `waterfall_last` algorithm. The key
    /// insight is scanning **backwards** from the budget boundary to find the
    /// **latest** possible punctuation break, maximizing chunk fill and giving
    /// the TTS model more context for natural prosody.
    ///
    /// - Parameters:
    ///   - text: The text to chunk.
    ///   - baseOffset: Character offset of `text` within the full source string.
    ///   - tokenCount: Closure that returns the phoneme-token count for a substring.
    ///   - maxTokens: Maximum token count per chunk (e.g. 80).
    /// - Returns: Chunks that each fit within the token budget.
    static func waterfallChunk(
        _ text: String,
        baseOffset: Int,
        tokenCount: (String) -> Int,
        maxTokens: Int
    ) -> [SentenceChunk] {
        let words = splitIntoWords(text)
        guard !words.isEmpty else { return [] }

        var chunks: [SentenceChunk] = []
        var bufferWords: [WordSlice] = []
        var bufferText = ""

        for word in words {
            let candidate = bufferText.isEmpty
                ? word.text
                : bufferText + word.text
            let count = tokenCount(candidate.trimmingCharacters(in: .whitespaces))

            if count > maxTokens, !bufferWords.isEmpty {
                // Budget exceeded — find the best backwards break point
                let breakIndex = waterfallBreakIndex(
                    bufferWords, tokenCount: tokenCount, maxTokens: maxTokens
                )
                let kept = bufferWords[..<breakIndex]
                let remainder = bufferWords[breakIndex...]

                let keptText = kept.map(\.text).joined()
                let trimmed = keptText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    let keptOffset = kept.first?.offset ?? 0
                    chunks.append(SentenceChunk(
                        text: trimmed,
                        offset: baseOffset + keptOffset
                    ))
                }

                // Start fresh with the remainder + current word
                bufferWords = Array(remainder) + [word]
                bufferText = bufferWords.map(\.text).joined()
            } else {
                bufferWords.append(word)
                bufferText = candidate
            }
        }

        // Flush remaining buffer
        let trimmed = bufferText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let bufOffset = bufferWords.first?.offset ?? 0
            chunks.append(SentenceChunk(text: trimmed, offset: baseOffset + bufOffset))
        }

        return chunks
    }

    /// A word or whitespace segment with its character offset within the parent string.
    private struct WordSlice {
        let text: String
        let offset: Int
    }

    /// Splits text into word slices preserving all whitespace as part of the
    /// preceding word's text (so concatenation is lossless).
    private static func splitIntoWords(_ text: String) -> [WordSlice] {
        var slices: [WordSlice] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let wordStart = idx
            // Consume non-whitespace
            while idx < text.endIndex, !text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
            // Consume trailing whitespace (attached to this word)
            while idx < text.endIndex, text[idx].isWhitespace {
                idx = text.index(after: idx)
            }
            let slice = String(text[wordStart ..< idx])
            let offset = text.distance(from: text.startIndex, to: wordStart)
            slices.append(WordSlice(text: slice, offset: offset))
        }
        return slices
    }

    /// Scans backwards through buffered words to find the latest punctuation
    /// break point, trying each waterfall tier in priority order.
    ///
    /// Returns the index at which to split: words `[0..<index]` go into the
    /// current chunk, words `[index...]` start the next chunk.
    private static func waterfallBreakIndex(
        _ words: [WordSlice],
        tokenCount: (String) -> Int,
        maxTokens: Int
    ) -> Int {
        let totalText = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        let totalCount = tokenCount(totalText)

        for tier in waterfallTiers {
            // Scan backwards for the last word ending with this punctuation tier
            guard let breakIdx = lastIndexEndingWith(words: words, punctuation: tier) else {
                continue
            }

            var splitAt = breakIdx + 1

            // Include any "bump" characters (closing quotes/parens) that follow
            if splitAt < words.count {
                let nextTrimmed = words[splitAt].text.trimmingCharacters(in: .whitespaces)
                if let firstChar = nextTrimmed.first, bumpCharacters.contains(firstChar) {
                    splitAt += 1
                }
            }

            // Verify the chunk after breaking still fits the budget
            let keptJoined = words[..<splitAt].map(\.text).joined()
            let keptText = keptJoined.trimmingCharacters(in: .whitespaces)
            let remainderJoined = words[splitAt...].map(\.text).joined()
            let remainderText = remainderJoined.trimmingCharacters(in: .whitespaces)

            let keptCount = tokenCount(keptText)
            if keptCount <= maxTokens, !remainderText.isEmpty {
                return splitAt
            }

            // If the kept portion exceeds budget, the break is too late.
            // Fall through to next tier if kept is still over budget but remainder
            // would be under — otherwise the break is unhelpful.
            if totalCount - keptCount <= maxTokens {
                return splitAt
            }
        }

        // No punctuation break found — fall back to splitting at the last word
        // that keeps the chunk within budget (greedy fill).
        return greedyBreakIndex(words, tokenCount: tokenCount, maxTokens: maxTokens)
    }

    /// Finds the last word index whose trailing character matches one of the
    /// given punctuation characters.
    private static func lastIndexEndingWith(
        words: [WordSlice], punctuation: [Character]
    ) -> Int? {
        let punctSet = Set(punctuation)
        for i in stride(from: words.count - 1, through: 0, by: -1) {
            let trimmed = words[i].text.trimmingCharacters(in: .whitespaces)
            guard let lastChar = trimmed.last else { continue }
            if punctSet.contains(lastChar) {
                return i
            }
        }
        return nil
    }

    /// Greedy word-by-word accumulation until the budget is exceeded.
    private static func greedyBreakIndex(
        _ words: [WordSlice],
        tokenCount: (String) -> Int,
        maxTokens: Int
    ) -> Int {
        var acc = ""
        for (i, word) in words.enumerated() {
            let candidate = acc + word.text
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if tokenCount(trimmed) > maxTokens, i > 0 {
                return i
            }
            acc = candidate
        }
        return words.count
    }
}

// MARK: - TtsError

/// Errors originating from the TTS subsystem.
enum TtsError: Error, LocalizedError {
    case notConfigured
    case voiceNotFound(voiceId: String)
    case synthesisFailure(message: String)
    case modelNotInstalled
    case alreadySpeaking
    case startingUp

    var errorDescription: String? {
        userMessage
    }

    /// Human-readable message suitable for display alongside any
    /// `suggestedAction`. Parallels the shape used by `SttError` / `LlmError`.
    var userMessage: String {
        switch self {
        case .notConfigured:
            "Text-to-speech is not configured"
        case let .voiceNotFound(voiceId):
            "Voice '\(voiceId)' not found"
        case let .synthesisFailure(message):
            "Speech synthesis failed: \(message)"
        case .modelNotInstalled:
            "Read-aloud model isn't installed"
        case .alreadySpeaking:
            "A speech session is already active"
        case .startingUp:
            "Read-aloud is still starting up"
        }
    }

    /// Optional actionable hint for the user, typically pointing them at
    /// Settings to resolve install or config issues.
    var suggestedAction: String? {
        switch self {
        case .notConfigured:
            "Enable text-to-speech in Settings"
        case .voiceNotFound:
            "Pick a different voice in Settings"
        case .synthesisFailure:
            "Open Settings to reinstall the TTS model"
        case .modelNotInstalled:
            "Open Settings to download it"
        case .alreadySpeaking:
            nil
        case .startingUp:
            "Try again shortly"
        }
    }
}
