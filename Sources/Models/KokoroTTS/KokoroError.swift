import Foundation

/// Errors from the Kokoro TTS model layer.
enum KokoroError: Error, LocalizedError {
    /// Model files could not be loaded from disk.
    case modelLoadFailed(reason: String)
    /// CoreML inference produced invalid or missing output tensors.
    case inferenceFailed(reason: String)
    /// Requested voice preset was not found in the loaded embeddings.
    case voiceNotFound(voice: String, available: [String])
    /// Model weight download failed after retries.
    case downloadFailed(reason: String)
    /// Model file failed SHA-256 integrity verification.
    case integrityVerificationFailed(modelId: String)

    var errorDescription: String? {
        switch self {
        case let .modelLoadFailed(reason):
            "Kokoro model load failed: \(reason)"
        case let .inferenceFailed(reason):
            "Kokoro inference failed: \(reason)"
        case let .voiceNotFound(voice, available):
            "Voice '\(voice)' not found. Available: \(available.prefix(5).joined(separator: ", "))"
        case let .downloadFailed(reason):
            "Kokoro download failed: \(reason)"
        case let .integrityVerificationFailed(modelId):
            "Kokoro model '\(modelId)' failed integrity verification and was deleted. "
                + "Please re-download the model."
        }
    }
}
