import Foundation
import OSLog
import WhisperKit

private let logger = Logger(subsystem: "com.aws.fastlang", category: "whisperkit.models")

/// Manages WhisperKit model downloads, caching, and deletion.
///
/// WhisperKit downloads compiled CoreML models from HuggingFace. This manager
/// wraps the `WhisperKit.download(variant:)` static method to provide cache
/// checks, progress reporting, and deletion -- matching the `LlamaCppModels`
/// interface used by the LLM tab.
enum WhisperKitModelManager {

    private static let defaultRepo = "argmaxinc/whisperkit-coreml"

    // MARK: - Cache Check

    /// Whether a model variant is already downloaded and cached locally.
    ///
    /// Performs a fast filesystem check without triggering a download.
    /// The model folder is resolved from a prior download result or by
    /// scanning the HuggingFace Hub cache directory.
    ///
    /// - Parameter modelId: Our internal model ID (e.g. `"whisper-small"`).
    /// - Returns: `true` if the model files exist on disk.
    static func isModelCached(_ modelId: String) -> Bool {
        guard let folder = cachedModelFolder(modelId) else { return false }
        return modelFilesExist(in: folder)
    }

    /// Returns the on-disk size of a cached model, or `nil` if not cached.
    ///
    /// - Parameter modelId: Our internal model ID.
    /// - Returns: Size in bytes, or `nil`.
    static func cachedModelSize(_ modelId: String) -> UInt64? {
        guard let folder = cachedModelFolder(modelId) else { return nil }
        return directorySize(folder)
    }

    /// Deletes a cached model from disk.
    ///
    /// - Parameter modelId: Our internal model ID.
    /// - Throws: File system errors if removal fails.
    static func deleteModel(_ modelId: String) throws {
        guard let folder = cachedModelFolder(modelId) else {
            logger.info("Model '\(modelId)' not cached, nothing to delete")
            return
        }
        try FileManager.default.removeItem(at: folder)
        logger.info("Deleted cached WhisperKit model '\(modelId)' at \(folder.path)")
    }

    // MARK: - Download

    /// Starts a background model download with progress reporting.
    ///
    /// - Parameter modelId: Our internal model ID (e.g. `"whisper-small"`).
    /// - Returns: An `AsyncStream` of `DownloadProgress` events.
    static func startModelDownload(modelId: String) -> AsyncStream<DownloadProgress> {
        let variant = mapModelIdToVariant(modelId)
        let downloadBase = resolveDownloadBase()

        return AsyncStream { continuation in
            Task {
                do {
                    let modelFolder = try await WhisperKit.download(
                        variant: variant,
                        downloadBase: downloadBase,
                        from: defaultRepo
                    ) { progress in
                        let downloaded = UInt64(progress.completedUnitCount)
                        let total = UInt64(max(progress.totalUnitCount, 1))
                        continuation.yield(.progress(downloaded: downloaded, total: total))
                    }
                    try await verifyIntegrity(
                        modelFolder: modelFolder,
                        modelId: modelId
                    )
                    continuation.yield(.complete(modelFolder))
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Variant Mapping

    /// Maps our internal model IDs to WhisperKit-compatible variant names.
    static func mapModelIdToVariant(_ id: String) -> String {
        switch id {
        case "whisper-tiny": "openai_whisper-tiny"
        case "whisper-base": "openai_whisper-base"
        case "whisper-small": "openai_whisper-small"
        case "whisper-medium": "openai_whisper-medium"
        case "whisper-large-v3": "openai_whisper-large-v3-v20240930_626MB"
        default: "openai_whisper-small"
        }
    }

    // MARK: - Integrity Verification

    /// Verifies all weight files for the variant against their known-good SHA-256 hashes.
    ///
    /// Looks up the variant in ``ModelIntegrityHashes/whisperkit``. On any mismatch the
    /// model directory is deleted and `SttError.modelIntegrityFailed` is thrown so the
    /// caller can surface a re-download prompt.
    ///
    /// - Parameters:
    ///   - modelFolder: Root folder of the downloaded model variant.
    ///   - modelId: Our internal model ID for error reporting.
    /// - Throws: `SttError.modelIntegrityFailed` on hash mismatch.
    static func verifyIntegrity(modelFolder: URL, modelId: String) async throws {
        let variant = mapModelIdToVariant(modelId)
        guard let entry = ModelIntegrityHashes.whisperkit[variant] else {
            logger.warning("No integrity entry for variant '\(variant)', skipping check")
            return
        }

        do {
            try await ModelIntegrityVerifier.shared.verifyAll(
                entry: entry,
                inFolder: modelFolder,
                modelId: modelId
            )
        } catch is ModelIntegrityError {
            logger.error(
                "Integrity FAILED for '\(modelId, privacy: .public)', deleting corrupted cache"
            )
            try? FileManager.default.removeItem(at: modelFolder)
            throw SttError.modelIntegrityFailed(modelId: modelId)
        }
    }

    // MARK: - Private Helpers

    /// Returns the HubApi download base rooted under `AppDirs.dataDir`.
    ///
    /// Falls back to `nil` (WhisperKit default) if `AppDirs` resolution fails.
    private static func resolveDownloadBase() -> URL? {
        guard let dirs = try? AppDirs.resolve() else { return nil }
        return dirs.dataDir
    }

    /// Resolves the on-disk folder for a cached model, or `nil` if not cached.
    ///
    /// Used by `WhisperKitSttProvider` to set `WhisperKitConfig.modelFolder`
    /// explicitly, avoiding WhisperKit's implicit folder-resolution side
    /// effect (which only fires when `download: true`).
    static func cachedModelFolderURL(_ modelId: String) -> URL? {
        cachedModelFolder(modelId)
    }

    /// Resolves the cache folder for a model without downloading.
    ///
    /// Models are stored under `AppDirs.dataDir/models/argmaxinc/whisperkit-coreml/{variant}/`.
    private static func cachedModelFolder(_ modelId: String) -> URL? {
        let variant = mapModelIdToVariant(modelId)
        let fm = FileManager.default

        guard let base = resolveDownloadBase() else { return nil }

        let variantDir = base
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(variant)

        guard fm.fileExists(atPath: variantDir.path), modelFilesExist(in: variantDir) else {
            return nil
        }
        return variantDir
    }

    /// Checks whether the required model files exist in a directory.
    ///
    /// WhisperKit's own model resolver requires the three `.mlmodelc`
    /// bundles *and* a top-level `config.json`. Checking only the CoreML
    /// directories was the source of a race: `WhisperKit.download(...)`
    /// yields `.complete` once the `.mlmodelc` bundles are written, but
    /// before `config.json` is materialized. Constructing a provider at
    /// that moment would succeed our `isModelCached` guard but fail
    /// WhisperKit's internal check with "STT model not found".
    private static func modelFilesExist(in folder: URL) -> Bool {
        let fm = FileManager.default
        let requiredBundles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let bundlesExist = requiredBundles.allSatisfy { file in
            fm.fileExists(atPath: folder.appendingPathComponent(file).path)
        }
        guard bundlesExist else { return false }
        return fm.fileExists(atPath: folder.appendingPathComponent("config.json").path)
    }

    /// Calculates the total size of all files in a directory tree.
    private static func directorySize(_ url: URL) -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return nil
        }

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
