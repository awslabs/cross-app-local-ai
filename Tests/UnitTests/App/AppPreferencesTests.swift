import Foundation
import Testing
@testable import FastLang

@Suite("AppPreferences")
struct AppPreferencesTests {

    // MARK: - getSummary

    @Test("getSummary returns empty for unknown app")
    func getSummaryUnknown() {
        let prefs = AppPreferences()
        #expect(prefs.getSummary("unknown").isEmpty)
    }

    @Test("getSummary returns learned text when inferred is enabled")
    func getSummaryEnabled() {
        var prefs = AppPreferences()
        prefs.setLearnedText("slack", learnedText: "Keep it casual", sessionsAnalyzed: 5)
        #expect(prefs.getSummary("slack") == "Keep it casual")
    }

    @Test("getSummary returns empty when inferred is disabled")
    func getSummaryDisabled() {
        var prefs = AppPreferences()
        prefs.setLearnedText("slack", learnedText: "Keep it casual", sessionsAnalyzed: 5)
        prefs.toggleInferred("slack")
        #expect(prefs.getSummary("slack").isEmpty)
    }

    // MARK: - isInferredEnabled

    @Test("isInferredEnabled defaults to true for unknown app")
    func inferredEnabledDefault() {
        let prefs = AppPreferences()
        #expect(prefs.isInferredEnabled("unknown"))
    }

    @Test("toggleInferred flips the value")
    func toggleInferred() {
        var prefs = AppPreferences()
        prefs.toggleInferred("slack")
        #expect(!prefs.isInferredEnabled("slack"))
        prefs.toggleInferred("slack")
        #expect(prefs.isInferredEnabled("slack"))
    }

    // MARK: - User Rules

    @Test("userRulesText returns empty for no rules")
    func userRulesEmpty() {
        let prefs = AppPreferences()
        #expect(prefs.userRulesText("slack").isEmpty)
    }

    @Test("userRulesText formats as numbered list")
    func userRulesFormatted() {
        var prefs = AppPreferences()
        prefs.addUserRule("slack", rule: "Be brief")
        prefs.addUserRule("slack", rule: "Use emojis")
        #expect(prefs.userRulesText("slack") == "1. Be brief\n2. Use emojis")
    }

    @Test("removeUserRule removes at index")
    func removeUserRule() {
        var prefs = AppPreferences()
        prefs.addUserRule("slack", rule: "Rule A")
        prefs.addUserRule("slack", rule: "Rule B")
        let removed = prefs.removeUserRule("slack", at: 0)
        #expect(removed)
        #expect(prefs.userRulesText("slack") == "1. Rule B")
    }

    @Test("removeUserRule returns false for bad index")
    func removeUserRuleBadIndex() {
        var prefs = AppPreferences()
        prefs.addUserRule("slack", rule: "Rule A")
        let result = prefs.removeUserRule("slack", at: 5)
        #expect(!result)
    }

    @Test("removeUserRule returns false for unknown app")
    func removeUserRuleUnknownApp() {
        var prefs = AppPreferences()
        let result = prefs.removeUserRule("unknown", at: 0)
        #expect(!result)
    }

    // MARK: - Learned Text

    @Test("setLearnedText stores text and bumps timestamp")
    func setLearnedTextStores() {
        var prefs = AppPreferences()
        prefs.setLearnedText("slack", learnedText: "casual tone, short", sessionsAnalyzed: 4)

        let pref = prefs.apps["slack"]
        #expect(pref?.learnedText == "casual tone, short")
        #expect(pref?.sessionsAnalyzed == 4)
        #expect((pref?.lastGenerated ?? 0) > 0)
    }

    @Test("clearLearnedText zeros text and timestamp but keeps rules")
    func clearLearnedText() {
        var prefs = AppPreferences()
        prefs.setLearnedText("slack", learnedText: "something", sessionsAnalyzed: 5)
        prefs.addUserRule("slack", rule: "Be brief")

        prefs.clearLearnedText("slack")

        let pref = prefs.apps["slack"]
        #expect(pref?.learnedText.isEmpty == true)
        #expect(pref?.lastGenerated == 0)
        #expect(pref?.sessionsAnalyzed == 0)
        // User rules preserved.
        #expect(pref?.userRules == ["Be brief"])
    }

    // MARK: - Staleness

    @Test("isStale returns true for unknown app")
    func staleUnknown() {
        let prefs = AppPreferences()
        #expect(prefs.isStale("unknown"))
    }

    @Test("isStale returns true when lastGenerated is zero")
    func staleZeroTimestamp() {
        var prefs = AppPreferences()
        prefs.apps["slack"] = AppPreference()
        #expect(prefs.isStale("slack"))
    }

    @Test("isStale returns false for recently generated")
    func staleRecent() {
        var prefs = AppPreferences()
        prefs.setLearnedText("slack", learnedText: "test", sessionsAnalyzed: 1)
        #expect(!prefs.isStale("slack"))
    }

