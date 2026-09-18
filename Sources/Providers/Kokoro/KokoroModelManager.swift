import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "kokoro.models")

/// Manages Kokoro TTS model downloads, caching, and deletion.
///
/// Wraps `KokoroDownloader` and `KokoroSynthesizer` to provide cache checks,
/// progress-tracked downloads, and deletion -- matching the `LlamaCppModels`
/// interface used by the LLM tab.
enum KokoroModelManager {

    /// Single model entry for the Kokoro 82M model.
    static let modelEntry = LocalModelEntry(
        id: "kokoro-82m",
        displayName: "Kokoro 82M (Neural)",
        // swiftlint:disable:next force_unwrapping
        downloadUrl: URL(string: "https://huggingface.co/aufklarer/Kokoro-82M-CoreML")!,
        filename: "Kokoro-82M-CoreML",
        sizeBytes: 318_000_000,
        memoryMB: 400,
        tier: .default,
        qualityScore: 8.5,
        description: "82M-parameter CoreML model on Neural Engine"
    )

    /// The HuggingFace model ID.
    private static let hfModelId = KokoroSynthesizer.defaultModelId

    // MARK: - Cache Check

    /// Whether the Kokoro model is already downloaded and cached locally.
    ///
    /// - Returns: `true` if the compiled CoreML model and vocabulary exist on disk.
    static func isModelCached() -> Bool {
        KokoroDownloader.isModelCached(modelId: hfModelId)
    }

    /// Returns the on-disk size of the cached model, or `nil` if not cached.
    static func cachedModelSize() -> UInt64? {
        KokoroDownloader.cachedModelSize(modelId: hfModelId)
    }

    /// Deletes the cached Kokoro model from disk.
    ///
    /// - Throws: File system errors if removal fails.
    static func deleteModel() throws {
        try KokoroDownloader.deleteModel(modelId: hfModelId)
    }

    // MARK: - Download

    /// Starts a background model download with progress reporting.
    ///
    /// Uses `KokoroSynthesizer.fromPretrained` which handles downloading,
    /// CoreML compilation, and caching. Progress is reported through the
    /// same `DownloadProgress` enum used by `LlamaCppModels`.
    ///
    /// - Returns: An `AsyncStream` of `DownloadProgress` events.
    static func startModelDownload() -> AsyncStream<DownloadProgress> {
        let expectedSize = modelEntry.sizeBytes

        return AsyncStream { continuation in
            Task {
                do {
                    _ = try await KokoroSynthesizer.fromPretrained(
                        modelId: hfModelId
                    ) { progress, _ in
                        let downloaded = UInt64(Double(expectedSize) * progress)
                        continuation.yield(.progress(downloaded: downloaded, total: expectedSize))
                    }

                    guard let cacheDir = try? KokoroDownloader.getCacheDirectory(
                        for: hfModelId
                    ) else {
                        continuation.yield(.complete(URL(fileURLWithPath: "/")))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.complete(cacheDir))
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }
}
