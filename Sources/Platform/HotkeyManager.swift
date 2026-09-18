import Foundation
import HotKey
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "hotkeys")

/// Manages global hotkey registration using the soffes/HotKey library.
///
/// Retaining a `HotKey` instance keeps its Carbon event handler registered;
/// releasing it (setting to `nil`) unregisters. This class owns the lifecycle
/// of the overlay trigger, push-to-talk, and read-aloud hotkeys.
@MainActor
final class HotkeyManager {
    private var overlayHotKey: HotKey?
    private var pttHotKey: HotKey?
    private var readAloudHotKey: HotKey?
    private var aiSearchHotKey: HotKey?

    /// Registers global hotkeys from the given configuration.
    ///
    /// Any previously registered hotkeys are unregistered first.
    ///
    /// - Parameters:
    ///   - config: The hotkey configuration containing key combo strings.
    ///   - aiSearchEnabled: Whether the AI search hotkey should be registered.
    ///   - onOverlayToggle: Called on the main thread when the overlay trigger fires.
    ///   - onPttDown: Called on the main thread when push-to-talk key is pressed.
    ///   - onPttUp: Called on the main thread when push-to-talk key is released.
    ///   - onReadAloud: Called on the main thread when the read-aloud trigger fires.
    ///   - onAiSearchDown: Called on the main thread when AI search key is pressed.
    ///   - onAiSearchUp: Called on the main thread when AI search key is released.
    func register(
        config: HotkeyConfig,
        aiSearchEnabled: Bool = true,
        onOverlayToggle: @escaping @MainActor () -> Void,
        onPttDown: @escaping @MainActor () -> Void,
        onPttUp: @escaping @MainActor () -> Void,
        onReadAloud: @escaping @MainActor () -> Void = {},
        onAiSearchDown: @escaping @MainActor () -> Void = {},
        onAiSearchUp: @escaping @MainActor () -> Void = {}
    ) {
        unregister()

        if let parsed = HotkeyParser.parse(config.triggerOverlay),
           let (key, modifiers) = parsed.toHotKeyLibrary() {
            let hotKey = HotKey(key: key, modifiers: modifiers)
            hotKey.keyDownHandler = { MainActor.assumeIsolated { onOverlayToggle() } }
            overlayHotKey = hotKey
            logger.info("Registered overlay hotkey: \(config.triggerOverlay)")
        } else {
            logger.error("Failed to parse overlay hotkey: \(config.triggerOverlay, privacy: .public)")
        }

        if let parsed = HotkeyParser.parse(config.pushToTalk),
           let (key, modifiers) = parsed.toHotKeyLibrary() {
            let hotKey = HotKey(key: key, modifiers: modifiers)
            hotKey.keyDownHandler = { MainActor.assumeIsolated { onPttDown() } }
            hotKey.keyUpHandler = { MainActor.assumeIsolated { onPttUp() } }
            pttHotKey = hotKey
            logger.info("Registered PTT hotkey: \(config.pushToTalk)")
        } else {
            logger.error("Failed to parse PTT hotkey: \(config.pushToTalk, privacy: .public)")
        }

        if let parsed = HotkeyParser.parse(config.readAloud),
           let (key, modifiers) = parsed.toHotKeyLibrary() {
            let hotKey = HotKey(key: key, modifiers: modifiers)
            hotKey.keyDownHandler = { MainActor.assumeIsolated { onReadAloud() } }
            readAloudHotKey = hotKey
            logger.info("Registered read-aloud hotkey: \(config.readAloud)")
        } else {
            logger.error("Failed to parse read-aloud hotkey: \(config.readAloud, privacy: .public)")
        }

        guard aiSearchEnabled else {
            // Feature flag is off. This isn't an error state — just skip
            // registration silently. Previously the joined `if` below lumped
            // "disabled" together with "parse failure" and logged both as
            // errors, which generated a false alarm on every launch.
            return
        }

        if let parsed = HotkeyParser.parse(config.aiSearch),
           let (key, modifiers) = parsed.toHotKeyLibrary() {
            let hotKey = HotKey(key: key, modifiers: modifiers)
            hotKey.keyDownHandler = { MainActor.assumeIsolated { onAiSearchDown() } }
            hotKey.keyUpHandler = { MainActor.assumeIsolated { onAiSearchUp() } }
            aiSearchHotKey = hotKey
            logger.info("Registered AI search hotkey: \(config.aiSearch)")
        } else {
            logger.error("Failed to parse AI search hotkey: \(config.aiSearch, privacy: .public)")
        }
    }

    /// Unregisters all hotkeys.
    func unregister() {
        overlayHotKey = nil
        pttHotKey = nil
        readAloudHotKey = nil
        aiSearchHotKey = nil
    }
}
