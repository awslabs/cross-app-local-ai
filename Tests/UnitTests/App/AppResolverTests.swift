import Foundation
import Testing
@testable import FastLang

@Suite("AppResolver")
struct AppResolverTests {
    let resolver = AppResolver(mappings: AppMappingsData.defaultMappings)

    // MARK: - Bundle ID Resolution

    @Test("resolves Slack by bundle ID")
    func slackBundleId() {
        let result = resolver.resolve(
            bundleId: "com.tinyspeck.slackmacgap",
            appName: "Slack",
            windowTitle: nil
        )
        #expect(result.appKey == "slack")
        #expect(result.contextType == .chat)
    }

    @Test("resolves VS Code by bundle ID")
    func vscodeBundleId() {
        let result = resolver.resolve(
            bundleId: "com.microsoft.VSCode",
            appName: "Code",
            windowTitle: nil
        )
        #expect(result.appKey == "vscode")
        #expect(result.contextType == .code)
    }

    @Test("resolves Apple Mail by bundle ID")
    func mailBundleId() {
        let result = resolver.resolve(
            bundleId: "com.apple.mail",
            appName: "Mail",
            windowTitle: nil
        )
        #expect(result.appKey == "mail")
        #expect(result.contextType == .email)
    }

    // MARK: - Browser Detection + Window Title

    @Test("Chrome with Gmail title resolves to gmail/email")
    func chromeGmail() {
        let result = resolver.resolve(
            bundleId: "com.google.Chrome",
            appName: "Chrome",
            windowTitle: "Inbox - user@example.com - Gmail"
        )
        #expect(result.appKey == "gmail")
        #expect(result.contextType == .email)
    }

    @Test("Safari with Slack title resolves to slack/chat")
    func safariSlack() {
        let result = resolver.resolve(
            bundleId: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Slack | #general"
        )
        #expect(result.appKey == "slack")
        #expect(result.contextType == .chat)
    }

    @Test("browser with unrecognized title resolves to browser/generic")
    func browserGeneric() {
        let result = resolver.resolve(
            bundleId: "com.google.Chrome",
            appName: "Chrome",
            windowTitle: "Example.com - Some random page"
        )
        #expect(result.appKey == "browser")
        #expect(result.contextType == .generic)
    }

    @Test("browser with nil title resolves to browser/generic")
    func browserNilTitle() {
        let result = resolver.resolve(
            bundleId: "com.apple.Safari",
            appName: "Safari",
            windowTitle: nil
        )
        #expect(result.appKey == "browser")
        #expect(result.contextType == .generic)
    }

    @Test("Arc browser detected by app name")
    func arcBrowser() {
        let result = resolver.resolve(
            bundleId: "company.thebrowser.Browser",
            appName: "Arc",
            windowTitle: "docs.google.com"
        )
        #expect(result.appKey == "google-docs")
        #expect(result.contextType == .document)
    }

    // MARK: - App Name Resolution

    @Test("resolves by app name when bundle ID is nil")
    func appNameResolution() {
        let result = resolver.resolve(
            bundleId: nil,
            appName: "Notion",
            windowTitle: nil
        )
        #expect(result.appKey == "notion")
        #expect(result.contextType == .document)
    }

    // MARK: - Unknown App Auto-Derive

    @Test("unknown app derives key from name")
    func unknownApp() {
        let result = resolver.resolve(
            bundleId: "com.example.SomeApp",
            appName: "My Custom Editor",
            windowTitle: nil
        )
        #expect(result.appKey == "my-custom-editor")
        #expect(result.contextType == .generic)
    }

    @Test("unknown app with no bundle ID derives from name")
    func unknownAppNoBundleId() {
        let result = resolver.resolve(
            bundleId: nil,
            appName: "FancyTool",
            windowTitle: nil
        )
        #expect(result.appKey == "fancytool")
        #expect(result.contextType == .generic)
    }

    // MARK: - Persistence

    @Test("loadMappings returns defaults for missing file")
    func loadMissingFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("missing.json")
        let loaded = AppResolver.loadMappings(from: path)
        #expect(!loaded.bundleIds.isEmpty)
        #expect(!loaded.browsers.isEmpty)
    }
}

@Suite("normalizeAppName")
struct NormalizeAppNameTests {

    @Test("lowercases and replaces spaces with hyphens")
    func basic() {
        #expect(normalizeAppName("Microsoft Teams") == "microsoft-teams")
    }

    @Test("strips .app suffix")
    func stripApp() {
        #expect(normalizeAppName("Slack.app") == "slack")
    }

    @Test("empty string returns unknown")
    func emptyString() {
        #expect(normalizeAppName("") == "unknown")
    }

    @Test("whitespace-only returns unknown")
    func whitespace() {
        #expect(normalizeAppName("   ") == "unknown")
    }

    @Test("strips non-alphanumeric characters")
    func specialChars() {
        #expect(normalizeAppName("My App (v2)") == "my-app-v2")
    }

    @Test("collapses multiple hyphens")
    func multipleHyphens() {
        #expect(normalizeAppName("My   App") == "my-app")
    }
}

@Suite("appKeyDisplayName")
struct AppKeyDisplayNameTests {

    @Test("known keys return curated names")
    func knownKeys() {
        #expect(appKeyDisplayName("slack") == "Slack")
        #expect(appKeyDisplayName("vscode") == "VS Code")
        #expect(appKeyDisplayName("gmail") == "Gmail")
    }

    @Test("unknown keys are title-cased from hyphens")
    func unknownKeys() {
        #expect(appKeyDisplayName("my-custom-app") == "My Custom App")
    }

    @Test("single-word unknown key gets capitalized")
    func singleWord() {
        #expect(appKeyDisplayName("fancytool") == "Fancytool")
    }
}
