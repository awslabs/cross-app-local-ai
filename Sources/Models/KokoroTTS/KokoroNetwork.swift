import CoreML
import Foundation

/// CoreML wrapper for Kokoro-82M end-to-end TTS inference.
///
/// Loads a single pre-compiled `kokoro_5s.mlmodelc` that runs the full pipeline
/// (BERT -> duration -> alignment -> prosody -> decoder) in one CoreML call.
final class KokoroNetwork {

    private let e2eModel: MLModel

    /// Load E2E CoreML model from cache directory.
    ///
    /// - Parameters:
    ///   - directory: Directory containing the `.mlmodelc` bundle.
    ///   - computeUnits: Hardware to run on. Defaults to `.all` (Neural Engine preferred).
    /// - Throws: `KokoroError.modelLoadFailed` if no model bundle is found.
    init(directory: URL, computeUnits: MLComputeUnits = .all) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        // Stable cache key so CoreML persists the ANE-compiled artifact across
        // launches instead of recompiling on every load (2+ GB disk writes).
        config.modelDisplayName = "kokoro-82m-tts"

        let e2eNames = ["kokoro_5s", "kokoro_10s", "kokoro_15s", "kokoro"]
        var loaded: MLModel?
        for name in e2eNames {
            let url = directory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                loaded = try MLModel(contentsOf: url, configuration: config)
                break
            }
        }

        guard let model = loaded else {
            throw KokoroError.modelLoadFailed(
                reason: "No Kokoro E2E model found in \(directory.path)"
            )
        }
        e2eModel = model
    }

    // MARK: - E2E Inference Output

    struct E2EOutput {
        let audio: MLMultiArray
        let audioLengthSamples: Int
        let predDur: MLMultiArray
    }

    // MARK: - Inference

    /// Run E2E inference producing audio, sample count, and predicted phoneme durations.
    ///
    /// - Parameters:
    ///   - inputIds: Phoneme token IDs `[1, 128]`.
    ///   - attentionMask: Mask `[1, 128]` (1 for real tokens, 0 for padding).
    ///   - refS: Voice style embedding `[1, styleDim]`.
    ///   - speed: Speed multiplier `[1]`.
    /// - Returns: Audio waveform, valid sample count, and phoneme duration predictions.
    /// - Throws: `KokoroError.inferenceFailed` if output tensors are missing.
    func predictE2E(
        inputIds: MLMultiArray,
        attentionMask: MLMultiArray,
        refS: MLMultiArray,
        speed: MLMultiArray? = nil
    ) throws -> E2EOutput {
        let randomPhases = try MLMultiArray(shape: [1, 9], dataType: .float32)
        let phasesPtr = randomPhases.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0 ..< 9 {
            phasesPtr[i] = Float.random(in: 0 ..< 1)
        }

        let speedInput: MLMultiArray
        if let speed {
            speedInput = speed
        } else {
            speedInput = try MLMultiArray(shape: [1], dataType: .float32)
            speedInput.dataPointer.assumingMemoryBound(to: Float.self).pointee = 1.0
        }

        let dict: [String: MLFeatureValue] = [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
            "ref_s": MLFeatureValue(multiArray: refS),
            "random_phases": MLFeatureValue(multiArray: randomPhases),
            "speed": MLFeatureValue(multiArray: speedInput),
        ]

        let input = try MLDictionaryFeatureProvider(dictionary: dict)
        let output = try e2eModel.prediction(from: input)

        guard let audio = output.featureValue(for: "audio")?.multiArrayValue,
              let audioLen = output.featureValue(for: "audio_length_samples")?.multiArrayValue,
              let predDur = output.featureValue(for: "pred_dur")?.multiArrayValue
        else {
            throw KokoroError.inferenceFailed(reason: "Missing output tensors from E2E model")
        }

        let lengthSamples = if audioLen.dataType == .float16 {
            Int(Float(audioLen.dataPointer.assumingMemoryBound(to: Float16.self).pointee))
        } else if audioLen.dataType == .int32 {
            Int(audioLen.dataPointer.assumingMemoryBound(to: Int32.self).pointee)
        } else {
            Int(audioLen.dataPointer.assumingMemoryBound(to: Float.self).pointee)
        }

        return E2EOutput(audio: audio, audioLengthSamples: lengthSamples, predDur: predDur)
    }
}
