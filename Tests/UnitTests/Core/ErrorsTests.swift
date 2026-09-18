import Foundation
import Testing
@testable import FastLang

@Suite("LlmError")
struct LlmErrorTests {

    @Test("every case has a non-empty userMessage")
    func allCasesHaveMessages() {
        let cases: [LlmError] = [
            .authentication(message: "bad creds", provider: "bedrock"),
            .rateLimit(message: "throttled", retryAfterSecs: 5),
            .modelNotFound(modelId: "test", availableModels: []),
            .network(message: "connection refused"),
            .invalidRequest(message: "bad params"),
            .provider(message: "internal", provider: "llamacpp"),
            .configuration(message: "missing field"),
            .timeout(seconds: 30),
            .contentFiltered,
            .modelFile(message: "corrupt gguf"),
        ]
        for error in cases {
            #expect(!error.userMessage.isEmpty, "Empty message for \(error)")
        }
    }

    @Test("retryable errors are rateLimit, network, and timeout")
    func retryableFlags() {
        #expect(LlmError.rateLimit(message: "", retryAfterSecs: nil).isRetryable)
        #expect(LlmError.network(message: "").isRetryable)
        #expect(LlmError.timeout(seconds: 30).isRetryable)

        #expect(!LlmError.authentication(message: "", provider: "").isRetryable)
        #expect(!LlmError.modelNotFound(modelId: "", availableModels: []).isRetryable)
        #expect(!LlmError.invalidRequest(message: "").isRetryable)
        #expect(!LlmError.contentFiltered.isRetryable)
        #expect(!LlmError.modelFile(message: "").isRetryable)
    }

    @Test("suggestedAction is non-nil for actionable errors")
    func suggestedActions() {
        #expect(LlmError.authentication(message: "", provider: "").suggestedAction != nil)
        #expect(LlmError.rateLimit(message: "", retryAfterSecs: nil).suggestedAction != nil)
        #expect(LlmError.modelNotFound(modelId: "", availableModels: []).suggestedAction != nil)
        #expect(LlmError.network(message: "").suggestedAction != nil)
        #expect(LlmError.timeout(seconds: 0).suggestedAction != nil)
        #expect(LlmError.contentFiltered.suggestedAction != nil)
        #expect(LlmError.modelFile(message: "").suggestedAction != nil)
        #expect(LlmError.configuration(message: "").suggestedAction != nil)
    }

    @Test("conforms to LocalizedError with errorDescription")
    func localizedError() {
        let error = LlmError.network(message: "timeout")
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription == error.userMessage)
    }
}

@Suite("FastLangError")
struct FastLangErrorTests {

    @Test("wrapping LlmError preserves retryable")
    func wrappedRetryable() {
        let llmErr = LlmError.network(message: "fail")
        let wrapped = FastLangError.llm(llmErr)
        #expect(wrapped.isRetryable)
    }

    @Test("non-LLM errors are not retryable")
    func nonLlmNotRetryable() {
        #expect(!FastLangError.config(message: "bad").isRetryable)
        #expect(!FastLangError.platform(message: "fail").isRetryable)
        #expect(!FastLangError.ui(message: "crash").isRetryable)
    }

    @Test("wrapping preserves nested userMessage")
    func wrappedMessage() {
        let capture = CaptureError.accessibilityDenied
        let wrapped = FastLangError.capture(capture)
        #expect(wrapped.userMessage == capture.userMessage)
    }
}

@Suite("SttError")
struct SttErrorTests {

    @Test("all cases have non-empty userMessage")
    func allCasesHaveMessages() {
        let cases: [SttError] = [
            .notConfigured,
            .recordingFailed(message: "no device"),
            .transcriptionFailed(message: "model error"),
            .modelNotFound(modelId: "whisper-large"),
            .permissionDenied,
            .modelIntegrityFailed(modelId: "whisper-small"),
        ]
        for error in cases {
            #expect(!error.userMessage.isEmpty, "Empty message for \(error)")
        }
    }

    @Test("modelIntegrityFailed has suggestedAction")
    func modelIntegritySuggestedAction() {
        let error = SttError.modelIntegrityFailed(modelId: "whisper-small")
        #expect(error.suggestedAction != nil)
        #expect(error.suggestedAction?.contains("re-download") == true)
    }
}

@Suite("CaptureError")
struct CaptureErrorTests {

    @Test("accessibilityDenied has a suggested action")
    func accessibilitySuggestion() {
        let action = CaptureError.accessibilityDenied.suggestedAction
        #expect(action != nil)
        #expect(action?.contains("Accessibility") == true)
    }
}

@Suite("enrichErrorMessage")
struct EnrichErrorMessageTests {

    @Test("context window errors get a hint")
    func contextWindow() {
        let enriched = enrichErrorMessage("NoKvCacheSlot: no space")
        #expect(enriched.contains("context window"))
    }

    @Test("prompt too long errors get a hint")
    func promptTooLong() {
        let enriched = enrichErrorMessage("Error: prompt is too long for model")
        #expect(enriched.contains("context window"))
    }

    @Test("timeout errors get a hint")
    func timeout() {
        let enriched = enrichErrorMessage("Request timed out after 30s")
        #expect(enriched.contains("timed out"))
    }

    @Test("network errors get a hint")
    func network() {
        let enriched = enrichErrorMessage("Network connection lost")
        #expect(enriched.contains("internet connection"))
    }

    @Test("unknown errors are returned unchanged")
    func unknown() {
        let original = "Something completely unexpected happened"
        let enriched = enrichErrorMessage(original)
        #expect(enriched == original)
    }

    #if BEDROCK_ENABLED
        @Test("AccessDeniedException gets credential hint")
        func bedrockAccessDenied() {
            let enriched = enrichErrorMessage("AccessDeniedException: not authorized")
            #expect(enriched.contains("AWS credentials"))
        }

        @Test("ThrottlingException gets rate limit hint")
        func bedrockThrottling() {
            let enriched = enrichErrorMessage("ThrottlingException: too many requests")
            #expect(enriched.contains("rate-limited"))
        }

        @Test("ValidationException gets model hint")
        func bedrockValidation() {
            let enriched = enrichErrorMessage("ValidationException: invalid model")
            #expect(enriched.contains("model selection"))
        }

        @Test("ResourceNotFoundException gets region hint")
        func bedrockResourceNotFound() {
            let enriched = enrichErrorMessage("ResourceNotFoundException: model not found")
            #expect(enriched.contains("region"))
        }
    #endif
}
