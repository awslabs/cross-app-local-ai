import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "history")

/// Maximum number of sessions retained in history.
private let maxSessions = 200

/// A single refinement iteration within a generation session.
struct Refinement: Codable, Equatable {
    var feedback: String
    var response: String
    var timestamp: String
}

/// A complete generation session, from prompt through response (and optional refinements).
struct Session: Codable, Identifiable, Equatable {
    let id: String
    var originalPrompt: String
    var originalResponse: String
    var finalResponse: String
    var accepted: Bool
    var refinements: [Refinement]
    var appName: String
    var appKey = ""
    var timestamp: String

    /// Creates a new session with a generated ID and current timestamp.
    init(
        originalPrompt: String,
        originalResponse: String,
        finalResponse: String,
        accepted: Bool,
        refinements: [Refinement] = [],
        appName: String,
        appKey: String
    ) {
        self.id = UUID().uuidString
        self.originalPrompt = originalPrompt
        self.originalResponse = originalResponse
        self.finalResponse = finalResponse
        self.accepted = accepted
        self.refinements = refinements
        self.appName = appName
        self.appKey = appKey
        self.timestamp = String(Int(Date().timeIntervalSince1970))
    }
}

/// The full collection of past generation sessions persisted to `sessions.json`.
struct History: Codable, Equatable {
    var sessions: [Session] = []

    /// Adds a session and prunes the oldest if the cap is exceeded.
    mutating func addSession(_ session: Session) {
        sessions.append(session)
        if sessions.count > maxSessions {
            let excess = sessions.count - maxSessions
            sessions.removeFirst(excess)
            let remaining = sessions.count
            logger.info("Pruned \(excess) old session(s), \(remaining) remaining")
        }
    }

    /// Returns sessions matching the given app key, most recent first.
    func sessionsForApp(_ appKey: String) -> [Session] {
        sessions.filter { $0.appKey == appKey }.reversed()
    }

    /// Removes all sessions for a given app key.
    mutating func removeSessionsForApp(_ appKey: String) {
        sessions.removeAll { $0.appKey == appKey }
    }

    // MARK: - Persistence

    /// Loads history from disk. Returns empty history if the file is missing or corrupt.
    static func load(from path: URL) -> History {
        guard let data = try? Data(contentsOf: path) else {
            logger.info("No sessions file, starting with empty history")
            return History()
        }
        do {
            return try sharedJSONDecoder.decode(History.self, from: data)
        } catch {
            logger.error("Failed to decode history: \(error.localizedDescription, privacy: .public). Starting fresh.")
            return History()
        }
    }

    /// Persists history to disk.
    ///
    /// - Parameter path: The file URL to write to.
    /// - Throws: Encoding or file system errors.
    func save(to path: URL) throws {
        let data = try sharedJSONEncoder.encode(self)
        try data.write(to: path, options: .atomic)
    }
}
