import Testing
@testable import FastLang

@Suite("HotkeyManager")
struct HotkeyManagerTests {

    @MainActor
    @Test("registers and unregisters without crashing")
    func registerUnregister() {
        let manager = HotkeyManager()
        var overlayToggled = false
        var pttDown = false
        var pttUp = false

        manager.register(
            config: HotkeyConfig(),
            onOverlayToggle: { overlayToggled = true },
            onPttDown: { pttDown = true },
            onPttUp: { pttUp = true },
            onReadAloud: {}
        )

        // Callbacks are not invoked until the hotkey fires
        #expect(!overlayToggled)
        #expect(!pttDown)
        #expect(!pttUp)

        manager.unregister()
    }

    @MainActor
    @Test("re-registration replaces previous hotkeys")
    func reRegistration() {
        let manager = HotkeyManager()
        var callCount = 0

        manager.register(
            config: HotkeyConfig(),
            onOverlayToggle: { callCount += 1 },
            onPttDown: {},
            onPttUp: {},
            onReadAloud: {}
        )

        var newConfig = HotkeyConfig()
        newConfig.triggerOverlay = "Cmd+Shift+Space"
        newConfig.pushToTalk = "Cmd+Shift+Z"

        manager.register(
            config: newConfig,
            onOverlayToggle: { callCount += 1 },
            onPttDown: {},
            onPttUp: {},
            onReadAloud: {}
        )

        #expect(callCount == 0)
        manager.unregister()
    }

    @MainActor
    @Test("handles invalid hotkey config gracefully")
    func invalidConfig() {
        let manager = HotkeyManager()
        var config = HotkeyConfig()
        config.triggerOverlay = ""
        config.pushToTalk = "InvalidKey"

        manager.register(
            config: config,
            onOverlayToggle: {},
            onPttDown: {},
            onPttUp: {},
            onReadAloud: {}
        )

        manager.unregister()
    }
}
