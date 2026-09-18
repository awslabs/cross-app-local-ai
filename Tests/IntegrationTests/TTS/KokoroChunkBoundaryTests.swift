import AVFoundation
import Foundation
import Testing
@testable import FastLang

/// Integration test that exercises the full Kokoro TTS pipeline on longer text
/// and writes per-chunk + combined WAV files for offline evaluation.
///
/// Run with:
/// ```
/// xcodebuild test -scheme FastLang -destination 'platform=macOS' \
///   -only-testing:IntegrationTests/KokoroChunkBoundaryTests
/// ```
///
/// WAV files are written to `/tmp/kokoro_chunk_test/`.
@Suite("Kokoro Chunk Boundary")
struct KokoroChunkBoundaryTests {

    /// The sample text that exhibits word loss at chunk boundaries.
    static let sampleText = """
    At the Generative AI Innovation Center, I design and build AI-powered solutions \
    that help organizations explore and adopt AI. I work to turn AI research into \
    intelligent pipelines that solve key customer pain points and optimize workflows \
    to reduce cost.

    My work includes designing context augmentation systems, custom model training \
    and fine-tuning, optimizing for latency and cost, and building LLM-powered \
    agent/workflows systems. I've led projects across commercial, nonprofit, and \
    government organizations, often serving as the technical lead. My focus is on \
    delivering responsible, efficient, and impactful solutions that drive real-world value.
    """

    static let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro_chunk_test")
    static let sampleRate = KokoroSynthesizer.sampleRate

