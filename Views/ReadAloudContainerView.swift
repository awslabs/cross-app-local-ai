import SwiftUI

// MARK: - ReadAloudContainerView

/// Displays captured text with word-by-word highlighting and playback controls.
///
/// The top section shows scrollable text where the currently-spoken word is
/// highlighted. The bottom toolbar provides play/pause, stop, speed controls,
/// and a close button. Tapping any word seeks playback to that position.
struct ReadAloudContainerView: View {
    let appState: AppState
    let onPlay: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onSeek: (Int) -> Void
    let onRateChange: (Float) -> Void
    let onSummarize: () -> Void
    let onRestoreOriginal: () -> Void
    let onDismiss: () -> Void

    @Environment(\.overlayFontScale) private var fontScale

    var body: some View {
        VStack(spacing: OverlayMetrics.spacing(scale: fontScale)) {
            textArea
                // Bounded, not `.infinity`. `ReadAloudPanelController.sizeToContent()`
                // sizes the NSPanel from `NSHostingView.fittingSize` -- SwiftUI's
                // unconstrained ideal size. A descendant requesting infinite height
                // makes that ideal size effectively unbounded, so the panel's
                // `min(fitting.height, panelMaxHeight)` clamp always picks
                // `panelMaxHeight`, regardless of how much text there actually is.
                // Capping here keeps `fittingSize` finite and reflective of real
                // content, matching the pattern in OverlayGeneratingView and
                // OverlayApprovalView, which bound their own scroll areas the same
                // way for the same reason.
                .frame(maxHeight: ReadAloudMetrics.panelMaxHeight(scale: fontScale) - 140)

            if let errorMessage = appState.readAloudErrorMessage {
                errorBanner(message: errorMessage)
            }

            Divider()
                .background(Color.overlayBorder)

            toolbar
        }
        .overlayCard(width: ReadAloudMetrics.panelWidth(scale: fontScale))
        .environment(\.overlayFontScale, fontScale)
    }

    // MARK: - Text Area

