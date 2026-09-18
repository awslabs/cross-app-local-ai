import Foundation
import Testing
@testable import FastLang

// MARK: - PlatformError Tests

@Suite("PlatformError")
struct PlatformErrorTests {

    @Test("All cases have non-empty user messages")
    func allCasesHaveMessages() {
        let cases: [PlatformError] = [
            .activeAppError(message: "test"),
            .focusError(message: "test"),
            .clipboardError(message: "test"),
            .hotkeyError(message: "test"),
            .permissionDenied(permission: "Accessibility"),
            .notSupported(platform: "Linux"),
        ]

        for error in cases {
            #expect(!error.userMessage.isEmpty, "Missing message for \(error)")
            #expect(error.errorDescription == error.userMessage)
        }
    }

    @Test("permissionDenied includes permission name in message")
    func permissionDeniedIncludesName() {
        let error = PlatformError.permissionDenied(permission: "Accessibility")
        #expect(error.userMessage.contains("Accessibility"))
    }

    @Test("permissionDenied has suggested action")
    func permissionDeniedHasSuggestedAction() {
        let error = PlatformError.permissionDenied(permission: "Accessibility")
        #expect(error.suggestedAction != nil)
        #expect(error.suggestedAction?.contains("System Settings") == true)
    }

    @Test("Equatable conformance")
    func equatable() {
        let lhs = PlatformError.activeAppError(message: "test")
        let rhs = PlatformError.activeAppError(message: "test")
        let different = PlatformError.activeAppError(message: "other")

        #expect(lhs == rhs)
        #expect(lhs != different)
    }
}

// MARK: - MockPlatformService Tests

@Suite("MockPlatformService")
struct MockPlatformServiceTests {

    @Test("getActiveApp returns configured context")
    func getActiveAppReturnsConfigured() async throws {
        let mock = MockPlatformService()
        let expected = AppContext(
            appName: "TestApp",
            bundleId: "com.test.app",
            processName: "TestApp",
            processId: 42,
            windowTitle: "Test Window"
        )
        await mock.setActiveApp(expected)

        let result = try await mock.getActiveApp()
        #expect(result == expected)
        let calls = await mock.calls
        #expect(calls == ["getActiveApp"])
    }

    @Test("captureSelection returns configured text")
    func captureSelectionReturnsConfigured() async throws {
        let mock = MockPlatformService()
        await mock.setSelectedText("Hello, world!")

        let result = try await mock.captureSelection()
        #expect(result == "Hello, world!")
    }

    @Test("captureSelection returns nil by default")
    func captureSelectionReturnsNilDefault() async throws {
        let mock = MockPlatformService()
        let result = try await mock.captureSelection()
        #expect(result == nil)
    }

    @Test("clipboard roundtrip via mock")
    func clipboardRoundtrip() async throws {
        let mock = MockPlatformService()
        try await mock.setClipboard("clipboard text")
        let result = await mock.getClipboard()
        #expect(result == "clipboard text")
    }

    @Test("injectText records call arguments")
    func injectTextRecordsArguments() async throws {
        let mock = MockPlatformService()
        let target = AppContext(
            appName: "Target",
            processName: "Target",
            processId: 99,
            windowTitle: ""
        )

        try await mock.injectText("injected", target: target)

        let lastText = await mock.lastInjectedText
        let lastTarget = await mock.lastInjectedTarget
        #expect(lastText == "injected")
        #expect(lastTarget == target)
    }

