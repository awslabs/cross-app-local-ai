import Foundation

/// Deterministic mock LLM provider for testing and first-launch fallback.
///
/// Returns predictable responses based on the user prompt, with simulated
/// word-by-word streaming. No network or model loading required.
struct MockLlmProvider: LlmProvider {
    let providerName = "Mock"

    /// Delay between streamed words in nanoseconds (50ms).
    private let streamDelayNs: UInt64 = 50_000_000

    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        mockResponse(for: userPrompt)
    }

    func generateStream(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let response = mockResponse(for: userPrompt)
        let delay = streamDelayNs

        return AsyncThrowingStream { continuation in
            let task = Task {
                let words = response.split(separator: " ")
                for (index, word) in words.enumerated() {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: delay)
                    let suffix = index < words.count - 1 ? " " : ""
                    continuation.yield(String(word) + suffix)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func availableModels() -> [ModelInfo] {
        [ModelInfo(id: "mock-model", displayName: "Mock Model")]
    }

    func validate() async throws {
        // Mock provider is always valid
    }

    private func mockResponse(for userPrompt: String) -> String {
        "Mock response to: \(userPrompt)"
    }
}
