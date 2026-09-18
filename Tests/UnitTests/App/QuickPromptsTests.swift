import Foundation
import Testing
@testable import FastLang

@Suite("QuickPrompt")
struct QuickPromptTests {

    @Test("init generates a UUID string ID")
    func initGeneratesId() {
        let prompt = QuickPrompt(name: "Test", prompt: "Do something")
        #expect(!prompt.id.isEmpty)
        #expect(UUID(uuidString: prompt.id) != nil)
    }

    @Test("two prompts have distinct IDs")
    func uniqueIds() {
        let promptA = QuickPrompt(name: "A", prompt: "a")
        let promptB = QuickPrompt(name: "B", prompt: "b")
        #expect(promptA.id != promptB.id)
    }
}

@Suite("QuickPrompts")
struct QuickPromptsCollectionTests {

    // MARK: - Defaults

    @Test("defaults contain 3 prompts")
    func defaultCount() {
        let qp = QuickPrompts.defaults
        #expect(qp.prompts.count == 3)
    }

    @Test("default prompt names match spec")
    func defaultNames() {
        let names = QuickPrompts.defaults.prompts.map(\.name)
        #expect(names.contains("Make professional"))
        #expect(names.contains("Make coherent"))
        #expect(names.contains("Make concise"))
    }

    // MARK: - CRUD

    @Test("add appends to the list")
    func add() {
        var qp = QuickPrompts(prompts: [])
        let prompt = QuickPrompt(name: "New", prompt: "new thing")
        qp.add(prompt)
        #expect(qp.prompts.count == 1)
        #expect(qp.prompts[0].name == "New")
    }

    @Test("remove by ID returns the removed prompt")
    func removeById() {
        var qp = QuickPrompts.defaults
        let id = qp.prompts[0].id
        let removed = qp.remove(id: id)
        #expect(removed != nil)
        #expect(removed?.id == id)
        #expect(qp.prompts.count == 2)
    }

    @Test("remove with unknown ID returns nil")
    func removeUnknown() {
        var qp = QuickPrompts.defaults
        let removed = qp.remove(id: "nonexistent")
        #expect(removed == nil)
        #expect(qp.prompts.count == 3)
    }

    @Test("get by ID returns the correct prompt")
    func getById() {
        let qp = QuickPrompts.defaults
        let first = qp.prompts[0]
        let found = qp.get(id: first.id)
        #expect(found?.name == first.name)
    }

    @Test("get with unknown ID returns nil")
    func getUnknown() {
        let qp = QuickPrompts.defaults
        #expect(qp.get(id: "nonexistent") == nil)
    }

    @Test("update changes name and prompt text")
    func update() {
        var qp = QuickPrompts.defaults
        let id = qp.prompts[0].id
        let success = qp.update(id: id, name: "Updated", prompt: "new text")
        #expect(success)
        #expect(qp.prompts[0].name == "Updated")
        #expect(qp.prompts[0].prompt == "new text")
    }

    @Test("update with unknown ID returns false")
    func updateUnknown() {
        var qp = QuickPrompts.defaults
        let success = qp.update(id: "nonexistent", name: "X", prompt: "Y")
        #expect(!success)
    }

    // MARK: - JSON Roundtrip

    @Test("encode-decode roundtrip preserves prompts")
    func jsonRoundtrip() throws {
        let original = QuickPrompts.defaults
        let data = try sharedJSONEncoder.encode(original)
        let decoded = try sharedJSONDecoder.decode(QuickPrompts.self, from: data)
        #expect(decoded.prompts.count == original.prompts.count)
        for (decoded, original) in zip(decoded.prompts, original.prompts) {
            #expect(decoded.id == original.id)
            #expect(decoded.name == original.name)
            #expect(decoded.prompt == original.prompt)
        }
    }

    // MARK: - Persistence

    @Test("save then load roundtrips")
    func saveLoadRoundtrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("quick_prompts.json")
        var qp = QuickPrompts.defaults
        qp.add(QuickPrompt(name: "Extra", prompt: "extra"))
        try qp.save(to: path)

        let loaded = QuickPrompts.load(from: path)
        #expect(loaded.prompts.count == 4)
    }

    @Test("load returns defaults for missing file")
    func loadMissing() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.json")
        let loaded = QuickPrompts.load(from: path)
        #expect(loaded.prompts.count == 3)
    }
}
