import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "appresolver")

// MARK: - Data Types

/// A mapping entry from an app identifier to its key and context type.
struct AppMapping: Codable, Equatable {
    var appKey: String
    var contextType: String
}

/// The full set of app mappings: bundle IDs, app names, window title patterns, and browsers.
struct AppMappingsData: Codable, Equatable {
    var bundleIds: [String: AppMapping] = [:]
    var appNames: [String: AppMapping] = [:]
    var windowTitlePatterns: [String: AppMapping] = [:]
    var browsers: [String] = []
}

/// The resolved identity of an application.
struct AppIdentity: Equatable {
    let appKey: String
    let contextType: ContextType
}

// MARK: - AppResolver

/// Resolves the identity and context type of a frontmost application.
///
/// Resolution order:
/// 1. Bundle ID exact match
/// 2. Browser detection + window title pattern matching
/// 3. App name exact match
/// 4. Auto-derive key from app name
struct AppResolver {
    let mappings: AppMappingsData

    /// Resolves an app's identity from its context.
    ///
    /// - Parameters:
    ///   - bundleId: The app's bundle identifier, if available.
    ///   - appName: The app's display name.
    ///   - windowTitle: The key window's title, if available.
    /// - Returns: The resolved `AppIdentity`.
    func resolve(bundleId: String?, appName: String, windowTitle: String?) -> AppIdentity {
        // 1. Bundle ID exact match
        if let bid = bundleId, let mapping = mappings.bundleIds[bid] {
            return AppIdentity(
                appKey: mapping.appKey,
                contextType: ContextType(rawValue: mapping.contextType) ?? .generic
            )
        }

        // 2. Browser detection
        if isBrowser(bundleId: bundleId, appName: appName) {
            if let title = windowTitle {
                let lowerTitle = title.lowercased()
                for (pattern, mapping) in mappings.windowTitlePatterns
                    where lowerTitle.contains(pattern.lowercased()) {
                    return AppIdentity(
                        appKey: mapping.appKey,
                        contextType: ContextType(rawValue: mapping.contextType) ?? .generic
                    )
                }
            }
            return AppIdentity(appKey: "browser", contextType: .generic)
        }

        // 3. App name exact match
        if let mapping = mappings.appNames[appName] {
            return AppIdentity(
                appKey: mapping.appKey,
                contextType: ContextType(rawValue: mapping.contextType) ?? .generic
            )
        }

        // 4. Auto-derive from app name
        return AppIdentity(
            appKey: normalizeAppName(appName),
            contextType: .generic
        )
    }

    /// Whether the app is a known web browser.
    private func isBrowser(bundleId: String?, appName: String) -> Bool {
        if let bid = bundleId, mappings.browsers.contains(bid) {
            return true
        }
        let lowerName = appName.lowercased()
        return mappings.browsers.contains { lowerName.contains($0.lowercased()) }
    }

    // MARK: - Persistence

    /// Loads mappings from disk, returning defaults if the file is missing or corrupt.
    static func loadMappings(from path: URL) -> AppMappingsData {
        guard let data = try? Data(contentsOf: path) else {
            logger.info("No app mappings file, using defaults")
            return AppMappingsData.defaultMappings
        }
        do {
            return try sharedJSONDecoder.decode(AppMappingsData.self, from: data)
        } catch {
            logger
                .error(
                    "Failed to decode app mappings: \(error.localizedDescription, privacy: .public). Using defaults."
                )
            return AppMappingsData.defaultMappings
        }
    }

    /// Saves mappings to disk.
    static func saveMappings(_ mappings: AppMappingsData, to path: URL) throws {
        let data = try sharedJSONEncoder.encode(mappings)
        try data.write(to: path, options: .atomic)
    }
}

// MARK: - Utility Functions

/// Normalizes an app name into a URL-safe key.
///
/// "Microsoft Teams" -> "microsoft-teams"
/// "Slack.app" -> "slack"
/// "" -> "unknown"
func normalizeAppName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return "unknown" }

    var result = trimmed.lowercased()

    // Strip .app suffix
    if result.hasSuffix(".app") {
        result = String(result.dropLast(4))
    }

    // Replace spaces with hyphens, strip non-alphanumeric except hyphens
    result = result
        .map { char in
            if char == " " { return "-" }
            if char.isLetter || char.isNumber || char == "-" { return String(char) }
            return ""
        }
        .joined()

    // Collapse multiple hyphens
    while result.contains("--") {
        result = result.replacingOccurrences(of: "--", with: "-")
    }

    // Trim leading/trailing hyphens
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    return result.isEmpty ? "unknown" : result
}

