import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "preferences")

/// How long before an app's inferred preferences are considered stale and
/// eligible for re-extraction (24 hours).
private let stalenessThresholdSeconds: UInt64 = 86400

/// Maximum length (in characters) for the learned-preferences text blob.
/// The extractor trims the model's output to this before storing, so a
/// runaway model can't blow up the prompt budget on subsequent uses.
let maxLearnedTextLength = 1500

// MARK: - AppPreference

/// LLM-inferred and user-defined writing preferences for a specific app.
///
/// The learned text is a plain prose blob (3–5 sentences) that the
/// extractor emits directly and the prompt template injects verbatim. No
/// structured insight list, no JSON parsing, no per-item enable/disable
/// toggles — the extraction produces text and that text IS the value.
///
/// User rules live alongside as a separate, always-applied channel. They
/// are not edited by the extractor and take precedence in the prompt
/// template.
struct AppPreference: Codable, Equatable {
    /// LLM-generated prose describing the user's writing preferences for
    /// this app. Empty when extraction hasn't succeeded yet, or when the
    /// user has cleared the learned text.
    var learnedText = ""

    /// User-defined rules. One string per rule. Rendered as a numbered
    /// list in the prompt template.
    var userRules: [String] = []

    /// When `true`, `learnedText` is injected into prompts for this app.
    /// User rules are applied regardless of this toggle.
    var inferredEnabled = true

    /// Unix timestamp of the last successful extraction. Zero means never
    /// successfully extracted, which `isStale` treats as always-stale.
    var lastGenerated: UInt64 = 0

    /// Session count included in the most recent extraction, surfaced in
    /// the Memory UI for transparency.
    var sessionsAnalyzed = 0

