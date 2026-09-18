import Foundation

/// Centralised registry of known-good SHA-256 hashes for downloaded model files.
///
/// Each supported model variant declares its expected revision (where applicable)
/// and a mapping of weight-file subpaths to their SHA-256 hex digests. Verifiers
/// look up entries here before delegating to ``ModelIntegrityVerifier`` for the
/// actual hash comparison.
///
/// To update when adopting a new model version:
/// 1. Download the new model files.
/// 2. Compute `shasum -a 256` for each weight file.
/// 3. Update the relevant entry below (revision + file hashes).
enum ModelIntegrityHashes {

    /// A single model variant's integrity data.
    struct Entry: Sendable {
        /// HuggingFace commit SHA to pin downloads to (Kokoro only; nil for WhisperKit).
        let revision: String?
        /// Subpath (relative to model root) -> expected lowercase SHA-256 hex.
        let files: [String: String]
    }

    // MARK: - Kokoro TTS

    // pragma: allowlist secret
    static let kokoro: [String: Entry] = [
        "aufklarer/Kokoro-82M-CoreML": Entry(
            revision: "f8ff771e4cab0bb3368e8af3a090a7e847485401",
            files: [
                "kokoro_5s.mlmodelc/weights/weight.bin":
                    "48b6d7301be895e25d80a6024b71ba023d1baa9ec71e26a66cc9e32f78f83a86",
            ]
        ),
    ]

    // MARK: - WhisperKit STT

    // pragma: allowlist secret
    static let whisperkit: [String: Entry] = [
        "openai_whisper-tiny": Entry(
            revision: nil,
            files: [
                "AudioEncoder.mlmodelc/weights/weight.bin":
                    "bcd0879f6d1c61832765c7ec05d883d0dcbf1504057b13095fd315484196fc5e",
            ]
        ),
        "openai_whisper-base": Entry(
            revision: nil,
            files: [
                "AudioEncoder.mlmodelc/weights/weight.bin":
                    "061ff4d74e5de3937b31288465d6c6f2697f92d121c80b23f51dd26bbdfe642b",
            ]
        ),
        "openai_whisper-small": Entry(
            revision: nil,
            files: [
                "AudioEncoder.mlmodelc/weights/weight.bin":
                    "fe35cef2c9406993a635639b16f373f6debb0215ac115b7bf93fa03c8e10310b",
                "MelSpectrogram.mlmodelc/weights/weight.bin":
                    "267017e533b5f542d195fd9a775f2ba649075128283ce8e86c63a2ec20de5b07",
                "TextDecoder.mlmodelc/weights/weight.bin":
                    "bfea8044a8f38e8d33f56585b1e75ce023d3845e2a945e20480bd7e16558016e",
            ]
        ),
        "openai_whisper-medium": Entry(
            revision: nil,
            files: [
                "AudioEncoder.mlmodelc/weights/weight.bin":
                    "577c78ed7e0ae71f9ed6fdb063dc74a0f4c0c44d04118111650458973f7ddae6",
            ]
        ),
        "openai_whisper-large-v3-v20240930_626MB": Entry(
            revision: nil,
            files: [
                "AudioEncoder.mlmodelc/weights/weight.bin":
                    "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1",
            ]
        ),
    ]
}
