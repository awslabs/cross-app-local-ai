import Foundation

/// Information about a model available through a provider.
struct ModelInfo: Identifiable, Equatable {
    /// Unique identifier used for provider API calls and persistence.
    let id: String
    /// Human-readable name shown in the settings UI.
    let displayName: String
}

/// Provider-agnostic LLM interface.
///
/// Implementations live in `Providers/` and are selected at runtime based on
/// the user's configuration. The `LlmService` actor holds the active provider
/// and delegates generation calls to it.
///
/// Streaming uses `AsyncThrowingStream<String, Error>`: each element is a
/// token string, stream termination signals completion, and errors are thrown.
protocol LlmProvider: Sendable {
    /// Generates a complete response (non-streaming).
    ///
    /// - Parameters:
    ///   - systemPrompt: The system-level instruction.
    ///   - userPrompt: The user's input prompt.
    /// - Returns: The full generated text.
    /// - Throws: `LlmError` on failure.
    func generate(systemPrompt: String, userPrompt: String) async throws -> String

    /// Generates a streaming response, yielding tokens incrementally.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system-level instruction.
    ///   - userPrompt: The user's input prompt.
    /// - Returns: An `AsyncThrowingStream` that yields token strings.
    /// - Throws: `LlmError` on failure to start the stream.
    func generateStream(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> AsyncThrowingStream<String, Error>

    /// Human-readable provider name for error messages and UI display.
    var providerName: String { get }

    /// Lists models available through this provider.
    ///
    /// - Returns: An array of `ModelInfo` for the settings model picker.
    func availableModels() -> [ModelInfo]

    /// Validates that the provider is correctly configured and operational.
    ///
    /// - Throws: `LlmError.configuration` if validation fails.
    func validate() async throws

    /// Whether this provider can safely serve multiple `generate` calls in
    /// flight at once.
    ///
    /// Remote HTTP providers (Bedrock) can; a single in-process model
    /// context (llama.cpp) cannot. Callers doing bulk work like map-reduce
    /// summarization use this to decide whether to parallelize chunk
    /// requests. Defaults to `false` so a new provider is safe-by-default
    /// until it explicitly opts in.
    var supportsConcurrentRequests: Bool { get }
}

extension LlmProvider {
    var supportsConcurrentRequests: Bool { false }
}
