import SwiftUI

/// Root container that switches between overlay sub-views based on `OverlayState`.
///
/// Hosted inside the `OverlayPanel` via `NSHostingView`. Reads `AppState`
/// and dispatches user actions back through closures.
struct OverlayContainerView: View {
    @Bindable var appState: AppState
    var onSubmit: (String) -> Void
    var onCancel: () -> Void
    var onAccept: () -> Void
    var onReject: () -> Void
    var onRefine: (String) -> Void

    var body: some View {
        Group {
            switch appState.overlayState {
            case .input:
                OverlayInputView(
                    appState: appState,
                    onSubmit: onSubmit,
                    onCancel: onCancel
                )

            case .generating:
                OverlayGeneratingView(
                    generatedText: appState.generatedText,
                    previousText: appState.previousGeneratedText,
                    onCancel: onCancel
                )

            case .approval:
                OverlayApprovalView(
                    appState: appState,
                    explainMode: appState.explainMode,
                    onAccept: onAccept,
                    onReject: onReject,
                    onRefine: onRefine
                )

            case let .error(message):
                OverlayErrorView(
                    message: message,
                    suggestedAction: appState.errorSuggestedAction,
                    onDismiss: onCancel
                )
            }
        }
        .overlayCard()
        .environment(\.overlayFontScale, appState.config.behavior.fontScale)
        .animation(.easeInOut(duration: 0.15), value: appState.overlayState)
    }
}

// MARK: - Previews

#Preview("Input") {
    let state = AppState()
    state.overlayState = .input
    return OverlayContainerView(
        appState: state,
        onSubmit: { _ in },
        onCancel: {},
        onAccept: {},
        onReject: {},
        onRefine: { _ in }
    )
    .padding()
}

#Preview("Generating") {
    let state = AppState()
    state.overlayState = .generating
    state.generatedText = "Streaming tokens appear here..."
    return OverlayContainerView(
        appState: state,
        onSubmit: { _ in },
        onCancel: {},
        onAccept: {},
        onReject: {},
        onRefine: { _ in }
    )
    .padding()
}

#Preview("Approval") {
    let state = AppState()
    state.overlayState = .approval
    state.generatedText = "Here is the fully generated text for review."
    return OverlayContainerView(
        appState: state,
        onSubmit: { _ in },
        onCancel: {},
        onAccept: {},
        onReject: {},
        onRefine: { _ in }
    )
    .padding()
}

#Preview("Error") {
    let state = AppState()
    state.overlayState = .error("Request timed out after 30 seconds")
    state.errorSuggestedAction = "Try again or increase timeout in Settings"
    return OverlayContainerView(
        appState: state,
        onSubmit: { _ in },
        onCancel: {},
        onAccept: {},
        onReject: {},
        onRefine: { _ in }
    )
    .padding()
}
