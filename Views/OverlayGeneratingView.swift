import SwiftUI

/// The generating state of the overlay: streaming text display with a cancel button.
struct OverlayGeneratingView: View {
    let generatedText: String
    let previousText: String
    var onCancel: () -> Void

    @Environment(\.overlayFontScale) private var fontScale

    var body: some View {
        VStack(alignment: .leading, spacing: OverlayMetrics.spacing(scale: fontScale)) {
            headerRow

            if !previousText.isEmpty, generatedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Previous response")
                        .font(.overlayCaption(scale: fontScale))
                        .foregroundStyle(.tertiary)
                    ScrollView {
                        Text(previousText)
                            .font(.overlayOutput(scale: fontScale))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(OverlayMetrics.fieldPadding(scale: fontScale))
                    }
                    .frame(maxHeight: 120)
                    .background(
                        RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                            .fill(Color.fieldBackground.opacity(0.5))
                    )
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading) {
                        Text(generatedText.isEmpty ? " " : generatedText)
                            .font(.overlayOutput(scale: fontScale))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .padding(OverlayMetrics.fieldPadding(scale: fontScale))
                }
                .frame(maxHeight: OverlayMetrics.panelMaxHeight(scale: fontScale) - 100)
                .background(
                    RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                        .fill(Color.fieldBackground)
                )
                .onChange(of: generatedText) {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Generating...")
                    .font(.overlayCaption(scale: fontScale))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(QGSecondaryButtonStyle())
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.qgAccent)
            Text("Generating")
                .font(.overlayHeading(scale: fontScale))
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}

// MARK: - Previews

#Preview("Streaming") {
    OverlayGeneratingView(
        generatedText: "Here is some generated text that is streaming in token by token...",
        previousText: "",
        onCancel: {}
    )
    .overlayCard()
    .padding()
}

#Preview("Empty") {
    OverlayGeneratingView(
        generatedText: "",
        previousText: "",
        onCancel: {}
    )
    .overlayCard()
    .padding()
}
