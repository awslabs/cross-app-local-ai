import SwiftUI

/// The error state of the overlay: error message with retry and dismiss actions.
struct OverlayErrorView: View {
    let message: String
    let suggestedAction: String?
    var onDismiss: () -> Void
    var onRetry: (() -> Void)?

    @Environment(\.overlayFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: OverlayMetrics.spacing(scale: fontScale)) {
            headerRow

            Text(message)
                .font(.overlayError(scale: fontScale))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(OverlayMetrics.fieldPadding(scale: fontScale))
                .background(
                    RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                        .fill(Color.qgDestructive.opacity(0.1))
                )

            if let action = suggestedAction {
                Label(action, systemImage: "lightbulb")
                    .font(.overlayCaption(scale: fontScale))
                    .foregroundStyle(.secondary)
            }

            buttonRow
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Color.qgDestructive)
            Text("Error")
                .font(.overlayHeading(scale: fontScale))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private var buttonRow: some View {
        HStack {
            Button("Dismiss") {
                onDismiss()
            }
            .buttonStyle(QGSecondaryButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            if let retry = onRetry {
                Button("Retry") {
                    retry()
                }
                .buttonStyle(QGPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}

// MARK: - Previews

#Preview("With Retry") {
    OverlayErrorView(
        message: "Network error: Connection timed out",
        suggestedAction: "Check your internet connection",
        onDismiss: {},
        onRetry: {}
    )
    .overlayCard()
    .padding()
}

#Preview("No Retry") {
    OverlayErrorView(
        message: "Content was filtered by safety settings",
        suggestedAction: nil,
        onDismiss: {}
    )
    .overlayCard()
    .padding()
}
