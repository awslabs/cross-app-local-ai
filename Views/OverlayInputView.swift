import SwiftUI

/// The input state of the overlay: prompt field, context badge, and submit/cancel buttons.
struct OverlayInputView: View {
    @Bindable var appState: AppState
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @Environment(\.overlayFontScale) private var fontScale
    @FocusState private var isPromptFocused: Bool
    @State private var chipWidths: [String: CGFloat] = [:]
    @State private var availableWidth: CGFloat = 0

    private var promptMode: PromptMode {
        appState.selectedText != nil ? .replace : .insert
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OverlayMetrics.spacing(scale: fontScale)) {
            headerRow

            if let selected = appState.selectedText, !selected.isEmpty {
                selectedTextPreview(selected)
            }

            if !appState.quickPrompts.prompts.isEmpty {
                quickPromptChips
            }

            promptField

            buttonRow
        }
        .onAppear {
            isPromptFocused = true
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            Image(systemName: promptMode == .replace ? "pencil" : "plus.bubble")
                .foregroundStyle(Color.qgAccent)
            Text(promptMode == .replace ? "Rewrite" : "Generate")
                .font(.overlayHeading(scale: fontScale))
                .foregroundStyle(.primary)

            Spacer()

            Text(appState.contextType.rawValue)
                .font(.overlayCaption(scale: fontScale))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.fieldBackground)
                )
        }
    }

    private static let moreButtonWidth: CGFloat = 70

    private var visibleChipCount: Int {
        let prompts = appState.quickPrompts.prompts
        guard availableWidth > 0 else { return prompts.count }

        let spacing = OverlayMetrics.smallSpacing(scale: fontScale)
        var used: CGFloat = 0
        for (index, qp) in prompts.enumerated() {
            let chipWidth = chipWidths[qp.id] ?? 0
            guard chipWidth > 0 else { continue }
            let needed = (index > 0 ? spacing : 0) + chipWidth
            let hasMore = index < prompts.count - 1
            let reserveForMore = hasMore ? spacing + Self.moreButtonWidth : 0
            if used + needed + reserveForMore > availableWidth {
                return index
            }
            used += needed
        }
        return prompts.count
    }

    private var quickPromptChips: some View {
        let prompts = appState.quickPrompts.prompts
        let visible = visibleChipCount
        let hasOverflow = visible < prompts.count

        return ZStack(alignment: .leading) {
            chipMeasuringLayer(prompts: prompts)

            GeometryReader { geo in
                Color.clear.onAppear { availableWidth = geo.size.width }
            }
            .frame(height: 0)

            HStack(spacing: OverlayMetrics.smallSpacing(scale: fontScale)) {
                ForEach(prompts.prefix(visible)) { qp in
                    chipButton(qp)
                }
                if hasOverflow {
                    overflowMenu(Array(prompts.dropFirst(visible)))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chipMeasuringLayer(prompts: [QuickPrompt]) -> some View {
        HStack(spacing: 0) {
            ForEach(prompts) { qp in
                chipLabel(qp.name)
                    .fixedSize()
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: ChipWidthPreferenceKey.self,
                            value: [qp.id: geo.size.width]
                        )
                    })
            }
        }
        .hidden()
        .frame(height: 0)
        .onPreferenceChange(ChipWidthPreferenceKey.self) { chipWidths = $0 }
    }

    private func chipButton(_ qp: QuickPrompt) -> some View {
        Button {
            appState.promptText = qp.prompt
            onSubmit(qp.prompt)
        } label: {
            chipLabel(qp.name)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ name: String) -> some View {
        Text(name)
            .font(.overlayCaption(scale: fontScale))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.fieldBackground))
            .overlay(Capsule().stroke(Color.overlayBorder, lineWidth: 0.5))
    }

    private func overflowMenu(_ prompts: [QuickPrompt]) -> some View {
        Menu {
            ForEach(prompts) { qp in
                Button(qp.name) {
                    appState.promptText = qp.prompt
                    onSubmit(qp.prompt)
                }
            }
        } label: {
            Text("More")
                .font(.overlayCaption(scale: fontScale))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.fieldBackground))
                .overlay(Capsule().stroke(Color.overlayBorder, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func selectedTextPreview(_ text: String) -> some View {
        let displayText = text.count > 200
            ? String(text.prefix(200)) + "..."
            : text

        return Text(displayText)
            .font(.overlayCaption(scale: fontScale))
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .padding(OverlayMetrics.fieldPadding(scale: fontScale))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                    .fill(Color.fieldBackground)
            )
    }

    private var promptField: some View {
        TextField("What would you like to write?", text: $appState.promptText, axis: .vertical)
            .font(.overlayBody(scale: fontScale))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .lineLimit(1 ... 6)
            .padding(OverlayMetrics.fieldPadding(scale: fontScale))
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                    .fill(Color.fieldBackground)
            )
            .focused($isPromptFocused)
            .onSubmit {
                submitIfValid()
            }
    }

    private var primaryButtonLabel: String {
        promptMode == .replace ? "Rewrite" : "Generate"
    }

    private var buttonRow: some View {
        HStack {
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(QGSecondaryButtonStyle())

            Spacer()

            if promptMode == .replace {
                Button("Explain") {
                    submitExplain()
                }
                .buttonStyle(QGSecondaryButtonStyle())
            }

            Button(primaryButtonLabel) {
                submitIfValid()
            }
            .buttonStyle(QGPrimaryButtonStyle(isEnabled: !appState.promptText.isEmpty))
            .disabled(appState.promptText.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func submitIfValid() {
        let trimmed = appState.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.explainMode = false
        onSubmit(trimmed)
    }

    private func submitExplain() {
        appState.explainMode = true
        let prompt = appState.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let explainPrompt = prompt.isEmpty ? "Explain this text" : prompt
        appState.promptText = explainPrompt
        onSubmit(explainPrompt)
    }
}

// MARK: - ChipWidthPreferenceKey

private struct ChipWidthPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Previews

#Preview("Insert Mode") {
    let state = AppState()
    OverlayInputView(
        appState: state,
        onSubmit: { _ in },
        onCancel: {}
    )
    .overlayCard()
    .padding()
}

#Preview("Replace Mode") {
    let state = AppState()
    state.selectedText = "The quick brown fox jumps over the lazy dog."
    state.contextType = .email
    return OverlayInputView(
        appState: state,
        onSubmit: { _ in },
        onCancel: {}
    )
    .overlayCard()
    .padding()
}

#Preview("With Quick Prompts") {
    let state = AppState()
    state.selectedText = "Some text to transform."
    return OverlayInputView(
        appState: state,
        onSubmit: { _ in },
        onCancel: {}
    )
    .overlayCard()
    .padding()
}
