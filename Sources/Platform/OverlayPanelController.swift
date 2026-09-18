import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.aws.fastlang", category: "overlay")

/// Manages the lifecycle of the floating overlay panel.
///
/// Creates the `OverlayPanel`, hosts `OverlayContainerView` inside it via
/// `NSHostingView`, and exposes `show()` / `hide()` / `toggle()` to control
/// visibility. The panel is centered on the active screen each time it appears.
/// An observation loop watches `AppState` properties so the panel automatically
/// resizes when the overlay state or generated text changes.
@MainActor
final class OverlayPanelController {
    private let panel: OverlayPanel
    private let appState: AppState
    private let hostingView: NSHostingView<OverlayContainerView>
    private var sttPanel: NSPanel?
    private var sttErrorDismissTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var spaceChangeObserver: NSObjectProtocol?
    private let onDismiss: () -> Void

    /// Creates the overlay panel controller and hosts the SwiftUI overlay inside it.
    ///
    /// - Parameters:
    ///   - appState: The shared app state driving the overlay views.
    ///   - onSubmit: Called when the user submits a prompt.
    ///   - onCancel: Called when the user cancels.
    ///   - onAccept: Called when the user accepts generated text.
    ///   - onReject: Called when the user rejects generated text.
    ///   - onRefine: Called when the user requests a refinement.
    ///   - onDismiss: Called when a dismissal trigger fires (escape, space change, focus loss).
    init(
        appState: AppState,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onAccept: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onRefine: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.appState = appState
        self.panel = OverlayPanel()
        self.onDismiss = onDismiss

        let containerView = OverlayContainerView(
            appState: appState,
            onSubmit: onSubmit,
            onCancel: onCancel,
            onAccept: onAccept,
            onReject: onReject,
            onRefine: onRefine
        )
        let hosting = NSHostingView(rootView: containerView)
        self.hostingView = hosting

        panel.contentView = hosting
        panel.onClose = { [weak self] in
            self?.onDismiss()
        }
        let scale = appState.config.behavior.fontScale
        panel.contentMinSize = NSSize(
            width: OverlayMetrics.panelWidth(scale: scale),
            height: OverlayMetrics.panelMinHeight(scale: scale)
        )
        panel.contentMaxSize = NSSize(
            width: OverlayMetrics.panelWidth(scale: scale),
            height: OverlayMetrics.panelMaxHeight(scale: scale)
        )

        setupDismissalHandlers()
        startObservingState()
        logger.debug("OverlayPanelController initialized")
    }

    /// Shows the overlay panel centered on the active screen.
    ///
    /// State management (`isOverlayVisible`, `overlayState`, etc.) is handled
    /// by `AppState`; this method only controls the NSPanel.
    func show() {
        sizeToContent()
        centerOnScreen()
        panel.orderFrontRegardless()
        panel.makeKey()
        logger.info("Overlay panel shown")
    }

    /// Hides the overlay panel.
    ///
    /// State management is handled by `AppState`; this method only
    /// dismisses the NSPanel.
    func hide() {
        panel.orderOut(nil)
        logger.info("Overlay panel hidden")
    }

    // MARK: - Dismissal Handlers

    private func setupDismissalHandlers() {
        setupEscapeMonitor()
        setupSpaceChangeObserver()
        setupFocusLossHandler()
    }