    @Test("staleAppKeys includes recently-used apps without preferences")
    func staleAppKeys() {
        let prefs = AppPreferences()
        var history = History()

        let now = UInt64(Date().timeIntervalSince1970)
        let recent = String(now - 60)

        // Three recent sessions across three apps — none have prefs,
        // so all should be considered stale.
        var s1 = Session(
            originalPrompt: "p",
            originalResponse: "r",
            finalResponse: "r",
            accepted: true,
            appName: "Slack",
            appKey: "slack"
        )
        s1.timestamp = recent
        history.addSession(s1)

        var s2 = Session(
            originalPrompt: "p",
            originalResponse: "r",
            finalResponse: "r",
            accepted: false,
            appName: "VSCode",
            appKey: "vscode"
        )
        s2.timestamp = recent
        history.addSession(s2)

        var s3 = Session(
            originalPrompt: "p",
            originalResponse: "r",
            finalResponse: "r",
            accepted: true,
            appName: "Mail",
            appKey: "mail"
        )
        s3.timestamp = recent
        history.addSession(s3)

        let stale = prefs.staleAppKeys(from: history)
        #expect(stale.contains("slack"))
        #expect(stale.contains("vscode"))
        #expect(stale.contains("mail"))
    }

    // MARK: - allKeysWithHistory

    @Test("allKeysWithHistory merges preference keys and history keys")
    func allKeysMerge() {
        var prefs = AppPreferences()
        prefs.apps["slack"] = AppPreference()

        var history = History()
        history.addSession(Session(
            originalPrompt: "p",
            originalResponse: "r",
            finalResponse: "r",
            accepted: true,
            appName: "VSCode",
            appKey: "vscode"
        ))

        let keys = prefs.allKeysWithHistory(from: history)
        #expect(keys.contains("slack"))
        #expect(keys.contains("vscode"))
    }

    @Test("allKeysWithHistory sorts by most recent session")
    func allKeysSortOrder() {
        let prefs = AppPreferences()
        var history = History()

        // Add slack first (older timestamp)
        var s1 = Session(
            originalPrompt: "p",
            originalResponse: "r",
            finalResponse: "r",
            accepted: true,
            appName: "Slack",
            appKey: "slack"
        )
        s1.timestamp = "1000"
        history.addSession(s1)

        // Add vscode second (newer timestamp)
        var s2 = Session(
            originalPrompt: "p",
            originalResponse: "r",
            finalResponse: "r",
            accepted: true,
            appName: "VSCode",
            appKey: "vscode"
        )
        s2.timestamp = "2000"
        history.addSession(s2)

        let keys = prefs.allKeysWithHistory(from: history)
        #expect(keys.first == "vscode")
    }

    // MARK: - JSON Roundtrip

    @Test("encode-decode roundtrip preserves preferences")
    func jsonRoundtrip() throws {
        var prefs = AppPreferences()
        prefs.setLearnedText("slack", learnedText: "casual", sessionsAnalyzed: 3)
        prefs.addUserRule("slack", rule: "Be brief")

        let data = try sharedJSONEncoder.encode(prefs)
        let decoded = try sharedJSONDecoder.decode(AppPreferences.self, from: data)
        #expect(decoded.getSummary("slack") == "casual")
        #expect(decoded.apps["slack"]?.userRules == ["Be brief"])
    }

    @Test("decode migrates legacy insights into learnedText")
    func legacyInsightMigration() throws {
        // Simulate an on-disk file from the pre-prose era.
        let legacyJSON = """
        {
          "apps": {
            "slack": {
              "summary": "",
              "insights": [
                {"id": "a", "text": "Prefers casual tone", "enabled": true},
                {"id": "b", "text": "Keeps messages short", "enabled": true}
              ],
              "userRules": ["Be brief"],
              "inferredEnabled": true,
              "lastGenerated": 1700000000,
              "sessionsAnalyzed": 5
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.getSummary("slack") == "Prefers casual tone Keeps messages short")
        #expect(decoded.apps["slack"]?.userRules == ["Be brief"])
    }

    @Test("decode migrates legacy summary when no insights present")
    func legacySummaryMigration() throws {
        let legacyJSON = """
        {
          "apps": {
            "slack": {
              "summary": "Keep it casual and short",
              "insights": [],
              "userRules": [],
              "inferredEnabled": true,
              "lastGenerated": 1700000000,
              "sessionsAnalyzed": 3
            }
          }
        }
        """
        let decoded = try JSONDecoder().decode(
            AppPreferences.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.getSummary("slack") == "Keep it casual and short")
    }

    // MARK: - Persistence

    @Test("save then load roundtrips")
    func saveLoadRoundtrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("app_rules.json")
        var prefs = AppPreferences()
        prefs.setLearnedText("slack", learnedText: "test", sessionsAnalyzed: 1)
        try prefs.save(to: path)

        let loaded = AppPreferences.load(from: path)
        #expect(loaded.getSummary("slack") == "test")
    }
}
