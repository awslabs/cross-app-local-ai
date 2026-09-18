import CoreML
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "kokoro.synthesizer")

// MARK: - KokoroSynthesisResult

/// Output of a single Kokoro synthesis call: raw audio and model-derived word timing.
struct KokoroSynthesisResult {
    /// Mono Float32 PCM samples at 24 kHz.
    let audio: [Float]
    /// Cumulative time offset (seconds) at which each word begins speaking.
    ///
    /// Computed from the model's `pred_dur` output tensor, which predicts
    /// the acoustic frame count for each phoneme token. Spaces between words
    /// in the phoneme sequence act as word boundary delimiters.
    let wordOffsets: [TimeInterval]
    /// Total duration predicted by the model's `pred_dur` tensor (seconds).
    ///
    /// When this exceeds `audioDuration`, the output audio was truncated by
    /// the model's fixed output tensor size and words at the tail were lost.
    let predictedDuration: TimeInterval
    /// Actual duration of the returned audio (seconds).
    let audioDuration: TimeInterval
}

// MARK: - KokoroSynthesizer

/// On-device Kokoro-82M text-to-speech synthesizer.
///
/// Wraps the CoreML E2E model (`kokoro_5s.mlmodelc`) and the full phonemizer
/// pipeline. Unlike the upstream library, `synthesize()` returns both audio
/// and word-level timing derived from the model's `pred_dur` tensor.
///
/// ```swift
/// let synth = try await KokoroSynthesizer.fromPretrained()
/// let result = try synth.synthesize(text: "Hello world", voice: "af_heart")
/// // result.audio      -- [Float] at 24 kHz
/// // result.wordOffsets -- [0.0, 0.312, ...]  seconds per word
/// ```
final class KokoroSynthesizer {

    /// Default HuggingFace model ID.
    static let defaultModelId = "aufklarer/Kokoro-82M-CoreML"
    /// Default voice preset.
    static let defaultVoice = "af_heart"
    /// Output sample rate in Hz.
    static let sampleRate = 24000
    /// Acoustic hop size: each predicted duration frame = 600 audio samples.
    ///
    /// Kokoro-82M uses an iSTFT-Net vocoder with `gen_istft_hop_size=5` and
    /// `upsample_rates=[10, 6]`. The total upsampling factor is
    /// `5 * 2 * 10 * 6 = 600` samples per duration frame.
    private static let hopSize = 600

    private let config: KokoroConfig
    private var network: KokoroNetwork?
    private let phonemizer: KokoroPhonemizer
    private var voiceEmbeddings: [String: [Float]]

    private init(
        config: KokoroConfig,
        network: KokoroNetwork,
        phonemizer: KokoroPhonemizer,
        voiceEmbeddings: [String: [Float]]
    ) {
        self.config = config
        self.network = network
        self.phonemizer = phonemizer
        self.voiceEmbeddings = voiceEmbeddings
    }

    // MARK: - Public API

    /// Whether the CoreML model is loaded and ready for inference.
    var isLoaded: Bool {
        network != nil
    }

    /// Release model resources to free memory.
    func unload() {
        network = nil
        voiceEmbeddings = [:]
    }

    /// Available voice preset identifiers.
    var availableVoices: [String] {
        Array(voiceEmbeddings.keys).sorted()
    }

    /// Returns the number of phoneme tokens the phonemizer produces for the given text.
    ///
    /// Useful for deciding whether a chunk of text fits within the model's
    /// 128-token input window before running inference.
    ///
    /// - Parameters:
    ///   - text: The text to measure.
    ///   - language: BCP-47 language code prefix (e.g. "en").
    /// - Returns: Token count including BOS and EOS.
    func tokenCount(for text: String, language: String = "en") -> Int {
        phonemizer.tokenize(text, maxLength: 510, language: language).count
    }

