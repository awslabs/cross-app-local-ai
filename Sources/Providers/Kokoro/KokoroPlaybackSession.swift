import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "kokoro.playback")

// MARK: - SynthesizedChunk

/// A chunk of synthesized audio with its timing metadata, ready for playback.
struct SynthesizedChunk {
    let samples: [Float]
    let timedWords: [TimedWord]
    let isLast: Bool
}

// MARK: - KokoroPlaybackSession

/// Manages audio playback and word-timing emission on the main actor.
///
/// Receives synthesized audio chunks from the provider actor, plays them
/// through `KokoroAudioPlayer`, and emits word-boundary events synchronized
/// with playback position. Applies a short cosine crossfade at chunk
/// boundaries to eliminate click/pop artifacts from waveform discontinuities.
@MainActor
final class KokoroPlaybackSession {
    private let continuation: AsyncThrowingStream<TtsEvent, Error>.Continuation
    private let audioPlayer: KokoroAudioPlayer
    private(set) var isCancelled = false
    private var wordTimingTask: Task<Void, Never>?
    private var currentTimedWords: [TimedWord] = []
    private var pendingChunks: [SynthesizedChunk] = []
    private var isPlaying = false

    /// Number of samples used for the crossfade region between chunks.
    /// At 24 kHz, 480 samples = 20 ms — short enough to preserve word
    /// clarity but long enough to smooth energy and pitch transitions
    /// between independently-synthesized chunks.
    private static let crossfadeSamples = 480

    /// Tail samples from the previously played chunk, used to crossfade
    /// into the next chunk's leading samples.
    private var previousTail: [Float] = []

    init(continuation: AsyncThrowingStream<TtsEvent, Error>.Continuation) {
        self.continuation = continuation
        self.audioPlayer = KokoroAudioPlayer(sampleRate: KokoroSynthesizer.sampleRate)
    }

    /// Enqueues a synthesized chunk for playback.
    ///
    /// If no audio is currently playing, starts playback immediately.
    /// Otherwise, buffers the chunk until the current one finishes.
    ///
    /// - Parameters:
    ///   - samples: Mono float PCM samples at 24 kHz.
    ///   - timedWords: Model-derived word timings for the chunk.
    ///   - isLast: Whether this is the final chunk in the sequence.
    func playChunk(samples: [Float], timedWords: [TimedWord], isLast: Bool) {
        pendingChunks.append(SynthesizedChunk(samples: samples, timedWords: timedWords, isLast: isLast))
        if !isPlaying {
            playNextPendingChunk()
        }
    }

    func pause() {
        audioPlayer.pause()
        wordTimingTask?.cancel()
    }

    func resume() {
        audioPlayer.resume()
        startWordTimingEmission()
    }

    func stop() {
        isCancelled = true
        wordTimingTask?.cancel()
        pendingChunks.removeAll()
        audioPlayer.stop()
        audioPlayer.tearDown()
        continuation.yield(.cancelled)
        continuation.finish()
    }

    /// Signals that synthesis has failed.
    ///
    /// - Parameter error: The error that caused the failure.
    func finish(throwing error: Error) {
        guard !isCancelled else { return }
        audioPlayer.tearDown()
        continuation.finish(throwing: error)
    }

    // MARK: - Playback Pipeline

