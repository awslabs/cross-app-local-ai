import Foundation

/// TTS provider that surfaces an error on every API call.
///
/// Used as a placeholder while the real TTS provider is still being
/// constructed (on app launch, before CoreML models finish loading) or
/// when the real provider failed to initialize. Paired with
/// `FailedInitSttProvider` / `FailedInitLlmProvider`.
struct FailedInitTtsProvider: TtsProvider {
    let providerName = "Unavailable (error)"

    /// The error surfaced from every method call.
    let error: TtsError

    func speak(_: TtsSynthesisRequest) async throws -> AsyncThrowingStream<TtsEvent, Error> {
        throw error
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}

    func availableVoices() async -> [TtsVoice] {
        []
    }

    func validate() async throws {
        throw error
    }
}
