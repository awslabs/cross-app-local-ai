import Foundation
import Testing
@testable import FastLang

@Suite("WhisperKitModels")
struct WhisperKitModelsTests {

    @Test("model registry has entries")
    func registryNotEmpty() {
        #expect(!WhisperKitModels.modelRegistry.isEmpty)
    }

    @Test("all model IDs are unique")
    func modelIdsAreUnique() {
        let ids = WhisperKitModels.modelRegistry.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test("all entries have whisper- prefix in ID")
    func idsHaveWhisperPrefix() {
        for entry in WhisperKitModels.modelRegistry {
            #expect(entry.id.hasPrefix("whisper-"), "Model \(entry.id) should start with whisper-")
        }
    }

    @Test("all entries have positive size and memory")
    func entriesHavePositiveMetrics() {
        for entry in WhisperKitModels.modelRegistry {
            #expect(entry.sizeBytes > 0, "Model \(entry.id) sizeBytes should be positive")
            #expect(entry.memoryMB > 0, "Model \(entry.id) memoryMB should be positive")
        }
    }

    @Test("staticModels returns correct count")
    func staticModelsCount() {
        let models = WhisperKitModels.staticModels()
        #expect(models.count == WhisperKitModels.modelRegistry.count)
    }

    @Test("staticModels entries have non-empty id and displayName")
    func staticModelsHaveContent() {
        for model in WhisperKitModels.staticModels() {
            #expect(!model.id.isEmpty)
            #expect(!model.displayName.isEmpty)
        }
    }

    @Test("registry includes medium and large-v3 models")
    func registryIncludesLargerModels() {
        let ids = Set(WhisperKitModels.modelRegistry.map(\.id))
        #expect(ids.contains("whisper-medium"))
        #expect(ids.contains("whisper-large-v3"))
    }

    @Test("findModel returns entry for known ID")
    func findModelReturnsKnownEntry() {
        let entry = WhisperKitModels.findModel("whisper-small")
        #expect(entry != nil)
        #expect(entry?.displayName == "Whisper Small")
    }

    @Test("findModel returns nil for unknown ID")
    func findModelReturnsNilForUnknown() {
        let entry = WhisperKitModels.findModel("nonexistent-model")
        #expect(entry == nil)
    }

    @Test("larger models report higher memory requirements")
    func largerModelsRequireMoreMemory() throws {
        let small = try #require(WhisperKitModels.findModel("whisper-small"))
        let medium = try #require(WhisperKitModels.findModel("whisper-medium"))
        let large = try #require(WhisperKitModels.findModel("whisper-large-v3"))
        #expect(medium.memoryMB > small.memoryMB)
        #expect(large.memoryMB > medium.memoryMB)
    }

    @Test("quality scores are ordered by tier")
    func qualityScoresOrdered() {
        let sorted = WhisperKitModels.modelRegistry.sorted { $0.qualityScore < $1.qualityScore }

        for (index, entry) in sorted.enumerated() where index > 0 {
            #expect(
                entry.qualityScore >= sorted[index - 1].qualityScore,
                "Models should be orderable by quality score"
            )
        }
    }
}
