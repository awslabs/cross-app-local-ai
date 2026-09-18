import Foundation

/// LLM provider that surfaces an error on every API call.
///
/// Used when the real provider can't be constructed (model missing on disk,
/// underlying framework threw on init, config references an unknown provider,
/// etc.). Replaces the earlier "fall back to MockLlmProvider" behavior so
/// failures are loud and diagnostic instead of silently returning fake
/// generation output.
///
/// - Note: Paired with `FailedInitSttProvider` in
///   `Providers/FailedInitSttProvider.swift`.
struct FailedInitLlmProvider: LlmProvider {
    /// The fixed provider name that `LlmService.isUnavailable` checks against.
    static let unavailableName = "Unavailable (error)"
    let providerName = unavailableName

    /// The error surfaced from every method call.
    let error: LlmError

    func generate(systemPrompt _: String, userPrompt _: String) async throws -> String {
        throw error
    }

    func generateStream(
        systemPrompt _: String,
        userPrompt _: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        throw error
    }

    func availableModels() -> [ModelInfo] {
        []
    }

    func validate() async throws {
        throw error
    }
}
