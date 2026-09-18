import AppKit
import Testing
@testable import FastLang

@Suite("Clipboard Integration")
struct ClipboardIntegrationTests {

    @Test("NSPasteboard set and get roundtrip")
    @MainActor
    func clipboardRoundtrip() {
        let pasteboard = NSPasteboard.general
        let testText = "FastLang clipboard test \(UUID().uuidString)"

        pasteboard.clearContents()
        let setResult = pasteboard.setString(testText, forType: .string)
        #expect(setResult == true)

        let retrieved = pasteboard.string(forType: .string)
        #expect(retrieved == testText)
    }

    @Test("changeCount increments on write")
    @MainActor
    func changeCountIncrements() {
        let pasteboard = NSPasteboard.general
        let countBefore = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("test", forType: .string)

        let countAfter = pasteboard.changeCount
        #expect(countAfter > countBefore)
    }

    @Test("clearContents increments changeCount")
    @MainActor
    func clearContentsIncrements() {
        let pasteboard = NSPasteboard.general
        let countBefore = pasteboard.changeCount

        pasteboard.clearContents()

        let countAfter = pasteboard.changeCount
        #expect(countAfter > countBefore)
    }

    @Test("MacPlatformService clipboard roundtrip")
    @MainActor
    func macPlatformServiceClipboardRoundtrip() async throws {
        let service = MacPlatformService()
        let testText = "MacPlatformService test \(UUID().uuidString)"

        try await service.setClipboard(testText)
        let result = await service.getClipboard()
        #expect(result == testText)
    }
}
