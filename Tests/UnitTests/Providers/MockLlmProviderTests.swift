import Foundation
import Testing
@testable import FastLang

@Suite("MockLlmProvider")
struct MockLlmProviderTests {

    @Test("providerName is Mock")
    func providerNameIsMock() {
        let provider = MockLlmProvider()
        #expect(provider.providerName == "Mock")
    }

    @Test("generate returns deterministic text containing user prompt")
    func generateReturnsDeterministicText() async throws {
        let provider = MockLlmProvider()
        let result = try await provider.generate(
            systemPrompt: "system",
            userPrompt: "test prompt"
        )
        #expect(result.contains("test prompt"))
    }

    @Test("generate result matches mock response format")
    func generateMatchesMockFormat() async throws {
        let provider = MockLlmProvider()
        let result = try await provider.generate(
            systemPrompt: "system",
            userPrompt: "hello"
        )
        #expect(result == "Mock response to: hello")
    }

    @Test("generateStream yields tokens that reconstruct the full response")
    func generateStreamReconstructsResponse() async throws {
        let provider = MockLlmProvider()
        let stream = try await provider.generateStream(
            systemPrompt: "system",
            userPrompt: "hello"
        )

        var collected = ""
        for try await token in stream {
            collected += token
        }

        let expected = try await provider.generate(
            systemPrompt: "system",
            userPrompt: "hello"
        )
        #expect(collected == expected)
    }

    @Test("generateStream yields multiple tokens")
    func generateStreamYieldsMultipleTokens() async throws {
        let provider = MockLlmProvider()
        let stream = try await provider.generateStream(
            systemPrompt: "system",
            userPrompt: "hello world"
        )

        var tokenCount = 0
        for try await _ in stream {
            tokenCount += 1
        }

        // "Mock response to: hello world" has 5 words -> 5 tokens
        #expect(tokenCount >= 2)
    }

    @Test("availableModels returns exactly one mock model")
    func availableModelsReturnsOne() {
        let provider = MockLlmProvider()
        let models = provider.availableModels()
        #expect(models.count == 1)
        #expect(models[0].id == "mock-model")
        #expect(models[0].displayName == "Mock Model")
    }

    @Test("validate does not throw")
    func validateSucceeds() async throws {
        let provider = MockLlmProvider()
        try await provider.validate()
    }
}
