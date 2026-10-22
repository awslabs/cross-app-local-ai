import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "platform")

/// Default maximum time (milliseconds) to wait for the clipboard to change
/// after simulating Cmd+C.
private let defaultClipboardPollMaxMs = 500

// MARK: - MacPlatformService

/// Production implementation of `PlatformService` using native macOS APIs.
///
/// All AppKit-touching methods run on `@MainActor`. Keyboard simulation
/// (copy/paste) uses `CGEvent` directly (requires Accessibility permission).
/// Text capture uses `AXUIElement` first, falling back to clipboard-based Cmd+C.
final class MacPlatformService: PlatformService, @unchecked Sendable {

    // MARK: - Active App Detection

    @MainActor
    func getActiveApp() async throws -> AppContext {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            throw PlatformError.activeAppError(message: "No frontmost application")
        }

        let appName = frontApp.localizedName ?? "Unknown"
        let bundleId = frontApp.bundleIdentifier
        let pid = frontApp.processIdentifier
        let windowInfo = Self.getWindowInfo(for: pid)

        return AppContext(
            appName: appName,
            bundleId: bundleId,
            processName: appName,
            processId: UInt32(pid),
            windowTitle: windowInfo?.title ?? "",
            windowBounds: windowInfo?.bounds
        )
    }

    // MARK: - Text Capture

    func captureSelection() async throws -> String? {
        guard PermissionChecker.hasAccessibilityPermission else {
            PermissionChecker.requestAccessibilityPermission()
            throw PlatformError.permissionDenied(permission: "Accessibility")
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let pid = frontApp?.processIdentifier else {
            return nil
        }

        // Tier 1: Accessibility API (fast, no clipboard side effects)
        if let text = Self.getSelectedTextViaAccessibility(pid: pid) {
            logger.debug("Captured selection via Accessibility API")
            return text
        }

        // Tier 2: Clipboard-based Cmd+C fallback
        logger.debug("Accessibility capture failed, falling back to clipboard-based capture")
        return await captureViaClipboard()
    }

    // MARK: - Text Injection

    func injectText(_ text: String, target: AppContext) async throws {
        guard PermissionChecker.hasAccessibilityPermission else {
            PermissionChecker.requestAccessibilityPermission()
            throw PlatformError.permissionDenied(permission: "Accessibility")
        }

        logger.debug("Simulating Cmd+V paste into \(target.appName) (pid \(target.processId))")
        guard Self.simulatePaste() else {
            PermissionChecker.requestAccessibilityPermission()
            throw PlatformError.permissionDenied(permission: "Accessibility")
        }
    }

    // MARK: - App Focus

    @MainActor
    func focusApp(_ target: AppContext) async throws {
        guard let app = NSRunningApplication(
            processIdentifier: pid_t(target.processId)
        ) else {
            throw PlatformError.focusError(
                message: "Process \(target.processId) not found"
            )
        }

        let activated = app.activate()
        if activated {
            logger.debug("Focused \(target.appName) (pid \(target.processId)) via NSRunningApplication")
        } else {
            logger.debug("NSRunningApplication.activate failed for pid \(target.processId), trying AppleScript")
            try Self.focusByAppleScript(pid: target.processId)
        }
    }

    // MARK: - Clipboard

    @MainActor
    func getClipboard() async -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @MainActor
    func setClipboard(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        if !success {
            throw PlatformError.clipboardError(message: "Failed to set clipboard text")
        }
        logger.debug("Clipboard set: \(text.count) chars, changeCount=\(pasteboard.changeCount)")
    }
}

// MARK: - Private Helpers

extension MacPlatformService {

    // MARK: Window Info

    private struct WindowInfo {
        let title: String
        let bounds: WindowBounds?
    }