    private var textArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                paragraphStack
                    .font(.overlayOutput(scale: fontScale))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(OverlayMetrics.fieldPadding(scale: fontScale))
            }
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                    .fill(Color.fieldBackground)
            )
            .environment(\.openURL, OpenURLAction { [onSeek] url in
                if url.scheme == "seek",
                   let offset = Int(url.host() ?? "") {
                    onSeek(offset)
                }
                return .handled
            })
            .onChange(of: appState.readAloudHighlightRange) { _, newRange in
                guard let range = newRange else { return }
                let fullText = appState.readAloudText ?? ""
                let paragraphs = HighlightedTextBuilder.splitParagraphs(fullText)
                let targetID = HighlightedTextBuilder.paragraphID(
                    containing: range.lowerBound,
                    in: paragraphs
                )
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(targetID, anchor: .top)
                }
            }
        }
    }

    private var paragraphStack: some View {
        let fullText = appState.readAloudText ?? ""
        let paragraphs = HighlightedTextBuilder.splitParagraphs(fullText)
        let allWords = HighlightedTextBuilder.tokenize(fullText)
        let highlight = appState.readAloudHighlightRange

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(paragraphs, id: \.offset) { paragraph in
                let wordsInParagraph = allWords.filter { word in
                    word.offset >= paragraph.offset
                        && word.offset < paragraph.offset + paragraph.text.count
                }
                let attributed = HighlightedTextBuilder.buildAttributedString(
                    sourceText: paragraph.text,
                    words: wordsInParagraph,
                    highlightRange: highlight,
                    paragraphOffset: paragraph.offset
                )
                Text(attributed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(paragraph.offset)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: OverlayMetrics.spacing(scale: fontScale)) {
            controlsBlock
            Spacer(minLength: 0)
            closeButton
        }
    }

    /// All playback controls (transport, speed, summarize) in a single
    /// shared card, separated internally by dividers.
    ///
    /// These used to be three independent cards, each sized to its own
    /// content -- transport's icon pair, speed's slider, and summarize's
    /// button or status text landed on visibly different widths and
    /// heights (the `.failed` state alone grows to two lines). One shared
    /// card with internal dividers reads as a single toolbar instead of
    /// mismatched chips.
    private var controlsBlock: some View {
        HStack(alignment: .top, spacing: OverlayMetrics.spacing(scale: fontScale)) {
            transportGroup

            controlDivider

            speedGroup

            if appState.config.tts.preprocessing == .llm {
                controlDivider
                summarizeGroup
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                .fill(Color.fieldBackground)
        )
    }

    private var controlDivider: some View {
        // A bare `Divider()` already fills the cross axis of its containing
        // `HStack` on its own -- an explicit `.frame(maxHeight: .infinity)`
        // requests infinite height, and that request propagates up through
        // `controlsBlock` and `toolbar` into the outer `VStack`, where it
        // competes with `textArea`'s own infinite frame and balloons the
        // whole toolbar row to roughly half the panel.
        Divider()
    }

    private var transportGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Playback")
                .font(.overlayCaption(scale: fontScale))
                .foregroundStyle(.secondary)

            HStack(spacing: OverlayMetrics.smallSpacing(scale: fontScale)) {
                Button(action: handlePlayPause) {
                    Image(systemName: playPauseIcon)
                        .font(.system(size: 16 * fontScale.multiplier))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(QGPrimaryButtonStyle())
                .help(playPauseLabel)

                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14 * fontScale.multiplier))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(QGSecondaryButtonStyle())
                .help("Stop")
                .disabled(appState.readAloudPlaybackState == .idle)
            }
        }
    }

    private var speedGroup: some View {
        VStack(spacing: 4) {
            Text("Speed")
                .font(.overlayCaption(scale: fontScale))
                .foregroundStyle(.secondary)

            HStack(spacing: OverlayMetrics.smallSpacing(scale: fontScale)) {
                Slider(
                    value: Binding(
                        get: { Double(appState.readAloudRate) },
                        set: { onRateChange(Float($0)) }
                    ),
                    in: 0.1 ... 0.9,
                    step: 0.05
                )
                .frame(width: 140 * fontScale.multiplier)

                Text(speedLabel)
                    .font(.overlayCaption(scale: fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .leading)
            }
        }
    }

    // MARK: - Summarize

    private var summarizeGroup: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Summary")
                .font(.overlayCaption(scale: fontScale))
                .foregroundStyle(.secondary)

            summarizeContent
        }
    }

    @ViewBuilder private var summarizeContent: some View {
        switch appState.readAloudRendition {
        case .summarized:
            Button(action: onRestoreOriginal) {
                Label("Restore Original", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12 * fontScale.multiplier))
            }
            .buttonStyle(QGSecondaryButtonStyle())
            .help("Restore the original text")

        case .original:
            switch appState.readAloudSummarizeState {
            case .idle:
                Button(action: onSummarize) {
                    Label("Summarize", systemImage: "text.redaction")
                        .font(.system(size: 12 * fontScale.multiplier))
                }
                .buttonStyle(QGSecondaryButtonStyle())
                .help("Summarize with the LLM")

            case let .inProgress(completed, total):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(total > 0 ? "Summarizing \(completed)/\(total)…" : "Summarizing…")
                        .font(.overlayCaption(scale: fontScale))
                        .foregroundStyle(.secondary)
                }

            case let .failed(message):
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: onSummarize) {
                        Label("Retry Summarize", systemImage: "arrow.clockwise")
                            .font(.system(size: 12 * fontScale.multiplier))
                    }
                    .buttonStyle(QGSecondaryButtonStyle())
                    Text(message)
                        .font(.overlayCaption(scale: fontScale))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 12 * fontScale.multiplier, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(QGSecondaryButtonStyle())
        .help("Close")
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.overlayCaption(scale: fontScale))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: OverlayMetrics.fieldCornerRadius)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private var playPauseIcon: String {
        switch appState.readAloudPlaybackState {
        case .idle: "play.fill"
        case .playing: "pause.fill"
        case .paused: "play.fill"
        }
    }

    private var playPauseLabel: String {
        switch appState.readAloudPlaybackState {
        case .idle: "Play"
        case .playing: "Pause"
        case .paused: "Resume"
        }
    }

    private var speedLabel: String {
        let mapped = 0.25 + Double(appState.readAloudRate) * 1.75
        return String(format: "%.1fx", mapped)
    }

    private func handlePlayPause() {
        switch appState.readAloudPlaybackState {
        case .idle: onPlay()
        case .playing: onPause()
        case .paused: onResume()
        }
    }
}

// MARK: - HighlightedTextBuilder

/// Builds an `AttributedString` with per-word styling for read-aloud highlighting.
///
/// Each word is styled based on its position relative to the current highlight
/// range: the active word gets a white foreground and an accent background, past
/// words use the primary foreground, and future words use a muted secondary
/// foreground. Font weight is intentionally kept uniform across all words so that
/// advancing the highlight never causes line reflow.
/// Words carry a `seek://` link so tapping invokes the seek action.
enum HighlightedTextBuilder {

    struct WordToken {
        let text: String
        /// Character offset in the full source text.
        let offset: Int
    }

    struct Paragraph {
        let text: String
        /// Character offset where this paragraph begins in the full source text.
        let offset: Int
    }