    private func playNextPendingChunk() {
        guard !isCancelled, !pendingChunks.isEmpty else {
            isPlaying = false
            return
        }

        let chunk = pendingChunks.removeFirst()
        let isLastChunk = chunk.isLast
        isPlaying = true

        let samplesToPlay = applyCrossfade(to: chunk.samples, isLast: isLastChunk)

        audioPlayer.onPlaybackFinished = { [weak self] in
            guard let self else { return }
            self.wordTimingTask?.cancel()
            if self.pendingChunks.isEmpty, isLastChunk {
                self.audioPlayer.tearDown()
                self.continuation.yield(.finished)
                self.continuation.finish()
                self.isPlaying = false
            } else {
                self.playNextPendingChunk()
            }
        }

        do {
            try audioPlayer.play(samples: samplesToPlay)
            startWordTimingEmission(timedWords: chunk.timedWords)
        } catch {
            guard !isCancelled else { return }
            logger.error("Failed to play audio: \(error.localizedDescription, privacy: .public)")
            continuation.finish(throwing: TtsError.synthesisFailure(
                message: "Playback failed: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Crossfade

    /// Applies a cosine crossfade between the tail of the previous chunk
    /// and the head of the current chunk, then stores the current chunk's
    /// tail for the next transition.
    ///
    /// - Parameters:
    ///   - samples: Raw audio samples for the current chunk.
    ///   - isLast: Whether this is the final chunk (skips tail storage).
    /// - Returns: Samples with crossfade applied at the leading edge.
    private func applyCrossfade(to samples: [Float], isLast: Bool) -> [Float] {
        let fadeLen = Self.crossfadeSamples
        var output = samples

        // Blend previous chunk's tail into this chunk's head.
        if !previousTail.isEmpty, output.count >= fadeLen {
            let blendLen = min(previousTail.count, fadeLen, output.count)
            for i in 0 ..< blendLen {
                let progress = Float(i) / Float(blendLen)
                let fadeOut = cosineWindow(progress: 1.0 - progress)
                let fadeIn = cosineWindow(progress: progress)
                output[i] = previousTail[i] * fadeOut + output[i] * fadeIn
            }
        }

        // Store this chunk's tail for the next crossfade (unless last chunk).
        if !isLast, output.count >= fadeLen {
            previousTail = Array(output.suffix(fadeLen))
            output = Array(output.dropLast(fadeLen))
        } else {
            previousTail = []
        }

        return output
    }

    /// Cosine window function for smooth fade curves.
    /// Returns 0 at progress=0, 1 at progress=1.
    private func cosineWindow(progress: Float) -> Float {
        0.5 * (1.0 - cos(Float.pi * progress))
    }

    // MARK: - Word Timing Emission

    /// Poll interval for checking playback position against word timings.
    /// ~60 Hz provides responsive highlighting without excessive CPU cost.
    private static let timingPollNanoseconds: UInt64 = 16_000_000

    private func startWordTimingEmission(timedWords: [TimedWord]? = nil) {
        wordTimingTask?.cancel()

        if let timedWords {
            currentTimedWords = timedWords
        }

        let words = currentTimedWords
        guard !words.isEmpty else { return }

        let offsetsList = words.map { String(format: "%.3f", $0.timeOffset) }
            .joined(separator: ", ")
        logger.debug("Word timing: \(words.count) words, offsets=[\(offsetsList)]")

        wordTimingTask = Task { [weak self] in
            var wordIndex = 0
            var deltas: [Double] = []
            while wordIndex < words.count {
                guard let self, !Task.isCancelled, !self.isCancelled else { return }

                let now = self.audioPlayer.currentTime
                if now >= words[wordIndex].timeOffset {
                    let delta = (now - words[wordIndex].timeOffset) * 1000
                    deltas.append(delta)
                    let lo = words[wordIndex].timing.range.lowerBound
                    let hi = words[wordIndex].timing.range.upperBound
                    let nowStr = String(format: "%.3f", now)
                    let expStr = String(format: "%.3f", words[wordIndex].timeOffset)
                    let deltaStr = String(format: "%.0f", delta)
                    logger.debug(
                        "Word \(wordIndex) [\(lo)..<\(hi)] t=\(nowStr) exp=\(expStr) late=\(deltaStr)ms"
                    )
                    self.continuation.yield(.wordBoundary(words[wordIndex].timing))
                    wordIndex += 1
                } else {
                    try? await Task.sleep(nanoseconds: Self.timingPollNanoseconds)
                }
            }

            if !deltas.isEmpty {
                let avg = deltas.reduce(0, +) / Double(deltas.count)
                let maxDelta = deltas.max() ?? 0
                let avgStr = String(format: "%.0f", avg)
                let maxStr = String(format: "%.0f", maxDelta)
                logger.info(
                    "Chunk timing: \(deltas.count) words, avgLate=\(avgStr)ms, maxLate=\(maxStr)ms"
                )
            }
        }
    }
}
