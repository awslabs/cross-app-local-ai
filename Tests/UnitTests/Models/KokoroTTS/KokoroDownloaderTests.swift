import CryptoKit
import Foundation
import Testing
@testable import FastLang

// pragma: allowlist secret
private let bogusHash = "0000000000000000000000000000000000000000000000000000000000000000"

@Suite("KokoroDownloader integrity verification")
struct KokoroDownloaderIntegrityTests {

    private func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a fake cache directory with the expected weight file structure.
    private func createFakeCacheDir(weightContent: Data) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-integrity-\(UUID().uuidString)")
        let weightDir = base
            .appendingPathComponent("kokoro_5s.mlmodelc/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightDir, withIntermediateDirectories: true)
        let weightFile = weightDir.appendingPathComponent("weight.bin")
        try weightContent.write(to: weightFile)
        return base
    }

    /// A test entry with known content and matching hash.
    private func makeTestEntry(for content: Data) -> ModelIntegrityHashes.Entry {
        let hash = sha256Hex(of: content)
        return ModelIntegrityHashes.Entry(
            revision: "abc123",
            files: ["kokoro_5s.mlmodelc/weights/weight.bin": hash]
        )
    }

    // MARK: - Verification passes

    @Test("verifyIntegrity succeeds when weight hash matches")
    func verifyMatchingHash() async throws {
        let content = Data("valid model weights".utf8)
        let cacheDir = try createFakeCacheDir(weightContent: content)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let entry = makeTestEntry(for: content)

        try await KokoroDownloader.verifyIntegrity(
            cacheDir: cacheDir, entry: entry, modelId: "test-kokoro"
        )
    }

    // MARK: - Missing weight file triggers error

    @Test("verifyIntegrity throws when weight file is missing")
    func missingWeightFileThrows() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let entry = ModelIntegrityHashes.Entry(
            revision: "abc123",
            files: ["kokoro_5s.mlmodelc/weights/weight.bin": "deadbeef"]
        )

        await #expect(throws: KokoroError.self) {
            try await KokoroDownloader.verifyIntegrity(
                cacheDir: base, entry: entry, modelId: "test-model"
            )
        }
    }

    // MARK: - Tampered file triggers error

    @Test("verifyIntegrity throws integrityVerificationFailed for tampered file")
    func tamperedFileThrows() async throws {
        let content = Data("this is tampered model data".utf8)
        let cacheDir = try createFakeCacheDir(weightContent: content)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let entry = ModelIntegrityHashes.Entry(
            revision: "abc123",
            files: [
                "kokoro_5s.mlmodelc/weights/weight.bin": bogusHash,
            ]
        )

        await #expect(throws: KokoroError.self) {
            try await KokoroDownloader.verifyIntegrity(
                cacheDir: cacheDir, entry: entry, modelId: "test-kokoro"
            )
        }
    }

    @Test("verifyIntegrity deletes cache directory on mismatch")
    func tamperedFileDeletesCache() async throws {
        let content = Data("corrupt model weights".utf8)
        let cacheDir = try createFakeCacheDir(weightContent: content)

        let entry = ModelIntegrityHashes.Entry(
            revision: "abc123",
            files: [
                "kokoro_5s.mlmodelc/weights/weight.bin": bogusHash,
            ]
        )

        #expect(FileManager.default.fileExists(atPath: cacheDir.path))

        do {
            try await KokoroDownloader.verifyIntegrity(
                cacheDir: cacheDir, entry: entry, modelId: "test-kokoro"
            )
            Issue.record("Expected integrityVerificationFailed to be thrown")
        } catch is KokoroError {
            #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
        }
    }

    // MARK: - Fail-closed: unrecognized model ID

    @Test("downloadWeights throws for unrecognized model ID")
    func unrecognizedModelIdThrows() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        await #expect(throws: KokoroError.self) {
            try await KokoroDownloader.downloadWeights(
                modelId: "unknown/nonexistent-model",
                to: tmpDir
            )
        }
    }

    // MARK: - Error type verification

    @Test("KokoroError.integrityVerificationFailed has correct errorDescription")
    func errorDescription() {
        let error = KokoroError.integrityVerificationFailed(modelId: "aufklarer/Kokoro-82M-CoreML")
        let description = error.errorDescription ?? ""
        #expect(description.contains("integrity verification"))
        #expect(description.contains("aufklarer/Kokoro-82M-CoreML"))
        #expect(description.contains("re-download"))
    }
}
