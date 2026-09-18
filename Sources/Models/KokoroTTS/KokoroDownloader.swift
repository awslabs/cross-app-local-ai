import Foundation
import Hub
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "kokoro.download")

/// Downloads and caches Kokoro TTS model weights from HuggingFace.
///
/// Uses `HubApi` from the swift-transformers `Hub` module for authenticated
/// downloads with resume support and metadata tracking.
enum KokoroDownloader {

    /// Cache directory name under `~/Library/Caches/` (pre-unification fallback,
    /// only used when `AppDirs` resolution fails).
    private static let cacheDirName = "fastlang-kokoro"

    // MARK: - Cache Directory

    /// Returns the local cache directory for a HuggingFace model.
    ///
    /// Models are stored under `AppDirs.dataDir/models/<org>/<model>/` alongside
    /// LLM and STT models. Falls back to `~/Library/Caches/fastlang-kokoro/` if
    /// `AppDirs` resolution fails.
    ///
    /// - Parameter modelId: HuggingFace model identifier (e.g. "aufklarer/Kokoro-82M-CoreML").
    /// - Returns: URL to the cache directory (created if needed).
    /// - Throws: File system errors if directory creation fails.
    static func getCacheDirectory(for modelId: String) throws -> URL {
        let base = resolveBaseCacheDir()
        let hub = HubApi(downloadBase: base)
        let repo = Hub.Repo(id: modelId)
        let dir = hub.localRepoLocation(repo)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Download

    /// Downloads model files required for Kokoro TTS.
    ///
    /// Fetches the E2E CoreML model, G2P models, vocabulary, dictionaries,
    /// and voice embeddings. The download is pinned to the revision SHA recorded
    /// in ``ModelIntegrityHashes/kokoro`` and verified after completion.
    /// Retries up to 3 times with exponential backoff.
    ///
    /// - Parameters:
    ///   - modelId: HuggingFace model identifier.
    ///   - directory: Local directory to download into.
    ///   - progressHandler: Fraction-complete callback (0.0 to 1.0).
    /// - Throws: `KokoroError.downloadFailed` if the model ID is unrecognized or
    ///   all retries are exhausted.
    static func downloadWeights(
        modelId: String,
        to directory: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        guard let entry = ModelIntegrityHashes.kokoro[modelId] else {
            throw KokoroError.downloadFailed(
                reason: "\(modelId): unrecognized model, no integrity entry"
            )
        }

        let globs: [String] = [
            "config.json",
            "kokoro_5s.mlmodelc/**",
            "G2PEncoder.mlmodelc/**",
            "G2PDecoder.mlmodelc/**",
            "vocab_index.json",
            "g2p_vocab.json",
            "us_gold.json",
            "us_silver.json",
            "voices/*.json",
        ]

        let hub = makeHubApi(for: modelId, repoDir: directory)
        let repo = Hub.Repo(id: modelId)
        let revision = entry.revision ?? "main"

        let maxRetries = 3
        var lastError: Error?
        for attempt in 1 ... maxRetries {
            do {
                try await hub.snapshot(from: repo, revision: revision, matching: globs) { progress in
                    progressHandler?(progress.fractionCompleted)
                }
                try await verifyIntegrity(cacheDir: directory, entry: entry, modelId: modelId)
                return
            } catch {
                lastError = error
                logger.warning(
                    "Download attempt \(attempt)/\(maxRetries) failed: \(error.localizedDescription)"
                )
                if attempt < maxRetries {
                    let delay = attempt == 1 ? 5 : 15
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw KokoroError.downloadFailed(
            reason: "\(modelId): \(lastError?.localizedDescription ?? "unknown")"
        )
    }

    // MARK: - Cache Queries

    /// Whether the compiled CoreML model and vocabulary exist on disk.
    ///
    /// Checks for the `.mlmodelc` bundle directory, its weight file, and
    /// the vocabulary — the three artifacts required for inference.
    static func isModelCached(modelId: String) -> Bool {
        guard let cacheDir = try? getCacheDirectory(for: modelId) else { return false }
        let fm = FileManager.default
        let modelDir = cacheDir.appendingPathComponent("kokoro_5s.mlmodelc", isDirectory: true)
        let weightPath = modelDir.appendingPathComponent("weights/weight.bin").path
        let vocabPath = cacheDir.appendingPathComponent("vocab_index.json").path
        return fm.fileExists(atPath: modelDir.path)
            && fm.fileExists(atPath: weightPath)
            && fm.fileExists(atPath: vocabPath)
    }

    /// Calculates the total on-disk size of cached model files, or `nil` if not cached.
    static func cachedModelSize(modelId: String) -> UInt64? {
        guard let cacheDir = try? getCacheDirectory(for: modelId) else { return nil }
        return directorySize(cacheDir)
    }

    /// Deletes all cached model files for the given model.
    ///
    /// - Throws: File system errors if removal fails.
    static func deleteModel(modelId: String) throws {
        guard let cacheDir = try? getCacheDirectory(for: modelId) else {
            logger.info("Kokoro cache directory not found, nothing to delete")
            return
        }
        guard FileManager.default.fileExists(atPath: cacheDir.path) else {
            logger.info("Kokoro model not cached, nothing to delete")
            return
        }
        try FileManager.default.removeItem(at: cacheDir)
        logger.info("Deleted cached Kokoro model at \(cacheDir.path)")
    }

    // MARK: - Integrity Verification

    /// Verifies all weight files in the entry against their known-good SHA-256 hashes.
    ///
    /// On mismatch the cache directory is deleted and `KokoroError.integrityVerificationFailed`
    /// is thrown so the caller can surface a re-download prompt.
    ///
    /// - Parameters:
    ///   - cacheDir: Root cache directory containing the downloaded model files.
    ///   - entry: The integrity entry with expected file hashes.
    ///   - modelId: HuggingFace model identifier for error reporting.
    /// - Throws: `KokoroError.integrityVerificationFailed` on hash mismatch.
    static func verifyIntegrity(
        cacheDir: URL,
        entry: ModelIntegrityHashes.Entry,
        modelId: String
    ) async throws {
        do {
            try await ModelIntegrityVerifier.shared.verifyAll(
                entry: entry,
                inFolder: cacheDir,
                modelId: modelId
            )
        } catch is ModelIntegrityError {
            logger.error(
                "Integrity verification FAILED for '\(modelId, privacy: .public)', deleting corrupted cache"
            )
            try? FileManager.default.removeItem(at: cacheDir)
            throw KokoroError.integrityVerificationFailed(modelId: modelId)
        }
    }

    // MARK: - Private Helpers

    private static func resolveBaseCacheDir() -> URL {
        if let dirs = try? AppDirs.resolve() {
            return dirs.dataDir
        }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent(cacheDirName, isDirectory: true)
    }

    /// Creates a `HubApi` whose `downloadBase` is derived from the repo directory.
    private static func makeHubApi(for modelId: String, repoDir: URL) -> HubApi {
        let repo = Hub.Repo(id: modelId)
        let suffix = "/\(repo.type.rawValue)/\(repo.id)"
        let repoDirPath = repoDir.path
        let downloadBase: URL
        if repoDirPath.hasSuffix(suffix) {
            let basePath = String(repoDirPath.dropLast(suffix.count))
            downloadBase = URL(fileURLWithPath: basePath, isDirectory: true)
        } else {
            downloadBase = resolveBaseCacheDir()
        }
        return HubApi(downloadBase: downloadBase)
    }

    private static func directorySize(_ url: URL) -> UInt64? {
        guard FileManager.default.fileExists(atPath: url.path),
              let enumerator = FileManager.default.enumerator(
                  at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
              )
        else { return nil }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += UInt64(size)
        }
        return total
    }
}
