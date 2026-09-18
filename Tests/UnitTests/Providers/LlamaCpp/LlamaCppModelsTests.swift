import Foundation
import Testing
@testable import FastLang

@Suite("LlamaCppModels")
struct LlamaCppModelsTests {

    // MARK: - Registry

    @Test("model registry has entries")
    func registryNotEmpty() {
        #expect(!LlamaCppModels.modelRegistry.isEmpty)
    }

    @Test("all model IDs are unique")
    func modelIdsAreUnique() {
        let ids = LlamaCppModels.modelRegistry.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test("all filenames end with .gguf")
    func filenamesAreGguf() {
        for entry in LlamaCppModels.modelRegistry {
            #expect(entry.filename.hasSuffix(".gguf"), "Model \(entry.id) filename should end with .gguf")
        }
    }

    @Test("all download URLs are HTTPS")
    func downloadUrlsAreHttps() {
        for entry in LlamaCppModels.modelRegistry {
            #expect(entry.downloadUrl.scheme == "https", "Model \(entry.id) should use HTTPS")
        }
    }

    @Test("all entries have positive size and memory")
    func entriesHavePositiveMetrics() {
        for entry in LlamaCppModels.modelRegistry {
            #expect(entry.sizeBytes > 0, "Model \(entry.id) sizeBytes should be positive")
            #expect(entry.memoryMB > 0, "Model \(entry.id) memoryMB should be positive")
        }
    }

    // MARK: - Lookup

    @Test("findModel returns entry for known ID")
    func findModelReturnsKnownEntry() {
        let entry = LlamaCppModels.findModel("gemma-4-e2b")
        #expect(entry != nil)
        #expect(entry?.displayName == "Gemma 4 E2B IT Q4")
    }

    @Test("findModel returns nil for unknown ID")
    func findModelReturnsNilForUnknown() {
        let entry = LlamaCppModels.findModel("nonexistent-model")
        #expect(entry == nil)
    }

    @Test("staticModels returns correct count")
    func staticModelsCount() {
        let models = LlamaCppModels.staticModels()
        #expect(models.count == LlamaCppModels.modelRegistry.count)
    }

    @Test("staticModels entries have non-empty id and displayName")
    func staticModelsHaveContent() {
        for model in LlamaCppModels.staticModels() {
            #expect(!model.id.isEmpty)
            #expect(!model.displayName.isEmpty)
        }
    }

    // MARK: - GGUF Validation

    @Test("validateGgufFile throws for missing file")
    func validateGgufMissingFile() {
        let path = URL(fileURLWithPath: "/tmp/nonexistent_model_\(UUID().uuidString).gguf")
        #expect(throws: LlmError.self) {
            try LlamaCppModels.validateGgufFile(at: path)
        }
    }

    @Test("validateGgufFile throws for too-small file")
    func validateGgufTooSmall() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_tiny_\(UUID().uuidString).gguf")
        try Data([0x47, 0x47]).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(throws: LlmError.self) {
            try LlamaCppModels.validateGgufFile(at: path)
        }
    }

    @Test("validateGgufFile throws for wrong magic bytes")
    func validateGgufBadMagic() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_badmagic_\(UUID().uuidString).gguf")
        try Data("FAKE".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(throws: LlmError.self) {
            try LlamaCppModels.validateGgufFile(at: path)
        }
    }

    @Test("validateGgufFile succeeds for valid GGUF header")
    func validateGgufValidHeader() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_valid_\(UUID().uuidString).gguf")
        var data = Data("GGUF".utf8)
        data.append(Data(repeating: 0, count: 100))
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        #expect(throws: Never.self) {
            try LlamaCppModels.validateGgufFile(at: path)
        }
    }

    // MARK: - Path Resolution

    @Test("resolveModelPath throws for unknown model ID")
    func resolveUnknownModel() async {
        let dirs = AppDirs.withRoot(
            FileManager.default.temporaryDirectory.appendingPathComponent("qg_test_\(UUID().uuidString)")
        )

        await #expect(throws: LlmError.self) {
            try await LlamaCppModels.resolveModelPath(
                dirs: dirs,
                modelId: "nonexistent-model",
                customPath: nil
            )
        }
    }

    @Test("resolveModelPath throws for missing custom path")
    func resolveMissingCustomPath() async {
        let dirs = AppDirs.withRoot(
            FileManager.default.temporaryDirectory.appendingPathComponent("qg_test_\(UUID().uuidString)")
        )

        await #expect(throws: LlmError.self) {
            try await LlamaCppModels.resolveModelPath(
                dirs: dirs,
                modelId: "gemma-4-e2b",
                customPath: "/nonexistent/path/model.gguf"
            )
        }
    }

    @Test("resolveModelPath returns custom path when file exists")
    func resolveCustomPathExists() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_custom_\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let dirs = AppDirs.withRoot(
            FileManager.default.temporaryDirectory.appendingPathComponent("qg_test_\(UUID().uuidString)")
        )

        let resolved = try await LlamaCppModels.resolveModelPath(
            dirs: dirs,
            modelId: "gemma-4-e2b",
            customPath: path.path
        )
        #expect(resolved == path)
    }

    @Test("locateModel returns nil when not cached")
    func locateModelNotCached() {
        let dirs = AppDirs.withRoot(
            FileManager.default.temporaryDirectory.appendingPathComponent("qg_test_\(UUID().uuidString)")
        )

        let result = LlamaCppModels.locateModel(dirs: dirs, modelId: "gemma-4-e2b")
        #expect(result == nil)
    }

    @Test("locateModel returns nil for unknown model")
    func locateModelUnknown() {
        let dirs = AppDirs.withRoot(FileManager.default.temporaryDirectory)

        let result = LlamaCppModels.locateModel(dirs: dirs, modelId: "nonexistent")
        #expect(result == nil)
    }
}
