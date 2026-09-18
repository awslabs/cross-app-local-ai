import Foundation
import Testing
@testable import FastLang

@Suite("ModelIntegrityHashes registry")
struct ModelIntegrityHashesTests {

    // MARK: - Kokoro entries

    @Test("kokoro registry contains the production model ID")
    func kokoroHasProductionEntry() {
        let entry = ModelIntegrityHashes.kokoro["aufklarer/Kokoro-82M-CoreML"]
        #expect(entry != nil)
    }

    @Test("kokoro entry has a pinned revision SHA")
    func kokoroRevisionIsPinned() {
        let entry = ModelIntegrityHashes.kokoro["aufklarer/Kokoro-82M-CoreML"]
        #expect(entry?.revision != nil)
        #expect(entry?.revision?.isEmpty == false)
    }

    @Test("kokoro entry has at least one file hash")
    func kokoroHasFileHashes() {
        let entry = ModelIntegrityHashes.kokoro["aufklarer/Kokoro-82M-CoreML"]
        #expect(entry?.files.isEmpty == false)
    }

    @Test("kokoro hashes are valid 64-character lowercase hex strings")
    func kokoroHashesAreValidHex() {
        for (_, entry) in ModelIntegrityHashes.kokoro {
            for (_, hash) in entry.files {
                let isLowercaseHex = hash.allSatisfy(\.isHexDigit)
                #expect(hash.count == 64)
                #expect(hash == hash.lowercased())
                #expect(isLowercaseHex)
            }
        }
    }

    // MARK: - WhisperKit entries

    @Test("whisperkit registry contains all five supported variants")
    func whisperkitHasAllVariants() {
        let expectedVariants = [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-medium",
            "openai_whisper-large-v3-v20240930_626MB",
        ]
        for variant in expectedVariants {
            #expect(ModelIntegrityHashes.whisperkit[variant] != nil, "Missing: \(variant)")
        }
    }

    @Test("whisperkit entries have nil revision (WhisperKit API limitation)")
    func whisperkitRevisionsAreNil() {
        for (_, entry) in ModelIntegrityHashes.whisperkit {
            #expect(entry.revision == nil)
        }
    }

    @Test("whisperkit hashes are valid 64-character lowercase hex strings")
    func whisperkitHashesAreValidHex() {
        for (_, entry) in ModelIntegrityHashes.whisperkit {
            for (_, hash) in entry.files {
                let isLowercaseHex = hash.allSatisfy(\.isHexDigit)
                #expect(hash.count == 64)
                #expect(hash == hash.lowercased())
                #expect(isLowercaseHex)
            }
        }
    }

    @Test("whisper-small has hashes for all three weight files")
    func whisperSmallHasThreeFiles() {
        let entry = ModelIntegrityHashes.whisperkit["openai_whisper-small"]
        #expect(entry?.files.count == 3)
        #expect(entry?.files["AudioEncoder.mlmodelc/weights/weight.bin"] != nil)
        #expect(entry?.files["MelSpectrogram.mlmodelc/weights/weight.bin"] != nil)
        #expect(entry?.files["TextDecoder.mlmodelc/weights/weight.bin"] != nil)
    }

    // MARK: - Entry struct

    @Test("Entry is Sendable")
    func entryIsSendable() {
        let entry = ModelIntegrityHashes.Entry(revision: "abc", files: ["a": "b"])
        let _: any Sendable = entry
    }
}
