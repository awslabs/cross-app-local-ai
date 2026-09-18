import AppKit
import Foundation

// MARK: - Monitor Detection

/// Returns the screen that currently contains the mouse cursor.
///
/// Falls back to `NSScreen.main` if no screen contains the cursor position,
/// which can happen briefly during display reconfiguration.
///
/// - Returns: The screen at the cursor, or `NSScreen.main`, or `nil` if
///   no screens are available.
@MainActor
func getMonitorAtCursor() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation

    for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
        return screen
    }

    return NSScreen.main
}

// MARK: - Overlay Positioning

/// Positions an NSPanel using a saved position or centered on the active monitor.
///
/// - Parameters:
///   - panel: The overlay panel to position.
///   - savedPosition: A previously saved window position, or `nil` to center.
@MainActor
func positionOverlay(_ panel: NSPanel, savedPosition: WindowPosition?) {
    if let saved = savedPosition {
        panel.setFrameOrigin(NSPoint(x: CGFloat(saved.x), y: CGFloat(saved.y)))
        return
    }

    guard let screen = getMonitorAtCursor() else { return }
    let screenFrame = screen.visibleFrame
    let panelSize = panel.frame.size

    let xPos = screenFrame.midX - panelSize.width / 2
    let yPos = screenFrame.midY - panelSize.height / 2

    panel.setFrameOrigin(NSPoint(x: xPos, y: yPos))
}
