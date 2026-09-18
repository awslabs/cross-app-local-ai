import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "llmservice")

// MARK: - LlmServiceConfig

/// Runtime configuration for the LLM service.
///
/// Constructed from the persisted `LlmConfig` during service initialization.
/// Separate from the `Codable` config to avoid coupling serialization to
/// service internals.
struct LlmServiceConfig: Equatable {
    var provider = "local_llamacpp"
    var region = "us-east-1"
    var awsProfile: String?
    var maxTokens = 1024
    var temperature: Float = 0.7
    var mockMode = false
    // Per-provider model ids, mirroring `LlmConfig`. The provider selects its
    // own field, so a mismatched pairing can't occur by construction. The
    // local id is non-optional: the config layer guarantees a value, so the
    // service never invents its own default.
    var localModelId = LlamaCppModels.defaultModelId
    var localModelPath: String?
    var localGpuLayers: UInt32 = 999
    var localContextSize: UInt32 = 4096
    var bedrockModelId = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

// MARK: - LlmService

/// Provider-agnostic LLM service that manages provider lifecycle.
///
/// Holds the active `LlmProvider` and delegates all generation calls to it.
/// Provider selection is based on the `LlmServiceConfig.provider` field.
/// Swapping providers is done by calling `updateConfig(_:)`.
actor LlmService {
    private var config: LlmServiceConfig
    private var provider: any LlmProvider

    /// Creates a new LLM service with the given configuration.
    ///
    /// Selects the provider based on `config.provider` and `config.mockMode`:
    /// - `mockMode == true` -> `MockLlmProvider` (tests only)
    /// - `"local_llamacpp"` with cached model -> `LlamaCppProvider`
    /// - `"local_llamacpp"` with missing model -> `FailedInitLlmProvider`
    ///   throwing `LlmError.modelNotInstalled` on every call
    /// - `"bedrock"` -> `BedrockProvider` (only when `BEDROCK_ENABLED`)
    /// - Provider init failure -> `FailedInitLlmProvider` throwing
    ///   `LlmError.providerInitFailed`
    /// - Unknown provider -> `FailedInitLlmProvider` throwing
    ///   `LlmError.unknownProvider`
    ///
    /// - Parameter config: The runtime LLM configuration.
    init(config: LlmServiceConfig) async {
        self.config = config
        let created = await Self.createProvider(for: config)
        self.provider = created
        logger.info("LlmService initialized with provider: \(created.providerName)")
    }

    // MARK: - Generation

    /// Non-streaming text generation.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system-level instruction.
    ///   - userPrompt: The user's input prompt.
    /// - Returns: The full generated text.
    /// - Throws: `LlmError` on failure.
    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        try await provider.generate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    /// Streaming text generation.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system-level instruction.
    ///   - userPrompt: The user's input prompt.
    /// - Returns: An `AsyncThrowingStream` that yields token strings.
    /// - Throws: `LlmError` on failure to start the stream.
    func generateStream(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        try await provider.generateStream(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    /// Validates the current provider configuration.
    ///
    /// - Throws: `LlmError` if validation fails.
    func validateConfig() async throws {
        try await provider.validate()
    }

    // MARK: - Configuration

    /// Updates the service configuration and reconstructs the provider.
    ///
    /// - Parameter newConfig: The new runtime configuration.
    func updateConfig(_ newConfig: LlmServiceConfig) async {
        config = newConfig
        provider = await Self.createProvider(for: newConfig)
        logger.info("LlmService reconfigured with provider: \(self.provider.providerName)")
    }

    /// Whether the service is running in mock mode.
    var isMockMode: Bool {
        config.mockMode
    }

    /// Whether the current provider is a failed-init stub.
    ///
    /// `true` when `BedrockProvider` or `LlamaCppProvider` construction
    /// failed (bad credentials, missing model, etc.) and the service is
    /// holding a `FailedInitLlmProvider` in its place. The caller can
    /// check this before generation and attempt a reconstruction if the
    /// underlying failure condition (e.g. an expired corporate SSO
    /// session used by the configured `credential_process` tool) may
    /// have cleared.
    var isUnavailable: Bool {
        provider.providerName == FailedInitLlmProvider.unavailableName
    }

    /// The human-readable name of the current provider.
    var providerName: String {
        provider.providerName
    }

    /// Whether the current provider can safely serve multiple `generate`
    /// calls in flight at once (e.g. Bedrock). Callers doing bulk work like
    /// map-reduce summarization use this to decide whether to parallelize
    /// chunk requests.
    var supportsConcurrentGeneration: Bool {
        provider.supportsConcurrentRequests
    }

    /// Lists models available through the current provider.
    func availableModels() -> [ModelInfo] {
        provider.availableModels()
    }

    /// Returns available models for a given provider name without constructing
    /// a live provider instance.
    ///
    /// Used by the settings UI for model dropdowns.
    ///
    /// - Parameter providerName: The provider identifier (e.g. `"local_llamacpp"`).
    /// - Returns: An array of `ModelInfo` for the model picker.
    static func modelsForProvider(_ providerName: String) -> [ModelInfo] {
        switch providerName {
        case "local_llamacpp":
            LlamaCppModels.staticModels()
        #if BEDROCK_ENABLED
            case "bedrock":
                BedrockProvider.staticModels()
        #endif
        case "mock":
            MockLlmProvider().availableModels()
        default:
            []
        }
    }

    // MARK: - Provider Construction

    private static func createProvider(for config: LlmServiceConfig) async -> any LlmProvider {
        if config.mockMode {
            logger.debug("Using MockLlmProvider (mock mode)")
            return MockLlmProvider()
        }

        switch config.provider {
        case "local_llamacpp":
            // Pre-flight cache check. If the model isn't on disk, surface a
            // specific error from every subsequent call instead of silently
            // returning mock generations. The user-facing download flow runs
            // separately through `LlamaCppModels.startModelDownload`.
            let activeModelId = config.localModelId
            guard LlamaCppModels.isModelCached(activeModelId) else {
                logger
                    .info(
                        "Local model '\(activeModelId)' not cached; LLM will surface modelNotInstalled errors until downloaded"
                    )
                return FailedInitLlmProvider(
                    error: .modelNotInstalled(modelId: activeModelId)
                )
            }
            do {
                let llamaConfig = LlamaCppConfig(
                    modelId: activeModelId,
                    modelPath: config.localModelPath,
                    nGpuLayers: config.localGpuLayers,
                    contextSize: config.localContextSize,
                    maxTokens: UInt32(config.maxTokens),
                    temperature: config.temperature
                )
                return try await LlamaCppProvider(config: llamaConfig)
            } catch {
                logger
                    .error(
                        "Failed to create LlamaCppProvider: \(error.localizedDescription). LLM will surface providerInitFailed errors."
                    )
                return FailedInitLlmProvider(
                    error: .providerInitFailed(
                        modelId: activeModelId,
                        underlying: error.localizedDescription
                    )
                )
            }
        #if BEDROCK_ENABLED
            case "bedrock":
                do {
                    let bedrockConfig = BedrockProviderConfig(
                        modelId: config.bedrockModelId,
                        region: config.region,
                        awsProfile: config.awsProfile,
                        maxTokens: UInt32(config.maxTokens),
                        temperature: config.temperature
                    )
                    return try await BedrockProvider(config: bedrockConfig)
                } catch {
                    logger
                        .error(
                            "Failed to create BedrockProvider: \(error.localizedDescription). LLM will surface providerInitFailed errors."
                        )
                    return FailedInitLlmProvider(
                        error: .providerInitFailed(
                            modelId: config.bedrockModelId,
                            underlying: error.localizedDescription
                        )
                    )
                }
        #endif
        default:
            logger
                .warning(
                    "Unknown provider '\(config.provider)'; LLM will surface unknownProvider errors"
                )
            return FailedInitLlmProvider(error: .unknownProvider(name: config.provider))
        }
    }
}
