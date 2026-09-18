import Foundation
import Testing
@testable import FastLang

@Suite("LlmService")
struct LlmServiceTests {

    @Test("mock mode creates MockLlmProvider")
    func mockModeCreatesMockProvider() async {
        let config = LlmServiceConfig(mockMode: true)
        let service = await LlmService(config: config)

        let name = await service.providerName
        #expect(name == "Mock")

        let isMock = await service.isMockMode
        #expect(isMock == true)
    }

    @Test("generate returns mock response in mock mode")
    func generateReturnsMockResponse() async throws {
        let config = LlmServiceConfig(mockMode: true)
        let service = await LlmService(config: config)

        let result = try await service.generate(
            systemPrompt: "system",
            userPrompt: "test"
        )
        #expect(result.contains("test"))
    }

    @Test("generateStream yields tokens and completes")
    func generateStreamYieldsTokens() async throws {
        let config = LlmServiceConfig(mockMode: true)
        let service = await LlmService(config: config)

        let stream = try await service.generateStream(
            systemPrompt: "system",
            userPrompt: "hello"
        )

        var collected = ""
        for try await token in stream {
            collected += token
        }

        #expect(!collected.isEmpty)
        #expect(collected.contains("hello"))
    }

    @Test("unknown provider surfaces error on generate")
    func unknownProviderSurfacesError() async {
        let config = LlmServiceConfig(provider: "nonexistent_provider")
        let service = await LlmService(config: config)

        // Unknown providers construct a FailedInitLlmProvider that throws
        // on every call. The service no longer silently falls back to the
        // mock, which previously hid configuration errors from users.
        await #expect(throws: LlmError.self) {
            _ = try await service.generate(systemPrompt: "s", userPrompt: "u")
        }
    }

    @Test("local_llamacpp creates a provider")
    func llamaCppCreatesProvider() async {
        let config = LlmServiceConfig(provider: "local_llamacpp")
        let service = await LlmService(config: config)

        // Construction depends on whether the local model is cached.
        // Either the real `LlamaCppProvider` or a
        // `FailedInitLlmProvider(.modelNotInstalled)` is valid —
        // both are well-typed outcomes.
        let name = await service.providerName
        let validNames: Set = ["Local (llama.cpp)", "Unavailable (error)"]
        #expect(validNames.contains(name))
    }

    #if BEDROCK_ENABLED
        @Test("bedrock creates a provider")
        func bedrockCreatesProvider() async {
            let config = LlmServiceConfig(provider: "bedrock")
            let service = await LlmService(config: config)

            // In dev environments without AWS credentials the Bedrock
            // client fails to initialize, in which case
            // `FailedInitLlmProvider` ("Unavailable (error)") replaces
            // the real provider. In fully-configured CI/local dev, the
            // real provider is returned.
            let name = await service.providerName
            let validNames: Set = ["AWS Bedrock", "Unavailable (error)"]
            #expect(validNames.contains(name))
        }
    #endif

    @Test("updateConfig changes provider")
    func updateConfigChangesProvider() async {
        let initialConfig = LlmServiceConfig(provider: "mock", mockMode: true)
        let service = await LlmService(config: initialConfig)

        let initialName = await service.providerName
        #expect(initialName == "Mock")

        let newConfig = LlmServiceConfig(provider: "local_llamacpp", mockMode: false)
        await service.updateConfig(newConfig)

        // As in `llamaCppCreatesProvider`, either a real or
        // error-surfacing provider is a valid outcome depending on
        // whether the local model is cached.
        let updatedName = await service.providerName
        let validNames: Set = ["Local (llama.cpp)", "Unavailable (error)"]
        #expect(validNames.contains(updatedName))

        let isMock = await service.isMockMode
        #expect(isMock == false)
    }

    @Test("availableModels returns non-empty list")
    func availableModelsNonEmpty() async {
        let config = LlmServiceConfig(mockMode: true)
        let service = await LlmService(config: config)

        let models = await service.availableModels()
        #expect(!models.isEmpty)
    }

    @Test("validateConfig does not throw for mock")
    func validateConfigSucceeds() async throws {
        let config = LlmServiceConfig(mockMode: true)
        let service = await LlmService(config: config)

        try await service.validateConfig()
    }

    @Test("modelsForProvider returns models for known providers")
    func modelsForProviderReturnsKnown() {
        let llamaModels = LlmService.modelsForProvider("local_llamacpp")
        #expect(!llamaModels.isEmpty)

        let mockModels = LlmService.modelsForProvider("mock")
        #expect(!mockModels.isEmpty)

        let unknownModels = LlmService.modelsForProvider("unknown")
        #expect(unknownModels.isEmpty)
    }

    #if BEDROCK_ENABLED
        @Test("modelsForProvider returns models for bedrock")
        func modelsForProviderReturnsBedrock() {
            let models = LlmService.modelsForProvider("bedrock")
            #expect(!models.isEmpty)
        }

        @Test("bedrock provider uses its own bedrockModelId, not the local id")
        func bedrockUsesBedrockModelId() async {
            // With per-provider model ids a local id can't leak into Bedrock.
            // A config whose localModelId is a gemma model but provider is
            // bedrock must still resolve to a real Bedrock provider (or the
            // no-credentials error-surfacing provider), never a broken one.
            let config = LlmServiceConfig(
                provider: "bedrock",
                localModelId: "gemma-4-e2b",
                bedrockModelId: BedrockModels.defaultModelId
            )
            let service = await LlmService(config: config)
            let name = await service.providerName
            let validNames: Set = ["AWS Bedrock", "Unavailable (error)"]
            #expect(validNames.contains(name))
        }
    #endif
}
