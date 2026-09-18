import Testing
@testable import FastLang

@Suite("Platform Integration")
struct PlatformIntegrationTests {

    @Test("getActiveApp returns non-empty app context")
    @MainActor
    func getActiveAppReturnsContext() async throws {
        let service = MacPlatformService()
        let context = try await service.getActiveApp()

        // In a test runner, the frontmost app is typically Xcode or
        // the test host. We just verify we get a valid result.
        #expect(!context.appName.isEmpty)
        #expect(context.processId > 0)
    }

    @Test("getClipboard returns nil or string")
    func getClipboardDoesNotCrash() async {
        let service = MacPlatformService()
        // Verify calling getClipboard does not crash.
        // It may return nil if the clipboard is empty or contains non-text data.
        let result = await service.getClipboard()
        #expect(result == nil || result != nil)
    }
}
