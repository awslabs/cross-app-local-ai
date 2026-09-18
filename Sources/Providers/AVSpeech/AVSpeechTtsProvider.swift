import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "avspeech.provider")

// MARK: - AVSpeechTtsProviderConfig

/// Configuration for the system speech synthesis provider.
struct AVSpeechTtsProviderConfig {
    /// BCP-47 voice identifier (e.g. "com.apple.voice.compact.en-US.Samantha").
    /// `nil` selects the system default.
    var voiceId: String?
    /// Speech rate normalized to 0.0 (slowest) .. 1.0 (fastest).
    var rate: Float = 0.5
    /// BCP-47 language code used when no voice is explicitly selected.
    var language = "en-US"
}

// MARK: - AVSpeechTtsProvider

/// macOS built-in text-to-speech provider using `AVSpeechSynthesizer`.
///
/// Splits input text into sentence-sized chunks and speaks them sequentially.
/// `AVSpeechSynthesizer` can silently stop mid-utterance on long texts;
/// chunking avoids this by keeping each utterance short.
///
/// Word-boundary callbacks report character offsets relative to the original
/// full text so the UI's word-by-word highlighting works across chunk boundaries.
///
/// All `AVSpeechSynthesizer` calls are dispatched to the main thread because
/// the synthesizer's internal audio session synchronization (`unsafeForcedSync`)
/// triggers warnings when called from Swift concurrency executor threads.
final class AVSpeechTtsProvider: TtsProvider, @unchecked Sendable {
    let providerName = "System (AVSpeech)"

    private let config: AVSpeechTtsProviderConfig
    private let synthesizer: AVSpeechSynthesizer
    private let delegate: SynthesizerDelegate

    /// Creates a new AVSpeech provider.
    ///
    /// - Parameter config: Voice, rate, and language settings.
    init(config: AVSpeechTtsProviderConfig) {
        self.config = config
        self.synthesizer = AVSpeechSynthesizer()
        self.delegate = SynthesizerDelegate()
        self.synthesizer.delegate = delegate
        logger.info("AVSpeechTtsProvider initialized")
    }

    // MARK: - TtsProvider

    func speak(_ request: TtsSynthesisRequest) async throws -> AsyncThrowingStream<TtsEvent, Error> {
        let isSpeaking = await MainActor.run { synthesizer.isSpeaking }
        guard !isSpeaking else {
            throw TtsError.alreadySpeaking
        }

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

        let chunks = TextChunking.splitIntoSentences(textToSpeak, baseOffset: baseOffset)
        let voice = resolveVoice(request: request)
        let rate = Self.mapRate(request.rate)

        logger.debug(
            "Speaking \(textToSpeak.count) chars in \(chunks.count) chunks at rate \(rate), offset \(baseOffset)"
        )

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TtsEvent.self)

        delegate.activate(
            continuation: continuation,
            chunks: chunks,
            voice: voice,
            rate: rate,
            synthesizer: synthesizer
        )

        await MainActor.run {
            self.delegate.speakNextChunk()
        }

