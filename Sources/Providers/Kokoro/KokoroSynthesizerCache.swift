import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "kokoro.cache")

/// Process-lifetime cache for the loaded `KokoroSynthesizer` instance.
///
/// CoreML ANE compilation writes 2+ GB of intermediate data to disk on every
/// fresh `MLModel(contentsOf:)` load. While `modelDisplayName` gives CoreML a
/// stable cache key to skip recompilation across launches, reconstructing the
/// `TtsService` (triggered by settings changes, downloads, or deletes) would
/// still re-load from scratch — paying the CoreML load cost each time.
///
/// This module-level state holds a single shared synthesizer that survives
/// provider reconstruction. `KokoroTtsProvider.ensureModelLoaded()` resolves
/// from this cache instead of creating its own instance. On model deletion,
/// `invalidate()` drops the cached reference so the next `speak()` correctly
/// discovers the model is gone.
///
/// Safety: all access occurs on `KokoroTtsProvider`'s actor serial executor.
/// The `nonisolated(unsafe)` annotation reflects this — the provider is the
/// sole consumer and it serializes all reads/writes through its own isolation.
enum KokoroSynthesizerCache {
    private(set) nonisolated(unsafe) static var cached: KokoroSynthesizer?
    private nonisolated(unsafe) static var isLoading = false

    /// Store a successfully loaded synthesizer.
    static func store(_ synthesizer: KokoroSynthesizer) {
        cached = synthesizer
        isLoading = false
        logger.info("Kokoro synthesizer cached successfully")
    }

    /// Whether a load is already in progress.
    static var loading: Bool {
        get { isLoading }
        set { isLoading = newValue }
    }

    /// Drops the cached synthesizer so the next `get()` reloads from disk.
    ///
    /// Call when the on-disk model is deleted or replaced.
    static func invalidate() {
        if cached != nil {
            logger.info("Invalidating cached Kokoro synthesizer")
        }
        cached = nil
        isLoading = false
    }
}