    @Test("injectText throws when configured to fail")
    func injectTextThrowsOnFailure() async throws {
        let mock = MockPlatformService()
        await mock.setInjectShouldFail(true)
        let target = AppContext(appName: "T", processName: "T", processId: 1, windowTitle: "")

        await #expect(throws: PlatformError.self) {
            try await mock.injectText("text", target: target)
        }
    }

    @Test("injectText throws permissionDenied when configured")
    func injectTextThrowsPermissionDenied() async throws {
        let mock = MockPlatformService()
        await mock.setInjectShouldFail(true)
        await mock.setInjectError(.permissionDenied(permission: "Accessibility"))
        let target = AppContext(appName: "T", processName: "T", processId: 1, windowTitle: "")

        do {
            try await mock.injectText("text", target: target)
            Issue.record("Expected throw")
        } catch let error as PlatformError {
            #expect(error.isPermissionDenied)
            #expect(error == .permissionDenied(permission: "Accessibility"))
        }
    }

    @Test("focusApp records target")
    func focusAppRecordsTarget() async throws {
        let mock = MockPlatformService()
        let target = AppContext(appName: "Focus", processName: "Focus", processId: 7, windowTitle: "")

        try await mock.focusApp(target)

        let lastFocused = await mock.lastFocusedTarget
        #expect(lastFocused == target)
    }

    @Test("focusApp throws when configured to fail")
    func focusAppThrowsOnFailure() async throws {
        let mock = MockPlatformService()
        await mock.setFocusShouldFail(true)
        let target = AppContext(appName: "T", processName: "T", processId: 1, windowTitle: "")

        await #expect(throws: PlatformError.self) {
            try await mock.focusApp(target)
        }
    }

    @Test("reset clears all recorded state")
    func resetClearsState() async throws {
        let mock = MockPlatformService()
        _ = try await mock.getActiveApp()
        try await mock.setClipboard("text")
        await mock.reset()

        let calls = await mock.calls
        let clipboard = await mock.clipboardText
        #expect(calls.isEmpty)
        #expect(clipboard == nil)
    }

    @Test("call recording tracks multiple calls in order")
    func callRecordingTracksOrder() async throws {
        let mock = MockPlatformService()

        _ = try await mock.getActiveApp()
        _ = try await mock.captureSelection()
        _ = await mock.getClipboard()
        try await mock.setClipboard("test")

        let calls = await mock.calls
        #expect(calls == ["getActiveApp", "captureSelection", "getClipboard", "setClipboard"])
    }
}

// MARK: - PlatformError Permission Error Composition

@Suite("PlatformError STT Injection Error Composition")
struct PlatformErrorCompositionTests {

    @Test("permission denied error produces actionable user message")
    func permissionDeniedProducesActionableMessage() {
        let error = PlatformError.permissionDenied(permission: "Accessibility")
        let message = "\(error.userMessage). \(error.suggestedAction ?? "Grant access in System Settings")"

        #expect(message.contains("Accessibility"))
        #expect(message.contains("permission is required"))
        #expect(message.contains("System Settings"))
        #expect(message.contains("Privacy & Security"))
    }

    @Test("isPermissionDenied returns true only for permissionDenied case")
    func isPermissionDeniedFiltersCorrectly() {
        let permDenied = PlatformError.permissionDenied(permission: "Accessibility")
        let clipboard = PlatformError.clipboardError(message: "fail")
        let focus = PlatformError.focusError(message: "fail")

        #expect(permDenied.isPermissionDenied)
        #expect(!clipboard.isPermissionDenied)
        #expect(!focus.isPermissionDenied)
    }

    @Test("non-permission error produces generic injection failure message")
    func nonPermissionErrorProducesGenericMessage() {
        let error = PlatformError.clipboardError(message: "write failed")
        let message = "Injection failed: \(error.localizedDescription)"

        #expect(message.contains("Injection failed"))
        #expect(message.contains("write failed"))
    }
}

// MARK: - SttIndicatorMode Tests

@Suite("SttIndicatorMode")
struct SttIndicatorModeTests {

    @Test("error mode carries message string")
    func errorModeCarriesMessage() {
        let mode = SttIndicatorMode.error(message: "Accessibility permission is required")
        if case let .error(message) = mode {
            #expect(message == "Accessibility permission is required")
        } else {
            Issue.record("Expected .error case")
        }
    }

    @Test("recording mode is distinct from error mode")
    func recordingIsDistinctFromError() {
        let recording = SttIndicatorMode.recording
        if case .error = recording {
            Issue.record("recording should not match error")
        }
    }

    @Test("transcribing mode is distinct from error mode")
    func transcribingIsDistinctFromError() {
        let transcribing = SttIndicatorMode.transcribing
        if case .error = transcribing {
            Issue.record("transcribing should not match error")
        }
    }
}

// MARK: - MockPlatformService setter helpers

extension MockPlatformService {
    func setActiveApp(_ context: AppContext) {
        activeApp = context
    }

    func setSelectedText(_ text: String?) {
        selectedText = text
    }

    func setInjectShouldFail(_ fail: Bool) {
        injectShouldFail = fail
    }

    func setInjectError(_ error: PlatformError) {
        injectError = error
    }

    func setFocusShouldFail(_ fail: Bool) {
        focusShouldFail = fail
    }
}
