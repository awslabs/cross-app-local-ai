import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "audio.recorder")

// MARK: - AudioRecorderState

/// Observable recording lifecycle state.
enum AudioRecorderState {
    case idle
    case recording
    case stopping
}

// MARK: - AudioRecorderProtocol

/// Abstracts audio recording for testability.
///
/// The real implementation uses `AVAudioEngine`; tests inject a mock.
protocol AudioRecorderProtocol: Sendable {
    /// Starts recording and returns an `AsyncStream` of `AudioChunk` values.
    ///
    /// Each chunk contains raw PCM float32 data at 16kHz mono, suitable for
    /// direct consumption by WhisperKit.
    ///
    /// - Throws: `SttError.recordingFailed` if the audio engine cannot start,
    ///   or `SttError.permissionDenied` if microphone access is denied.
    /// - Returns: A stream of audio chunks that ends when `stop()` is called.
    func start() async throws -> AsyncStream<AudioChunk>

    /// Stops recording and finishes the chunk stream.
    func stop() async

    /// The complete recorded audio as a single buffer.
    ///
    /// Available after `stop()` is called. Returns `nil` if no audio was recorded.
    func recordedBuffer() async -> AudioBuffer?

    /// Wall-clock duration of the most recently completed recording session,
    /// measured from `start()` to `stop()`. `nil` if no session has
    /// completed yet.
    ///
    /// `recordedBuffer()` returning `nil` doesn't say whether the key was
    /// held for a genuine (but silent) session or barely tapped by
    /// accident; this exposes the timing needed to tell those apart.
    func recordingDuration() async -> TimeInterval?
}

// MARK: - RecorderState

/// Internal mutable state protected by `OSAllocatedUnfairLock`.
private struct RecorderMutableState {
    var state: AudioRecorderState = .idle
    var accumulatedData = Data()
    var continuation: AsyncStream<AudioChunk>.Continuation?
    var hasSuccessfulConversion = false
    var warmupGatePassed = false

    /// Persistent UID of the preferred input device. `nil` uses the
    /// system default. Lock-protected (rather than an immutable `let` on
    /// `AudioRecorder`) so `updatePreferredDevice` can change it after
    /// construction when the user picks a different microphone in
    /// Settings.
    var preferredDeviceUID: String?

    /// Wall-clock timestamp `start()` was called, cleared on `stop()`
    /// once `lastRecordingDuration` is derived from it.
    var recordingStartedAt: Date?

    /// Duration of the most recently completed session, computed in
    /// `stop()`. See `AudioRecorderProtocol.recordingDuration()`.
    ///
    /// Reset to `nil` at the start of every session (in `start()`) rather
    /// than relying solely on `stop()` to overwrite it. No current caller
    /// can observe a stale value — `recordingDuration()` is only read from
    /// behind an `isRecording` gate that's only `true` after `start()`
    /// succeeds, and every successful `start()`/`stop()` pair recomputes
    /// this fresh — but `start()`'s engine-setup failure path clears
    /// `recordingStartedAt` without updating this field, so without the
    /// reset a previous session's value would otherwise sit here stale
    /// until the next real `stop()`.
    var lastRecordingDuration: TimeInterval?
}

/// RMS energy below this threshold is treated as silence during warmup.
/// Empirically tuned: Bluetooth profile switches produce near-zero energy.
private let warmupSilenceThreshold: Float = 0.005

// MARK: - AudioRecorder

/// Records microphone audio at 16kHz mono float32 using `AVAudioEngine`.
///
/// The input node tap runs at the hardware's native sample rate (typically 48kHz).
/// An `AVAudioConverter` downsamples each buffer to the 16kHz mono float32 format
/// that WhisperKit expects. This avoids the `NSException` that AVFAudio throws when
/// a tap format doesn't match the hardware format on the input node.
///
/// Bluetooth audio devices (AirPods, etc.) trigger a codec profile switch the first
/// time the input element is accessed. `prewarm()` forces this switch at app startup
/// so the latency is absorbed before the user presses PTT. A warmup gate additionally
/// discards leading silence buffers that arrive while the switch completes.
final class AudioRecorder: AudioRecorderProtocol, @unchecked Sendable {
    private let protectedState = OSAllocatedUnfairLock(initialState: RecorderMutableState())

