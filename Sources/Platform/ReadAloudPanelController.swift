import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.aws.fastlang", category: "readaloud.panel")

/// Manages the lifecycle of the floating read-aloud panel.
///
/// Creates the `ReadAloudPanel`, hosts `ReadAloudContainerView` inside it via
/// `NSHostingView`, and exposes `show()` / `hide()` to control visibility.
/// An observation loop watches `AppState` properties so the panel automatically
/// resizes when the text or playback state changes.
@MainActor
final class ReadAloudPanelController {
    private let panel: ReadAloudPanel
    private let appState: AppState
    private let hostingView: NSHostingView<ReadAloudContainerView>
    private let onDismiss: () -> Void

    /// Creates the read-aloud panel controller.
    ///
    /// - Parameters:
    ///   - appState: The shared app state driving the view.
    ///   - onPlay: Called when the user presses play.
    ///   - onPause: Called when the user presses pause.
    ///   - onResume: Called when the user presses resume.
    ///   - onStop: Called when the user presses stop.
    ///   - onSeek: Called when the user taps a word to seek.
    ///   - onRateChange: Called when the user adjusts the speed slider.
    ///   - onSummarize: Called when the user requests an LLM summary.
    ///   - onRestoreOriginal: Called when the user restores the original text.
    ///   - onDismiss: Called when the panel should be dismissed.
    init(
        appState: AppState,
        onPlay: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onSeek: @escaping (Int) -> Void,
        onRateChange: @escaping (Float) -> Void,
        onSummarize: @escaping () -> Void,
        onRestoreOriginal: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.appState = appState
        self.panel = ReadAloudPanel()
        self.onDismiss = onDismiss

        let containerView = ReadAloudContainerView(
            appState: appState,
            onPlay: onPlay,
            onPause: onPause,
            onResume: onResume,
            onStop: onStop,
            onSeek: onSeek,
            onRateChange: onRateChange,
            onSummarize: onSummarize,
            onRestoreOriginal: onRestoreOriginal,
            onDismiss: onDismiss
        )
        let hosting = NSHostingView(rootView: containerView)
        self.hostingView = hosting

        panel.contentView = hosting

        let scale = appState.config.behavior.fontScale
        panel.contentMinSize = NSSize(
            width: ReadAloudMetrics.panelWidth(scale: scale),
            height: ReadAloudMetrics.panelMinHeight(scale: scale)
        )
        panel.contentMaxSize = NSSize(
            width: ReadAloudMetrics.panelWidth(scale: scale),
            height: ReadAloudMetrics.panelMaxHeight(scale: scale)
        )

        setupEscapeHandler()
        setupFocusLossHandler()
        startObservingState()
        logger.debug("ReadAloudPanelController initialized")
    }

    /// Shows the read-aloud panel centered on the active screen.
    func show() {
        sizeToContent()
        centerOnScreen()
        panel.orderFrontRegardless()
        panel.makeKey()
        logger.info("Read-aloud panel shown")
    }

    /// Hides the read-aloud panel.
    func hide() {
        panel.orderOut(nil)
        logger.info("Read-aloud panel hidden")
    }

    // MARK: - Dismissal

    private func setupEscapeHandler() {
        panel.onCancel = { [weak self] in
            guard let self,
                  self.appState.isReadAloudVisible,
                  self.appState.config.behavior.readAloudDismissOnEscape
            else {
                return
            }
            self.onDismiss()
        }
    }

    private func setupFocusLossHandler() {
        panel.onResignKey = { [weak self] in
            guard let self,
                  self.appState.isReadAloudVisible,
                  self.appState.config.behavior.readAloudDismissOnFocusLoss
            else {
                return
            }
            self.onDismiss()
        }
    }

    // MARK: - Dynamic Sizing

    private func sizeToContent() {
        let scale = appState.config.behavior.fontScale
        let scaledWidth = ReadAloudMetrics.panelWidth(scale: scale)
        let fitting = hostingView.fittingSize
        let height = min(
            max(fitting.height, ReadAloudMetrics.panelMinHeight(scale: scale)),
            ReadAloudMetrics.panelMaxHeight(scale: scale)
        )
        let newSize = NSSize(width: scaledWidth, height: height)

        panel.contentMinSize = NSSize(
            width: scaledWidth,
            height: ReadAloudMetrics.panelMinHeight(scale: scale)
        )
        panel.contentMaxSize = NSSize(
            width: scaledWidth,
            height: ReadAloudMetrics.panelMaxHeight(scale: scale)
        )

        guard abs(panel.frame.width - newSize.width) > 1
            || abs(panel.frame.height - newSize.height) > 1
        else { return }
        panel.setContentSize(newSize)
    }

    private func startObservingState() {
        scheduleObservation()
    }

    private func scheduleObservation() {
        withObservationTracking {
            _ = self.appState.readAloudText
            _ = self.appState.readAloudPlaybackState
            _ = self.appState.readAloudHighlightRange
            _ = self.appState.readAloudRendition
            _ = self.appState.readAloudSummarizeState
            _ = self.appState.config.behavior.fontScale
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sizeToContent()
                self.scheduleObservation()
            }
        }
    }

    // MARK: - Positioning

    private func centerOnScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let originX = screenFrame.midX - panelSize.width / 2
        let originY = screenFrame.midY - panelSize.height / 2 + screenFrame.height * 0.1
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}
