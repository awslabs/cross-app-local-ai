import Foundation

/// Provider-agnostic text-to-speech interface.
///
/// Each provider handles both synthesis and audio playback internally.
/// The event stream carries word-boundary notifications for UI highlighting;
/// no raw audio data flows through the protocol surface. Transport controls
/// (`pause`, `resume`, `stop`) delegate to the provider's native mechanism.
///
/// Implementations:
/// - `AVSpeechTtsProvider`: macOS built-in speech synthesis via `AVSpeechSynthesizer`.
/// - `KokoroTtsProvider`: on-device neural synthesis via Kokoro CoreML.
/// - `MockTtsProvider`: deterministic stub used only by the unit-test suite.
///
/// Future providers (Amazon Polly, OpenAI TTS, local neural models) would
/// manage their own audio engine internally and expose the same event stream.
protocol TtsProvider: Sendable {
    /// Begins synthesizing and playing the given text.
    ///
    /// Returns immediately with an event stream. Events are emitted as the
    /// provider progresses through the text:
    /// - `.wordBoundary(WordTiming)` each time a new word begins
    /// - `.finished` when playback completes naturally
    /// - `.cancelled` when stopped via `stop()`
    ///
    /// Only one synthesis session may be active at a time. Calling `speak`
    /// while already speaking throws `TtsError.alreadySpeaking`.
    ///
    /// - Parameter request: The synthesis parameters.
    /// - Returns: An async stream of `TtsEvent` values.
    /// - Throws: `TtsError` if synthesis cannot start.
    func speak(_ request: TtsSynthesisRequest) async throws -> AsyncThrowingStream<TtsEvent, Error>

    /// Pauses playback at the current word boundary.
    ///
    /// No-op if not currently speaking.
    func pause() async

    /// Resumes playback from where it was paused.
    ///
    /// No-op if not currently paused.
    func resume() async

    /// Stops playback and cancels synthesis.
    ///
    /// The event stream receives `.cancelled` and then finishes.
    /// No-op if not currently speaking or paused.
    func stop() async

    /// Human-readable provider name for error messages and UI display.
    var providerName: String { get }

    /// Lists voices available through this provider.
    ///
    /// - Returns: An array of `TtsVoice` for the settings voice picker.
    func availableVoices() async -> [TtsVoice]

    /// Validates that the provider is correctly configured and operational.
    ///
    /// - Throws: `TtsError` if validation fails.
    func validate() async throws
}
