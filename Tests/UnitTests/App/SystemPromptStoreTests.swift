import Foundation
import Testing
@testable import FastLang

@Suite("SystemPromptStore")
struct SystemPromptStoreTests {

    private func makeContext(
        explainMode: Bool = false,
        mode: PromptMode = .replace,
        contextType: ContextType = .generic,
        appKey: String = "unknown",
        appName: String = "Unknown",
        userRules: String = "",
        inferredPreferences: String = "",
        refinementFeedback: [String] = []
    ) -> PromptRenderContext {
        PromptRenderContext(
            explainMode: explainMode,
            mode: mode,
            contextType: contextType,
            appKey: appKey,
            appName: appName,
            userRules: userRules,
            inferredPreferences: inferredPreferences,
            refinementFeedback: refinementFeedback
        )
    }

    // MARK: - Template Resolution

    @Test("resolves to explain template when explainMode is true")
    func resolveExplain() {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(explainMode: true, appKey: "slack")
        #expect(store.resolveTemplateName(context: context) == "explain")
    }

    @Test("resolves to app-specific template when available")
    func resolveAppKey() {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(contextType: .chat, appKey: "slack")
        #expect(store.resolveTemplateName(context: context) == "slack")
    }

    @Test("falls back to context type template when app key not found")
    func resolveContextType() {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(contextType: .email, appKey: "someunknownapp")
        #expect(store.resolveTemplateName(context: context) == "email")
    }

    @Test("falls back to generic when nothing matches")
    func resolveGeneric() {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(contextType: .generic, appKey: "someunknownapp")
        #expect(store.resolveTemplateName(context: context) == "generic")
    }

    @Test("explain takes priority over app key")
    func explainPriority() {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(explainMode: true, appKey: "slack")
        #expect(store.resolveTemplateName(context: context) == "explain")
    }

    // MARK: - Rendering