    /// Synthesize speech from text, returning audio and model-derived word timing.
    ///
    /// The word offsets are computed by partitioning the `pred_dur` tensor at
    /// space token boundaries. Each partition's summed frames are converted to
    /// seconds via `frames * hopSize / sampleRate`.
    ///
    /// - Parameters:
    ///   - text: Text to speak.
    ///   - voice: Voice preset identifier (e.g. "af_heart").
    ///   - language: BCP-47 language code prefix (e.g. "en", "fr").
    ///   - speed: Speed multiplier. 1.0 = normal.
    /// - Returns: Audio samples and per-word start time offsets.
    /// - Throws: `KokoroError` on model or inference failure.
    func synthesize(
        text: String,
        voice: String = "af_heart",
        language: String = "en",
        speed: Float = 1.0
    ) throws -> KokoroSynthesisResult {
        guard isLoaded, let network else {
            throw KokoroError.inferenceFailed(reason: "Model not loaded")
        }

        let allTokenIds = phonemizer.tokenize(text, maxLength: 510, language: language)
        if allTokenIds.count > 128 {
            logger.warning(
                "Input text produced \(allTokenIds.count) tokens, truncating to 128 (text: \(text.prefix(80))...)"
            )
        }
        let tokenIds = allTokenIds.count > 128
            ? Array(allTokenIds.prefix(127)) + [phonemizer.eosId]
            : allTokenIds
        let tokenCount = min(tokenIds.count, 128)

        guard let styleVector = voiceEmbeddings[voice] else {
            throw KokoroError.voiceNotFound(voice: voice, available: availableVoices)
        }

        let padTo = 128
        let paddedIds = phonemizer.pad(Array(tokenIds.prefix(padTo)), to: padTo)

        let inputIds = try createInt32Array(shape: [1, padTo], values: paddedIds.map { Int32($0) })
        let maskArray = try createInt32Array(
            shape: [1, padTo],
            values: (0 ..< padTo).map { Int32($0 < tokenCount ? 1 : 0) }
        )
        let refS = try createFloatArray(shape: [1, config.styleDim], values: styleVector)
        let speedArray = try createFloatArray(shape: [1], values: [speed])

        let t0 = CFAbsoluteTimeGetCurrent()
        let result = try network.predictE2E(
            inputIds: inputIds, attentionMask: maskArray, refS: refS, speed: speedArray
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        // Extract audio samples
        let validSamples = min(result.audioLengthSamples, result.audio.count)
        guard validSamples > 0 else {
            return KokoroSynthesisResult(
                audio: [], wordOffsets: [], predictedDuration: 0, audioDuration: 0
            )
        }

        var audio = [Float](repeating: 0, count: validSamples)
        if result.audio.dataType == .float16 {
            let ptr = result.audio.dataPointer.bindMemory(to: Float16.self, capacity: validSamples)
            for i in 0 ..< validSamples {
                audio[i] = Float(ptr[i])
            }
        } else {
            let ptr = result.audio.dataPointer.bindMemory(to: Float.self, capacity: validSamples)
            for i in 0 ..< validSamples {
                audio[i] = ptr[i]
            }
        }

        // Compute word offsets from pred_dur
        let wordOffsets = computeWordOffsets(
            tokenIds: Array(tokenIds.prefix(tokenCount)),
            predDur: result.predDur,
            tokenCount: tokenCount,
            speed: speed
        )

        let audioDuration = Double(validSamples) / Double(config.sampleRate)
        let elapsedMs = elapsed * 1000

        // Diagnostic: compare pred_dur total to actual audio duration.
        // If these diverge significantly, pred_dur may not be speed-adjusted
        // and word offsets will drift from actual playback.
        let predDurTotal = computeTotalPredDurSeconds(
            predDur: result.predDur, tokenCount: tokenCount
        )
        let driftMs = (predDurTotal - audioDuration) * 1000

        let durationStr = String(format: "%.3f", audioDuration)
        let predDurStr = String(format: "%.3f", predDurTotal)
        let driftStr = String(format: "%+.0f", driftMs)
        let elapsedMsStr = String(format: "%.0f", elapsedMs)
        let offsetsStr = wordOffsets.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        logger.info(
            "Kokoro E2E: \(tokenCount) tokens -> \(validSamples) samples (\(durationStr)s) in \(elapsedMsStr)ms"
        )
        logger.info(
            "Kokoro timing: predDur=\(predDurStr)s vs audio=\(durationStr)s (drift=\(driftStr)ms), \(wordOffsets.count) offsets: [\(offsetsStr)]"
        )

        return KokoroSynthesisResult(
            audio: audio,
            wordOffsets: wordOffsets,
            predictedDuration: predDurTotal,
            audioDuration: audioDuration
        )
    }

    /// Warm up the CoreML model with a short dummy inference.
    func warmUp() {
        _ = try? synthesize(text: "hello", voice: availableVoices.first ?? Self.defaultVoice)
    }

    // MARK: - Word Offset Computation

    /// Partitions `pred_dur` frames at space-token boundaries to produce per-word start times.
    ///
    /// The phonemizer produces token IDs where spaces (token for " ") delimit word
    /// boundaries. BOS (1) and EOS (2) are structural tokens. For each contiguous
    /// run of non-space, non-BOS, non-EOS tokens, the corresponding `pred_dur`
    /// frames are summed and converted to seconds.
    ///
    /// - Parameters:
    ///   - tokenIds: The actual (unpadded) token IDs produced by the phonemizer.
    ///   - predDur: The `pred_dur` output tensor from CoreML `[1, 128]`.
    ///   - tokenCount: Number of real (unpadded) tokens.
    ///   - speed: Speed multiplier applied during synthesis.
    /// - Returns: Cumulative start-time offsets for each word.
    private func computeWordOffsets(
        tokenIds: [Int],
        predDur: MLMultiArray,
        tokenCount: Int,
        speed: Float
    ) -> [TimeInterval] {
        guard let spaceId = phonemizer.tokenId(for: " ") else {
            logger.warning("Space token not found in vocabulary -- word boundaries will be incorrect")
            return []
        }
        let bosId = phonemizer.bosId
        let eosId = phonemizer.eosId

        let durations = Self.readPredDurValues(predDur: predDur, tokenCount: tokenCount)
        let durCount = durations.count

        logger.debug(
            "computeWordOffsets: \(tokenIds.count) tokens, \(durCount) durations, spaceId=\(spaceId), bosId=\(bosId), eosId=\(eosId)"
        )

        // Walk tokens, accumulating duration frames per word.
        // A "word" is a run of tokens that are not space/BOS/EOS.
        var wordOffsets: [TimeInterval] = []
        var cumulativeFrames: Float = 0
        var inWord = false

        for i in 0 ..< min(tokenIds.count, durCount) {
            let tok = tokenIds[i]

            if tok == bosId || tok == eosId {
                if inWord { inWord = false }
                cumulativeFrames += durations[i]
                continue
            }

            if tok == spaceId {
                if inWord { inWord = false }
                cumulativeFrames += durations[i]
                continue
            }

            // Content token belonging to a word.
            if !inWord {
                let seconds = TimeInterval(cumulativeFrames) * TimeInterval(Self.hopSize)
                    / TimeInterval(Self.sampleRate)
                wordOffsets.append(seconds)
                inWord = true
            }
            cumulativeFrames += durations[i]
        }

        return wordOffsets
    }

    /// Reads `pred_dur` float values from the CoreML output tensor.
    static func readPredDurValues(predDur: MLMultiArray, tokenCount: Int) -> [Float] {
        let durCount = min(tokenCount, predDur.count)
        var durations = [Float](repeating: 0, count: durCount)
        if predDur.dataType == .float16 {
            let ptr = predDur.dataPointer.assumingMemoryBound(to: Float16.self)
            for i in 0 ..< durCount {
                durations[i] = Float(ptr[i])
            }
        } else {
            let ptr = predDur.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0 ..< durCount {
                durations[i] = ptr[i]
            }
        }
        return durations
    }

    /// Sums all pred_dur frames and converts to seconds for diagnostic comparison.
    private func computeTotalPredDurSeconds(predDur: MLMultiArray, tokenCount: Int) -> TimeInterval {
        let durations = Self.readPredDurValues(predDur: predDur, tokenCount: tokenCount)
        let totalFrames = durations.reduce(0, +)
        return TimeInterval(totalFrames) * TimeInterval(Self.hopSize) / TimeInterval(Self.sampleRate)
    }

    // MARK: - Model Loading

    /// Load a pretrained Kokoro model from HuggingFace.
    ///
    /// Downloads weights on first call, then loads from the local cache.
    ///
    /// - Parameters:
    ///   - modelId: HuggingFace model identifier.
    ///   - computeUnits: CoreML compute units. Defaults to `.all` (Neural Engine preferred).
    ///   - progressHandler: Progress callback with fraction (0.0-1.0) and stage description.
    /// - Returns: A ready-to-use synthesizer instance.
    /// - Throws: `KokoroError` on download or load failure.
    static func fromPretrained(
        modelId: String = defaultModelId,
        computeUnits: MLComputeUnits = .all,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> sending KokoroSynthesizer {
        logger.info("Loading Kokoro model: \(modelId)")

        let cacheDir = try KokoroDownloader.getCacheDirectory(for: modelId)

        if KokoroDownloader.isModelCached(modelId: modelId) {
            logger.info("Kokoro model already cached, verifying integrity")
            do {
                guard let entry = ModelIntegrityHashes.kokoro[modelId] else {
                    throw KokoroError.downloadFailed(
                        reason: "\(modelId): unrecognized model, no integrity entry"
                    )
                }
                try await KokoroDownloader.verifyIntegrity(
                    cacheDir: cacheDir, entry: entry, modelId: modelId
                )
            } catch {
                logger.warning(
                    "Cached Kokoro model failed integrity check; re-downloading"
                )
                try? FileManager.default.removeItem(at: cacheDir)
                try FileManager.default.createDirectory(
                    at: cacheDir, withIntermediateDirectories: true
                )
                progressHandler?(0.0, "Re-downloading model...")
                try await KokoroDownloader.downloadWeights(
                    modelId: modelId,
                    to: cacheDir
                ) { fraction in
                    progressHandler?(fraction * 0.7, "Re-downloading model...")
                }
            }
            progressHandler?(0.7, "Model verified")
        } else {
            progressHandler?(0.0, "Downloading model...")
            try await KokoroDownloader.downloadWeights(
                modelId: modelId,
                to: cacheDir
            ) { fraction in
                progressHandler?(fraction * 0.7, "Downloading model...")
            }
        }

        // Load vocabulary
        progressHandler?(0.72, "Loading vocabulary...")
        let vocabURL = cacheDir.appendingPathComponent("vocab_index.json")
        guard FileManager.default.fileExists(atPath: vocabURL.path) else {
            throw KokoroError.modelLoadFailed(reason: "vocab_index.json not found in cache")
        }
        let phonemizer = try KokoroPhonemizer.loadVocab(from: vocabURL)
        try phonemizer.loadDictionaries(from: cacheDir)

        // Load G2P models
        progressHandler?(0.76, "Loading G2P models...")
        let g2pEncoderURL = cacheDir.appendingPathComponent("G2PEncoder.mlmodelc", isDirectory: true)
        let g2pDecoderURL = cacheDir.appendingPathComponent("G2PDecoder.mlmodelc", isDirectory: true)
        let g2pVocabURL = cacheDir.appendingPathComponent("g2p_vocab.json")
        if FileManager.default.fileExists(atPath: g2pEncoderURL.path),
           FileManager.default.fileExists(atPath: g2pDecoderURL.path) {
            try phonemizer.loadG2PModels(
                encoderURL: g2pEncoderURL, decoderURL: g2pDecoderURL, vocabURL: g2pVocabURL
            )
            logger.debug("Loaded CoreML G2P encoder + decoder")
        }

        // Load voice embeddings
        progressHandler?(0.78, "Loading voice embeddings...")
        var voiceEmbeddings = [String: [Float]]()
        let voicesDir = cacheDir.appendingPathComponent("voices")
        if FileManager.default.fileExists(atPath: voicesDir.path) {
            let files = try FileManager.default.contentsOfDirectory(at: voicesDir, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                let voiceName = file.deletingPathExtension().lastPathComponent
                if let embedding = try? loadVoiceEmbedding(from: file, styleDim: KokoroConfig.default.styleDim) {
                    voiceEmbeddings[voiceName] = embedding
                }
            }
            logger.debug("Loaded \(voiceEmbeddings.count) voice presets")
        }

        // Load E2E CoreML model
        progressHandler?(0.85, "Loading CoreML model...")
        let network = try KokoroNetwork(directory: cacheDir, computeUnits: computeUnits)
        logger.debug("Loaded Kokoro E2E model")

        progressHandler?(1.0, "Model loaded")
        logger.info("Kokoro model loaded successfully")

        return KokoroSynthesizer(
            config: .default, network: network,
            phonemizer: phonemizer, voiceEmbeddings: voiceEmbeddings
        )
    }

    // MARK: - Private Helpers

    private static func loadVoiceEmbedding(from url: URL, styleDim: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double]
        else { return [] }
        return embedding.prefix(styleDim).map { Float($0) }
    }

    private func createInt32Array(shape: [Int], values: [Int32]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape.map { $0 as NSNumber }, dataType: .int32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0 ..< values.count {
            ptr[i] = values[i]
        }
        return arr
    }

    private func createFloatArray(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: shape.map { $0 as NSNumber }, dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0 ..< values.count {
            ptr[i] = values[i]
        }
        return arr
    }
}
