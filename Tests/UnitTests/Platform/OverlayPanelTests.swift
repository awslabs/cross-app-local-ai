import AppKit
import Testing
@testable import FastLang

@Suite("OverlayPanel")
struct OverlayPanelTests {

    @Test("canBecomeKey is true")
    @MainActor
    func canBecomeKeyIsTrue() {
        let panel = OverlayPanel()
        #expect(panel.canBecomeKey == true)
    }

    @Test("level is 101")
    @MainActor
    func levelIs101() {
        let panel = OverlayPanel()
        #expect(panel.level == NSWindow.Level(rawValue: 101))
        #expect(panel.level == OverlayPanel.overlayLevel)
    }

    @Test("collectionBehavior includes canJoinAllSpaces")
    @MainActor
    func canJoinAllSpaces() {
        let panel = OverlayPanel()
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    }

    @Test("collectionBehavior includes fullScreenAuxiliary")
    @MainActor
    func fullScreenAuxiliary() {
        let panel = OverlayPanel()
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test("styleMask includes nonactivatingPanel")
    @MainActor
    func nonActivatingPanel() {
        let panel = OverlayPanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    @Test("styleMask includes fullSizeContentView")
    @MainActor
    func fullSizeContentView() {
        let panel = OverlayPanel()
        #expect(panel.styleMask.contains(.fullSizeContentView))
    }

    @Test("hidesOnDeactivate is false")
    @MainActor
    func hidesOnDeactivateIsFalse() {
        let panel = OverlayPanel()
        #expect(panel.hidesOnDeactivate == false)
    }

    @Test("titlebar is transparent")
    @MainActor
    func titlebarIsTransparent() {
        let panel = OverlayPanel()
        #expect(panel.titlebarAppearsTransparent == true)
        #expect(panel.titleVisibility == .hidden)
    }

    @Test("isFloatingPanel is true")
    @MainActor
    func isFloatingPanelTrue() {
        let panel = OverlayPanel()
        #expect(panel.isFloatingPanel == true)
    }
}