    @Test("Synthesize sample text and write WAV files for evaluation")
    func synthesizeAndWriteWavs() async throws {
        guard KokoroModelManager.isModelCached() else {
            print("SKIP: Kokoro model not cached. Download it in Settings first.")
            return
        }

        let synth = try await KokoroSynthesizer.fromPretrained()

        // Clean output directory
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.outputDir.path) {
            try fm.removeItem(at: Self.outputDir)
        }
        try fm.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)

        // Step 1: Split text exactly as KokoroTtsProvider does
        let sentences = TextChunking.splitIntoSentences(Self.sampleText, baseOffset: 0)
        let chunks = splitLongChunks(sentences, synthesizer: synth, language: "en")

        print("\n===== CHUNKING DIAGNOSTICS =====")
        print("Input text length: \(Self.sampleText.count) chars")
        print("Sentence chunks: \(sentences.count)")
        print("Final chunks (after token-budget splitting): \(chunks.count)")
        print("")

        // Write chunk text metadata
        var chunkManifest: [[String: Any]] = []
        var allSamples: [Float] = []
        var totalDuration: Double = 0

        for (i, chunk) in chunks.enumerated() {
            let tokenCount = synth.tokenCount(for: chunk.text, language: "en")
            print("--- Chunk \(i) ---")
            print("  Offset: \(chunk.offset)")
            print("  Tokens: \(tokenCount)")
            print("  Text: \"\(chunk.text)\"")

            // Step 2: Synthesize
            let result = try synth.synthesize(
                text: chunk.text,
                voice: "af_heart",
                language: "en",
                speed: 1.0
            )

            let duration = result.audioDuration
            let drift = result.predictedDuration - result.audioDuration
            print("  Audio: \(result.audio.count) samples (\(String(format: "%.3f", duration))s)")
            print(
                "  PredDur: \(String(format: "%.3f", result.predictedDuration))s (drift=\(String(format: "%+.0f", drift * 1000))ms)"
            )
            print("  Word offsets: \(result.wordOffsets.count)")

            // Assert no chunk is truncated beyond the tolerance threshold
            let driftMs = Int(drift * 1000)
            #expect(drift < 0.2, "Chunk \(i) truncated: drift=+\(driftMs)ms")

            // Step 3: Word timing analysis
            let words = WordTokenizer.tokenize(chunk.text, baseOffset: chunk.offset)
            print("  Text words: \(words.count)")

            if words.count != result.wordOffsets.count {
                print("  WARNING: word count mismatch! text=\(words.count) vs model=\(result.wordOffsets.count)")
            }

            // Show word-timing pairs
            let pairCount = min(words.count, result.wordOffsets.count)
            for j in 0 ..< pairCount {
                let wordRange = words[j].range
                let lower = Self.sampleText.index(Self.sampleText.startIndex, offsetBy: wordRange.lowerBound)
                let upper = Self.sampleText.index(
                    Self.sampleText.startIndex,
                    offsetBy: min(wordRange.upperBound, Self.sampleText.count)
                )
                let wordText = String(Self.sampleText[lower ..< upper])
                let offset = result.wordOffsets[j]
                print("    word[\(j)]: \"\(wordText)\" @ \(String(format: "%.3f", offset))s (range: \(wordRange))")
            }

            // Step 4: Write per-chunk WAV
            let chunkUrl = Self.outputDir.appendingPathComponent("chunk_\(String(format: "%02d", i)).wav")
            try writeWav(samples: result.audio, to: chunkUrl)
            print("  Written: \(chunkUrl.lastPathComponent)")

            allSamples.append(contentsOf: result.audio)
            totalDuration += duration

            chunkManifest.append([
                "index": i,
                "offset": chunk.offset,
                "text": chunk.text,
                "tokens": tokenCount,
                "samples": result.audio.count,
                "duration": duration,
                "wordCount": words.count,
                "modelWordOffsets": result.wordOffsets.count,
            ])
            print("")
        }

        // Step 5: Write combined WAV (no crossfade -- raw concatenation)
        let combinedUrl = Self.outputDir.appendingPathComponent("combined_raw.wav")
        try writeWav(samples: allSamples, to: combinedUrl)
        print("Combined WAV (raw): \(allSamples.count) samples (\(String(format: "%.3f", totalDuration))s)")
        print("Written: \(combinedUrl.lastPathComponent)")

        // Step 6: Write combined WAV WITH crossfade (matching production behavior)
        let crossfadedSamples = applyCrossfadeToChunks(chunks: chunks, synthesizer: synth)
        let crossfadedUrl = Self.outputDir.appendingPathComponent("combined_crossfaded.wav")
        try writeWav(samples: crossfadedSamples, to: crossfadedUrl)
        let crossfadedDuration = Double(crossfadedSamples.count) / Double(Self.sampleRate)
        print(
            "Combined WAV (crossfaded): \(crossfadedSamples.count) samples (\(String(format: "%.3f", crossfadedDuration))s)"
        )
        print("Written: \(crossfadedUrl.lastPathComponent)")

        // Step 7: Write metadata JSON
        let metadata: [String: Any] = [
            "sampleText": Self.sampleText,
            "sampleRate": Self.sampleRate,
            "chunkCount": chunks.count,
            "totalSamplesRaw": allSamples.count,
            "totalSamplesCrossfaded": crossfadedSamples.count,
            "totalDurationRaw": totalDuration,
            "totalDurationCrossfaded": crossfadedDuration,
            "chunks": chunkManifest,
        ]
        let metadataUrl = Self.outputDir.appendingPathComponent("metadata.json")
        let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: metadataUrl)
        print("\nMetadata written: metadata.json")
        print("\nOutput directory: \(Self.outputDir.path)")

        // Basic sanity: ensure we produced audio for every chunk
        #expect(chunks.count > 0)
        #expect(allSamples.count > 0)
    }

    // MARK: - Chunk Splitting (uses shared TextChunking.waterfallChunk)

    private static let maxTokensPerChunk = 80

    private func splitLongChunks(
        _ sentences: [SentenceChunk],
        synthesizer: KokoroSynthesizer,
        language: String
    ) -> [SentenceChunk] {
        let maxTokens = Self.maxTokensPerChunk
        var result: [SentenceChunk] = []
        for chunk in sentences {
            if synthesizer.tokenCount(for: chunk.text, language: language) <= maxTokens + 2 {
                result.append(chunk)
            } else {
                result.append(contentsOf: TextChunking.waterfallChunk(
                    chunk.text,
                    baseOffset: chunk.offset,
                    tokenCount: { synthesizer.tokenCount(for: $0, language: language) },
                    maxTokens: maxTokens
                ))
            }
        }
        return result
    }

    // MARK: - Crossfade (mirrors KokoroPlaybackSession logic)

    private static let crossfadeSamples = 480

    private func applyCrossfadeToChunks(
        chunks: [SentenceChunk],
        synthesizer: KokoroSynthesizer
    ) -> [Float] {
        var allSamples: [Float] = []
        var previousTail: [Float] = []
        let fadeLen = Self.crossfadeSamples

        for (i, chunk) in chunks.enumerated() {
            guard let result = try? synthesizer.synthesize(
                text: chunk.text, voice: "af_heart", language: "en", speed: 1.0
            ) else { continue }

            var output = result.audio
            let isLast = i == chunks.count - 1

            // Blend previous tail into head
            if !previousTail.isEmpty, output.count >= fadeLen {
                let blendLen = min(previousTail.count, fadeLen, output.count)
                for j in 0 ..< blendLen {
                    let progress = Float(j) / Float(blendLen)
                    let fadeOut = cosineWindow(progress: 1.0 - progress)
                    let fadeIn = cosineWindow(progress: progress)
                    output[j] = previousTail[j] * fadeOut + output[j] * fadeIn
                }
            }

            // Store tail for next crossfade
            if !isLast, output.count >= fadeLen {
                previousTail = Array(output.suffix(fadeLen))
                output = Array(output.dropLast(fadeLen))
            } else {
                previousTail = []
            }

            allSamples.append(contentsOf: output)
        }
        return allSamples
    }

    private func cosineWindow(progress: Float) -> Float {
        0.5 * (1.0 - cos(Float.pi * progress))
    }

    // MARK: - WAV Writer

    private func writeWav(samples: [Float], to url: URL) throws {
        let sampleRate = Double(Self.sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TtsError.synthesisFailure(message: "Failed to create audio format for WAV")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw TtsError.synthesisFailure(message: "Failed to create PCM buffer")
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw TtsError.synthesisFailure(message: "No channel data in buffer")
        }
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channelData.update(from: base, count: samples.count)
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
