import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "ttsservice")

// MARK: - TtsServiceConfig

/// Runtime configuration for the TTS service.
///
/// Constructed from the persisted `TtsAppConfig` during service initialization.
/// Separate from the `Codable` config to avoid coupling serialization to
/// service internals.
struct TtsServiceConfig: Equatable {
    var provider = "system"
    var voiceId: String?
    var rate: Float = 0.5
    var language = "en-US"
    var mockMode = false
}

// MARK: - TtsService

/// Provider-agnostic text-to-speech service that manages provider lifecycle.
///
/// Holds the active `TtsProvider` and delegates all synthesis and transport
/// calls to it. Provider selection is based on `TtsServiceConfig.provider`.
actor TtsService {
    private var config: TtsServiceConfig
    private var provider: any TtsProvider

    /// Creates a new TTS service with the given configuration.
    ///
    /// Selects the provider based on `config.provider` and `config.mockMode`:
    /// - `mockMode == true` -> `FailedInitTtsProvider(.notConfigured)`
    ///   (feature disabled via Settings; synthesis calls throw the
    ///   clean error instead of silently succeeding with no audio).
    /// - `"system"` -> `AVSpeechTtsProvider`
    /// - `"kokoro"` -> `KokoroTtsProvider`
    /// - Unknown provider -> `FailedInitTtsProvider(.notConfigured)`
    ///
    /// - Parameter config: The runtime TTS configuration.
    init(config: TtsServiceConfig) {
        self.config = config
        let created = Self.createProvider(for: config)
        self.provider = created
        logger.info("TtsService initialized with provider: \(created.providerName)")
    }

    // MARK: - Synthesis

    /// Begins synthesizing and playing the given text.
    ///
    /// - Parameter request: The synthesis parameters.
    /// - Returns: An async stream of `TtsEvent` values.
    /// - Throws: `TtsError` if synthesis cannot start.
    func speak(_ request: TtsSynthesisRequest) async throws -> AsyncThrowingStream<TtsEvent, Error> {
        try await provider.speak(request)
    }

    /// Pauses playback at the current word boundary.
    func pause() async {
        await provider.pause()
    }

    /// Resumes playback from where it was paused.
    func resume() async {
        await provider.resume()
    }

    /// Stops playback and cancels synthesis.
    func stop() async {
        await provider.stop()
    }

    /// Validates the current provider configuration.
    ///
    /// - Throws: `TtsError` if validation fails.
    func validateConfig() async throws {
        try await provider.validate()
    }

    // MARK: - Configuration

    /// Updates the service configuration and reconstructs the provider.
    ///
    /// - Parameter newConfig: The new runtime configuration.
    func updateConfig(_ newConfig: TtsServiceConfig) {
        config = newConfig
        provider = Self.createProvider(for: newConfig)
        logger.info("TtsService reconfigured with provider: \(self.provider.providerName)")
    }

    /// The human-readable name of the current provider.
    var providerName: String {
        provider.providerName
    }

    /// Lists voices available through the current provider.
    func availableVoices() async -> [TtsVoice] {
        await provider.availableVoices()
    }

    // MARK: - Provider Construction

    private static func createProvider(for config: TtsServiceConfig) -> any TtsProvider {
        if config.mockMode {
            logger.debug("TTS feature disabled; returning error-surfacing provider")
            return FailedInitTtsProvider(error: .notConfigured)
        }

        switch config.provider {
        case "system":
            let avConfig = AVSpeechTtsProviderConfig(
                voiceId: config.voiceId,
                rate: config.rate,
                language: config.language
            )
            return AVSpeechTtsProvider(config: avConfig)
        case "kokoro":
            let kokoroConfig = KokoroTtsProviderConfig(
                voiceId: config.voiceId ?? KokoroTtsProviderConfig().voiceId,
                language: String(config.language.prefix(2))
            )
            return KokoroTtsProvider(config: kokoroConfig)
        default:
            logger.warning("Unknown TTS provider '\(config.provider)'; TTS will surface notConfigured errors")
            return FailedInitTtsProvider(error: .notConfigured)
        }
    }
}
