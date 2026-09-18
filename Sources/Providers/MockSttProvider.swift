import Foundation

/// Deterministic mock STT provider for testing and first-launch fallback.
///
/// Returns predictable transcription text. No microphone or model required.
struct MockSttProvider: SttProvider {
    let providerName = "Mock STT"

    func transcribe(_ audio: AudioBuffer) async throws -> Transcription {
        Transcription(
            text: "Mock transcription of \(audio.data.count) bytes",
            language: "en",
            confidence: 0.95
        )
    }

    func transcribeStream(
        audio: AsyncStream<AudioChunk>
    ) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var chunkCount = 0
                for await _ in audio {
                    chunkCount += 1
                    continuation.yield(.partial("Mock partial \(chunkCount)..."))
                }
                continuation.yield(.final(Transcription(
                    text: "Mock streaming transcription (\(chunkCount) chunks)",
                    language: "en",
                    confidence: 0.95
                )))
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func supportedLanguages() -> [String] {
        ["en", "es", "fr", "de", "ja"]
    }

    func validate() async throws {
        // Mock provider is always valid
    }
}
