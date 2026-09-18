import AppKit

/// A non-activating floating panel for the read-aloud feature.
///
/// Wider than the standard overlay to comfortably display full text passages.
/// Shares the same floating, transparent, chromeless behavior as
/// `OverlayPanel` so the read-aloud UI can render the shared overlay card
/// (blurred material + border) instead of an opaque background.
class ReadAloudPanel: NSPanel {

    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?

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
        // whose dismissal is driven by the SwiftUI toolbar's close button
        // and Escape key handling.
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        isFloatingPanel = true
        // Setting `level` after `isFloatingPanel` is required; the latter
        // resets level to `.floating` (3) otherwise.
        level = OverlayPanel.overlayLevel

        // Transparent window so the SwiftUI `.ultraThinMaterial` card shows
        // its blur through to whatever's behind. With an opaque window and
        // a non-zero background color the material would render against a
        // solid dark fill and look flat.
        backgroundColor = .clear
        isOpaque = false
    }

    override var canBecomeKey: Bool {
        true
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_: Any?) {
        onCancel?()
    }
}
