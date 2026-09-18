import CryptoKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "security")

/// Verifies the SHA-256 integrity of downloaded model files.
///
/// Hashes are computed by streaming the file in chunks to avoid loading
/// multi-gigabyte models into memory. Verification results are cached
/// in memory for the lifetime of the actor (one app session), so repeated
/// loads only pay the hashing cost once.
actor ModelIntegrityVerifier {

    /// Shared instance for app-wide use.
    static let shared = ModelIntegrityVerifier()

    /// Cached verification results: file URL -> computed SHA-256 hex string.
    private var cache: [URL: String] = [:]

    /// Size of each read chunk during streaming hash computation (1 MB).
    private let chunkSize = 1_048_576

    // MARK: - Public API

    /// Verifies that a file's SHA-256 hash matches the expected value.
    ///
    /// Results are cached per file URL. If the file was already verified in
    /// this session, the cached hash is compared without re-reading the file.
    ///
    /// - Parameters:
    ///   - url: Path to the model file on disk.
    ///   - expectedHash: The lowercase hex-encoded SHA-256 hash to compare against.
    ///   - modelId: Model identifier for error reporting.
    /// - Throws: `ModelIntegrityError.checksumMismatch` if hashes differ,
    ///           `ModelIntegrityError.fileUnreadable` if the file cannot be read.
    func verify(fileAt url: URL, expectedHash: String, modelId: String) async throws {
        let computedHash = try await hash(fileAt: url)

        guard computedHash == expectedHash.lowercased() else {
            let exp = String(expectedHash.prefix(12))
            let act = String(computedHash.prefix(12))
            logger.error(
                "Integrity FAILED '\(modelId, privacy: .public)': \(exp, privacy: .public) vs \(act, privacy: .public)"
            )
            throw ModelIntegrityError.checksumMismatch(
                modelId: modelId,
                expected: expectedHash,
                actual: computedHash
            )
        }

        logger.info("Integrity check passed for '\(modelId)' (\(computedHash.prefix(16))...)")
    }

    /// Verifies all files listed in a hash entry against their expected SHA-256 digests.
    ///
    /// Every file in the entry must exist on disk. Missing files are treated as
    /// integrity failures (incomplete or corrupted download).
    ///
    /// - Parameters:
    ///   - entry: The integrity entry containing subpath-to-hash mappings.
    ///   - folder: Root directory of the model files.
    ///   - modelId: Model identifier for error reporting.
    /// - Throws: `ModelIntegrityError.fileMissing` if a required file is absent,
    ///           `ModelIntegrityError.checksumMismatch` on first hash mismatch,
    ///           `ModelIntegrityError.fileUnreadable` if a present file cannot be read.
    func verifyAll(
        entry: ModelIntegrityHashes.Entry,
        inFolder folder: URL,
        modelId: String
    ) async throws {
        for (subpath, expectedHash) in entry.files {
            let fileURL = folder.appendingPathComponent(subpath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                logger
                    .error(
                        "Required file missing: \(subpath, privacy: .public) for model '\(modelId, privacy: .public)'"
                    )
                throw ModelIntegrityError.fileMissing(modelId: modelId, subpath: subpath)
            }
            do {
                try await verify(fileAt: fileURL, expectedHash: expectedHash, modelId: modelId)
            } catch {
                invalidateCache(for: fileURL)
                throw error
            }
        }
    }

    /// Computes the SHA-256 hash of a file, using the cache if available.
    ///
    /// - Parameter url: Path to the file.
    /// - Returns: Lowercase hex-encoded SHA-256 hash string.
    /// - Throws: `ModelIntegrityError.fileUnreadable` if the file cannot be opened.
    func hash(fileAt url: URL) async throws -> String {
        if let cached = cache[url] {
            return cached
        }

        let computed = try computeSHA256(at: url)
        cache[url] = computed
        return computed
    }

    /// Removes a cached verification result for a file (e.g., after deletion).
    func invalidateCache(for url: URL) {
        cache.removeValue(forKey: url)
    }

    /// Clears the entire verification cache.
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    /// Streams a file through SHA-256 in fixed-size chunks.
    private func computeSHA256(at url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelIntegrityError.fileUnreadable(path: url.path, underlying: error)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw ModelIntegrityError.fileUnreadable(path: url.path, underlying: error)
            }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
