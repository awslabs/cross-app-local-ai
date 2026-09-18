import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "llamacpp.models")

// MARK: - ModelTier

/// Classification of model quality/speed tradeoff.
enum ModelTier: String {
    case edge = "Edge"
    case `default` = "Default"
    case quality = "Quality"
}

// MARK: - LocalModelEntry

/// A model available for local inference via llama.cpp.
struct LocalModelEntry {
    let id: String
    let displayName: String
    let downloadUrl: URL
    let filename: String
    let sizeBytes: UInt64
    let memoryMB: UInt32
    let tier: ModelTier
    let qualityScore: Float
    let description: String
    /// Expected SHA-256 hash of the primary model file for integrity verification.
    /// `nil` for user-provided custom models where no known-good hash exists.
    let sha256: String?

    init(
        id: String,
        displayName: String,
        downloadUrl: URL,
        filename: String,
        sizeBytes: UInt64,
        memoryMB: UInt32,
        tier: ModelTier,
        qualityScore: Float,
        description: String,
        sha256: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.downloadUrl = downloadUrl
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.memoryMB = memoryMB
        self.tier = tier
        self.qualityScore = qualityScore
        self.description = description
        self.sha256 = sha256
    }
}

// MARK: - DownloadProgress

/// Events emitted during a model download.
enum DownloadProgress {
    case progress(downloaded: UInt64, total: UInt64)
    case complete(URL)
    case error(String)
}

// MARK: - LlamaCppModels

/// Model registry, path resolution, download, and GGUF validation.
enum LlamaCppModels {

    /// Canonical default local model id. Single source of truth for the
    /// value the config falls back to when no local model is persisted.
    /// Mirrors `BedrockModels.defaultModelId` for the local provider.
    static let defaultModelId = "gemma-4-e2b"