    // Legacy fields retained only for decoding old `app_rules.json` files.
    // Migrated into `learnedText` on load, then dropped on next save.
    private var legacySummary: String?
    private var legacyInsightTexts: [String]?

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case learnedText
        case userRules
        case inferredEnabled
        case lastGenerated
        case sessionsAnalyzed
        // Legacy keys from the pre-prose era.
        case summary
        case insights
    }

    /// Legacy insight shape used only during decoding of old files.
    private struct LegacyInsight: Codable {
        let text: String
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        learnedText = try container.decodeIfPresent(String.self, forKey: .learnedText) ?? ""
        userRules = try container.decodeIfPresent([String].self, forKey: .userRules) ?? []
        inferredEnabled = try container.decodeIfPresent(Bool.self, forKey: .inferredEnabled) ?? true
        lastGenerated = try container.decodeIfPresent(UInt64.self, forKey: .lastGenerated) ?? 0
        sessionsAnalyzed = try container.decodeIfPresent(Int.self, forKey: .sessionsAnalyzed) ?? 0

        legacySummary = try container.decodeIfPresent(String.self, forKey: .summary)
        if let legacyInsights = try container.decodeIfPresent([LegacyInsight].self, forKey: .insights) {
            legacyInsightTexts = legacyInsights.map(\.text)
        }

        // Migrate legacy fields into `learnedText` if the new field is empty.
        if learnedText.isEmpty {
            if let insightTexts = legacyInsightTexts, !insightTexts.isEmpty {
                learnedText = insightTexts.joined(separator: " ")
            } else if let summary = legacySummary, !summary.isEmpty {
                learnedText = summary
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(learnedText, forKey: .learnedText)
        try container.encode(userRules, forKey: .userRules)
        try container.encode(inferredEnabled, forKey: .inferredEnabled)
        try container.encode(lastGenerated, forKey: .lastGenerated)
        try container.encode(sessionsAnalyzed, forKey: .sessionsAnalyzed)
        // Deliberately do not re-emit legacy fields; writing the file
        // completes the migration.
    }
}

// MARK: - AppPreferences

/// Per-app preference store persisted to `app_rules.json`.
struct AppPreferences: Codable, Equatable {
    var apps: [String: AppPreference] = [:]

    // MARK: - Queries

    /// Returns the learned-preferences text for an app, or empty string
    /// if the app has none or has the inferred toggle disabled. This is
    /// the exact string injected into prompts.
    func getSummary(_ appKey: String) -> String {
        guard let pref = apps[appKey], pref.inferredEnabled else { return "" }
        return pref.learnedText
    }

    /// Whether inferred preferences are enabled for an app. Defaults to
    /// `true` for unknown apps so new apps start learning immediately.
    func isInferredEnabled(_ appKey: String) -> Bool {
        apps[appKey]?.inferredEnabled ?? true
    }

    /// Returns user rules formatted as a numbered list, or empty string
    /// if none.
    func userRulesText(_ appKey: String) -> String {
        guard let rules = apps[appKey]?.userRules, !rules.isEmpty else { return "" }
        return rules.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
    }

    // MARK: - Mutations

    /// Toggles inferred preference generation for an app. Creates an
    /// entry if one doesn't exist.
    mutating func toggleInferred(_ appKey: String) {
        var pref = apps[appKey] ?? AppPreference()
        pref.inferredEnabled.toggle()
        apps[appKey] = pref
    }

    /// Stores a successful extraction result.
    ///
    /// Does not validate the text beyond the caller's preparation — the
    /// extractor is responsible for trimming and truncating before this
    /// call. Updates `lastGenerated` so `isStale` begins the next
    /// 24-hour clock.
    ///
    /// - Parameters:
    ///   - appKey: The app key to update.
    ///   - learnedText: The prose summary to inject into prompts.
    ///   - sessionsAnalyzed: Number of sessions the extractor considered.
    mutating func setLearnedText(
        _ appKey: String,
        learnedText: String,
        sessionsAnalyzed: Int
    ) {
        var pref = apps[appKey] ?? AppPreference()
        pref.learnedText = learnedText
        pref.sessionsAnalyzed = sessionsAnalyzed
        pref.lastGenerated = UInt64(Date().timeIntervalSince1970)
        apps[appKey] = pref
    }

    /// Compatibility shim for tests and any remaining call sites that
    /// haven't migrated to `setLearnedText`. Prefer `setLearnedText` in
    /// new code.
    mutating func setSummary(
        _ appKey: String,
        summary: String,
        sessionsAnalyzed: Int
    ) {
        setLearnedText(appKey, learnedText: summary, sessionsAnalyzed: sessionsAnalyzed)
    }

    /// Clears the learned text for an app without removing the app's
    /// other state (user rules, inferred toggle, history reference).
    /// Also zeroes `lastGenerated` so the app is immediately eligible
    /// for re-extraction.
    mutating func clearLearnedText(_ appKey: String) {
        guard var pref = apps[appKey] else { return }
        pref.learnedText = ""
        pref.lastGenerated = 0
        pref.sessionsAnalyzed = 0
        apps[appKey] = pref
    }

    /// Removes all preference data for an app.
    mutating func removeApp(_ appKey: String) {
        apps.removeValue(forKey: appKey)
    }

    /// Adds a user-defined rule for an app.
    mutating func addUserRule(_ appKey: String, rule: String) {
        var pref = apps[appKey] ?? AppPreference()
        pref.userRules.append(rule)
        apps[appKey] = pref
    }

    /// Removes a user rule at the given index.
    ///
    /// - Returns: `true` if the rule was removed.
    @discardableResult
    mutating func removeUserRule(_ appKey: String, at index: Int) -> Bool {
        guard var pref = apps[appKey],
              pref.userRules.indices.contains(index)
        else {
            return false
        }
        pref.userRules.remove(at: index)
        apps[appKey] = pref
        return true
    }

    // MARK: - Staleness

    /// Whether an app's preferences are stale and should be re-extracted.
    func isStale(_ appKey: String) -> Bool {
        guard let pref = apps[appKey] else { return true }
        if pref.lastGenerated == 0 { return true }
        let now = UInt64(Date().timeIntervalSince1970)
        return now - pref.lastGenerated > stalenessThresholdSeconds
    }

    /// Returns app keys that have history but stale or missing
    /// preferences, and that have been used recently (within the last 4
    /// hours). The extractor scans this set periodically and generates
    /// preferences for each.
    func staleAppKeys(from history: History) -> [String] {
        let recentThreshold = UInt64(Date().timeIntervalSince1970) - (4 * 60 * 60)
        var recentAppKeys: Set<String> = []
        for session in history.sessions where !session.appKey.isEmpty {
            if let ts = UInt64(session.timestamp), ts >= recentThreshold {
                recentAppKeys.insert(session.appKey)
            }
        }
        return recentAppKeys.filter { isStale($0) }.sorted()
    }

    /// Returns all app keys that appear either in preferences or history,
    /// sorted by most recently used (most recent session timestamp first).
    func allKeysWithHistory(from history: History) -> [String] {
        var allKeys: Set<String> = Set(apps.keys)
        for session in history.sessions where !session.appKey.isEmpty {
            allKeys.insert(session.appKey)
        }

        let latestTimestamp: [String: String] = history.sessions.reduce(into: [:]) { dict, session in
            guard !session.appKey.isEmpty else { return }
            if let existing = dict[session.appKey] {
                if session.timestamp > existing {
                    dict[session.appKey] = session.timestamp
                }
            } else {
                dict[session.appKey] = session.timestamp
            }
        }

        return allKeys.sorted { lhs, rhs in
            let tsLhs = latestTimestamp[lhs] ?? "0"
            let tsRhs = latestTimestamp[rhs] ?? "0"
            return tsLhs > tsRhs
        }
    }

    // MARK: - Persistence

    /// Loads preferences from disk. Returns empty preferences if the
    /// file is missing or corrupt.
    static func load(from path: URL) -> AppPreferences {
        guard let data = try? Data(contentsOf: path) else {
            logger.info("No app rules file, starting with empty preferences")
            return AppPreferences()
        }
        do {
            return try sharedJSONDecoder.decode(AppPreferences.self, from: data)
        } catch {
            logger.error("Failed to decode app rules: \(error.localizedDescription, privacy: .public). Starting fresh.")
            return AppPreferences()
        }
    }

    /// Persists preferences to disk.
    ///
    /// - Parameter path: The file URL to write to.
    /// - Throws: Encoding or file system errors.
    func save(to path: URL) throws {
        let data = try sharedJSONEncoder.encode(self)
        try data.write(to: path, options: .atomic)
    }
}
