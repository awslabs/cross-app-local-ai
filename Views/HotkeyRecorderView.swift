import AppKit
import HotKey
import SwiftUI

/// An inline hotkey recorder that captures a modifier+key combination.
///
/// The view displays the current hotkey string. Clicking enters recording mode,
/// which captures the next key-down event with modifiers and writes the result
/// back through the binding as a `HotkeyParser`-compatible display string.
///
/// Escape cancels recording. At least one modifier key is required.
struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var hotkeyString: String

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.hotkeyString = hotkeyString
        view.onChange = { newValue in
            hotkeyString = newValue
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        if nsView.hotkeyString != hotkeyString {
            nsView.hotkeyString = hotkeyString
        }
    }
}

// MARK: - HotkeyRecorderNSView

/// Custom `NSView` that acts as a hotkey capture field.
///
/// Uses local event monitors to reliably intercept keyboard events while
/// recording, regardless of responder chain state within the SwiftUI form.
final class HotkeyRecorderNSView: NSView {
    var hotkeyString = "" {
        didSet { needsDisplay = true }
    }

    var onChange: ((String) -> Void)?

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    private var keyDownMonitor: Any?
    private var flagsMonitor: Any?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 24)
    }

    deinit {
        // NSView.deinit is always main-thread; assumeIsolated satisfies
        // Swift 6 without dispatching.
        MainActor.assumeIsolated {
            if let monitor = keyDownMonitor {
                NSEvent.removeMonitor(monitor)
            }
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    // MARK: - Event Handling

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5)

        let bgColor: NSColor = isRecording
            ? .controlAccentColor.withAlphaComponent(0.12)
            : .controlBackgroundColor
        bgColor.setFill()
        path.fill()

        let borderColor: NSColor = isRecording ? .controlAccentColor : .separatorColor
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let displayText = isRecording ? "Press shortcut\u{2026}" : hotkeyString
        let textColor: NSColor = isRecording ? .controlAccentColor : .secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: textColor,
        ]
        let attrString = NSAttributedString(string: displayText, attributes: attrs)
        let textSize = attrString.size()
        let textOrigin = NSPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        )
        attrString.draw(at: textOrigin)
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.handleKeyDown(event)
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            _ = self
            return event
        }
    }

    private func stopRecording() {
        isRecording = false
        removeMonitors()
    }

    private func removeMonitors() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let keyCode = event.keyCode

        // Escape cancels recording without changing the hotkey.
        if keyCode == 53 {
            stopRecording()
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !modifiers.isEmpty else { return }

        guard let key = Key(carbonKeyCode: UInt32(keyCode)) else { return }
        guard let displayName = Self.displayName(for: key) else { return }

        var parsed = ParsedHotkey()
        parsed.command = modifiers.contains(.command)
        parsed.control = modifiers.contains(.control)
        parsed.option = modifiers.contains(.option)
        parsed.shift = modifiers.contains(.shift)
        parsed.key = displayName

        let formatted = HotkeyParser.format(parsed)
        hotkeyString = formatted
        onChange?(formatted)
        stopRecording()
    }

    // MARK: - Key Display Names

    // swiftlint:disable cyclomatic_complexity
    /// Maps a `Key` enum case to its canonical display name for `HotkeyParser`.
    ///
    /// Returns `nil` for modifier-only keys and other keys that should not be
    /// assigned as hotkey triggers.
    private static func displayName(for key: Key) -> String? {
        switch key {
        case .a: "A"
        case .b: "B"
        case .c: "C"
        case .d: "D"
        case .e: "E"
        case .f: "F"
        case .g: "G"
        case .h: "H"
        case .i: "I"
        case .j: "J"
        case .k: "K"
        case .l: "L"
        case .m: "M"
        case .n: "N"
        case .o: "O"
        case .p: "P"
        case .q: "Q"
        case .r: "R"
        case .s: "S"
        case .t: "T"
        case .u: "U"
        case .v: "V"
        case .w: "W"
        case .x: "X"
        case .y: "Y"
        case .z: "Z"
        case .zero: "0"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .four: "4"
        case .five: "5"
        case .six: "6"
        case .seven: "7"
        case .eight: "8"
        case .nine: "9"
        case .space: "Space"
        case .return: "Return"
        case .tab: "Tab"
        case .delete: "Delete"
        case .forwardDelete: "ForwardDelete"
        case .upArrow: "UpArrow"
        case .downArrow: "DownArrow"
        case .leftArrow: "LeftArrow"
        case .rightArrow: "RightArrow"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PageUp"
        case .pageDown: "PageDown"
        case .minus: "-"
        case .equal: "="
        case .leftBracket: "["
        case .rightBracket: "]"
        case .backslash: "\\"
        case .semicolon: ";"
        case .quote: "'"
        case .comma: ","
        case .period: "."
        case .slash: "/"
        case .grave: "`"
        case .f1: "F1"
        case .f2: "F2"
        case .f3: "F3"
        case .f4: "F4"
        case .f5: "F5"
        case .f6: "F6"
        case .f7: "F7"
        case .f8: "F8"
        case .f9: "F9"
        case .f10: "F10"
        case .f11: "F11"
        case .f12: "F12"
        case .f13: "F13"
        case .f14: "F14"
        case .f15: "F15"
        case .f16: "F16"
        case .f17: "F17"
        case .f18: "F18"
        case .f19: "F19"
        case .f20: "F20"
        case .section: "Section"
        default: nil
        }
    }
    // swiftlint:enable cyclomatic_complexity
}

// MARK: - Previews

#Preview("Default State") {
    VStack(spacing: 16) {
        HotkeyRecorderView(hotkeyString: .constant("Option+Space"))
        HotkeyRecorderView(hotkeyString: .constant("Cmd+Shift+Z"))
    }
    .padding()
}