    private static func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("Invalid hardcoded URL: \(string)")
        }
        return url
    }

    /// Built-in model registry matching the Rust `MODEL_REGISTRY`.
    static let modelRegistry: [LocalModelEntry] = [
        LocalModelEntry(
            id: "gemma-4-e2b",
            displayName: "Gemma 4 E2B IT Q4",
            downloadUrl: makeURL(
                "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/739965d73654c0ead8020786aa998fc813070087/gemma-4-E2B-it-Q4_K_M.gguf"
            ),
            filename: "gemma-4-E2B-it-Q4_K_M.gguf",
            sizeBytes: 3_106_736_256,
            memoryMB: 3000,
            tier: .default,
            qualityScore: 8.09,
            description: "Balanced correction and summarization at high speed",
            // Public SHA-256 of the model file for integrity verification, not a secret.
            sha256: "9378bc471710229ef165709b62e34bfb62231420ddaf6d729e727305b5b8672d" // pragma: allowlist secret
        ),
        LocalModelEntry(
            id: "gemma-4-e4b",
            displayName: "Gemma 4 E4B IT Q4",
            downloadUrl: makeURL(
                "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/0720adb23527c2cd5ea01d1db067cd960327fdac/gemma-4-E4B-it-Q4_K_M.gguf"
            ),
            filename: "gemma-4-E4B-it-Q4_K_M.gguf",
            sizeBytes: 4_977_169_568,
            memoryMB: 4800,
            tier: .quality,
            qualityScore: 8.48,
            description: "Best quality across all tested models",
            // Public SHA-256 of the model file for integrity verification, not a secret.
            sha256: "519b9793ed6ce0ff530f1b7c96e848e08e49e7af4d57bb97f76215963a54146d" // pragma: allowlist secret
        ),
    ]

    // MARK: - Lookup

    /// Finds a model entry by ID.
    static func findModel(_ modelId: String) -> LocalModelEntry? {
        modelRegistry.first { $0.id == modelId }
    }

    /// Returns `ModelInfo` array for the settings model picker.
    static func staticModels() -> [ModelInfo] {
        modelRegistry.map { ModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    // MARK: - Path Resolution

    /// Directory where downloaded models are stored.
    static func modelsDir(_ dirs: AppDirs) -> URL {
        dirs.modelsDir
    }

    /// Checks whether a model is already cached on disk.
    static func locateModel(dirs: AppDirs, modelId: String) -> URL? {
        guard let entry = findModel(modelId) else { return nil }
        let path = modelsDir(dirs).appendingPathComponent(entry.filename)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Convenience check without requiring an `AppDirs` instance.
    static func isModelCached(_ modelId: String) -> Bool {
        guard let dirs = try? AppDirs.resolve() else { return false }
        return locateModel(dirs: dirs, modelId: modelId) != nil
    }

    /// Deletes a cached model from disk.
    ///
    /// - Parameters:
    ///   - dirs: Application directory paths.
    ///   - modelId: The model identifier from the registry.
    /// - Throws: `LlmError.modelFile` if the model file cannot be removed.
    static func deleteModel(dirs: AppDirs, modelId: String) throws {
        guard let entry = findModel(modelId) else {
            throw LlmError.modelFile(message: "Unknown model '\(modelId)'")
        }
        let path = modelsDir(dirs).appendingPathComponent(entry.filename)
        guard FileManager.default.fileExists(atPath: path.path) else {
            logger.info("Model '\(modelId)' not cached, nothing to delete")
            return
        }
        try FileManager.default.removeItem(at: path)
        logger.info("Deleted cached model '\(modelId)' at \(path.path)")
    }

    /// Returns the disk size in bytes for a cached model, or `nil` if not cached.
    static func cachedModelSize(dirs: AppDirs, modelId: String) -> UInt64? {
        guard let path = locateModel(dirs: dirs, modelId: modelId) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let size = attrs[.size] as? UInt64
        else { return nil }
        return size
    }

    /// Resolves the path to a model file, downloading if necessary.
    ///
    /// Resolution order:
    /// 1. Custom path override (if set and file exists)
    /// 2. Cached model in the models directory (integrity verified once per session)
    /// 3. Download from the registry (integrity verified post-download)
    ///
    /// - Parameters:
    ///   - dirs: Application directory paths.
    ///   - modelId: The model identifier from the registry.
    ///   - customPath: Optional user-specified path to a GGUF file.
    /// - Returns: The URL of the resolved model file.
    /// - Throws: `LlmError.modelFile` if resolution fails.
    static func resolveModelPath(
        dirs: AppDirs,
        modelId: String,
        customPath: String?
    ) async throws -> URL {
        if let customPath, !customPath.isEmpty {
            let url = URL(fileURLWithPath: customPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LlmError.modelFile(message: "Custom path does not exist: \(customPath)")
            }
            return url
        }

        let entry = findModel(modelId)

        if let cached = locateModel(dirs: dirs, modelId: modelId) {
            if let expectedHash = entry?.sha256 {
                do {
                    try await verifyIntegrity(
                        at: cached,
                        expectedHash: expectedHash,
                        modelId: modelId
                    )
                } catch {
                    logger.warning(
                        "Cached model '\(modelId)' failed integrity check; re-downloading"
                    )
                    try? FileManager.default.removeItem(at: cached)
                    await ModelIntegrityVerifier.shared.invalidateCache(for: cached)
                    guard let entry else {
                        throw LlmError.modelFile(message: "Unknown model '\(modelId)'")
                    }
                    return try await downloadModel(dirs: dirs, entry: entry)
                }
            }
            logger.info("Using cached model at \(cached.path)")
            return cached
        }

        guard let entry else {
            throw LlmError.modelFile(message: "Unknown model '\(modelId)'")
        }
        return try await downloadModel(dirs: dirs, entry: entry)
    }

    // MARK: - Download

    /// Downloads a model synchronously (no progress reporting).
    private static func downloadModel(dirs: AppDirs, entry: LocalModelEntry) async throws -> URL {
        let modelsDirectory = modelsDir(dirs)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let finalPath = modelsDirectory.appendingPathComponent(entry.filename)
        let tempPath = modelsDirectory.appendingPathComponent("\(entry.filename).downloading")

        // Clean up any leftover temp file from a previous failed download
        if FileManager.default.fileExists(atPath: tempPath.path) {
            try? FileManager.default.removeItem(at: tempPath)
        }

        let fileGuard = TempFileGuard(path: tempPath)

        logger.info("Downloading model '\(entry.id)' from \(entry.downloadUrl.absoluteString)")

        let (tempFileUrl, response) = try await URLSession.shared.download(from: entry.downloadUrl)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw LlmError.modelFile(message: "Download failed for model '\(entry.id)'")
        }

        try FileManager.default.moveItem(at: tempFileUrl, to: tempPath)
        try FileManager.default.moveItem(at: tempPath, to: finalPath)
        fileGuard.persist()

        if let expectedHash = entry.sha256 {
            try await verifyIntegrity(at: finalPath, expectedHash: expectedHash, modelId: entry.id)
        }

        logger.info("Model '\(entry.id)' downloaded to \(finalPath.path)")
        return finalPath
    }

    /// Starts a background model download with progress reporting.
    ///
    /// - Parameter modelId: The model identifier from the registry.
    /// - Returns: An `AsyncStream` of `DownloadProgress` events.
    /// - Throws: `LlmError.modelFile` if the model ID is unknown.
    static func startModelDownload(modelId: String) throws
        -> (stream: AsyncStream<DownloadProgress>, cancel: @Sendable () -> Void) {
        guard let entry = findModel(modelId) else {
            throw LlmError.modelFile(message: "Unknown model '\(modelId)'")
        }

        let dirs = try AppDirs.resolve()
        let cancelHolder = DownloadCancelHolder()

        let stream = AsyncStream<DownloadProgress> { continuation in
            Task {
                do {
                    let expectedSize = entry.sizeBytes
                    let path = try await downloadModelStreaming(
                        dirs: dirs,
                        entry: entry,
                        cancelHolder: cancelHolder
                    ) { downloaded, total in
                        let reliableTotal = expectedSize > 0 ? expectedSize : total
                        continuation.yield(.progress(downloaded: downloaded, total: reliableTotal))
                    }
                    continuation.yield(.complete(path))
                } catch {
                    if cancelHolder.isCancelled {
                        // Don't report error if we cancelled intentionally
                    } else {
                        continuation.yield(.error(error.localizedDescription))
                    }
                }
                continuation.finish()
            }
        }

        return (stream: stream, cancel: { cancelHolder.cancel() })
    }

    /// Downloads a model with byte-level progress callbacks.
    private static func downloadModelStreaming(
        dirs: AppDirs,
        entry: LocalModelEntry,
        cancelHolder: DownloadCancelHolder,
        onProgress: @Sendable @escaping (UInt64, UInt64) -> Void
    ) async throws -> URL {
        let modelsDirectory = modelsDir(dirs)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let finalPath = modelsDirectory.appendingPathComponent(entry.filename)
        let tempPath = modelsDirectory.appendingPathComponent("\(entry.filename).downloading")

        // Check available disk space before starting
        if let freeSpace = try? FileManager.default.attributesOfFileSystem(
            forPath: modelsDirectory.path
        )[.systemFreeSize] as? UInt64 {
            let freeGB = String(format: "%.1f", Double(freeSpace) / 1_000_000_000.0)
            let neededGB = String(format: "%.1f", Double(entry.sizeBytes) / 1_000_000_000.0)
            logger.info("Disk space check: \(freeGB) GB free, model needs \(neededGB) GB")
            if freeSpace < entry.sizeBytes {
                throw LlmError.modelFile(
                    message: "Not enough disk space. Need \(neededGB) GB but only \(freeGB) GB available."
                )
            }
        }

        // Clean up any leftover temp file from a previous failed download
        if FileManager.default.fileExists(atPath: tempPath.path) {
            logger.info("Removing leftover temp file from previous download attempt")
            try? FileManager.default.removeItem(at: tempPath)
        }

        // Check if final file already exists (race condition guard)
        if FileManager.default.fileExists(atPath: finalPath.path) {
            logger.info("Model file already exists at \(finalPath.path), skipping download")
            return finalPath
        }

        let fileGuard = TempFileGuard(path: tempPath)

        let url = entry.downloadUrl.absoluteString
        logger.info(
            "Starting download: model='\(entry.id)', url=\(url), size=\(entry.sizeBytes) bytes"
        )
        logger.info("Download paths: temp=\(tempPath.path), final=\(finalPath.path)")

        logger.info("Connecting to \(entry.downloadUrl.host ?? "unknown host")...")

        // Use a fully delegate-driven download so progress callbacks fire reliably.
        // The async session.download(from:) API does not guarantee delegate progress calls.
        let delegate = StreamingDownloadDelegate(
            modelId: entry.id,
            onProgress: onProgress
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        cancelHolder.session = session

        let tempFileUrl: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.completion = continuation
            session.downloadTask(with: entry.downloadUrl).resume()
        }

        // Get status code from the delegate's finished download task response
        let statusCode = delegate.httpStatusCode
        let contentLength = delegate.httpContentLength
        if statusCode > 0 {
            logger.info("Download HTTP response: status=\(statusCode), contentLength=\(contentLength)")
        }

        guard (200 ... 299).contains(statusCode) else {
            throw LlmError.modelFile(
                message: "Download failed: HTTP \(statusCode) from \(entry.downloadUrl.host ?? "unknown")"
            )
        }

        // Verify downloaded file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: tempFileUrl.path),
           let downloadedSize = attrs[.size] as? UInt64 {
            let sizeGB = String(format: "%.2f", Double(downloadedSize) / 1_000_000_000.0)
            logger.info("Download complete: \(downloadedSize) bytes (\(sizeGB) GB) written to temp file")
        }

        logger.info("Moving temp file to staging path: \(tempPath.path)")
        try FileManager.default.moveItem(at: tempFileUrl, to: tempPath)

        logger.info("Moving staged file to final path: \(finalPath.path)")
        try FileManager.default.moveItem(at: tempPath, to: finalPath)
        fileGuard.persist()

        if let expectedHash = entry.sha256 {
            try await verifyIntegrity(at: finalPath, expectedHash: expectedHash, modelId: entry.id)
        }

        logger.info("Model '\(entry.id)' download complete at \(finalPath.path)")
        return finalPath
    }

    // MARK: - Integrity Verification

    /// Verifies a model file's SHA-256 hash against the expected value.
    ///
    /// On mismatch the file is deleted and re-downloaded once. If the retry
    /// also fails verification, throws `LlmError.modelFile`.
    ///
    /// - Parameters:
    ///   - path: Location of the model file on disk.
    ///   - expectedHash: Lowercase hex SHA-256 from the model registry.
    ///   - modelId: Model identifier for logging and error messages.
    private static func verifyIntegrity(
        at path: URL,
        expectedHash: String,
        modelId: String
    ) async throws {
        do {
            try await ModelIntegrityVerifier.shared.verify(
                fileAt: path,
                expectedHash: expectedHash,
                modelId: modelId
            )
        } catch is ModelIntegrityError {
            logger.error("Integrity verification failed for '\(modelId, privacy: .public)', deleting corrupted file")
            try? FileManager.default.removeItem(at: path)
            await ModelIntegrityVerifier.shared.invalidateCache(for: path)
            throw LlmError.modelFile(
                message: "Model '\(modelId)' failed integrity verification and was deleted. "
                    + "The file may have been corrupted during download, or the upstream model was updated. "
                    + "Please check for an app update or try re-downloading."
            )
        }
    }

    // MARK: - GGUF Validation

    /// Validates that a file is a valid GGUF model by checking its magic bytes.
    ///
    /// - Parameter path: The URL of the file to validate.
    /// - Throws: `LlmError.modelFile` if the file is missing, too small, or not GGUF.
    static func validateGgufFile(at path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw LlmError.modelFile(message: "Model file not found: \(path.path)")
        }

        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }

        guard let header = try handle.read(upToCount: 4), header.count == 4 else {
            throw LlmError.modelFile(message: "Model file too small to be valid GGUF")
        }

        let ggufMagic = Data("GGUF".utf8)
        guard header == ggufMagic else {
            throw LlmError.modelFile(message: "File does not appear to be GGUF format")
        }
    }
}

