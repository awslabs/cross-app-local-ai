#if canImport(AWSTranscribeStreaming)
    import AWSTranscribeStreaming
    import Foundation
    import Testing
    @testable import FastLang

    /// Integration test that synthesizes text with Kokoro TTS, streams the audio to
    /// AWS Transcribe Streaming for transcription, then compares transcripts against
    /// source text to identify word loss at chunk boundaries.
    ///
    /// Run with:
    /// ```
    /// xcodebuild test -scheme FastLang -destination 'platform=macOS' \
    ///   -only-testing:IntegrationTests/KokoroTtsEvalTests
    /// ```
    ///
    /// Prerequisites:
    /// - Kokoro model cached locally (download via Settings)
    /// - Valid AWS credentials with transcribe:StartStreamTranscription permission
    @Suite("Kokoro TTS Eval")
    struct KokoroTtsEvalTests {

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

        private static let sampleRate = KokoroSynthesizer.sampleRate
        private static let maxTokensPerChunk = 126

        // MARK: - Main Eval Test

        @Test("Transcribe per-chunk and combined audio, report word loss at boundaries")
        func evaluateChunkBoundaries() async throws {
            guard KokoroModelManager.isModelCached() else {
                print("SKIP: Kokoro model not cached. Download it in Settings first.")
                return
            }

            let synth = try await KokoroSynthesizer.fromPretrained()

            // Split text using production logic
            let sentences = TextChunking.splitIntoSentences(Self.sampleText, baseOffset: 0)
            let chunks = splitLongChunks(sentences, synthesizer: synth, language: "en")

            print("\n===== TTS EVAL: CHUNK BOUNDARY WORD LOSS =====")
            print("Input text length: \(Self.sampleText.count) chars")
            print("Chunks: \(chunks.count)")

            // Synthesize each chunk
            var chunkAudios: [[Float]] = []
            for (i, chunk) in chunks.enumerated() {
                let result = try synth.synthesize(
                    text: chunk.text, voice: "af_heart", language: "en", speed: 1.0
                )
                chunkAudios.append(result.audio)
                let duration = Double(result.audio.count) / Double(Self.sampleRate)
                print(
                    "  Chunk \(i): \(result.audio.count) samples (\(String(format: "%.3f", duration))s) - \"\(chunk.text.prefix(60))...\""
                )
            }

            // Combine all chunks (raw concatenation)
            let combinedRaw = chunkAudios.flatMap(\.self)

            // Combine with crossfade (production behavior)
            let combinedCrossfaded = applyCrossfade(chunkAudios: chunkAudios)

            let rawDuration = Double(combinedRaw.count) / Double(Self.sampleRate)
            let crossfadedDuration = Double(combinedCrossfaded.count) / Double(Self.sampleRate)
            print("\nCombined raw: \(combinedRaw.count) samples (\(String(format: "%.3f", rawDuration))s)")
            print(
                "Combined crossfaded: \(combinedCrossfaded.count) samples (\(String(format: "%.3f", crossfadedDuration))s)"
            )

            // Transcribe each chunk individually
            print("\n--- Per-Chunk Transcription ---")
            var chunkTranscripts: [String] = []
            for (i, audio) in chunkAudios.enumerated() {
                print("  Transcribing chunk \(i)...", terminator: " ")
                let transcript = try await transcribeAudio(samples: audio)
                chunkTranscripts.append(transcript)
                print("done (\(transcript.split(separator: " ").count) words)")
            }

            // Transcribe combined audio
            print("\n--- Combined Transcription ---")
            print("  Transcribing combined_raw...", terminator: " ")
            let rawTranscript = try await transcribeAudio(samples: combinedRaw)
            print("done (\(rawTranscript.split(separator: " ").count) words)")

            print("  Transcribing combined_crossfaded...", terminator: " ")
            let crossfadedTranscript = try await transcribeAudio(samples: combinedCrossfaded)
            print("done (\(crossfadedTranscript.split(separator: " ").count) words)")

            // Analysis
            print("\n" + String(repeating: "=", count: 60))
            print("RESULTS")
            print(String(repeating: "=", count: 60))

            // Per-chunk accuracy
            print("\n--- Per-Chunk Word Accuracy ---")
            for (i, (chunk, transcript)) in zip(chunks, chunkTranscripts).enumerated() {
                let diff = wordDiff(expected: chunk.text, actual: transcript)
                let status = diff.similarity > 0.9 ? "OK" : "ISSUE"
                print("\n  Chunk \(i) [\(status)] (similarity: \(String(format: "%.1f%%", diff.similarity * 100)))")
                print("    Expected: \"\(chunk.text.prefix(80))\"")
                print("    Got:      \"\(transcript.prefix(80))\"")
                if !diff.missingWords.isEmpty {
                    let missing = diff.missingWords.prefix(10).map(\.word).joined(separator: ", ")
                    print("    Missing words: \(missing)")
                }
                if !diff.substitutions.isEmpty {
                    let subs = diff.substitutions.prefix(5).map { "\($0.expected)->\($0.actual)" }
                        .joined(separator: ", ")
                    print("    Substitutions: \(subs)")
                }
            }

            // Combined accuracy
            print("\n--- Combined Audio Word Accuracy ---")
            for (
                label,
                transcript
            ) in [("combined_raw", rawTranscript), ("combined_crossfaded", crossfadedTranscript)] {
                let diff = wordDiff(expected: Self.sampleText, actual: transcript)
                print("\n  \(label) (similarity: \(String(format: "%.1f%%", diff.similarity * 100)))")
                print("    Expected words: \(diff.expectedWordCount)")
                print("    Transcribed words: \(diff.actualWordCount)")
                if !diff.missingWords.isEmpty {
                    print("    Missing (\(diff.missingWords.count) words):")
                    for w in diff.missingWords.prefix(20) {
                        print("      pos \(w.position): \"\(w.word)\"")
                    }
                }
                if !diff.substitutions.isEmpty {
                    print("    Substitutions (\(diff.substitutions.count)):")
                    for s in diff.substitutions.prefix(10) {
                        print("      pos \(s.position): \"\(s.expected)\" -> \"\(s.actual)\"")
                    }
                }
            }

            // Boundary analysis
            print("\n--- Chunk Boundary Analysis ---")
            let boundaryIssues = analyzeBoundaries(chunks: chunks, chunkTranscripts: chunkTranscripts)
            if boundaryIssues.isEmpty {
                print("  No boundary issues detected!")
            } else {
                for issue in boundaryIssues {
                    print("\n  \(issue.boundary):")
                    if !issue.tailMissing.isEmpty {
                        print("    Tail words MISSING from chunk end: \(issue.tailMissing)")
                        print("    (last 5 transcribed: \(issue.lastTranscribed))")
                    }
                    if !issue.headMissing.isEmpty {
                        print("    Head words MISSING from next chunk start: \(issue.headMissing)")
                        print("    (first 5 transcribed: \(issue.firstTranscribed))")
                    }
                }
            }

            // Write results JSON
            let outputDir = URL(fileURLWithPath: "/tmp/kokoro_chunk_test")
            let fm = FileManager.default
            if !fm.fileExists(atPath: outputDir.path) {
                try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
            }
            let results: [String: Any] = [
                "sampleText": Self.sampleText,
                "chunkCount": chunks.count,
                "chunkTranscripts": chunkTranscripts,
                "combinedRawTranscript": rawTranscript,
                "combinedCrossfadedTranscript": crossfadedTranscript,
                "boundaryIssues": boundaryIssues.map { [
                    "boundary": $0.boundary,
                    "tailMissing": $0.tailMissing,
                    "headMissing": $0.headMissing,
                ] as [String: Any] },
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            let resultsPath = outputDir.appendingPathComponent("eval_results.json")
            try jsonData.write(to: resultsPath)
            print("\nResults written to: \(resultsPath.path)")

            // Assertions
            #expect(chunks.count > 0)
            #expect(combinedRaw.count > 0)
            #expect(!rawTranscript.isEmpty)
            #expect(!crossfadedTranscript.isEmpty)
        }

        // MARK: - AWS Transcribe Streaming

        private func transcribeAudio(samples: [Float]) async throws -> String {
            let pcmData = floatToPCM16(samples)
            let client = try TranscribeStreamingClient(region: "us-east-1")

            // Create audio stream that sends chunks of ~100ms each
            let chunkSize = Self.sampleRate / 10 // 2400 samples = 100ms at 24kHz
            let bytesPerChunk = chunkSize * 2 // 16-bit = 2 bytes per sample

            let audioStream = AsyncThrowingStream<TranscribeStreamingClientTypes.AudioStream, Error> { continuation in
                Task {
                    var offset = 0
                    while offset < pcmData.count {
                        let end = min(offset + bytesPerChunk, pcmData.count)
                        let chunk = pcmData[offset ..< end]
                        let audioEvent = TranscribeStreamingClientTypes.AudioEvent(audioChunk: Data(chunk))
                        continuation.yield(.audioevent(audioEvent))
                        offset = end
                        // Small delay to avoid overwhelming the service
                        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                    }
                    continuation.finish()
                }
            }

            let input = StartStreamTranscriptionInput(
                audioStream: audioStream,
                languageCode: .enUs,
                mediaEncoding: .pcm,
                mediaSampleRateHertz: Self.sampleRate
            )

            let output = try await client.startStreamTranscription(input: input)

            guard let resultStream = output.transcriptResultStream else {
                return ""
            }

            var finalTranscript = ""
            for try await event in resultStream {
                switch event {
                case let .transcriptevent(transcriptEvent):
                    guard let results = transcriptEvent.transcript?.results else { continue }
                    for result in results where !result.isPartial {
                        if let text = result.alternatives?.first?.transcript {
                            if !finalTranscript.isEmpty {
                                finalTranscript += " "
                            }
                            finalTranscript += text
                        }
                    }
                case .sdkUnknown:
                    break
                }
            }

            return finalTranscript
        }

        /// Convert Float32 PCM samples to signed 16-bit little-endian PCM bytes.
        private func floatToPCM16(_ samples: [Float]) -> Data {
            var data = Data(capacity: samples.count * 2)
            for sample in samples {
                let clamped = max(-1.0, min(1.0, sample))
                let int16Value = Int16(clamped * Float(Int16.max))
                withUnsafeBytes(of: int16Value.littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }

        // MARK: - Chunk Splitting (uses shared TextChunking.waterfallChunk)

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

        private static let crossfadeSamples = 120

        private func applyCrossfade(chunkAudios: [[Float]]) -> [Float] {
            var allSamples: [Float] = []
            var previousTail: [Float] = []
            let fadeLen = Self.crossfadeSamples

            for (i, var audio) in chunkAudios.enumerated() {
                let isLast = i == chunkAudios.count - 1

                // Blend previous tail into head
                if !previousTail.isEmpty, audio.count >= fadeLen {
                    let blendLen = min(previousTail.count, fadeLen, audio.count)
                    for j in 0 ..< blendLen {
                        let progress = Float(j) / Float(blendLen)
                        let fadeOut = cosineWindow(progress: 1.0 - progress)
                        let fadeIn = cosineWindow(progress: progress)
                        audio[j] = previousTail[j] * fadeOut + audio[j] * fadeIn
                    }
                }

                // Store tail for next crossfade
                if !isLast, audio.count >= fadeLen {
                    previousTail = Array(audio.suffix(fadeLen))
                    audio = Array(audio.dropLast(fadeLen))
                } else {
                    previousTail = []
                }

                allSamples.append(contentsOf: audio)
            }
            return allSamples
        }

        private func cosineWindow(progress: Float) -> Float {
            0.5 * (1.0 - cos(Float.pi * progress))
        }

        // MARK: - Word Diff Analysis

        private struct WordDiffResult {
            let similarity: Double
            let expectedWordCount: Int
            let actualWordCount: Int
            let missingWords: [MissingWord]
            let extraWords: [ExtraWord]
            let substitutions: [Substitution]
        }

        private struct MissingWord {
            let word: String
            let position: Int
        }

        private struct ExtraWord {
            let word: String
            let position: Int
        }

        private struct Substitution {
            let expected: String
            let actual: String
            let position: Int
        }

        private func normalizeText(_ text: String) -> String {
            var normalized = text.lowercased()
            normalized = normalized.replacingOccurrences(
                of: "[^\\w\\s]",
                with: "",
                options: .regularExpression
            )
            normalized = normalized.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            return normalized
        }

        private func wordDiff(expected: String, actual: String) -> WordDiffResult {
            let expectedWords = normalizeText(expected).split(separator: " ").map(String.init)
            let actualWords = normalizeText(actual).split(separator: " ").map(String.init)

            // Simple LCS-based diff
            let lcs = longestCommonSubsequence(expectedWords, actualWords)
            let similarity = expectedWords.isEmpty ? 1.0 : Double(lcs.count) / Double(expectedWords.count)

            // Find missing and extra words using set-based approach with positions
            let lcsSet = Set(lcs)
            var missingWords: [MissingWord] = []
            var extraWords: [ExtraWord] = []
            var substitutions: [Substitution] = []

            // Track which expected words are in LCS
            var expectedInLCS = [Bool](repeating: false, count: expectedWords.count)
            var lcsIdx = 0
            for (i, word) in expectedWords.enumerated() {
                if lcsIdx < lcs.count, word == lcs[lcsIdx] {
                    expectedInLCS[i] = true
                    lcsIdx += 1
                }
            }

            var actualInLCS = [Bool](repeating: false, count: actualWords.count)
            lcsIdx = 0
            for (i, word) in actualWords.enumerated() {
                if lcsIdx < lcs.count, word == lcs[lcsIdx] {
                    actualInLCS[i] = true
                    lcsIdx += 1
                }
            }

            for (i, word) in expectedWords.enumerated() where !expectedInLCS[i] {
                missingWords.append(MissingWord(word: word, position: i))
            }

            for (i, word) in actualWords.enumerated() where !actualInLCS[i] {
                extraWords.append(ExtraWord(word: word, position: i))
            }

            // Pair up missing/extra at similar positions as substitutions
            var usedExtra = Set<Int>()
            for missing in missingWords {
                if let matchIdx = extraWords.indices.first(where: { idx in
                    !usedExtra.contains(idx) && abs(extraWords[idx].position - missing.position) <= 3
                }) {
                    substitutions.append(Substitution(
                        expected: missing.word,
                        actual: extraWords[matchIdx].word,
                        position: missing.position
                    ))
                    usedExtra.insert(matchIdx)
                }
            }

            let purelyMissing = missingWords.filter { m in
                !substitutions.contains(where: { $0.position == m.position })
            }
            let purelyExtra = extraWords.enumerated().filter { !usedExtra.contains($0.offset) }.map(\.element)

            return WordDiffResult(
                similarity: similarity,
                expectedWordCount: expectedWords.count,
                actualWordCount: actualWords.count,
                missingWords: purelyMissing,
                extraWords: purelyExtra,
                substitutions: substitutions
            )
        }

        private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
            let m = a.count
            let n = b.count
            var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

            for i in 1 ... m {
                for j in 1 ... n {
                    if a[i - 1] == b[j - 1] {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }

            // Backtrack to find actual LCS
            var result: [String] = []
            var i = m, j = n
            while i > 0, j > 0 {
                if a[i - 1] == b[j - 1] {
                    result.append(a[i - 1])
                    i -= 1
                    j -= 1
                } else if dp[i - 1][j] > dp[i][j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }
            return result.reversed()
        }

        // MARK: - Boundary Analysis

        private struct BoundaryIssue {
            let boundary: String
            let tailMissing: [String]
            let headMissing: [String]
            let lastTranscribed: [String]
            let firstTranscribed: [String]
        }

        private func analyzeBoundaries(
            chunks: [SentenceChunk],
            chunkTranscripts: [String]
        ) -> [BoundaryIssue] {
            var issues: [BoundaryIssue] = []

            for i in 0 ..< (chunks.count - 1) {
                let currWords = chunks[i].text.trimmingCharacters(in: .whitespaces).split(separator: " ")
                    .map(String.init)
                let nextWords = chunks[i + 1].text.trimmingCharacters(in: .whitespaces).split(separator: " ")
                    .map(String.init)

                let tailWords = Array(currWords.suffix(3))
                let headWords = Array(nextWords.prefix(3))

                let currTranscriptWords = normalizeText(chunkTranscripts[i]).split(separator: " ").map(String.init)
                let nextTranscriptWords = normalizeText(chunkTranscripts[i + 1]).split(separator: " ").map(String.init)

                let lastFive = Array(currTranscriptWords.suffix(5))
                let firstFive = Array(nextTranscriptWords.prefix(5))

                let tailContext = lastFive.joined(separator: " ")
                let headContext = firstFive.joined(separator: " ")

                let tailMissing = tailWords.filter { word in
                    !tailContext.contains(normalizeText(word))
                }
                let headMissing = headWords.filter { word in
                    !headContext.contains(normalizeText(word))
                }

                if !tailMissing.isEmpty || !headMissing.isEmpty {
                    issues.append(BoundaryIssue(
                        boundary: "chunk_\(i) -> chunk_\(i + 1)",
                        tailMissing: tailMissing,
                        headMissing: headMissing,
                        lastTranscribed: lastFive,
                        firstTranscribed: firstFive
                    ))
                }
            }

            return issues
        }
    }
#endif
