import SwiftUI

/// The approval state of the overlay: generated text display with accept/reject/refine actions.
struct OverlayApprovalView: View {
    @Bindable var appState: AppState
    let explainMode: Bool
    var onAccept: () -> Void
    var onReject: () -> Void
    var onRefine: (String) -> Void

    @Environment(\.overlayFontScale) private var fontScale
    @State private var refinementText = ""
    @State private var textToRefine = ""
    @FocusState private var isRefinementFocused: Bool

    private var isRefining: Bool {
        get { appState.isRefining }
        nonmutating set { appState.isRefining = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OverlayMetrics.spacing(scale: fontScale)) {
            headerRow

            ScrollView {
                Text(isRefining ? textToRefine : appState.generatedText)
                    .font(.overlayOutput(scale: fontScale))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OverlayMetrics.fieldPadding(scale: fontScale))
            }
            .frame(maxHeight: isRefining ? 120 : OverlayMetrics.panelMaxHeight(scale: fontScale) - 100)
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                    .fill(Color.fieldBackground)
            )

            if isRefining {
                refinementField
            }

            buttonRow
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            Image(systemName: explainMode ? "lightbulb" : "checkmark.circle")
                .foregroundStyle(explainMode ? Color.qgAccent : Color.qgSuccess)
            Text(explainMode ? "Explanation" : "Review")
                .font(.overlayHeading(scale: fontScale))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private var refinementField: some View {
        TextField("What should be different?", text: $refinementText, axis: .vertical)
            .font(.overlayBody(scale: fontScale))
            .textFieldStyle(.plain)
            .lineLimit(1 ... 4)
            .padding(OverlayMetrics.fieldPadding(scale: fontScale))
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                    .fill(Color.fieldBackground)
            )
            .focused($isRefinementFocused)
            .onSubmit {
                submitRefinement()
            }
    }

    private var buttonRow: some View {
        HStack {
            if !explainMode {
                Button("Reject") {
                    onReject()
                }
                .buttonStyle(QGDestructiveButtonStyle())
            }

            if isRefining {
                Button("Send") {
                    submitRefinement()
                }
                .buttonStyle(QGPrimaryButtonStyle(isEnabled: !refinementText.isEmpty))
                .disabled(refinementText.isEmpty)
            } else {
                Button("Refine") {
                    textToRefine = appState.generatedText
                    isRefining = true
                    isRefinementFocused = true
                }
                .buttonStyle(QGSecondaryButtonStyle())
            }

            Spacer()

            if explainMode {
                Button("Dismiss") {
                    onReject()
                }
                .buttonStyle(QGPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                Button("Insert") {
                    onAccept()
                }
                .buttonStyle(QGPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func submitRefinement() {
        let trimmed = refinementText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        refinementText = ""
        isRefining = false
        onRefine(trimmed)
    }
}

// MARK: - Previews

#Preview("Short Text") {
    let state = AppState()
    state.generatedText = "This is a short generated response."
    return OverlayApprovalView(
        appState: state,
        explainMode: false,
        onAccept: {},
        onReject: {},
        onRefine: { _ in }
    )
    .overlayCard()
    .padding()
}

#Preview("Long Text") {
    let state = AppState()
    state.generatedText = String(repeating: "Generated text that spans multiple lines. ", count: 20)
    return OverlayApprovalView(
        appState: state,
        explainMode: false,
        onAccept: {},
        onReject: {},
        onRefine: { _ in }
    )
    .overlayCard()
    .padding()
}

#Preview("Explain Mode") {
    let state = AppState()
    state.generatedText = "This code defines a recursive Fibonacci function that returns the nth number."
    return OverlayApprovalView(
        appState: state,
        explainMode: true,
        onAccept: {},
        onReject: {},
        onRefine: { _ in }
    )
    .overlayCard()
    .padding()
}