        return stream
    }

    func pause() async {
        await MainActor.run {
            guard synthesizer.isSpeaking else { return }
            synthesizer.pauseSpeaking(at: .word)
        }
    }

    func resume() async {
        await MainActor.run {
            guard synthesizer.isPaused else { return }
            _ = synthesizer.continueSpeaking()
        }
    }

    func stop() async {
        delegate.cancelRemaining()
        await MainActor.run {
            guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func availableVoices() async -> [TtsVoice] {
        await MainActor.run {
            AVSpeechSynthesisVoice.speechVoices().map { voice in
                TtsVoice(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language
                )
            }
        }
    }

    func validate() async throws {}

    // MARK: - Voice Resolution

    private func resolveVoice(request: TtsSynthesisRequest) -> AVSpeechSynthesisVoice? {
        if let voice = request.voice {
            AVSpeechSynthesisVoice(identifier: voice.id)
        } else if let voiceId = config.voiceId {
            AVSpeechSynthesisVoice(identifier: voiceId)
        } else {
            AVSpeechSynthesisVoice(language: config.language)
        }
    }

    // MARK: - Rate Mapping

    /// Maps a 0.0..1.0 normalized rate to the AVSpeechUtterance rate scale.
    ///
    /// AVSpeechUtterance uses a range where:
    /// - `AVSpeechUtteranceMinimumSpeechRate` (~0.0) is slowest
    /// - `AVSpeechUtteranceDefaultSpeechRate` (~0.5) is normal
    /// - `AVSpeechUtteranceMaximumSpeechRate` (~1.0) is fastest
    ///
    /// The input 0.0..1.0 is mapped linearly across this range.
    static func mapRate(_ normalized: Float) -> Float {
        let minRate = AVSpeechUtteranceMinimumSpeechRate
        let maxRate = AVSpeechUtteranceMaximumSpeechRate
        let clamped = max(0.0, min(1.0, normalized))
        return minRate + clamped * (maxRate - minRate)
    }

}

// MARK: - SynthesizerDelegate

/// Maximum number of times a silently-skipped chunk will be retried before advancing.
private let maxChunkRetries = 2

/// Delay in seconds before retrying a silently-skipped chunk.
private let chunkRetryDelay: TimeInterval = 0.15

/// Bridges `AVSpeechSynthesizerDelegate` callbacks to an `AsyncThrowingStream.Continuation`,
/// driving sentence-by-sentence synthesis.
///
/// The delegate holds a queue of `SentenceChunk` values. When a chunk finishes,
/// it enqueues the next one on the synthesizer. Only after the final chunk does
/// the stream receive `.finished`. Cancellation at any point ends the stream
/// immediately.
///
/// A monotonically increasing `sessionID` distinguishes the current session from
/// stale callbacks. When `activate()` installs a new session, any delegate
/// callbacks still in-flight for a previous session are rejected by comparing
/// their captured session ID against the current one. This prevents a stale
/// `didCancel` from a prior `stopSpeaking(.immediate)` call from finishing a
/// newly created continuation.
///
/// **Silent-skip retry:** When `AVSpeechSynthesizer`'s internal AudioQueue fails
/// to start I/O (common during Bluetooth profile reconfiguration), `didFinish`
/// fires without any preceding `willSpeakRangeOfSpeechString` callback. The
/// delegate detects this and retries the chunk up to `maxChunkRetries` times
/// with a brief delay, giving the audio subsystem time to settle.
private final class SynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private var continuation: AsyncThrowingStream<TtsEvent, Error>.Continuation?
    private var chunks: [SentenceChunk] = []
    private var currentChunkIndex = 0
    private var voice: AVSpeechSynthesisVoice?
    private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    private weak var synthesizer: AVSpeechSynthesizer?
    private var sessionID: UInt64 = 0
    private var currentUtterance: AVSpeechUtterance?
    private var didReceiveWordCallback = false
    private var currentChunkRetryCount = 0

    /// Prepares the delegate for a new multi-chunk synthesis session.
    ///
    /// Finishes the previous continuation (if any) before installing a new one,
    /// preventing stale delegate callbacks from corrupting the new session's stream.
    ///
    /// - Parameters:
    ///   - continuation: The stream continuation to yield events into.
    ///   - chunks: Sentence chunks to speak in order.
    ///   - voice: The voice to use for all utterances.
    ///   - rate: The speech rate for all utterances.
    ///   - synthesizer: The synthesizer instance (weak ref to avoid retain cycle).
    func activate(
        continuation: AsyncThrowingStream<TtsEvent, Error>.Continuation,
        chunks: [SentenceChunk],
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        synthesizer: AVSpeechSynthesizer
    ) {
        // Drain the old session so any in-flight callbacks cannot reach the new one.
        self.continuation?.finish()

        sessionID &+= 1
        self.continuation = continuation
        self.chunks = chunks
        self.currentChunkIndex = 0
        self.voice = voice
        self.rate = rate
        self.synthesizer = synthesizer
        self.currentUtterance = nil
        self.didReceiveWordCallback = false
        self.currentChunkRetryCount = 0
    }

    /// Speaks the next chunk in the queue, or finishes the stream if all chunks are done.
    ///
    /// Must be called on the main thread (synthesizer calls require it).
    func speakNextChunk() {
        guard let synthesizer, let continuation else { return }

        guard currentChunkIndex < chunks.count else {
            continuation.yield(.finished)
            continuation.finish()
            self.continuation = nil
            self.currentUtterance = nil
            return
        }

        let chunk = chunks[currentChunkIndex]

        // Skip whitespace-only chunks (e.g. blank lines between paragraphs).
        if chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentChunkIndex += 1
            speakNextChunk()
            return
        }

        let utterance = AVSpeechUtterance(string: chunk.text)
        utterance.rate = rate
        utterance.voice = voice
        currentUtterance = utterance
        didReceiveWordCallback = false
        synthesizer.speak(utterance)
    }

    /// Discards remaining chunks so `didFinish` for the current utterance
    /// finishes the stream instead of advancing.
    func cancelRemaining() {
        currentChunkIndex = chunks.count
        currentUtterance = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(
        _: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard utterance === currentUtterance else { return }
        guard currentChunkIndex < chunks.count else { return }
        didReceiveWordCallback = true
        let chunkOffset = chunks[currentChunkIndex].offset
        let start = chunkOffset + characterRange.location
        let end = start + characterRange.length
        continuation?.yield(.wordBoundary(WordTiming(range: start ..< end)))
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }

        if !didReceiveWordCallback, currentChunkRetryCount < maxChunkRetries {
            currentChunkRetryCount += 1
            let attempt = currentChunkRetryCount
            let chunkIdx = currentChunkIndex
            logger.warning(
                "Chunk \(chunkIdx) finished without audio, retrying (attempt \(attempt)/\(maxChunkRetries))"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + chunkRetryDelay) { [weak self] in
                self?.speakNextChunk()
            }
            return
        }

        if !didReceiveWordCallback {
            logger.error("Chunk \(self.currentChunkIndex) skipped after \(maxChunkRetries) retries")
        }

        currentChunkIndex += 1
        currentChunkRetryCount = 0
        speakNextChunk()
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        continuation?.yield(.cancelled)
        continuation?.finish()
        continuation = nil
        currentUtterance = nil
    }
}
