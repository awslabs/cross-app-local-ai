import CryptoKit
import Foundation
import Testing
@testable import FastLang

@Suite("WhisperKitModelManager integrity verification")
struct WhisperKitModelManagerIntegrityTests {

    private func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a fake model folder with weight files for all three CoreML bundles.
    private func createFakeModelFolder(
        audioEncoderContent: Data,
        melSpectrogramContent: Data,
        textDecoderContent: Data
    ) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-integrity-\(UUID().uuidString)")

        let bundles: [(String, Data)] = [
            ("AudioEncoder.mlmodelc/weights", audioEncoderContent),
            ("MelSpectrogram.mlmodelc/weights", melSpectrogramContent),
            ("TextDecoder.mlmodelc/weights", textDecoderContent),
        ]
        for (subdir, content) in bundles {
            let dir = base.appendingPathComponent(subdir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: dir.appendingPathComponent("weight.bin"))
        }
        return base
    }

    /// Convenience: creates a model folder with identical content in all weight files.
    private func createFakeModelFolder(weightContent: Data) throws -> URL {
        try createFakeModelFolder(
            audioEncoderContent: weightContent,
            melSpectrogramContent: weightContent,
            textDecoderContent: weightContent
        )
    }

    // MARK: - Missing weight file is fatal

    @Test("verifyIntegrity throws when weight files are missing")
    func missingWeightFileThrows() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        await #expect(throws: SttError.self) {
            try await WhisperKitModelManager.verifyIntegrity(
                modelFolder: base, modelId: "whisper-small"
            )
        }
    }

    // MARK: - Tampered file triggers error

    @Test("verifyIntegrity throws modelIntegrityFailed for tampered file")
    func tamperedFileThrows() async throws {
        let content = Data("tampered whisperkit model weights".utf8)
        let modelFolder = try createFakeModelFolder(weightContent: content)
        defer { try? FileManager.default.removeItem(at: modelFolder) }

        await #expect(throws: SttError.self) {
            try await WhisperKitModelManager.verifyIntegrity(
                modelFolder: modelFolder, modelId: "whisper-small"
            )
        }
    }

    @Test("verifyIntegrity deletes model folder on mismatch")
    func tamperedFileDeletesFolder() async throws {
        let content = Data("corrupt whisper weights".utf8)
        let modelFolder = try createFakeModelFolder(weightContent: content)

        #expect(FileManager.default.fileExists(atPath: modelFolder.path))

        do {
            try await WhisperKitModelManager.verifyIntegrity(
                modelFolder: modelFolder, modelId: "whisper-small"
            )
            Issue.record("Expected modelIntegrityFailed to be thrown")
        } catch is SttError {
            #expect(!FileManager.default.fileExists(atPath: modelFolder.path))
        }
    }

    // MARK: - Multi-file verification

    @Test("verifyIntegrity fails when only AudioEncoder present with bad content")
    func tamperedAudioEncoderThrows() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-integrity-\(UUID().uuidString)")
        let audioDir = base.appendingPathComponent("AudioEncoder.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try Data("bad audio encoder".utf8).write(to: audioDir.appendingPathComponent("weight.bin"))
        defer { try? FileManager.default.removeItem(at: base) }

        await #expect(throws: SttError.self) {
            try await WhisperKitModelManager.verifyIntegrity(
                modelFolder: base, modelId: "whisper-small"
            )
        }
    }

    @Test("verifyIntegrity fails when only MelSpectrogram present with bad content")
    func tamperedMelSpectrogramThrows() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-integrity-\(UUID().uuidString)")

        let melDir = base.appendingPathComponent("MelSpectrogram.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: melDir, withIntermediateDirectories: true)
        try Data("bad mel spectrogram".utf8).write(to: melDir.appendingPathComponent("weight.bin"))

        defer { try? FileManager.default.removeItem(at: base) }

        await #expect(throws: SttError.self) {
            try await WhisperKitModelManager.verifyIntegrity(
                modelFolder: base, modelId: "whisper-small"
            )
        }
    }

    // MARK: - Variant mapping

    @Test("mapModelIdToVariant maps all known IDs correctly")
    func variantMapping() {
        #expect(WhisperKitModelManager.mapModelIdToVariant("whisper-tiny") == "openai_whisper-tiny")
        #expect(WhisperKitModelManager.mapModelIdToVariant("whisper-base") == "openai_whisper-base")
        #expect(WhisperKitModelManager.mapModelIdToVariant("whisper-small") == "openai_whisper-small")
        #expect(WhisperKitModelManager.mapModelIdToVariant("whisper-medium") == "openai_whisper-medium")
        #expect(
            WhisperKitModelManager.mapModelIdToVariant("whisper-large-v3")
                == "openai_whisper-large-v3-v20240930_626MB"
        )
    }

    @Test("mapModelIdToVariant defaults to openai_whisper-small for unknown IDs")
    func variantMappingDefault() {
        #expect(WhisperKitModelManager.mapModelIdToVariant("unknown") == "openai_whisper-small")
    }

    // MARK: - Error type verification

    @Test("SttError.modelIntegrityFailed has correct error description")
    func errorDescription() {
        let error = SttError.modelIntegrityFailed(modelId: "whisper-medium")
        let description = error.userMessage
        #expect(description.contains("integrity verification"))
        #expect(description.contains("whisper-medium"))
        #expect(description.contains("re-download"))
    }
}
