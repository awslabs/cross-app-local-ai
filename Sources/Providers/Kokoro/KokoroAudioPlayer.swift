import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "kokoro.audioplayer")

// MARK: - KokoroAudioPlayer

/// Plays raw `[Float]` PCM audio through `AVAudioEngine`.
///
/// Wraps an `AVAudioEngine` with a single `AVAudioPlayerNode`.
/// Audio data is converted to an `AVAudioPCMBuffer` at the given sample rate
/// and scheduled on the player node. Supports pause, resume, stop, and
/// reports the current playback time for word-boundary synchronization.
///
/// All public methods must be called from the main thread since
/// `AVAudioEngine` has the same main-thread affinity requirements
/// as `AVSpeechSynthesizer`.
@MainActor
final class KokoroAudioPlayer {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let sampleRate: Double
    private var isEngineRunning = false

    /// Called when the player node finishes playing the scheduled buffer.
    var onPlaybackFinished: (() -> Void)?

    /// Creates a new audio player for the given sample rate.
    ///
    /// - Parameter sampleRate: The sample rate of the audio data (e.g. 24000 for Kokoro).
    init(sampleRate: Int) {
        self.sampleRate = Double(sampleRate)
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        // AVAudioFormat never returns nil for a standard format with valid sample rate and channel count.
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: self.sampleRate,
            channels: 1
        ) else {
            fatalError("Failed to create AVAudioFormat for sample rate \(sampleRate)")
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    /// Schedules and plays raw PCM samples.
    ///
    /// Stops any currently playing audio before scheduling the new buffer.
    ///
    /// - Parameter samples: Mono float PCM samples at `sampleRate` Hz.
    func play(samples: [Float]) throws {
        stop()

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw TtsError.synthesisFailure(message: "Failed to create audio format")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw TtsError.synthesisFailure(message: "Failed to create audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw TtsError.synthesisFailure(message: "Audio buffer has no channel data")
        }
        samples.withUnsafeBufferPointer { src in
            guard let baseAddress = src.baseAddress else { return }
            channelData.update(from: baseAddress, count: samples.count)
        }

        if !isEngineRunning {
            try engine.start()
            isEngineRunning = true
            let latencyMs = engine.outputNode.presentationLatency * 1000
            logger.debug("Audio engine started (output latency: \(String(format: "%.1f", latencyMs))ms)")
        }

        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            Task { @MainActor [weak self] in
                self?.onPlaybackFinished?()
            }
        }
        playerNode.play()

        let durationStr = String(format: "%.2f", Double(samples.count) / self.sampleRate)
        logger.debug("Playing \(samples.count) samples at \(self.sampleRate) Hz (\(durationStr)s)")
    }

    /// Pauses playback, preserving the current position.
    func pause() {
        guard playerNode.isPlaying else { return }
        playerNode.pause()
    }

    /// Resumes playback from where it was paused.
    func resume() {
        playerNode.play()
    }

    /// Stops playback and resets the player.
    func stop() {
        playerNode.stop()
    }

    /// Current *audible* playback time in seconds since the buffer started playing.
    ///
    /// The render graph processes audio ahead of what the user hears. Subtracting
    /// `outputNode.presentationLatency` shifts the reported position from the
    /// render cursor to the approximate point the user is actually hearing,
    /// keeping word-boundary highlights synchronized with speech.
    ///
    /// Returns 0 if nothing is playing or the position cannot be determined.
    var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return 0
        }
        let renderTime = Double(playerTime.sampleTime) / playerTime.sampleRate
        let latency = engine.outputNode.presentationLatency
        return max(0, renderTime - latency)
    }

    /// Tears down the audio engine.
    func tearDown() {
        playerNode.stop()
        if isEngineRunning {
            engine.stop()
            isEngineRunning = false
        }
    }
}