    /// The 16kHz mono float32 format required by WhisperKit.
    private let targetFormat: AVAudioFormat

    /// Engine and converter are created fresh per recording session to avoid
    /// `AVAudioEngine`'s "invalid reuse after initialization failure" error.
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?

    /// Test seam: when set, `updatePreferredDevice` calls this instead of
    /// dispatching the real detached `prewarm()`. `nil` (the production
    /// default) uses the real behavior. Lets unit tests verify the UID
    /// persists and the re-warm decision fires without touching real
    /// `AVAudioEngine`/CoreAudio hardware. `internal`, not `private`, so
    /// `@testable import` tests can set it.
    var prewarmOverride: (() -> Void)?

    /// Creates a new audio recorder.
    ///
    /// - Parameter preferredDeviceUID: Persistent UID of the preferred input device.
    ///   Pass `nil` to use the system default.
    init(preferredDeviceUID: String? = nil) {
        protectedState.withLock { $0.preferredDeviceUID = preferredDeviceUID }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to create 16kHz mono float32 AVAudioFormat")
        }
        self.targetFormat = format
    }

    /// Forces the audio subsystem to initialize the input device path.
    ///
    /// On Bluetooth devices (AirPods, headsets) macOS switches from the AAC
    /// stereo-out codec to the SCO hands-free codec the first time input is
    /// accessed. This switch takes ~500ms during which audio buffers are
    /// silence or garbage. Calling `prewarm()` at app startup absorbs this
    /// latency so the first real PTT recording captures clean audio.
    func prewarm() {
        let engine = AVAudioEngine()
        configureInputDevice(on: engine)
        _ = engine.inputNode.inputFormat(forBus: 0)
        logger.info("Audio input pre-warmed (Bluetooth profile switch triggered if needed)")
    }

    /// Updates the preferred input device for subsequent recording sessions
    /// and, if idle, immediately re-runs `prewarm()` against it.
    ///
    /// `AudioRecorder` is constructed once at app startup with whatever
    /// device was configured at that moment. Without this, picking a
    /// different microphone in Settings — e.g. a Bluetooth headset that
    /// connected after launch — had no effect until the app restarted:
    /// `start()` kept using the stale device. Re-warming immediately also
    /// means the codec-switch latency lands here instead of on the user's
    /// next PTT press.
    ///
    /// The UID is always persisted so the *next* `start()` picks it up
    /// regardless of this method's return. The re-warm itself only fires
    /// when the UID actually changed AND no recording is currently in
    /// progress. `prewarm()` opens a second `AVAudioEngine`/AUHAL against
    /// the same hardware a live session's `start()` engine is using;
    /// without this guard, saving settings mid-PTT (or right as the key is
    /// released) could force an unwanted Bluetooth profile renegotiation on
    /// the device the active recording is reading from — the exact glitch
    /// `prewarm()` exists to avoid in the first place.
    ///
    /// `prewarm()` blocks its calling thread for ~500ms while the Bluetooth
    /// codec switch completes. This method is called from `saveSettings()`
    /// on the main actor, so the re-warm is detached onto a background task
    /// (mirroring `AppState.initializeAsync()`'s startup prewarm) to avoid
    /// freezing the UI every time the user changes their microphone.
    ///
    /// The idle check above runs once, synchronously, before this method
    /// returns — but `Task.detached` doesn't run `prewarm()` until some
    /// later, unscheduled point. A PTT press can call `start()` in that
    /// gap, so `shouldRewarmNow()` re-checks idle state immediately before
    /// `prewarm()` actually opens its engine, narrowing (not eliminating)
    /// the race. A fully race-free fix would need `start()` to also
    /// respect a shared "warming" flag; not worth the added complexity for
    /// this low-severity, timing-dependent glitch.
    ///
    /// - Parameter uid: Persistent UID of the new preferred input device.
    ///   Pass `nil` to use the system default.
    func updatePreferredDevice(uid: String?) {
        let shouldPrewarm = protectedState.withLock { locked -> Bool in
            let changed = locked.preferredDeviceUID != uid
            locked.preferredDeviceUID = uid
            return changed && locked.state == .idle
        }
        guard shouldPrewarm else { return }

        if let prewarmOverride {
            prewarmOverride()
        } else {
            Task.detached { [self] in
                guard shouldRewarmNow() else { return }
                prewarm()
            }
        }
    }

    /// Re-checks idle state at the last possible moment before `prewarm()`
    /// runs. See the race-window note on `updatePreferredDevice`.
    /// `internal`, not `private`, so tests can exercise the guard logic
    /// directly without a timing-dependent async test.
    func shouldRewarmNow() -> Bool {
        protectedState.withLock { $0.state == .idle }
    }

    /// The currently configured preferred input device UID, or `nil` for
    /// the system default.
    ///
    /// Internal (not `private`) so `@testable import` regression tests can
    /// verify `updatePreferredDevice` actually persisted the new UID,
    /// without exposing the lock-protected `RecorderMutableState` type
    /// itself (which stays `private`).
    var currentPreferredDeviceUID: String? {
        protectedState.withLock { $0.preferredDeviceUID }
    }

    /// Forces the lock-protected state value without going through
    /// `start()`/`stop()`, which require real microphone hardware and OS
    /// permission. `internal`, not `private`, so `@testable import` tests
    /// can exercise `updatePreferredDevice`'s recording-state guard
    /// deterministically. Production code never calls this.
    func setStateForTesting(_ state: AudioRecorderState) {
        protectedState.withLock { $0.state = state }
    }

    /// Forces `recordingDuration()`'s return value without a real
    /// `start()`/`stop()` cycle. `internal`, not `private`, so
    /// `@testable import` tests can simulate a specific hold duration
    /// (e.g. a trivial accidental tap) deterministically. Production code
    /// never calls this.
    func setRecordingDurationForTesting(_ duration: TimeInterval?) {
        protectedState.withLock { $0.lastRecordingDuration = duration }
    }

    func recordingDuration() async -> TimeInterval? {
        protectedState.withLock { $0.lastRecordingDuration }
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        let hasPermission = await PermissionChecker.checkMicrophonePermission()
        guard hasPermission else {
            throw SttError.permissionDenied
        }

        let isIdle = protectedState.withLock { locked in
            guard locked.state == .idle else { return false }
            locked.accumulatedData = Data()
            locked.hasSuccessfulConversion = false
            locked.warmupGatePassed = false
            locked.recordingStartedAt = Date()
            locked.lastRecordingDuration = nil
            locked.state = .recording
            return true
        }
        guard isIdle else {
            throw SttError.recordingFailed(message: "Recording already in progress")
        }

        let stream = AsyncStream<AudioChunk> { continuation in
            self.protectedState.withLock { locked in
                locked.continuation = continuation
            }

            continuation.onTermination = { @Sendable _ in
                self.protectedState.withLock { locked in
                    locked.continuation = nil
                }
            }
        }

        do {
            let newEngine = AVAudioEngine()
            engine = newEngine
            configureInputDevice(on: newEngine)
            try installAudioTap(on: newEngine)
            try newEngine.start()
            logger.info("AudioRecorder started (16kHz mono float32 via converter)")
        } catch {
            // Any failure during setup — tap install, converter creation, or
            // engine start — must roll the recorder back to .idle. The state
            // was set to .recording before this block; leaving it there wedges
            // STT permanently, because every subsequent start() then throws
            // "Recording already in progress" while AppState still believes it
            // is idle. Previously only engine.start() failures were cleaned up,
            // so a throwing installAudioTap() (e.g. no input device ready)
            // leaked the .recording state.
            engine?.inputNode.removeTap(onBus: 0)
            engine = nil
            converter = nil
            // Extract the continuation under the lock, then finish() it outside
            // the lock. finish() synchronously runs the stream's onTermination
            // handler on this thread, and that handler also takes
            // `protectedState`. Calling finish() while the lock is held
            // re-enters a non-recursive os_unfair_lock and traps (SIGKILL).
            let continuation = protectedState.withLock { locked -> AsyncStream<AudioChunk>.Continuation? in
                locked.state = .idle
                locked.recordingStartedAt = nil
                let continuation = locked.continuation
                locked.continuation = nil
                return continuation
            }
            continuation?.finish()
            if let sttError = error as? SttError {
                throw sttError
            }
            throw SttError.recordingFailed(message: error.localizedDescription)
        }

        return stream
    }

    /// Sets the preferred input device on the engine's input audio unit.
    ///
    /// Must be called before `installAudioTap` and `engine.start()`.
    /// Falls back to the system default silently if the UID cannot be resolved.
    private func configureInputDevice(on engine: AVAudioEngine) {
        guard let uid = protectedState.withLock({ $0.preferredDeviceUID }) else { return }

        guard var deviceID = AudioDeviceEnumerator.deviceID(forUID: uid) else {
            logger.warning("Preferred input device '\(uid)' not found, using system default")
            return
        }

        guard let audioUnit = engine.inputNode.audioUnit else {
            logger.warning("No audio unit on input node, cannot set preferred device")
            return
        }

        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        if status == noErr {
            logger.info("Set input device to '\(uid)' (ID \(deviceID))")
        } else {
            logger.warning("Failed to set input device '\(uid)': OSStatus \(status)")
        }
    }

    private func installAudioTap(on engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            throw SttError.recordingFailed(
                message: "No audio input available (channels=\(hwFormat.channelCount), rate=\(hwFormat.sampleRate))"
            )
        }

        guard let newConverter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw SttError.recordingFailed(
                message: "Cannot create converter from \(hwFormat) to \(targetFormat)"
            )
        }
        converter = newConverter

        let capturedConverter = newConverter
        let capturedTargetFormat = targetFormat
        let targetSampleRate = targetFormat.sampleRate

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: hwFormat
        ) { [weak self] buffer, time in
            guard let self else { return }

            guard let convertedBuffer = self.convert(
                buffer: buffer,
                converter: capturedConverter,
                outputFormat: capturedTargetFormat
            ) else {
                self.logConversionFailure()
                return
            }

            guard let channelData = convertedBuffer.floatChannelData else { return }
            let frameCount = Int(convertedBuffer.frameLength)
            guard frameCount > 0 else { return }

            let data = Data(
                bytes: channelData[0],
                count: frameCount * MemoryLayout<Float>.size
            )
            let rms = Self.rmsEnergy(channelData[0], frameCount: frameCount)

            self.yieldIfPastWarmup(
                data: data,
                rmsEnergy: rms,
                sampleTime: time.sampleTime,
                targetSampleRate: targetSampleRate
            )
        }
    }

    /// Processes a converted audio buffer: applies warmup gate and yields a chunk.
    ///
    /// - Parameters:
    ///   - data: PCM float32 data already copied from the converted buffer.
    ///   - rmsEnergy: Pre-computed RMS energy of the buffer for warmup gating.
    ///   - sampleTime: The sample time from the original tap callback.
    ///   - targetSampleRate: The target sample rate for timestamp computation.
    private func yieldIfPastWarmup(
        data: Data,
        rmsEnergy: Float,
        sampleTime: AVAudioFramePosition,
        targetSampleRate: Double
    ) {
        let shouldYield = protectedState.withLock { locked -> Bool in
            locked.hasSuccessfulConversion = true

            if !locked.warmupGatePassed {
                if rmsEnergy < warmupSilenceThreshold {
                    return false
                }
                locked.warmupGatePassed = true
                logger.debug("Warmup gate passed (RMS \(rmsEnergy, format: .fixed(precision: 4)))")
            }

            locked.accumulatedData.append(data)
            return true
        }

        guard shouldYield else { return }

        let chunk = AudioChunk(
            data: data,
            timestamp: Double(sampleTime) / targetSampleRate
        )

        let cont = protectedState.withLock { $0.continuation }
        cont?.yield(chunk)
    }

    /// Computes RMS energy of a float32 audio buffer.
    static func rmsEnergy(_ samples: UnsafePointer<Float>, frameCount: Int) -> Float {
        guard frameCount > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for i in 0 ..< frameCount {
            let sample = samples[i]
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(frameCount)).squareRoot()
    }

    /// Converts a hardware-rate buffer to the 16kHz target format.
    private func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCapacity > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error != nil {
            return nil
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    /// Logs conversion failures at the appropriate level depending on warmup state.
    private func logConversionFailure() {
        let warmedUp = protectedState.withLock { $0.hasSuccessfulConversion }
        if warmedUp {
            logger.warning("Audio conversion failed after successful warmup")
        } else {
            logger.debug("Skipping buffer during audio engine warmup")
        }
    }

    func stop() async {
        let shouldStop = protectedState.withLock { locked -> Bool in
            guard locked.state == .recording else { return false }
            locked.state = .stopping
            return true
        }
        guard shouldStop else { return }

        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        converter = nil

        // Extract the continuation under the lock, then finish() it outside the
        // lock. finish() synchronously runs the stream's onTermination handler
        // on this thread, and that handler also takes `protectedState`. Calling
        // finish() while the lock is held re-enters a non-recursive
        // os_unfair_lock and traps (SIGKILL).
        let (continuation, byteCount) = protectedState.withLock { locked -> (
            AsyncStream<AudioChunk>.Continuation?,
            Int
        ) in
            let continuation = locked.continuation
            locked.continuation = nil
            locked.state = .idle
            if let startedAt = locked.recordingStartedAt {
                locked.lastRecordingDuration = Date().timeIntervalSince(startedAt)
            }
            locked.recordingStartedAt = nil
            return (continuation, locked.accumulatedData.count)
        }
        continuation?.finish()

        logger.info("AudioRecorder stopped (\(byteCount) bytes)")
    }

    func recordedBuffer() async -> AudioBuffer? {
        let data = protectedState.withLock { $0.accumulatedData }

        guard !data.isEmpty else { return nil }

        return AudioBuffer(
            meta: AudioMeta(
                format: .pcm,
                sampleRate: .wideband,
                channels: .mono
            ),
            data: data
        )
    }
}