    private func setupEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 53,
                  self.appState.isOverlayVisible,
                  self.appState.config.behavior.dismissOnEscape
            else {
                return event
            }
            self.onDismiss()
            return nil
        }
    }

    private func setupSpaceChangeObserver() {
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.appState.isOverlayVisible,
                      self.appState.config.behavior.dismissOnSpaceChange
                else {
                    return
                }
                self.onDismiss()
            }
        }
    }

    private func setupFocusLossHandler() {
        panel.onResignKey = { [weak self] in
            guard let self,
                  self.appState.isOverlayVisible,
                  self.appState.config.behavior.dismissOnFocusLoss
            else {
                return
            }
            self.onDismiss()
        }
    }

    // MARK: - Dynamic Sizing

    /// Resizes the panel to match its SwiftUI content's ideal size.
    private func sizeToContent() {
        let scale = appState.config.behavior.fontScale
        let scaledWidth = OverlayMetrics.panelWidth(scale: scale)
        let fitting = hostingView.fittingSize
        let height = min(
            max(fitting.height, OverlayMetrics.panelMinHeight(scale: scale)),
            OverlayMetrics.panelMaxHeight(scale: scale)
        )
        let newSize = NSSize(width: scaledWidth, height: height)

        panel.contentMinSize = NSSize(
            width: scaledWidth,
            height: OverlayMetrics.panelMinHeight(scale: scale)
        )
        panel.contentMaxSize = NSSize(
            width: scaledWidth,
            height: OverlayMetrics.panelMaxHeight(scale: scale)
        )

        guard abs(panel.frame.width - newSize.width) > 1
            || abs(panel.frame.height - newSize.height) > 1
        else { return }
        panel.setContentSize(newSize)
    }

    /// Watches `AppState` properties that affect overlay layout and resizes the
    /// panel whenever they change.
    private func startObservingState() {
        scheduleObservation()
    }

    private func scheduleObservation() {
        withObservationTracking {
            // Access the properties whose changes should trigger a resize.
            _ = self.appState.overlayState
            _ = self.appState.generatedText
            _ = self.appState.isGenerating
            _ = self.appState.isRefining
            _ = self.appState.promptText
            _ = self.appState.config.behavior.fontScale
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sizeToContent()
                self.scheduleObservation()
            }
        }
    }

    // MARK: - STT Indicator

    /// Shows a floating recording indicator near the top of the screen.
    func showSttIndicator() {
        showSttPanel(mode: .recording)
    }

    /// Transitions the floating indicator to the transcribing state.
    ///
    /// If the recording panel is already visible it is replaced in-place;
    /// otherwise a new panel is created.
    func showSttTranscribingIndicator() {
        showSttPanel(mode: .transcribing)
    }

    /// Hides the STT indicator regardless of its current mode.
    func hideSttIndicator() {
        sttPanel?.orderOut(nil)
        sttPanel = nil
    }

    /// Shows a floating STT notice — a red error or a neutral status — with a
    /// message, auto-dismissing after a delay long enough to read it.
    ///
    /// - Parameter notice: The message and its severity (`.error` or `.info`).
    func showSttNotice(_ notice: SttIndicatorNotice) {
        let mode: SttIndicatorMode = switch notice.kind {
        case .error: .error(message: notice.text)
        case .info: .info(message: notice.text)
        }
        showSttPanel(mode: mode)

        sttErrorDismissTask?.cancel()
        sttErrorDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.hideSttIndicator()
        }
    }

    private func showSttPanel(mode: SttIndicatorMode) {
        // Tear down existing panel so we get a fresh view for the new mode.
        sttPanel?.orderOut(nil)
        sttPanel = nil

        // Size the panel to the SwiftUI content's ideal size so multi-line
        // error/info messages aren't clipped. `fittingSize` reflects the
        // view's wrapped dimensions (the message caps at its own maxWidth).
        let indicatorHostingView = NSHostingView(rootView: SttIndicatorView(mode: mode))
        let fitting = indicatorHostingView.fittingSize
        let contentWidth = max(fitting.width, 120)
        let contentHeight = max(fitting.height, 36)

        let indicatorPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        indicatorPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        indicatorPanel.hidesOnDeactivate = false
        indicatorPanel.isFloatingPanel = true
        indicatorPanel.level = OverlayPanel.overlayLevel
        indicatorPanel.backgroundColor = .clear
        indicatorPanel.isOpaque = false
        indicatorPanel.titlebarAppearsTransparent = true
        indicatorPanel.titleVisibility = .hidden

        indicatorPanel.contentView = indicatorHostingView

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            // Anchor by the TOP edge so every pill — recording, transcribing,
            // and the taller multi-line error/info pills — appears in the same
            // place near the top of the screen. (Origin is bottom-left, so a
            // taller pill needs a lower origin to keep the top fixed.)
            let topInset: CGFloat = 24
            let x = screenFrame.midX - contentWidth / 2
            let y = screenFrame.maxY - topInset - contentHeight
            indicatorPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        indicatorPanel.orderFront(nil)
        sttPanel = indicatorPanel
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