    // MARK: - Tokenization

    static func tokenize(_ text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var currentIndex = text.startIndex

        while currentIndex < text.endIndex {
            while currentIndex < text.endIndex, text[currentIndex].isWhitespace {
                currentIndex = text.index(after: currentIndex)
            }
            guard currentIndex < text.endIndex else { break }

            let wordStart = currentIndex
            while currentIndex < text.endIndex, !text[currentIndex].isWhitespace {
                currentIndex = text.index(after: currentIndex)
            }

            let offset = text.distance(from: text.startIndex, to: wordStart)
            let word = String(text[wordStart ..< currentIndex])
            tokens.append(WordToken(text: word, offset: offset))
        }

        return tokens
    }

    // MARK: - Paragraph Splitting

    /// Splits text into paragraphs on newline boundaries, preserving trailing
    /// newlines within each paragraph so the original whitespace is retained.
    static func splitParagraphs(_ text: String) -> [Paragraph] {
        guard !text.isEmpty else { return [] }

        var paragraphs: [Paragraph] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            let paragraphStart = searchStart

            // Find the next newline (or end of string).
            if let newlineRange = text.range(of: "\n", range: searchStart ..< text.endIndex) {
                let paragraphEnd = text.index(after: newlineRange.lowerBound)
                let offset = text.distance(from: text.startIndex, to: paragraphStart)
                paragraphs.append(Paragraph(
                    text: String(text[paragraphStart ..< paragraphEnd]),
                    offset: offset
                ))
                searchStart = paragraphEnd
            } else {
                let offset = text.distance(from: text.startIndex, to: paragraphStart)
                paragraphs.append(Paragraph(
                    text: String(text[paragraphStart ..< text.endIndex]),
                    offset: offset
                ))
                searchStart = text.endIndex
            }
        }

        return paragraphs
    }

    /// Returns the paragraph offset that contains the given character position.
    static func paragraphID(containing charOffset: Int, in paragraphs: [Paragraph]) -> Int {
        for paragraph in paragraphs.reversed() where charOffset >= paragraph.offset {
            return paragraph.offset
        }
        return paragraphs.first?.offset ?? 0
    }

    // MARK: - Attributed String

    /// Builds an `AttributedString` for a single paragraph.
    ///
    /// - Parameters:
    ///   - sourceText: The paragraph's text content.
    ///   - words: Words whose offsets fall within this paragraph (global offsets).
    ///   - highlightRange: The currently highlighted range (global offsets).
    ///   - paragraphOffset: The paragraph's starting offset in the full text.
    static func buildAttributedString(
        sourceText: String,
        words: [WordToken],
        highlightRange: Range<Int>?,
        paragraphOffset: Int
    ) -> AttributedString {
        var result = AttributedString()
        var lastEnd = sourceText.startIndex

        for word in words {
            let localOffset = word.offset - paragraphOffset
            guard localOffset >= 0, localOffset < sourceText.count else { continue }

            let wordStart = sourceText.index(sourceText.startIndex, offsetBy: localOffset)
            let wordEnd = sourceText.index(
                wordStart,
                offsetBy: word.text.count,
                limitedBy: sourceText.endIndex
            ) ?? sourceText.endIndex

            if lastEnd < wordStart {
                let gap = String(sourceText[lastEnd ..< wordStart])
                result.append(AttributedString(gap))
            }

            var chunk = AttributedString(word.text)
            let isHighlighted = highlightRange.map {
                word.offset >= $0.lowerBound && word.offset < $0.upperBound
            } ?? false
            let isPast = highlightRange.map { word.offset < $0.lowerBound } ?? false

            if isHighlighted {
                chunk.foregroundColor = .white
                chunk.backgroundColor = .accentColor.opacity(0.6)
            } else if isPast {
                chunk.foregroundColor = .primary
            } else {
                chunk.foregroundColor = .secondary
            }

            if let seekURL = URL(string: "seek://\(word.offset)") {
                chunk.link = seekURL
            }

            result.append(chunk)
            lastEnd = wordEnd
        }

        if lastEnd < sourceText.endIndex {
            let trailing = String(sourceText[lastEnd ..< sourceText.endIndex])
            result.append(AttributedString(trailing))
        }

        return result
    }
}

// MARK: - ReadAloud Metrics

enum ReadAloudMetrics {
    static func panelWidth(scale: FontScale = .medium) -> CGFloat {
        900 * scale.multiplier
    }

    static func panelMinHeight(scale: FontScale = .medium) -> CGFloat {
        400 * scale.multiplier
    }

    static func panelMaxHeight(scale: FontScale = .medium) -> CGFloat {
        650 * scale.multiplier
    }
}