// MARK: - MockAudioRecorder

/// Mock audio recorder for unit tests.
///
/// Yields preconfigured chunks when started, completes immediately on stop.
actor MockAudioRecorder: AudioRecorderProtocol {
    var chunks: [AudioChunk] = []
    var shouldFailOnStart = false
    var failureMessage = "Mock recording failure"
    /// Test-configurable value for `recordingDuration()`. The mock's own
    /// `start()`/`stop()` run near-instantly, so there's no real wall-clock
    /// duration to derive; tests set this directly to exercise callers that
    /// branch on recording duration (e.g. the short-tap vs. genuine-silence
    /// distinction in `AppState+Services`).
    var mockRecordingDuration: TimeInterval?
    private var storedBuffer: AudioBuffer?

    func start() async throws -> AsyncStream<AudioChunk> {
        if shouldFailOnStart {
            throw SttError.recordingFailed(message: failureMessage)
        }

        let capturedChunks = chunks
        var accumulated = Data()
        for chunk in capturedChunks {
            accumulated.append(chunk.data)
        }
        storedBuffer = accumulated.isEmpty ? nil : AudioBuffer(
            meta: AudioMeta(format: .pcm, sampleRate: .wideband, channels: .mono),
            data: accumulated
        )

        return AsyncStream { continuation in
            for chunk in capturedChunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func stop() async {
        // Mock stops immediately
    }

    func recordedBuffer() async -> AudioBuffer? {
        storedBuffer
    }

    func recordingDuration() async -> TimeInterval? {
        mockRecordingDuration
    }
}
