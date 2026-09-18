import AppKit
import HotKey
import Testing
@testable import FastLang

@Suite("HotkeyParser")
struct HotkeyParserTests {

    // MARK: - Parsing

    @Test("parses Cmd+Shift+Space")
    func cmdShiftSpace() {
        let result = HotkeyParser.parse("Cmd+Shift+Space")
        #expect(result != nil)
        #expect(result?.command == true)
        #expect(result?.shift == true)
        #expect(result?.option == false)
        #expect(result?.control == false)
        #expect(result?.key == "Space")
    }

    @Test("parses Option+Space")
    func optionSpace() {
        let result = HotkeyParser.parse("Option+Space")
        #expect(result != nil)
        #expect(result?.option == true)
        #expect(result?.key == "Space")
    }

    @Test("parses Command alias")
    func commandAlias() {
        let result = HotkeyParser.parse("Command+S")
        #expect(result != nil)
        #expect(result?.command == true)
        #expect(result?.key == "S")
    }

    @Test("parses Control alias")
    func controlAlias() {
        let result = HotkeyParser.parse("Control+C")
        #expect(result != nil)
        #expect(result?.control == true)
    }

    @Test("parses Alt alias for Option")
    func altAlias() {
        let result = HotkeyParser.parse("Alt+Tab")
        #expect(result != nil)
        #expect(result?.option == true)
        #expect(result?.key == "Tab")
    }

    @Test("parses Ctrl alias")
    func ctrlAlias() {
        let result = HotkeyParser.parse("Ctrl+Space")
        #expect(result != nil)
        #expect(result?.control == true)
    }

    @Test("parses all four modifiers")
    func allModifiers() {
        let result = HotkeyParser.parse("Cmd+Ctrl+Option+Shift+R")
        #expect(result != nil)
        #expect(result?.command == true)
        #expect(result?.control == true)
        #expect(result?.option == true)
        #expect(result?.shift == true)
        #expect(result?.key == "R")
    }

    @Test("normalizes single character key to uppercase")
    func uppercaseKey() {
        let result = HotkeyParser.parse("Cmd+r")
        #expect(result?.key == "R")
    }

    // MARK: - Edge Cases

    @Test("returns nil for empty string")
    func emptyString() {
        #expect(HotkeyParser.parse("") == nil)
    }

    @Test("returns nil for whitespace-only string")
    func whitespaceOnly() {
        #expect(HotkeyParser.parse("   ") == nil)
    }

    @Test("returns nil when no modifier present")
    func noModifier() {
        #expect(HotkeyParser.parse("Space") == nil)
    }

    @Test("returns nil for modifier-only input")
    func modifierOnly() {
        #expect(HotkeyParser.parse("Cmd+Shift") == nil)
    }

    @Test("returns nil for unknown middle token")
    func unknownMiddleToken() {
        #expect(HotkeyParser.parse("Cmd+Foo+Space") == nil)
    }

    // MARK: - Formatting

    @Test("format produces canonical modifier order")
    func formatOrder() {
        var hotkey = ParsedHotkey()
        hotkey.shift = true
        hotkey.command = true
        hotkey.option = true
        hotkey.key = "Space"
        #expect(HotkeyParser.format(hotkey) == "Cmd+Option+Shift+Space")
    }

    @Test("format with single modifier")
    func formatSingle() {
        var hotkey = ParsedHotkey()
        hotkey.option = true
        hotkey.key = "Space"
        #expect(HotkeyParser.format(hotkey) == "Option+Space")
    }

    // MARK: - Roundtrip

    @Test("parse then format roundtrips")
    func roundtrip() {
        let inputs = [
            "Cmd+Shift+Space",
            "Option+Space",
            "Cmd+Shift+R",
            "Ctrl+Option+S",
        ]
        for input in inputs {
            let parsed = HotkeyParser.parse(input)
            #expect(parsed != nil, "Failed to parse: \(input)")
            guard let parsed else { continue }
            let formatted = HotkeyParser.format(parsed)
            let reparsed = HotkeyParser.parse(formatted)
            #expect(reparsed == parsed, "Roundtrip failed for: \(input)")
        }
    }

    @Test("format then parse roundtrips")
    func roundtripReverse() {
        var hotkey = ParsedHotkey()
        hotkey.command = true
        hotkey.shift = true
        hotkey.key = "Space"
        let formatted = HotkeyParser.format(hotkey)
        let reparsed = HotkeyParser.parse(formatted)
        #expect(reparsed == hotkey)
    }
}

// MARK: - HotKey Library Conversion

@Suite("ParsedHotkey HotKey Conversion")
struct ParsedHotkeyConversionTests {

    @Test("converts Option+Space to Key.space with option modifier")
    func optionSpace() {
        guard let parsed = HotkeyParser.parse("Option+Space") else {
            Issue.record("Failed to parse Option+Space")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .space)
        #expect(result?.modifiers == .option)
    }

    @Test("converts Cmd+Shift+Z to Key.z with command and shift modifiers")
    func cmdShiftZ() {
        guard let parsed = HotkeyParser.parse("Cmd+Shift+Z") else {
            Issue.record("Failed to parse Cmd+Shift+Z")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .z)
        #expect(result?.modifiers == [.command, .shift])
    }

    @Test("converts Cmd+Shift+R to Key.r with command and shift modifiers")
    func cmdShiftR() {
        guard let parsed = HotkeyParser.parse("Cmd+Shift+R") else {
            Issue.record("Failed to parse Cmd+Shift+R")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .r)
        #expect(result?.modifiers == [.command, .shift])
    }

    @Test("converts all four modifiers correctly")
    func allModifiers() {
        guard let parsed = HotkeyParser.parse("Cmd+Ctrl+Option+Shift+S") else {
            Issue.record("Failed to parse Cmd+Ctrl+Option+Shift+S")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .s)
        #expect(result?.modifiers.contains(.command) == true)
        #expect(result?.modifiers.contains(.control) == true)
        #expect(result?.modifiers.contains(.option) == true)
        #expect(result?.modifiers.contains(.shift) == true)
    }

    @Test("converts Return key")
    func returnKey() {
        guard let parsed = HotkeyParser.parse("Cmd+Return") else {
            Issue.record("Failed to parse Cmd+Return")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .return)
    }

    @Test("converts Tab key")
    func tabKey() {
        guard let parsed = HotkeyParser.parse("Option+Tab") else {
            Issue.record("Failed to parse Option+Tab")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .tab)
    }

    @Test("converts Escape key")
    func escapeKey() {
        guard let parsed = HotkeyParser.parse("Cmd+Escape") else {
            Issue.record("Failed to parse Cmd+Escape")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .escape)
    }

    @Test("default overlay hotkey converts successfully")
    func defaultOverlayHotkey() {
        let config = HotkeyConfig()
        guard let parsed = HotkeyParser.parse(config.triggerOverlay) else {
            Issue.record("Failed to parse default overlay hotkey")
            return
        }
        #expect(parsed.toHotKeyLibrary() != nil)
    }

    @Test("default PTT hotkey converts successfully")
    func defaultPttHotkey() {
        let config = HotkeyConfig()
        guard let parsed = HotkeyParser.parse(config.pushToTalk) else {
            Issue.record("Failed to parse default PTT hotkey")
            return
        }
        let result = parsed.toHotKeyLibrary()
        #expect(result != nil)
        #expect(result?.key == .z)
        #expect(result?.modifiers == [.command, .shift])
    }
}
