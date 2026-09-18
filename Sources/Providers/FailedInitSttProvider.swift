import Foundation

/// STT provider that surfaces an error on every API call.
///
/// Used when the real provider can't be constructed (model missing on disk,
/// underlying framework threw on init, config references an unknown provider,
/// etc.). Replaces the earlier "fall back to MockSttProvider" behavior so
/// failures are loud and diagnostic instead of silently returning fake
/// transcription text.
///
/// - Note: Paired with `FailedInitLlmProvider` in
///   `Providers/FailedInitLlmProvider.swift`. TTS uses its own dedicated
///   error flow and doesn't need this pattern.
struct FailedInitSttProvider: SttProvider {
    let providerName = "Unavailable (error)"

    /// The error surfaced from every method call.
    let error: SttError

    func transcribe(_: AudioBuffer) async throws -> Transcription {
        throw error
    }

    func transcribeStream(
        audio _: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        throw error
    }

    func supportedLanguages() -> [String] {
        []
    }

    func validate() async throws {
        throw error
    }
}
