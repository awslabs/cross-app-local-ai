import Foundation

/// Provider-agnostic speech-to-text interface.
///
/// Implementations live in `Providers/` and are selected at runtime based on
/// the user's STT configuration. The `SttService` actor holds the active
/// provider and delegates transcription calls to it.
protocol SttProvider: Sendable {
    /// Transcribes a complete audio buffer in one shot.
    ///
    /// - Parameter audio: The recorded audio with format metadata.
    /// - Returns: The transcription result.
    /// - Throws: `SttError` on failure.
    func transcribe(_ audio: AudioBuffer) async throws -> Transcription

    /// Starts a streaming transcription session.
    ///
    /// Receives audio chunks through the input stream and yields transcription
    /// events (partial and final) through the returned stream.
    ///
    /// - Parameter audio: An async stream of audio chunks to transcribe.
    /// - Returns: An `AsyncThrowingStream` that yields `TranscriptionEvent` values.
    /// - Throws: `SttError` on failure to start the stream.
    func transcribeStream(
        audio: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, Error>

    /// Human-readable provider name for error messages and UI display.
    var providerName: String { get }

    /// Lists languages supported by this provider.
    ///
    /// - Returns: ISO 639-1 language codes (e.g. `["en", "es", "fr"]`).
    func supportedLanguages() -> [String]

    /// Validates that the provider is correctly configured and operational.
    ///
    /// - Throws: `SttError` if validation fails.
    func validate() async throws
}
