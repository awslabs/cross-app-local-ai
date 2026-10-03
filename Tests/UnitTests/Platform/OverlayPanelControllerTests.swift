import AppKit
import Foundation
import Testing
@testable import FastLang

/// Builds a race-free `AppState` for tests: skips `initializeAsync()` /
/// `initializeTelemetry()` so no background `Task` can race with assertions.
@MainActor
private func makeTestAppState() -> AppState {
    let dirs = AppDirs.withRoot(URL(fileURLWithPath: "/tmp/qg-overlaypanelcontroller-tests"))
    return AppState(
        config: Config(),
        dirs: dirs,
        platformService: MacPlatformService(),
        audioRecorder: AudioRecorder(),
        agent: BackgroundAgent(),
        appResolver: AppResolver(mappings: AppMappingsData.defaultMappings),
        promptStore: nil
    )
}

@MainActor
private func makeController(currentScreenProvider: @escaping () -> NSScreen?) -> OverlayPanelController {
    OverlayPanelController(
        appState: makeTestAppState(),
        onSubmit: { _ in },
        onCancel: {},
        onAccept: {},
        onReject: {},
        onRefine: { _ in },
        onDismiss: {},
        currentScreenProvider: currentScreenProvider
    )
}

/// Covers the STT indicator screen-anchoring behavior described in
/// `OverlayPanelController.sttAnchorScreen`: once a session starts, every
/// pill transition in that session must reuse the same screen rather than
/// re-resolving "the screen with keyboard focus" on every call — which would
/// otherwise let a failed injection (opening System Settings, or the OS
/// Accessibility trust prompt) strand the error pill on a different screen
/// than the recording/transcribing pills the user was already looking at.
@Suite("OverlayPanelController STT indicator anchoring")
@MainActor
struct OverlayPanelControllerSttAnchorTests {

    @Test("showSttIndicator resolves the screen once, then reuses it")
    func anchorsOncePerSession() {
        var callCount = 0
        let controller = makeController {
            callCount += 1
            return NSScreen.main
        }

        controller.showSttIndicator()
        #expect(callCount == 1)

        controller.showSttTranscribingIndicator()
        #expect(callCount == 1)

        controller.showSttNotice(
            SttIndicatorNotice(text: "Accessibility permission required.", kind: .error)
        )
        #expect(callCount == 1)
    }

    @Test("the anchored screen does not drift even if the current screen changes mid-session")
    func anchorDoesNotDriftWhenCurrentScreenChanges() {
        // Simulates the real bug: something (System Settings opening, the OS
        // Accessibility trust prompt) steals keyboard focus mid-session, so
        // "the current screen" the provider would report changes between the
        // recording pill and the error pill. The anchored screen must not
        // follow that change — the provider must not be consulted again once
        // the session has an anchor.
        var callCount = 0
        var currentScreen: NSScreen? = NSScreen.main
        let controller = makeController {
            callCount += 1
            return currentScreen
        }

        controller.showSttIndicator()
        #expect(callCount == 1)

        // Something else takes keyboard focus, changing what the provider
        // would now report if it were consulted again.
        currentScreen = nil

        controller.showSttNotice(
            SttIndicatorNotice(text: "Accessibility permission required.", kind: .error)
        )

        // Still 1: the error pill reused the anchor instead of re-resolving
        // (and getting nil from) the provider.
        #expect(callCount == 1)
    }

    @Test("hideSttIndicator resets the anchor so the next session re-resolves the screen")
    func resetsAnchorAfterHide() {
        var callCount = 0
        let controller = makeController {
            callCount += 1
            return NSScreen.main
        }

        controller.showSttIndicator()
        #expect(callCount == 1)

        controller.hideSttIndicator()

        controller.showSttIndicator()
        #expect(callCount == 2)
    }

    @Test("a notice shown without a prior recording session still resolves a screen")
    func noticeWithoutPriorRecordingAnchors() {
        var callCount = 0
        let controller = makeController {
            callCount += 1
            return NSScreen.main
        }

        controller.showSttNotice(
            SttIndicatorNotice(text: "Speech recognition is still starting up.", kind: .info)
        )
        #expect(callCount == 1)
    }
}
