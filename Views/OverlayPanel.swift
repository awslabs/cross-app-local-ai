import AppKit

/// A non-activating floating panel for the FastLang overlay.
///
/// This panel floats above all applications (including fullscreen),
/// appears on all Spaces, and accepts keyboard input without stealing
/// focus from the user's active application.
///
/// Key properties:
/// - `level = 101`: above fullscreen windows
/// - `collectionBehavior`: visible on all Spaces and alongside fullscreen apps
/// - `canBecomeKey`: accepts keyboard input for the prompt text field
/// - `hidesOnDeactivate = false`: stays visible when FastLang loses focus
class OverlayPanel: NSPanel {

    /// The window level used by the overlay (above fullscreen apps).
    static let overlayLevel = NSWindow.Level(rawValue: 101)

    /// Called when the panel loses key window status (user clicked outside).
    var onResignKey: (() -> Void)?

    /// Called when the panel is closed via the red X button.
    var onClose: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [
                .nonactivatingPanel,
                .titled,
                .closable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        hidesOnDeactivate = false

        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // Hide the traffic light buttons — this is a custom floating panel
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isFloatingPanel = true

        // Set level AFTER isFloatingPanel, which resets level to .floating (3).
        level = Self.overlayLevel

        backgroundColor = .clear
        isOpaque = false

        delegate = self
    }

    override var canBecomeKey: Bool {
        true
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - NSWindowDelegate

extension OverlayPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
