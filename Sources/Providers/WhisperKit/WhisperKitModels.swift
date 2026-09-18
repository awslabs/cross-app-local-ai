import Foundation

/// Static model registry for WhisperKit STT models.
///
/// WhisperKit handles its own model downloading natively. This registry
/// exists primarily for the settings UI (model selection, size display).
enum WhisperKitModels {

    private static func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("Invalid hardcoded URL: \(string)")
        }
        return url
    }

    static let modelRegistry: [LocalModelEntry] = [
        LocalModelEntry(
            id: "whisper-tiny",
            displayName: "Whisper Tiny",
            downloadUrl: makeURL("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"),
            filename: "ggml-tiny.bin",
            sizeBytes: 75_000_000,
            memoryMB: 75,
            tier: .edge,
            qualityScore: 6.0,
            description: "Fastest, lowest quality"
        ),
        LocalModelEntry(
            id: "whisper-base",
            displayName: "Whisper Base",
            downloadUrl: makeURL("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"),
            filename: "ggml-base.bin",
            sizeBytes: 142_000_000,
            memoryMB: 142,
            tier: .default,
            qualityScore: 7.0,
            description: "Good balance of speed and quality"
        ),
        LocalModelEntry(
            id: "whisper-small",
            displayName: "Whisper Small",
            downloadUrl: makeURL("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"),
            filename: "ggml-small.bin",
            sizeBytes: 466_000_000,
            memoryMB: 466,
            tier: .quality,
            qualityScore: 8.0,
            description: "Good accuracy, moderate memory"
        ),
        LocalModelEntry(
            id: "whisper-medium",
            displayName: "Whisper Medium",
            downloadUrl: makeURL("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"),
            filename: "ggml-medium.bin",
            sizeBytes: 1_530_000_000,
            memoryMB: 1800,
            tier: .quality,
            qualityScore: 8.5,
            description: "High accuracy, requires 2 GB+ free memory"
        ),
        LocalModelEntry(
            id: "whisper-large-v3",
            displayName: "Whisper Large V3",
            downloadUrl: makeURL("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"),
            filename: "ggml-large-v3.bin",
            sizeBytes: 3_100_000_000,
            memoryMB: 3200,
            tier: .quality,
            qualityScore: 9.5,
            description: "Best accuracy, requires 4 GB+ free memory"
        ),
    ]

    /// Returns `ModelInfo` array for the settings model picker.
    static func staticModels() -> [ModelInfo] {
        modelRegistry.map { ModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    /// Finds a model entry by ID.
    static func findModel(_ modelId: String) -> LocalModelEntry? {
        modelRegistry.first { $0.id == modelId }
    }
}
