import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "kokoro.provider")

// MARK: - KokoroTtsProviderConfig

/// Configuration for the Kokoro TTS provider.
struct KokoroTtsProviderConfig {
    /// Kokoro voice preset name (e.g. "af_heart", "am_adam", "bf_emma").
    var voiceId: String = KokoroSynthesizer.defaultVoice
    /// BCP-47 language code prefix (e.g. "en", "fr", "es").
    var language = "en"
    /// HuggingFace model identifier for weight download.
    var modelId: String = KokoroSynthesizer.defaultModelId
}

// MARK: - KokoroTtsProvider

/// On-device neural TTS provider using Kokoro-82M via CoreML.
///
/// Kokoro is a non-autoregressive model that produces full utterances in a single
/// inference pass (~45ms on the Neural Engine). Since it returns raw PCM samples
/// rather than driving system audio, this provider handles:
///
/// 1. **Sentence chunking** -- Long text is split into sentences (reusing
///    Foundation's linguistic sentence enumerator) so each chunk fits the
///    128-phoneme input limit.
/// 2. **Audio playback** -- Raw `[Float]` samples at 24 kHz are played through
///    `AVAudioEngine` via `KokoroAudioPlayer`.
/// 3. **Model-derived word timing** -- Word offsets are computed from the
///    `pred_dur` tensor produced by CoreML inference, giving accurate
///    phoneme-level duration predictions rather than character-based estimates.
///
/// The model is loaded lazily on first `speak()` to avoid blocking app startup.
/// First-run downloads ~170 MB of weights from HuggingFace.
actor KokoroTtsProvider: TtsProvider {
    let providerName = "Kokoro (Neural)"

    private let config: KokoroTtsProviderConfig

    /// Active playback session on the main actor.
    private var activeSession: KokoroPlaybackSession?

    init(config: KokoroTtsProviderConfig) {
        self.config = config
        logger.info("KokoroTtsProvider initialized (voice: \(config.voiceId), lang: \(config.language))")

        // Eagerly warm the shared cache in the background if cached on disk.
        // Without this, the first speak() call blocks for 10-30s while
        // CoreML compiles/loads the model from disk.
        if KokoroModelManager.isModelCached() {
            Task { await self.preloadModel() }
        }
    }

    // MARK: - TtsProvider

    func speak(_ request: TtsSynthesisRequest) async throws -> AsyncThrowingStream<TtsEvent, Error> {
        let synth = try await ensureModelLoaded()

        let textToSpeak: String
        let baseOffset: Int

        if request.startOffset > 0, request.startOffset < request.text.count {
            let idx = request.text.index(
                request.text.startIndex,
                offsetBy: request.startOffset
            )
            textToSpeak = String(request.text[idx...])
            baseOffset = request.startOffset
        } else {
            textToSpeak = request.text
            baseOffset = 0
        }

        let sentences = TextChunking.splitIntoSentences(textToSpeak, baseOffset: baseOffset)
        let chunks = splitLongChunks(sentences, synthesizer: synth)
        let voiceId = resolveVoiceId(request: request)
        let speed = mapSpeed(request.rate)
        let language = config.language

        logger.debug(
            "Speaking \(textToSpeak.count) chars in \(chunks.count) chunks (voice: \(voiceId), speed: \(speed))"
        )

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TtsEvent.self)

        let session = await KokoroPlaybackSession(continuation: continuation)
        activeSession = session

        Task {
            await self.synthesizeChunks(
                chunks,
                synthesizer: synth,
                voiceId: voiceId,
                language: language,
                speed: speed,
                session: session
            )
        }

        return stream
    }

    func pause() async {
        guard let session = activeSession else { return }
        await session.pause()
    }

    func resume() async {
        guard let session = activeSession else { return }
        await session.resume()
    }

    func stop() async {
        guard let session = activeSession else { return }
        activeSession = nil
        await session.stop()
    }

    func availableVoices() async -> [TtsVoice] {
        guard let synth = try? await ensureModelLoaded() else { return [] }
        return synth.availableVoices.map { voiceId in
            TtsVoice(
                id: voiceId,
                name: Self.displayName(for: voiceId),
                language: Self.languageCode(for: voiceId)
            )
        }
    }

    func validate() async throws {
        _ = try await ensureModelLoaded()
    }

    // MARK: - Synthesis Pipeline

    /// Minimum drift (seconds) between predicted and actual audio duration
    /// that triggers the truncation recovery path.
    private static let truncationThreshold: TimeInterval = 0.2

    /// Synthesizes chunks sequentially, passing audio to the playback session.
    ///
    /// Word timing is derived from the model's `pred_dur` output tensor, which
    /// predicts phoneme-level acoustic frame durations. The resulting offsets
    /// are paired with text-level word ranges to produce accurate `TimedWord`
    /// values for the UI highlighting loop.
    ///
    /// If the model truncates a chunk (predicted duration exceeds actual audio
    /// duration by more than 200ms), the audio is trimmed to the last complete
    /// word boundary and the remaining text is re-synthesized as a follow-up chunk.
    private func synthesizeChunks(
        _ chunks: [SentenceChunk],
        synthesizer: KokoroSynthesizer,
        voiceId: String,
        language: String,
        speed: Float,
        session: KokoroPlaybackSession
    ) async {

        var queue = chunks
        var queueIndex = 0

        while queueIndex < queue.count {
            let isCancelled = await session.isCancelled
            guard !isCancelled else { return }

            let chunk = queue[queueIndex]
            queueIndex += 1

            if chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            do {
                let result = try synthesizer.synthesize(
                    text: chunk.text, voice: voiceId, language: language, speed: speed
                )
                let cancelled = await session.isCancelled
                guard !cancelled else { return }

                if result.audio.isEmpty {
                    logger.warning("Kokoro returned empty audio for chunk \(queueIndex - 1)")
                    continue
                }

                let isLast = queueIndex >= queue.count
                let chunkIdx = queueIndex - 1
                if let remainder = await processChunkResult(
                    result: result,
                    chunk: chunk,
                    chunkIndex: chunkIdx,
                    isLast: isLast,
                    session: session
                ) {
                    queue.append(remainder)
                }
            } catch {
                let cancelled = await session.isCancelled
                guard !cancelled else { return }
                logger.error(
                    "Kokoro synthesis failed for chunk \(queueIndex - 1): \(error.localizedDescription, privacy: .public)"
                )
                await session.finish(throwing: TtsError.synthesisFailure(
                    message: "Synthesis failed: \(error.localizedDescription)"
                ))
                return
            }
        }
    }

    /// Processes a synthesis result, handling truncation if needed.
    ///
    /// - Returns: A remainder chunk if the result was truncated, `nil` otherwise.
    private func processChunkResult(
        result: KokoroSynthesisResult,
        chunk: SentenceChunk,
        chunkIndex: Int,
        isLast: Bool,
        session: KokoroPlaybackSession
    ) async -> SentenceChunk? {
        let words = WordTokenizer.tokenize(chunk.text, baseOffset: chunk.offset)
        let drift = result.predictedDuration - result.audioDuration

        if drift > Self.truncationThreshold {
            let predStr = String(format: "%.3f", result.predictedDuration)
            let actStr = String(format: "%.3f", result.audioDuration)
            let driftStr = String(format: "+%.0f", drift * 1000)
            logger.warning(
                "Chunk truncated: predicted \(predStr)s but got \(actStr)s (drift=\(driftStr)ms) -- splitting"
            )

            let recovery = recoverTruncatedChunk(
                result: result, words: words, chunkText: chunk.text, chunkOffset: chunk.offset
            )
            let timedWords = zipWordTimings(words: recovery.words, offsets: result.wordOffsets)
            let chunkIsLast = isLast && recovery.remainder == nil
            await session.playChunk(samples: recovery.audio, timedWords: timedWords, isLast: chunkIsLast)
            return recovery.remainder
        }

        let timedWords = zipWordTimings(words: words, offsets: result.wordOffsets)
        if words.count != result.wordOffsets.count {
            logger.warning(
                "Chunk \(chunkIndex): text words=\(words.count) vs model offsets=\(result.wordOffsets.count) -- mismatch"
            )
        }
        await session.playChunk(samples: result.audio, timedWords: timedWords, isLast: isLast)
        return nil
    }

    /// Result of recovering audio from a truncated synthesis pass.
    private struct TruncationRecovery {
        let audio: [Float]
        let words: [WordTiming]
        let remainder: SentenceChunk?
    }

    /// Recovers from a truncated synthesis result by trimming audio to the last
    /// complete word and returning the remaining text as a new chunk.
    ///
    /// - Parameters:
    ///   - result: The truncated synthesis result.
    ///   - words: Word timings for the chunk text.
    ///   - chunkText: Original text of the truncated chunk.
    ///   - chunkOffset: Character offset of the chunk in the source text.
    /// - Returns: Recovery containing trimmed audio, word list, and optional remainder.
    private func recoverTruncatedChunk(
        result: KokoroSynthesisResult,
        words: [WordTiming],
        chunkText: String,
        chunkOffset: Int
    ) -> TruncationRecovery {
        let lastSafeWordIndex = findLastSafeWordIndex(
            offsets: result.wordOffsets, wordCount: words.count, audioDuration: result.audioDuration
        )

        if lastSafeWordIndex >= words.count - 1 {
            return TruncationRecovery(audio: result.audio, words: words, remainder: nil)
        }

        let keptWords = Array(words.prefix(lastSafeWordIndex + 1))
        let trimmedAudio = trimAudioToWordBoundary(
            audio: result.audio, offsets: result.wordOffsets, afterWordIndex: lastSafeWordIndex
        )

        let remainder = buildRemainderChunk(
            words: words, fromIndex: lastSafeWordIndex + 1,
            chunkText: chunkText, chunkOffset: chunkOffset
        )

        if let remainder {
            let preview = String(remainder.text.prefix(60))
            logger.info(
                "Truncation recovery: kept \(keptWords.count)/\(words.count) words, remainder=\(preview)..."
            )
        }

        return TruncationRecovery(audio: trimmedAudio, words: keptWords, remainder: remainder)
    }

    /// Finds the index of the last word whose onset fits within the audio duration.
    private func findLastSafeWordIndex(
        offsets: [TimeInterval], wordCount: Int, audioDuration: TimeInterval
    ) -> Int {
        let safeEnd = audioDuration - 0.05
        var lastSafe = 0
        for (i, offset) in offsets.enumerated() where i < wordCount {
            if offset <= safeEnd {
                lastSafe = i
            } else {
                break
            }
        }
        return lastSafe
    }

    /// Trims audio to the onset of the word after `afterWordIndex`.
    private func trimAudioToWordBoundary(
        audio: [Float], offsets: [TimeInterval], afterWordIndex: Int
    ) -> [Float] {
        let nextIndex = afterWordIndex + 1
        guard nextIndex < offsets.count else { return audio }
        let trimSamples = min(
            Int(offsets[nextIndex] * Double(KokoroSynthesizer.sampleRate)), audio.count
        )
        return Array(audio.prefix(trimSamples))
    }

    /// Builds a remainder chunk from the first dropped word onward.
    private func buildRemainderChunk(
        words: [WordTiming], fromIndex: Int, chunkText: String, chunkOffset: Int
    ) -> SentenceChunk? {
        guard fromIndex < words.count else { return nil }
        let firstDropped = words[fromIndex]
        let localStart = firstDropped.range.lowerBound - chunkOffset
        guard localStart >= 0, localStart < chunkText.count else { return nil }

        let startIdx = chunkText.index(chunkText.startIndex, offsetBy: localStart)
        let text = String(chunkText[startIdx...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return SentenceChunk(text: text, offset: firstDropped.range.lowerBound)
    }

    /// Pairs text-level word ranges with model-derived time offsets.
    ///
    /// If the model produced fewer offsets than words (e.g. due to tokenization
    /// differences), remaining words are estimated by distributing the last
    /// known offset evenly.
    private func zipWordTimings(words: [WordTiming], offsets: [TimeInterval]) -> [TimedWord] {
        var result: [TimedWord] = []
        for (i, word) in words.enumerated() {
            let offset: TimeInterval = if i < offsets.count {
                offsets[i]
            } else if let last = offsets.last {
                last
            } else {
                0
            }
            result.append(TimedWord(timing: word, timeOffset: offset))
        }
        return result
    }

    // MARK: - Model Loading

    /// Eagerly warms the shared synthesizer cache.
    /// Called from the background Task in `init`.
    private func preloadModel() async {
        _ = try? await ensureModelLoaded()
    }

    private func ensureModelLoaded() async throws -> KokoroSynthesizer {
        if let existing = KokoroSynthesizerCache.cached {
            return existing
        }

        if KokoroSynthesizerCache.loading {
            // Surface "starting up" so the UI shows a transient message
            // rather than a hard synthesis-failure error.
            throw TtsError.startingUp
        }

        // Pre-flight cache check: without this, `fromPretrained` silently
        // re-downloads weights from HuggingFace when files are missing,
        // which would undo an explicit user delete.
        guard KokoroModelManager.isModelCached() else {
            throw TtsError.modelNotInstalled
        }

        KokoroSynthesizerCache.loading = true

        do {
            logger.info("Loading Kokoro model into shared cache")
            let loaded = try await KokoroSynthesizer.fromPretrained(
                modelId: config.modelId
            ) { progress, stage in
                logger.debug("Kokoro load: \(String(format: "%.0f%%", progress * 100)) - \(stage)")
            }

            KokoroSynthesizerCache.store(loaded)
            return loaded
        } catch {
            KokoroSynthesizerCache.loading = false
            logger.error("Failed to load Kokoro model: \(error.localizedDescription, privacy: .public)")
            throw TtsError.synthesisFailure(
                message: "Failed to load Kokoro model: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Voice Resolution

    private func resolveVoiceId(request: TtsSynthesisRequest) -> String {
        if let voice = request.voice {
            return voice.id
        }
        return config.voiceId
    }

    /// Maps the normalized 0.0..1.0 rate to Kokoro speed (0.5..2.0).
    ///
    /// - Parameter normalizedRate: A value in the range 0.0...1.0.
    /// - Returns: Kokoro speed in the range 0.5...2.0.
    private func mapSpeed(_ normalizedRate: Float) -> Float {
        let clamped = max(0.0, min(1.0, normalizedRate))
        return 0.5 + clamped * 1.5
    }
}

// MARK: - Chunk Splitting

extension KokoroTtsProvider {

    /// Maximum phoneme tokens per chunk.
    ///
    /// The CoreML model (`kokoro_5s`) has a fixed output tensor of 120,000
    /// samples (5.0s at 24 kHz). When `pred_dur` predicts more frames than
    /// fit in that window the audio is silently truncated, losing words at
    /// the chunk tail. Empirically, 125 tokens can require 8+ seconds of
    /// audio. Capping at 80 tokens keeps output safely under the 5s ceiling
    /// for all observed content while still producing 3-4s chunks.
    private static var maxTokensPerChunk: Int {
        80
    }

    /// Splits sentence chunks that exceed the model's token budget using
    /// backwards waterfall chunking.
    ///
    /// Uses the phonemizer's actual token count rather than a character-based
    /// heuristic, so the budget is exact regardless of text complexity. When a
    /// sentence exceeds the token limit, the waterfall algorithm scans
    /// **backwards** from the budget boundary to find the **latest** natural
    /// punctuation break point, maximizing chunk fill and giving the model more
    /// context for natural prosody.
    ///
    /// - Parameters:
    ///   - sentences: Sentence chunks from `splitIntoSentences`.
    ///   - synthesizer: The loaded synthesizer (provides `tokenCount(for:)`).
    /// - Returns: Chunks that each fit within the model's token budget.
    private func splitLongChunks(
        _ sentences: [SentenceChunk],
        synthesizer: KokoroSynthesizer
    ) -> [SentenceChunk] {
        let language = config.language
        let maxTokens = Self.maxTokensPerChunk
        var result: [SentenceChunk] = []

        for chunk in sentences {
            if synthesizer.tokenCount(for: chunk.text, language: language) <= maxTokens + 2 {
                result.append(chunk)
            } else {
                result.append(contentsOf: TextChunking.waterfallChunk(
                    chunk.text,
                    baseOffset: chunk.offset,
                    tokenCount: { synthesizer.tokenCount(for: $0, language: language) },
                    maxTokens: maxTokens
                ))
            }
        }
        return result
    }
}

// MARK: - Voice Metadata

extension KokoroTtsProvider {

    /// Derives a human-readable display name from a Kokoro voice ID.
    ///
    /// Kokoro voice IDs follow the pattern `{prefix}_{name}` where:
    /// - `a` = American English, `b` = British English
    /// - `f` = female, `m` = male
    static func displayName(for voiceId: String) -> String {
        let parts = voiceId.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return voiceId }

        let prefix = String(parts[0])
        let name = String(parts[1]).capitalized

        let accent = if prefix.hasPrefix("a") {
            "US"
        } else if prefix.hasPrefix("b") {
            "UK"
        } else {
            ""
        }

        let gender = if prefix.hasSuffix("f") {
            "Female"
        } else if prefix.hasSuffix("m") {
            "Male"
        } else {
            ""
        }

        let label = [name, gender, accent].filter { !$0.isEmpty }.joined(separator: " ")
        return label.isEmpty ? voiceId : label
    }

    /// Infers a BCP-47-style language code from a Kokoro voice ID prefix.
    static func languageCode(for voiceId: String) -> String {
        guard let first = voiceId.first else { return "en" }
        switch first {
        case "a": return "en-US"
        case "b": return "en-GB"
        default: return "en"
        }
    }
}