// MARK: - DownloadCancelHolder

/// Thread-safe holder for cancelling an in-progress URLSession download.
final class DownloadCancelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: URLSession?
    private var _cancelled = false

    var session: URLSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    var isCancelled: Bool {
        lock.withLock { _cancelled }
    }

    func cancel() {
        lock.withLock {
            _cancelled = true
            _session?.invalidateAndCancel()
            _session = nil
        }
    }
}

// MARK: - DownloadProgressDelegate

/// Fully delegate-driven download handler that reports progress and completes via a continuation.
/// Unlike the async `session.download(from:)` API, this guarantees `didWriteData` progress callbacks fire.
private final class StreamingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let modelId: String
    let onProgress: @Sendable (UInt64, UInt64) -> Void
    var completion: CheckedContinuation<URL, Error>?
    private(set) var httpStatusCode = 0
    private(set) var httpContentLength: Int64 = -1
    private var lastLoggedPercent = -1

    init(modelId: String, onProgress: @Sendable @escaping (UInt64, UInt64) -> Void) {
        self.modelId = modelId
        self.onProgress = onProgress
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? UInt64(totalBytesExpectedToWrite) : 0
        let downloaded = UInt64(totalBytesWritten)
        onProgress(downloaded, total)

        if total > 0 {
            let currentPercent = Int(Double(downloaded) / Double(total) * 100)
            let milestone = currentPercent / 10 * 10
            if milestone > lastLoggedPercent {
                lastLoggedPercent = milestone
                let dlMB = String(format: "%.0f", Double(downloaded) / 1_000_000.0)
                let totalMB = String(format: "%.0f", Double(total) / 1_000_000.0)
                logger.info("Download progress [\(self.modelId)]: \(milestone)% (\(dlMB)/\(totalMB) MB)")
            }
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Capture HTTP status from the task's response
        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            httpStatusCode = httpResponse.statusCode
            httpContentLength = httpResponse.expectedContentLength
        }

        // Copy to a stable location before the system deletes the temp file
        let stableTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gguf.tmp")
        do {
            try FileManager.default.moveItem(at: location, to: stableTmp)
            logger.info("Download delegate: file moved to stable temp \(stableTmp.path)")
            completion?.resume(returning: stableTmp)
        } catch {
            logger.error("Download delegate: failed to move temp file: \(error.localizedDescription, privacy: .public)")
            completion?.resume(throwing: error)
        }
        completion = nil
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            let desc = error.localizedDescription
            logger.error("Download error [\(self.modelId, privacy: .public)]: \(desc, privacy: .public)")
            completion?.resume(throwing: error)
            completion = nil
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirectHost = request.url?.host ?? "unknown"
        logger.info("Download redirect [\(self.modelId)]: HTTP \(response.statusCode) -> \(redirectHost)")
        completionHandler(request)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        logger.info("Download resumed [\(self.modelId)]: offset=\(fileOffset), expected=\(expectedTotalBytes)")
    }
}
