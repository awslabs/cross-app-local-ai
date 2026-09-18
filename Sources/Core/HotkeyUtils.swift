import AppKit
import Foundation
import HotKey

/// A parsed hotkey combination ready for registration.
struct ParsedHotkey: Equatable {
    var command = false
    var control = false
    var option = false
    var shift = false
    var key = ""

    /// Converts this parsed hotkey to the soffes/HotKey library types.
    ///
    /// - Returns: A tuple of `(Key, NSEvent.ModifierFlags)`, or `nil` if the
    ///   key string does not map to a valid `Key` enum case.
    func toHotKeyLibrary() -> (key: Key, modifiers: NSEvent.ModifierFlags)? {
        guard let hotKeyKey = Key(string: key.lowercased()) else {
            return nil
        }
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if control { flags.insert(.control) }
        if option { flags.insert(.option) }
        if shift { flags.insert(.shift) }
        return (hotKeyKey, flags)
    }
}

/// Parses and formats human-readable hotkey strings like "Cmd+Shift+Space".
enum HotkeyParser {

    /// Parses a display string into a `ParsedHotkey`.
    ///
    /// - Parameter string: e.g. "Cmd+Shift+Space", "Option+Space", "Ctrl+Alt+S"
    /// - Returns: The parsed hotkey, or `nil` if the string is empty, has no modifier, or has an unrecognized key.
    private enum Modifier {
        case command, control, option, shift

        init?(token: String) {
            switch token.lowercased() {
            case "cmd", "command": self = .command
            case "ctrl", "control": self = .control
            case "option", "alt": self = .option
            case "shift": self = .shift
            default: return nil
            }
        }
    }

    static func parse(_ string: String) -> ParsedHotkey? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }

        var hotkey = ParsedHotkey()
        var foundKey = false

        for (index, part) in parts.enumerated() {
            if let modifier = Modifier(token: part) {
                applyModifier(modifier, to: &hotkey)
            } else if index == parts.count - 1 {
                hotkey.key = normalizeKeyName(part)
                foundKey = true
            } else {
                return nil
            }
        }

        guard foundKey else { return nil }
        let hasModifier = hotkey.command || hotkey.control || hotkey.option || hotkey.shift
        guard hasModifier else { return nil }

        return hotkey
    }

    private static func applyModifier(_ modifier: Modifier, to hotkey: inout ParsedHotkey) {
        switch modifier {
        case .command: hotkey.command = true
        case .control: hotkey.control = true
        case .option: hotkey.option = true
        case .shift: hotkey.shift = true
        }
    }

    /// Formats a `ParsedHotkey` back into a display string.
    ///
    /// Modifier order: Cmd, Ctrl, Option, Shift (matching macOS conventions).
    ///
    /// - Parameter hotkey: The parsed hotkey to format.
    /// - Returns: A display string like "Cmd+Shift+Space".
    static func format(_ hotkey: ParsedHotkey) -> String {
        var parts: [String] = []
        if hotkey.command { parts.append("Cmd") }
        if hotkey.control { parts.append("Ctrl") }
        if hotkey.option { parts.append("Option") }
        if hotkey.shift { parts.append("Shift") }
        parts.append(hotkey.key)
        return parts.joined(separator: "+")
    }

    private static let keyNameAliases: [String: String] = [
        "space": "Space", "return": "Return", "enter": "Return",
        "tab": "Tab", "escape": "Escape", "esc": "Escape",
        "delete": "Delete", "backspace": "Delete",
        "forwarddelete": "ForwardDelete",
        "up": "UpArrow", "uparrow": "UpArrow",
        "down": "DownArrow", "downarrow": "DownArrow",
        "left": "LeftArrow", "leftarrow": "LeftArrow",
        "right": "RightArrow", "rightarrow": "RightArrow",
        "home": "Home", "end": "End",
        "pageup": "PageUp", "pagedown": "PageDown",
        "section": "Section",
    ]

    /// Normalizes a key name to its canonical display form.
    private static func normalizeKeyName(_ key: String) -> String {
        if let canonical = keyNameAliases[key.lowercased()] {
            return canonical
        }
        return key.count == 1 ? key.uppercased() : key
    }
}