    @Test("renders generic template without errors")
    func renderGeneric() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext()
        let result = try store.render(context: context)
        #expect(!result.isEmpty)
        #expect(result.contains("helpful writing assistant"))
    }

    @Test("renders with user rules injected")
    func renderWithUserRules() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(userRules: "1. Be brief\n2. Use emoji")
        let result = try store.render(context: context)
        #expect(result.contains("1. Be brief"))
        #expect(result.contains("2. Use emoji"))
    }

    @Test("renders with inferred preferences injected")
    func renderWithPreferences() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(inferredPreferences: "User prefers short responses")
        let result = try store.render(context: context)
        #expect(result.contains("User prefers short responses"))
    }

    @Test("renders with refinement feedback injected")
    func renderWithRefinements() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(refinementFeedback: ["Make it shorter", "Remove jargon"])
        let result = try store.render(context: context)
        #expect(result.contains("Make it shorter"))
        #expect(result.contains("Remove jargon"))
    }

    @Test("non-explain templates include paste-ready instruction")
    func pasteReadyIncluded() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(explainMode: false)
        let result = try store.render(context: context)
        #expect(result.contains("CRITICAL"))
        #expect(result.contains("pasted directly"))
    }

    @Test("explain template does NOT include paste-ready instruction")
    func explainNoPasteReady() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(explainMode: true)
        let result = try store.render(context: context)
        #expect(!result.contains("pasted directly"))
    }

    @Test("replace mode produces 'Rewrite' instruction")
    func replaceMode() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(mode: .replace)
        let result = try store.render(context: context)
        #expect(result.contains("Rewrite or transform"))
    }

    @Test("insert mode produces 'Generate new' instruction")
    func insertMode() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(mode: .insert)
        let result = try store.render(context: context)
        #expect(result.contains("Generate new content"))
    }

    // MARK: - Default Templates

    @Test("16 default templates exist")
    func defaultTemplateCount() {
        #expect(SystemPromptStore.defaultTemplates.count == 16)
    }

    @Test("all expected template names are present")
    func defaultTemplateNames() {
        let expected = [
            "generic", "email", "chat", "document", "spreadsheet",
            "code", "notes", "slack", "outlook", "gmail",
            "quip", "browser", "chrome", "word", "teams", "explain",
        ]
        for name in expected {
            #expect(
                SystemPromptStore.defaultTemplates[name] != nil,
                "Missing default template: \(name)"
            )
        }
    }

    @Test("all default templates are non-empty")
    func defaultTemplatesNonEmpty() {
        for (name, content) in SystemPromptStore.defaultTemplates {
            #expect(!content.isEmpty, "Empty template: \(name)")
        }
    }

    // MARK: - Disk Seeding

    @Test("init seeds templates to disk and loads them back")
    func diskSeedAndLoad() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dirs = AppDirs.withRoot(tmpDir)
        try dirs.ensureDirs()

        let store = try SystemPromptStore(dirs: dirs)
        #expect(store.templateNames.count == 16)
        #expect(store.templateNames.contains("generic"))
        #expect(store.templateNames.contains("slack"))
    }

    @Test("preserves user edits on subsequent loads")
    func preservesUserEdits() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dirs = AppDirs.withRoot(tmpDir)
        try dirs.ensureDirs()

        // First load seeds defaults
        _ = try SystemPromptStore(dirs: dirs)

        // User edits the generic template
        let genericPath = dirs.systemPromptsDir.appendingPathComponent("generic.md.jinja")
        try "Custom template content".write(to: genericPath, atomically: true, encoding: .utf8)

        // Second load should preserve the edit
        let store2 = try SystemPromptStore(dirs: dirs)
        let context = makeContext()
        let result = try store2.render(context: context)
        #expect(result.contains("Custom template content"))
    }

    @Test("missing template falls back to generic")
    func missingTemplateFallback() throws {
        let store = SystemPromptStore(templates: [
            "generic": "Fallback: {{ mode_instruction }}",
        ])
        let context = makeContext(contextType: .chat, appKey: "nonexistent")
        let result = try store.render(context: context)
        #expect(result.contains("Fallback:"))
    }

    // MARK: - Template Versioning

    @Test("templateVersion is positive")
    func templateVersionPositive() {
        #expect(SystemPromptStore.templateVersion > 0)
    }

    @Test("re-seeds templates when version file is outdated")
    func reSeedsOnVersionBump() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dirs = AppDirs.withRoot(tmpDir)
        try dirs.ensureDirs()

        // First load seeds at current version
        _ = try SystemPromptStore(dirs: dirs)

        // Simulate a stale version by overwriting the version file
        let versionPath = dirs.systemPromptsDir.appendingPathComponent(".template_version")
        try "0".write(to: versionPath, atomically: true, encoding: .utf8)

        // Corrupt a template to verify re-seeding overwrites it
        let genericPath = dirs.systemPromptsDir.appendingPathComponent("generic.md.jinja")
        try "STALE".write(to: genericPath, atomically: true, encoding: .utf8)

        // Second load sees version 0 < current -> re-seeds
        let store = try SystemPromptStore(dirs: dirs)
        let context = makeContext()
        let result = try store.render(context: context)
        #expect(result.contains("helpful writing assistant"))
        #expect(!result.contains("STALE"))
    }

    @Test("paste-ready instruction appears after user rules in rendered output")
    func pasteReadyAfterUserRules() throws {
        let store = SystemPromptStore(templates: SystemPromptStore.defaultTemplates)
        let context = makeContext(userRules: "CUSTOM_RULE_MARKER")
        let result = try store.render(context: context)
        let criticalRange = result.range(of: "CRITICAL")
        let rulesRange = result.range(of: "CUSTOM_RULE_MARKER")
        #expect(criticalRange != nil)
        #expect(rulesRange != nil)
        if let criticalStart = criticalRange, let rulesStart = rulesRange {
            #expect(rulesStart.lowerBound < criticalStart.lowerBound)
        }
    }
}
