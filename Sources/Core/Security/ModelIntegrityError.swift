import Foundation

/// Errors raised by model integrity verification.
enum ModelIntegrityError: LocalizedError {
    /// The computed SHA-256 hash does not match the expected value.
    case checksumMismatch(modelId: String, expected: String, actual: String)
    /// The model file could not be read for hashing.
    case fileUnreadable(path: String, underlying: Error)
    /// A required model file is missing from disk.
    case fileMissing(modelId: String, subpath: String)

    var errorDescription: String? {
        switch self {
        case let .checksumMismatch(modelId, expected, actual):
            "Integrity check failed for model '\(modelId)': "
                + "expected SHA-256 \(expected.prefix(12))..., got \(actual.prefix(12))..."
        case let .fileUnreadable(path, underlying):
            "Cannot read model file at \(path): \(underlying.localizedDescription)"
        case let .fileMissing(modelId, subpath):
            "Required file '\(subpath)' is missing for model '\(modelId)'"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .checksumMismatch, .fileMissing:
            "The model file may be corrupted or incomplete. "
                + "It will be deleted and re-downloaded automatically."
        case .fileUnreadable:
            "Check that the file exists and is not locked by another process."
        }
    }
}
