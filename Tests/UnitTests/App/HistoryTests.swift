import Foundation
import Testing
@testable import FastLang

@Suite("Session")
struct SessionTests {

    @Test("init generates a UUID string ID")
    func initGeneratesId() {
        let session = Session(
            originalPrompt: "test",
            originalResponse: "response",
            finalResponse: "response",
            accepted: true,
            appName: "Slack",
            appKey: "slack"
        )
        #expect(!session.id.isEmpty)
        #expect(UUID(uuidString: session.id) != nil)
    }

    @Test("init sets timestamp as Unix seconds string")
    func initTimestamp() {
        let session = Session(
            originalPrompt: "test",
            originalResponse: "response",
            finalResponse: "response",
            accepted: true,
            appName: "Slack",
            appKey: "slack"
        )
        let ts = Int(session.timestamp)
        #expect(ts != nil)
        let now = Int(Date().timeIntervalSince1970)
        #expect(abs((ts ?? 0) - now) < 5)
    }
}

@Suite("History")
struct HistoryTests {

    private func makeSession(appKey: String = "test", accepted: Bool = true) -> Session {
        Session(
            originalPrompt: "prompt",
            originalResponse: "response",
            finalResponse: "response",
            accepted: accepted,
            appName: appKey.capitalized,
            appKey: appKey
        )
    }

    @Test("starts with empty sessions")
    func empty() {
        let history = History()
        #expect(history.sessions.isEmpty)
    }

    @Test("addSession appends to the list")
    func addSession() {
        var history = History()
        history.addSession(makeSession())
        #expect(history.sessions.count == 1)
    }

    @Test("prunes oldest when exceeding 200 sessions")
    func prunesAtCap() {
        var history = History()
        for i in 0 ..< 205 {
            history.addSession(makeSession(appKey: "app-\(i)"))
        }
        #expect(history.sessions.count == 200)
        #expect(history.sessions.first?.appKey == "app-5")
        #expect(history.sessions.last?.appKey == "app-204")
    }

    @Test("sessionsForApp filters by app key")
    func sessionsForApp() {
        var history = History()
        history.addSession(makeSession(appKey: "slack"))
        history.addSession(makeSession(appKey: "vscode"))
        history.addSession(makeSession(appKey: "slack"))

        let slackSessions = history.sessionsForApp("slack")
        #expect(slackSessions.count == 2)
        #expect(slackSessions.allSatisfy { $0.appKey == "slack" })
    }

    @Test("sessionsForApp returns most recent first")
    func sessionsForAppOrder() {
        var history = History()
        let s1 = makeSession(appKey: "slack")
        let s2 = makeSession(appKey: "slack")
        history.addSession(s1)
        history.addSession(s2)

        let results = history.sessionsForApp("slack")
        #expect(results.first?.id == s2.id)
        #expect(results.last?.id == s1.id)
    }

    @Test("sessionsForApp returns empty for unknown app")
    func sessionsForAppUnknown() {
        let history = History()
        #expect(history.sessionsForApp("unknown").isEmpty)
    }

    // MARK: - JSON Roundtrip

    @Test("encode-decode roundtrip preserves sessions")
    func jsonRoundtrip() throws {
        var history = History()
        history.addSession(makeSession(appKey: "slack"))
        history.addSession(makeSession(appKey: "vscode"))

        let data = try sharedJSONEncoder.encode(history)
        let decoded = try sharedJSONDecoder.decode(History.self, from: data)
        #expect(decoded.sessions.count == 2)
        #expect(decoded.sessions[0].appKey == "slack")
    }

    @Test("snake_case keys in JSON output")
    func snakeCaseKeys() throws {
        var history = History()
        history.addSession(makeSession())
        let data = try sharedJSONEncoder.encode(history)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"original_prompt\""))
        #expect(json.contains("\"original_response\""))
        #expect(json.contains("\"final_response\""))
        #expect(json.contains("\"app_name\""))
        #expect(json.contains("\"app_key\""))
    }

    // MARK: - Persistence

    @Test("save then load roundtrips")
    func saveLoadRoundtrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("sessions.json")
        var history = History()
        history.addSession(makeSession(appKey: "slack"))
        try history.save(to: path)

        let loaded = History.load(from: path)
        #expect(loaded.sessions.count == 1)
        #expect(loaded.sessions[0].appKey == "slack")
    }

    @Test("load returns empty history for missing file")
    func loadMissing() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.json")
        let loaded = History.load(from: path)
        #expect(loaded.sessions.isEmpty)
    }
}
