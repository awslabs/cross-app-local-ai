import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "sttservice")

// MARK: - SttServiceConfig

/// Runtime configuration for the STT service.
///
/// Constructed from the persisted `SttAppConfig` during service initialization.
struct SttServiceConfig: Equatable {
    var provider = "whisper"
    var language: String? = "en"
    var mockMode = false
    var whisperModelId = "whisper-small"
    var whisperModelPath: String?
}

// MARK: - SttService

/// Provider-agnostic speech-to-text service that manages provider lifecycle.
///
/// Holds the active `SttProvider` and delegates all transcription calls to it.
/// Provider selection is based on `SttServiceConfig.provider`.
actor SttService {
    private var config: SttServiceConfig
    private var provider: any SttProvider

    /// Creates a new STT service with the given configuration.
    ///
    /// Selects the provider based on `config.provider` and `config.mockMode`:
    /// - `mockMode == true` -> `FailedInitSttProvider(.notConfigured)`
    ///   (feature disabled via Settings; transcription calls throw the
    ///   clean error instead of silently returning fake text).
    /// - `"whisper"` with cached model -> `WhisperKitSttProvider`
    /// - `"whisper"` with missing model -> `FailedInitSttProvider`
    ///   throwing `SttError.modelNotInstalled` on every call
    /// - Provider init failure -> `FailedInitSttProvider` throwing
    ///   `SttError.providerInitFailed`
    /// - Unknown provider -> `FailedInitSttProvider` throwing
    ///   `SttError.unknownProvider`
    ///
    /// - Parameter config: The runtime STT configuration.
    init(config: SttServiceConfig) async {
        self.config = config
        let created = await Self.createProvider(for: config)
        self.provider = created
        logger.info("SttService initialized with provider: \(created.providerName)")
    }

    /// Creates a service pre-populated with a specific provider, used
    /// for the transient "starting up" state while a real provider is
    /// being constructed in the background. See
    /// `AppState.reconstructSttService` for usage.
    ///
    /// - Parameters:
    ///   - config: The runtime STT configuration (retained for any
    ///     subsequent `updateConfig(_:)` calls).
    ///   - overridingProvider: Provider to install directly, bypassing
    ///     `createProvider` and its async construction costs.
    init(config: SttServiceConfig, overridingProvider: any SttProvider) async {
        self.config = config
        self.provider = overridingProvider
        logger.info(
            "SttService initialized with overriding provider: \(overridingProvider.providerName)"
        )
    }

    // MARK: - Transcription

    /// Transcribes a complete audio buffer in one shot.
    ///
    /// - Parameter audio: The recorded audio with format metadata.
    /// - Returns: The transcription result.
    /// - Throws: `SttError` on failure.
    func transcribe(_ audio: AudioBuffer) async throws -> Transcription {
        try await provider.transcribe(audio)
    }

    /// Starts a streaming transcription session.
    ///
    /// - Parameter audio: An async stream of audio chunks.
    /// - Returns: An `AsyncThrowingStream` yielding transcription events.
    /// - Throws: `SttError` on failure.
    func transcribeStream(
        audio: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        try await provider.transcribeStream(audio: audio)
    }

    /// Validates the current provider configuration.
    ///
    /// - Throws: `SttError` if validation fails.
    func validateConfig() async throws {
        try await provider.validate()
    }

    // MARK: - Configuration

    /// Updates the service configuration and reconstructs the provider.
    ///
    /// - Parameter newConfig: The new runtime configuration.
    func updateConfig(_ newConfig: SttServiceConfig) async {
        config = newConfig
        provider = await Self.createProvider(for: newConfig)
        logger.info("SttService reconfigured with provider: \(self.provider.providerName)")
    }

    /// The human-readable name of the current provider.
    var providerName: String {
        provider.providerName
    }

    /// The error the active provider would throw on use, if it's a
    /// failed-init placeholder rather than a usable provider — e.g. still
    /// warming up after launch (`.startingUp`), model not on disk
    /// (`.modelNotInstalled`), or the feature disabled (`.notConfigured`).
    /// Returns `nil` when a real, ready provider is loaded.
    ///
    /// Mirrors `LlmService.isUnavailable`: lets callers detect an unusable
    /// provider up front instead of only discovering it when a call throws.
    var unavailableError: SttError? {
        (provider as? FailedInitSttProvider)?.error
    }

    /// Lists languages supported by the current provider.
    func supportedLanguages() -> [String] {
        provider.supportedLanguages()
    }

    // MARK: - Provider Construction

    private static func createProvider(for config: SttServiceConfig) async -> any SttProvider {
        if config.mockMode {
            logger.debug("STT feature disabled; returning error-surfacing provider")
            return FailedInitSttProvider(error: .notConfigured)
        }

        switch config.provider {
        case "whisper":
            // Pre-flight cache check. If the model isn't on disk, surface a
            // specific error from every subsequent call instead of silently
            // returning mock transcriptions. The user-facing download flow
            // runs separately through `WhisperKitModelManager.startModelDownload`.
            guard WhisperKitModelManager.isModelCached(config.whisperModelId) else {
                logger
                    .info(
                        "WhisperKit model '\(config.whisperModelId)' not cached; STT will surface modelNotInstalled errors until downloaded"
                    )
                return FailedInitSttProvider(
                    error: .modelNotInstalled(modelId: config.whisperModelId)
                )
            }
            do {
                let whisperConfig = WhisperKitProviderConfig(
                    modelId: config.whisperModelId,
                    modelPath: config.whisperModelPath,
                    language: config.language ?? "en"
                )
                return try await WhisperKitSttProvider(config: whisperConfig)
            } catch {
                logger
                    .error(
                        "Failed to create WhisperKitSttProvider: \(error.localizedDescription). STT will surface providerInitFailed errors."
                    )
                return FailedInitSttProvider(
                    error: .providerInitFailed(
                        modelId: config.whisperModelId,
                        underlying: error.localizedDescription
                    )
                )
            }
        default:
            logger.warning("Unknown STT provider '\(config.provider)'; STT will surface unknownProvider errors")
            return FailedInitSttProvider(error: .unknownProvider(name: config.provider))
        }
    }
}
