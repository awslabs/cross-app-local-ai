import CryptoKit
import Foundation
import Testing
@testable import FastLang

@Suite("ModelIntegrityVerifier")
struct ModelIntegrityVerifierTests {

    private let verifier = ModelIntegrityVerifier()

    private func createTempFile(content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".test")
        try content.write(to: url)
        return url
    }

    private func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verification passes

    @Test("verify succeeds when file hash matches expected value")
    func verifyMatchingHash() async throws {
        let content = Data("hello model weights".utf8)
        let url = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let expectedHash = sha256Hex(of: content)

        try await verifier.verify(fileAt: url, expectedHash: expectedHash, modelId: "test-model")
    }

    // MARK: - Verification fails

    @Test("verify throws checksumMismatch when hash does not match")
    func verifyMismatch() async throws {
        let content = Data("legitimate model data".utf8)
        let url = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let wrongHash = sha256Hex(of: Data("tampered".utf8))

        await #expect(throws: ModelIntegrityError.self) {
            try await verifier.verify(fileAt: url, expectedHash: wrongHash, modelId: "bad-model")
        }
    }

    @Test("verify throws fileUnreadable for non-existent file")
    func verifyMissingFile() async {
        let bogusUrl = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-nonexistent.gguf")

        await #expect(throws: ModelIntegrityError.self) {
            try await verifier.verify(
                fileAt: bogusUrl,
                expectedHash: "aaaa",
                modelId: "ghost-model"
            )
        }
    }

    // MARK: - Caching behaviour

    @Test("hash is cached after first computation")
    func hashIsCached() async throws {
        let content = Data("cache test payload".utf8)
        let url = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        let hash1 = try await verifier.hash(fileAt: url)
        let hash2 = try await verifier.hash(fileAt: url)

        #expect(hash1 == hash2)
        #expect(hash1 == sha256Hex(of: content))
    }

    @Test("invalidateCache forces re-hash on next call")
    func invalidateCacheWorks() async throws {
        let content = Data("original".utf8)
        let url = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await verifier.hash(fileAt: url)
        await verifier.invalidateCache(for: url)

        // Write new content to the same URL
        let newContent = Data("modified".utf8)
        try newContent.write(to: url)

        let hashAfterInvalidate = try await verifier.hash(fileAt: url)
        #expect(hashAfterInvalidate == sha256Hex(of: newContent))
    }

    @Test("clearCache removes all cached entries")
    func clearCacheWorks() async throws {
        let content = Data("clear test".utf8)
        let url = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await verifier.hash(fileAt: url)
        await verifier.clearCache()

        // Replace file content
        let newContent = Data("replaced".utf8)
        try newContent.write(to: url)

        let hashAfterClear = try await verifier.hash(fileAt: url)
        #expect(hashAfterClear == sha256Hex(of: newContent))
    }

    // MARK: - Large file streaming

    @Test("hash correctly handles multi-chunk files")
    func multiChunkFile() async throws {
        // Create a 2 MB file to ensure multiple 1 MB chunks are read
        let chunkSize = 1_048_576
        var data = Data(count: chunkSize * 2)
        for i in 0 ..< data.count {
            data[i] = UInt8(i % 256)
        }

        let url = try createTempFile(content: data)
        defer { try? FileManager.default.removeItem(at: url) }

        let computed = try await verifier.hash(fileAt: url)
        let expected = sha256Hex(of: data)

        #expect(computed == expected)
    }

    // MARK: - Read error propagation

    @Test("verify throws fileUnreadable when file is a directory")
    func verifyDirectoryThrowsFileUnreadable() async {
        let dirUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirUrl) }

        await #expect(throws: ModelIntegrityError.self) {
            try await verifier.verify(
                fileAt: dirUrl,
                expectedHash: "abc123",
                modelId: "dir-model"
            )
        }
    }

    @Test("hash throws fileUnreadable not checksumMismatch on unreadable path")
    func hashUnreadablePathThrowsCorrectError() async {
        let dirUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dirUrl, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dirUrl) }

        do {
            _ = try await verifier.hash(fileAt: dirUrl)
            Issue.record("Expected fileUnreadable to be thrown")
        } catch let error as ModelIntegrityError {
            guard case .fileUnreadable = error else {
                Issue.record("Expected fileUnreadable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ModelIntegrityError, got \(error)")
        }
    }

    // MARK: - verifyAll

    @Test("verifyAll succeeds when all files match their expected hashes")
    func verifyAllPasses() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifyAll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let content1 = Data("file-one".utf8)
        let content2 = Data("file-two".utf8)

        let dir1 = folder.appendingPathComponent("a", isDirectory: true)
        let dir2 = folder.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        try content1.write(to: dir1.appendingPathComponent("w.bin"))
        try content2.write(to: dir2.appendingPathComponent("w.bin"))

        let entry = ModelIntegrityHashes.Entry(
            revision: nil,
            files: [
                "a/w.bin": sha256Hex(of: content1),
                "b/w.bin": sha256Hex(of: content2),
            ]
        )

        try await verifier.verifyAll(entry: entry, inFolder: folder, modelId: "test")
    }

    @Test("verifyAll throws fileMissing when a required file is absent")
    func verifyAllThrowsOnAbsentFiles() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifyAll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let entry = ModelIntegrityHashes.Entry(
            revision: nil,
            files: ["nonexistent/weight.bin": "deadbeef"]
        )

        do {
            try await verifier.verifyAll(entry: entry, inFolder: folder, modelId: "test")
            Issue.record("Expected fileMissing to be thrown")
        } catch let error as ModelIntegrityError {
            guard case let .fileMissing(modelId, subpath) = error else {
                Issue.record("Expected fileMissing, got \(error)")
                return
            }
            #expect(modelId == "test")
            #expect(subpath == "nonexistent/weight.bin")
        }
    }

    @Test("verifyAll throws on first mismatched file")
    func verifyAllThrowsOnMismatch() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifyAll-\(UUID().uuidString)")
        let dir = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("tampered".utf8).write(to: dir.appendingPathComponent("w.bin"))
        defer { try? FileManager.default.removeItem(at: folder) }

        let entry = ModelIntegrityHashes.Entry(
            revision: nil,
            files: [
                "sub/w.bin": "0000000000000000000000000000000000000000000000000000000000000000",
            ]
        )

        await #expect(throws: ModelIntegrityError.self) {
            try await verifier.verifyAll(entry: entry, inFolder: folder, modelId: "bad")
        }
    }

    @Test("verifyAll invalidates cache for the failed file")
    func verifyAllInvalidatesCacheOnFailure() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("verifyAll-\(UUID().uuidString)")
        let dir = folder.appendingPathComponent("x", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("w.bin")
        let content = Data("original content".utf8)
        try content.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Prime the cache with the correct hash
        _ = try await verifier.hash(fileAt: fileURL)

        // Now create an entry with a WRONG expected hash to trigger failure
        let entry = ModelIntegrityHashes.Entry(
            revision: nil,
            files: [
                "x/w.bin": "0000000000000000000000000000000000000000000000000000000000000000",
            ]
        )

        do {
            try await verifier.verifyAll(entry: entry, inFolder: folder, modelId: "test")
            Issue.record("Expected checksumMismatch")
        } catch is ModelIntegrityError {
            // After failure, replace file content and verify cache was invalidated
            let newContent = Data("replaced content".utf8)
            try newContent.write(to: fileURL)
            let newHash = try await verifier.hash(fileAt: fileURL)
            #expect(newHash == sha256Hex(of: newContent))
        }
    }
}
