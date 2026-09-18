import Foundation
import OSLog
import WhisperKit

private let logger = Logger(subsystem: "com.aws.fastlang", category: "whisperkit.provider")

// MARK: - WhisperKitConfig

/// Configuration for the WhisperKit STT provider.
struct WhisperKitProviderConfig {
    var modelId = "whisper-small"
    var modelPath: String?
    var language = "en"
}

// MARK: - WhisperKitProvider

/// On-device speech-to-text provider backed by WhisperKit.
///
/// WhisperKit handles model download and CoreML compilation internally.
/// Audio input must be 16kHz mono PCM float32 samples.
final class WhisperKitSttProvider: SttProvider, @unchecked Sendable {
    let providerName = "WhisperKit"
    private let whisperKit: WhisperKit
    private let config: WhisperKitProviderConfig

    /// Creates a new WhisperKit provider.
    ///
    /// This triggers model download and compilation if the model is not
    /// already cached. May take several seconds on first launch.
    ///
    /// - Parameter config: The STT provider configuration.
    /// - Throws: `SttError` if WhisperKit initialization fails.
    init(config: WhisperKitProviderConfig) async throws {
        self.config = config

        let modelName = Self.mapModelId(config.modelId)
        let downloadBase = (try? AppDirs.resolve())?.dataDir
        // Resolve the cached model folder explicitly. WhisperKit's implicit
        // folder resolution only runs when `download: true`, which we can't
        // use here — it auto-pulls the model on every provider
        // construction, re-downloading anything the user just deleted.
        // With `download: false` we must supply `modelFolder` ourselves, or
        // init throws "Model folder is not set".
        guard let modelFolderURL = WhisperKitModelManager.cachedModelFolderURL(config.modelId) else {
            throw SttError.modelNotInstalled(modelId: config.modelId)
        }
        try await WhisperKitModelManager.verifyIntegrity(
            modelFolder: modelFolderURL, modelId: config.modelId
        )
        let modelFolderPath: String? = modelFolderURL.path
        let whisperConfig = WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            modelFolder: modelFolderPath,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )

        do {
            self.whisperKit = try await WhisperKit(whisperConfig)
            logger.info("WhisperKitProvider initialized with model '\(config.modelId)' -> '\(modelName)'")
        } catch {
            // Re-throw the underlying WhisperKit error unchanged so the
            // outer `SttService.createProvider` can wrap it once in
            // `SttError.providerInitFailed(modelId:underlying:)` with a
            // clean message. Previously we remapped to
            // `SttError.modelNotFound`, which meant the caller's wrapper
            // then produced `"Failed to load ... : STT model not found"` —
            // the same information stated twice.
            logger.error("WhisperKit initialization failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - SttProvider

    func transcribe(_ audio: AudioBuffer) async throws -> Transcription {
        let samples = Self.convertToFloat32Samples(audio)
        guard !samples.isEmpty else {
            throw SttError.transcriptionFailed(message: "Audio buffer is empty")
        }

        do {
            let results = try await whisperKit.transcribe(audioArray: samples)
            guard let firstResult = results.first else {
                // No segments is a "no speech detected" outcome, not a
                // failure. Return empty text and let the caller decide
                // whether to surface this (the PTT handler treats empty
                // text as a silent no-op, which is the desired UX).
                return Transcription(text: "", language: config.language, confidence: nil)
            }
            let text = firstResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Transcription(text: text, language: config.language, confidence: nil)
        } catch let error as SttError {
            throw error
        } catch {
            throw SttError.transcriptionFailed(message: error.localizedDescription)
        }
    }

    func transcribeStream(
        audio: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        var allSamples: [Float] = []
        for await chunk in audio {
            let chunkSamples = Self.convertChunkToFloat32(chunk)
            allSamples.append(contentsOf: chunkSamples)
        }

        guard !allSamples.isEmpty else {
            throw SttError.transcriptionFailed(message: "No audio data received")
        }

        let results = try await whisperKit.transcribe(audioArray: allSamples)
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let language = config.language

        return AsyncThrowingStream { continuation in
            continuation.yield(.final(Transcription(
                text: text,
                language: language,
                confidence: nil
            )))
            continuation.finish()
        }
    }

    func supportedLanguages() -> [String] {
        ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ar", "hi", "ru"]
    }

    func validate() async throws {
        // WhisperKit validates during init; if we got here, it's valid
    }

    // MARK: - Model ID Mapping

    /// Maps our internal model IDs to WhisperKit-compatible model identifiers.
    private static func mapModelId(_ id: String) -> String {
        switch id {
        case "whisper-tiny": "openai_whisper-tiny"
        case "whisper-base": "openai_whisper-base"
        case "whisper-small": "openai_whisper-small"
        case "whisper-medium": "openai_whisper-medium"
        case "whisper-large-v3": "openai_whisper-large-v3-v20240930_626MB"
        default: "openai_whisper-small"
        }
    }

    // MARK: - Audio Conversion

    /// Converts an `AudioBuffer` to a `[Float]` array for WhisperKit.
    ///
    /// Assumes the input is PCM float32 at 16kHz mono (the format produced
    /// by `AudioRecorder`).
    private static func convertToFloat32Samples(_ audio: AudioBuffer) -> [Float] {
        audio.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return [] }
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
            let count = audio.data.count / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: floatBuffer, count: count))
        }
    }

    /// Converts an `AudioChunk` to a `[Float]` array.
    private static func convertChunkToFloat32(_ chunk: AudioChunk) -> [Float] {
        chunk.data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return [] }
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
            let count = chunk.data.count / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: floatBuffer, count: count))
        }
    }
}