    /// Queries `CGWindowListCopyWindowInfo` for the key window of the given PID.
    private static func getWindowInfo(for pid: pid_t) -> WindowInfo? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]]
        else {
            return nil
        }

        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            let title = window[kCGWindowName as String] as? String ?? ""
            let bounds: WindowBounds? = if let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                                           let xVal = boundsDict["X"] as? Int32,
                                           let yVal = boundsDict["Y"] as? Int32,
                                           let width = boundsDict["Width"] as? Int32,
                                           let height = boundsDict["Height"] as? Int32 {
                WindowBounds(x: xVal, y: yVal, width: width, height: height)
            } else {
                nil
            }

            return WindowInfo(title: title, bounds: bounds)
        }

        return nil
    }

    // MARK: Accessibility Capture

    /// Attempts to read selected text via the Accessibility API.
    ///
    /// Requires Accessibility permission to be granted.
    ///
    /// - Parameter pid: The process identifier of the target application.
    /// - Returns: The selected text, or `nil` if unavailable.
    private static func getSelectedTextViaAccessibility(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success,
              let focused = focusedElement
        else {
            return nil
        }

        // AXUIElementCopyAttributeValue returns AnyObject; the focused element
        // is always an AXUIElement when the result is .success.
        let focusedAXElement = focused as! AXUIElement // swiftlint:disable:this force_cast

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        guard textResult == .success,
              let text = selectedText as? String,
              !text.isEmpty
        else {
            return nil
        }

        return text
    }

    // MARK: Clipboard-Based Capture

    /// Captures selected text by simulating Cmd+C and polling the clipboard.
    @MainActor
    private func captureViaClipboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount

        guard Self.simulateCopy() else {
            logger.warning("simulateCopy failed — CGEvent creation returned nil")
            return nil
        }

        let didChange = await waitForClipboardChange(
            initialCount: initialChangeCount,
            maxWaitMs: defaultClipboardPollMaxMs
        )

        guard didChange else { return nil }
        return pasteboard.string(forType: .string)
    }

    /// Runs an AppleScript via `/usr/bin/osascript` subprocess.
    ///
    /// Using a subprocess rather than `NSAppleScript` avoids in-process
    /// sandbox restrictions and matches the Rust codebase's approach.
    ///
    /// - Parameter script: The AppleScript source text.
    /// - Returns: `true` if the script executed successfully.
    @discardableResult
    private static func runOsascript(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.debug("osascript launch failed: \(error.localizedDescription)")
            return false
        }

        if process.terminationStatus != 0 {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? "unknown"
            logger.debug("osascript failed (exit \(process.terminationStatus)): \(errorMsg)")
            return false
        }

        return true
    }

    /// Simulates Cmd+C via CGEvent (Accessibility permission required).
    ///
    /// - Returns: `true` if the events were created and posted; `false` if
    ///   CGEvent creation failed (indicating broken permissions).
    @discardableResult
    private static func simulateCopy() -> Bool {
        simulateKeystrokeCGEvent(virtualKey: 0x08)
    }

    /// Simulates Cmd+V via CGEvent (Accessibility permission required).
    ///
    /// - Returns: `true` if the events were created and posted; `false` if
    ///   CGEvent creation failed (indicating broken permissions).
    @discardableResult
    private static func simulatePaste() -> Bool {
        simulateKeystrokeCGEvent(virtualKey: 0x09)
    }

    /// Simulates Cmd+<key> via CGEvent (Accessibility permission required).
    ///
    /// - Parameter virtualKey: The virtual key code (0x08 = 'c', 0x09 = 'v').
    /// - Returns: `true` if both key-down and key-up events were created and
    ///   posted successfully; `false` if CGEvent returned nil.
    private static func simulateKeystrokeCGEvent(virtualKey: CGKeyCode) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else {
            logger.warning("CGEvent creation failed for keyCode \(virtualKey) — likely stale accessibility permission")
            return false
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Simulates a key press with optional modifier flags via CGEvent.
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g. 36 = Return).
    ///   - flags: The modifier flags to apply (empty for no modifiers).
    func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) async throws {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Polls `NSPasteboard.general.changeCount` until it differs from `initialCount`.
    ///
    /// Uses cooperative `Task.sleep` rather than blocking `usleep` so the run loop
    /// can process pasteboard daemon XPC messages between polls, preventing
    /// concurrent `NSPasteboard` access that corrupts its internal cache.
    ///
    /// - Parameters:
    ///   - initialCount: The change count before the simulated copy.
    ///   - maxWaitMs: Maximum wait time in milliseconds.
    /// - Returns: `true` if the clipboard changed within the timeout.
    @MainActor
    private func waitForClipboardChange(initialCount: Int, maxWaitMs: Int) async -> Bool {
        let maxIterations = maxWaitMs / 10
        for _ in 0 ..< maxIterations {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
            if NSPasteboard.general.changeCount != initialCount {
                return true
            }
        }
        return false
    }

    // MARK: AppleScript Focus Fallback

    /// Focuses an application by PID using osascript subprocess.
    private static func focusByAppleScript(pid: UInt32) throws {
        let script = """
        tell application "System Events"
            set targetProcess to first application process whose unix id is \(pid)
            set frontmost of targetProcess to true
        end tell
        """

        if !runOsascript(script) {
            throw PlatformError.focusError(
                message: "osascript focus failed for PID \(pid)"
            )
        }
    }
}
