import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

// MARK: - PlatformService Protocol

/// Platform abstraction for macOS system interaction.
///
/// Methods are `async throws` to support both the real implementation
/// (which may poll or sleep) and actor-based mocks for testing.
protocol PlatformService: Sendable {
    /// Returns the currently active (frontmost) application.
    ///
    /// - Throws: `PlatformError.activeAppError` if no frontmost app is detected.
    /// - Returns: An `AppContext` describing the frontmost application.
    func getActiveApp() async throws -> AppContext

    /// Captures selected text from the active application.
    ///
    /// Uses a two-tier strategy: Accessibility API first, clipboard-based
    /// Cmd+C fallback second.
    ///
    /// - Returns: The selected text, or `nil` if nothing is selected.
    /// - Throws: `PlatformError.permissionDenied` if accessibility access is denied.
    func captureSelection() async throws -> String?

    /// Injects text into the target application via clipboard paste.
    ///
    /// - Parameters:
    ///   - text: The text to inject.
    ///   - target: The `AppContext` identifying the target application.
    /// - Throws: `PlatformError.focusError` or `PlatformError.clipboardError`.
    func injectText(_ text: String, target: AppContext) async throws

    /// Brings the specified application to the foreground.
    ///
    /// - Parameter target: The `AppContext` identifying the application to focus.
    /// - Throws: `PlatformError.focusError` if the process cannot be activated.
    func focusApp(_ target: AppContext) async throws

    /// Reads the current clipboard contents as plain text.
    ///
    /// - Returns: The clipboard string, or `nil` if the clipboard is empty or
    ///   does not contain plain text.
    func getClipboard() async -> String?

    /// Writes plain text to the system clipboard.
    ///
    /// - Parameter text: The text to place on the clipboard.
    /// - Throws: `PlatformError.clipboardError` if the write fails.
    func setClipboard(_ text: String) async throws
}

// MARK: - PlatformError

/// Errors originating from platform service operations.
enum PlatformError: LocalizedError, Equatable {
    case activeAppError(message: String)
    case focusError(message: String)
    case clipboardError(message: String)
    case hotkeyError(message: String)
    case permissionDenied(permission: String)
    case notSupported(platform: String)

    var isPermissionDenied: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case let .activeAppError(message): "Active app detection failed: \(message)"
        case let .focusError(message): "Focus failed: \(message)"
        case let .clipboardError(message): "Clipboard error: \(message)"
        case let .hotkeyError(message): "Hotkey error: \(message)"
        case let .permissionDenied(permission): "\(permission) permission is required"
        case let .notSupported(platform): "Not supported on \(platform)"
        }
    }

    var suggestedAction: String? {
        switch self {
        case .activeAppError: nil
        case .focusError: nil
        case .clipboardError: nil
        case .hotkeyError: "Check hotkey settings"
        case let .permissionDenied(permission):
            "Grant \(permission) access in System Settings > Privacy & Security"
        case .notSupported: nil
        }
    }
}

// MARK: - PermissionChecker

/// Checks and requests macOS privacy permissions required by FastLang.
enum PermissionChecker {
    /// Whether Accessibility permission has been granted.
    ///
    /// Required for reading selected text via the Accessibility API.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user to grant Accessibility permission.
    ///
    /// Opens the System Settings privacy pane with the current app highlighted.
    static func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Opens System Settings directly to the Accessibility privacy pane.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Whether Screen Recording permission has been granted.
    ///
    /// Required for reading window titles via `CGWindowListCopyWindowInfo`.
    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts the user to grant Screen Recording permission.
    static func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Whether microphone access has been granted.
    ///
    /// Required for push-to-talk speech-to-text.
    ///
    /// - Returns: `true` if access is granted, `false` otherwise.
    static func checkMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// MARK: - MockPlatformService

/// A mock implementation of `PlatformService` for unit testing.
///
/// Configure return values before calling protocol methods.
/// Call records are stored for assertion.
actor MockPlatformService: PlatformService {
    /// The `AppContext` returned by `getActiveApp()`.
    var activeApp = AppContext(
        appName: "MockApp",
        bundleId: "com.mock.app",
        processName: "MockApp",
        processId: 1234,
        windowTitle: "Mock Window"
    )

    /// The text returned by `captureSelection()`.
    var selectedText: String?

    /// The text stored by `setClipboard()` and returned by `getClipboard()`.
    var clipboardText: String?

    /// Whether `injectText` should throw.
    var injectShouldFail = false

    /// The error thrown by `injectText` when `injectShouldFail` is true.
    /// Defaults to `clipboardError`; set to `permissionDenied` to simulate
    /// missing Accessibility permission.
    var injectError: PlatformError = .clipboardError(message: "Mock inject failure")

    /// Whether `focusApp` should throw.
    var focusShouldFail = false

    /// Records of method calls for assertion.
    private(set) var calls: [String] = []

    /// The text passed to the most recent `injectText` call.
    private(set) var lastInjectedText: String?

    /// The target passed to the most recent `injectText` call.
    private(set) var lastInjectedTarget: AppContext?

    /// The target passed to the most recent `focusApp` call.
    private(set) var lastFocusedTarget: AppContext?

    func getActiveApp() async throws -> AppContext {
        calls.append("getActiveApp")
        return activeApp
    }

    func captureSelection() async throws -> String? {
        calls.append("captureSelection")
        return selectedText
    }

    func injectText(_ text: String, target: AppContext) async throws {
        calls.append("injectText")
        lastInjectedText = text
        lastInjectedTarget = target
        if injectShouldFail {
            throw injectError
        }
    }

    func focusApp(_ target: AppContext) async throws {
        calls.append("focusApp")
        lastFocusedTarget = target
        if focusShouldFail {
            throw PlatformError.focusError(message: "Mock focus failure")
        }
    }

    func getClipboard() async -> String? {
        calls.append("getClipboard")
        return clipboardText
    }

    func setClipboard(_ text: String) async throws {
        calls.append("setClipboard")
        clipboardText = text
    }

    /// Resets all recorded state.
    func reset() {
        calls.removeAll()
        clipboardText = nil
        lastInjectedText = nil
        lastInjectedTarget = nil
        lastFocusedTarget = nil
        injectShouldFail = false
        injectError = .clipboardError(message: "Mock inject failure")
        focusShouldFail = false
    }
}