/// Converts an app key back to a human-readable display name.
///
/// Known keys map to curated names. Unknown keys are title-cased from hyphen-separated words.
///
/// "slack" -> "Slack"
/// "vscode" -> "VS Code"
/// "my-custom-app" -> "My Custom App"
func appKeyDisplayName(_ key: String) -> String {
    if let known = knownDisplayNames[key] {
        return known
    }
    return key.split(separator: "-")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

private let knownDisplayNames: [String: String] = [
    "slack": "Slack",
    "vscode": "VS Code",
    "outlook": "Outlook",
    "mail": "Mail",
    "teams": "Teams",
    "notion": "Notion",
    "terminal": "Terminal",
    "xcode": "Xcode",
    "gmail": "Gmail",
    "chrome": "Chrome",
    "safari": "Safari",
    "firefox": "Firefox",
    "arc": "Arc",
    "browser": "Browser",
    "quip": "Quip",
    "word": "Microsoft Word",
    "excel": "Microsoft Excel",
    "google-docs": "Google Docs",
    "google-sheets": "Google Sheets",
    "intellij": "IntelliJ IDEA",
    "sublime": "Sublime Text",
    "notes": "Notes",
    "textedit": "TextEdit",
    "pages": "Pages",
    "numbers": "Numbers",
    "keynote": "Keynote",
    "github": "GitHub",
]

// MARK: - Default Mappings

extension AppMappingsData {
    static let defaultMappings = AppMappingsData(
        bundleIds: [
            "com.tinyspeck.slackmacgap": AppMapping(appKey: "slack", contextType: "Chat"),
            "com.microsoft.Outlook": AppMapping(appKey: "outlook", contextType: "Email"),
            "com.microsoft.VSCode": AppMapping(appKey: "vscode", contextType: "Code"),
            "com.apple.mail": AppMapping(appKey: "mail", contextType: "Email"),
            "com.microsoft.teams2": AppMapping(appKey: "teams", contextType: "Chat"),
            "notion.id": AppMapping(appKey: "notion", contextType: "Document"),
            "com.apple.Terminal": AppMapping(appKey: "terminal", contextType: "Code"),
            "com.googlecode.iterm2": AppMapping(appKey: "terminal", contextType: "Code"),
            "com.apple.dt.Xcode": AppMapping(appKey: "xcode", contextType: "Code"),
            "com.jetbrains.intellij": AppMapping(appKey: "intellij", contextType: "Code"),
            "com.sublimetext.4": AppMapping(appKey: "sublime", contextType: "Code"),
            "com.apple.Notes": AppMapping(appKey: "notes", contextType: "Notes"),
            "com.apple.TextEdit": AppMapping(appKey: "textedit", contextType: "Document"),
            "com.apple.Pages": AppMapping(appKey: "pages", contextType: "Document"),
            "com.apple.Numbers": AppMapping(appKey: "numbers", contextType: "Spreadsheet"),
            "com.apple.Keynote": AppMapping(appKey: "keynote", contextType: "Document"),
            "com.microsoft.Word": AppMapping(appKey: "word", contextType: "Document"),
            "com.microsoft.Excel": AppMapping(appKey: "excel", contextType: "Spreadsheet"),
        ],
        appNames: [
            "Slack": AppMapping(appKey: "slack", contextType: "Chat"),
            "Outlook": AppMapping(appKey: "outlook", contextType: "Email"),
            "Visual Studio Code": AppMapping(appKey: "vscode", contextType: "Code"),
            "Mail": AppMapping(appKey: "mail", contextType: "Email"),
            "Microsoft Teams": AppMapping(appKey: "teams", contextType: "Chat"),
            "Notion": AppMapping(appKey: "notion", contextType: "Document"),
            "Terminal": AppMapping(appKey: "terminal", contextType: "Code"),
            "iTerm2": AppMapping(appKey: "terminal", contextType: "Code"),
            "Xcode": AppMapping(appKey: "xcode", contextType: "Code"),
            "IntelliJ IDEA": AppMapping(appKey: "intellij", contextType: "Code"),
            "Sublime Text": AppMapping(appKey: "sublime", contextType: "Code"),
            "Notes": AppMapping(appKey: "notes", contextType: "Notes"),
            "TextEdit": AppMapping(appKey: "textedit", contextType: "Document"),
            "Pages": AppMapping(appKey: "pages", contextType: "Document"),
            "Numbers": AppMapping(appKey: "numbers", contextType: "Spreadsheet"),
            "Keynote": AppMapping(appKey: "keynote", contextType: "Document"),
            "Microsoft Word": AppMapping(appKey: "word", contextType: "Document"),
            "Microsoft Excel": AppMapping(appKey: "excel", contextType: "Spreadsheet"),
        ],
        windowTitlePatterns: [
            "gmail": AppMapping(appKey: "gmail", contextType: "Email"),
            "slack": AppMapping(appKey: "slack", contextType: "Chat"),
            "docs.google": AppMapping(appKey: "google-docs", contextType: "Document"),
            "sheets.google": AppMapping(appKey: "google-sheets", contextType: "Spreadsheet"),
            "outlook.office": AppMapping(appKey: "outlook", contextType: "Email"),
            "outlook.live": AppMapping(appKey: "outlook", contextType: "Email"),
            "notion.so": AppMapping(appKey: "notion", contextType: "Document"),
            "quip.com": AppMapping(appKey: "quip", contextType: "Document"),
            "teams.microsoft": AppMapping(appKey: "teams", contextType: "Chat"),
            "github.com": AppMapping(appKey: "github", contextType: "Code"),
            "stackoverflow.com": AppMapping(appKey: "stackoverflow", contextType: "Code"),
            "chat.openai.com": AppMapping(appKey: "chatgpt", contextType: "Chat"),
        ],
        browsers: [
            "com.google.Chrome",
            "com.apple.Safari",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "com.operasoftware.Opera",
            "Chrome",
            "Safari",
            "Firefox",
            "Arc",
            "Edge",
            "Brave",
        ]
    )
}
