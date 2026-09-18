import Foundation
import LocalLLMClient
import LocalLLMClientLlama
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "llamacpp.provider")

// MARK: - LlamaCppConfig

/// Configuration for the llama.cpp provider.
struct LlamaCppConfig {
    var modelId = "gemma-4-e2b"
    var modelPath: String?
    var nGpuLayers: UInt32 = 999
    var contextSize: UInt32 = 4096
    var maxTokens: UInt32 = 1024
    var temperature: Float = 0.7
}

// MARK: - LlamaCppProvider

/// Local LLM provider backed by llama.cpp via the LocalLLMClient package.
///
/// Wraps `LlamaClient` from `LocalLLMClientLlama` and conforms to the
/// `LlmProvider` protocol. The underlying GGUF model is loaded during
/// initialization when the `LlamaClient` is constructed.
final class LlamaCppProvider: LlmProvider, @unchecked Sendable {
    let providerName = "Local (llama.cpp)"
    private let config: LlamaCppConfig
    private let client: LlamaClient
    private let modelPath: URL

    /// Creates a new llama.cpp provider.
    ///
    /// Resolves the model path (downloading if needed), validates the GGUF
    /// file, and initializes the underlying `LlamaClient`.
    ///
    /// - Parameter config: The provider configuration.
    /// - Throws: `LlmError.modelFile` if the model cannot be found or is invalid.
    init(config: LlamaCppConfig) async throws {
        self.config = config

        let dirs = try AppDirs.resolve()
        let resolvedPath = try await LlamaCppModels.resolveModelPath(
            dirs: dirs,
            modelId: config.modelId,
            customPath: config.modelPath
        )
        try LlamaCppModels.validateGgufFile(at: resolvedPath)
        self.modelPath = resolvedPath

        let parameter = LlamaClient.Parameter(
            context: Int(config.contextSize),
            batch: 512,
            temperature: config.temperature,
            topK: 40,
            topP: 0.95
        )

        do {
            self.client = try await LocalLLMClient.llama(
                url: resolvedPath,
                parameter: parameter
            )
        } catch {
            throw Self.mapError(error)
        }

        logger.info("LlamaCppProvider created for model '\(config.modelId)' at \(resolvedPath.path)")
    }

    // MARK: - LlmProvider

    func generate(systemPrompt: String, userPrompt: String) async throws -> String {
        let input = Self.buildInput(systemPrompt: systemPrompt, userPrompt: userPrompt)
        do {
            return try await client.generateText(from: input)
        } catch {
            throw Self.mapError(error)
        }
    }

    func generateStream(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> AsyncThrowingStream<String, Error> {
        let input = Self.buildInput(systemPrompt: systemPrompt, userPrompt: userPrompt)

        let generator: Generator
        do {
            generator = try client.textStream(from: input)
        } catch {
            throw Self.mapError(error)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await token in generator {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
        }
    }

    func availableModels() -> [ModelInfo] {
        LlamaCppModels.staticModels()
    }

    func validate() async throws {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw LlmError.modelFile(message: "Model file no longer exists at \(modelPath.path)")
        }
    }

    // MARK: - Helpers

    private static func buildInput(systemPrompt: String, userPrompt: String) -> LLMInput {
        .chat([
            .system(systemPrompt),
            .user(userPrompt),
        ])
    }

    /// Maps LocalLLMClient errors to our domain `LlmError`.
    private static func mapError(_ error: Error) -> LlmError {
        if let llmError = error as? LLMError {
            switch llmError {
            case let .failedToLoad(reason):
                return .modelFile(message: "Failed to load model: \(reason)")
            case let .invalidParameter(reason):
                return .invalidRequest(message: reason)
            case let .failedToDecode(reason):
                return .provider(message: "Decoding error: \(reason)", provider: "local_llamacpp")
            case .visionUnsupported:
                return .invalidRequest(message: "Vision features are not supported")
            case let .unsupportedOperation(reason):
                return .invalidRequest(message: reason)
            }
        }
        return .provider(message: error.localizedDescription, provider: "local_llamacpp")
    }
}
