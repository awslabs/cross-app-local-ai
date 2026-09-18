import SwiftUI

/// Visual mode for the floating STT indicator capsule.
enum SttIndicatorMode {
    /// Orange pulsing dot — audio is being captured.
    case recording
    /// Accent-colored spinner — audio is being transcribed.
    case transcribing
    /// Red error capsule — injection failed (e.g. missing Accessibility permission).
    case error(message: String)
    /// Neutral capsule — a transient, non-failure status such as the STT
    /// model still warming up after launch.
    case info(message: String)
}

/// A floating indicator shown during push-to-talk recording or transcription.
struct SttIndicatorView: View {
    var mode: SttIndicatorMode = .recording

    @State private var isPulsing = false
    @State private var isSpinning = false

    /// Fixed width for the text-bearing pills (error/info) so long messages
    /// wrap to multiple lines within a predictable width. `nil` for the short
    /// recording/transcribing pills, which size to their content.
    private var pillFixedWidth: CGFloat? {
        switch mode {
        case .recording, .transcribing: nil
        case .error, .info: 340
        }
    }

    private var tintColor: Color {
        switch mode {
        case .recording: Color.qgWarning
        case .transcribing: Color.qgAccent
        case .error: Color.qgDestructive
        // Uses the same red as `.error` for now — the neutral secondary tint
        // was too faint to notice. Kept as a separate case so the styling can
        // diverge later without touching the notice-routing plumbing.
        case .info: Color.qgDestructive
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch mode {
            case .recording:
                Circle()
                    .fill(tintColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPulsing ? 1.3 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                        value: isPulsing
                    )

                Image(systemName: "mic.fill")
                    .foregroundStyle(tintColor)
                    .font(.system(size: 12, weight: .semibold))

                Text("Recording...")
                    .font(.overlayCaption())
                    .foregroundStyle(tintColor)

            case .transcribing:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(tintColor)
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(
                        .linear(duration: 1.0).repeatForever(autoreverses: false),
                        value: isSpinning
                    )

                Image(systemName: "waveform")
                    .foregroundStyle(tintColor)
                    .font(.system(size: 12, weight: .semibold))

                Text("Transcribing...")
                    .font(.overlayCaption())
                    .foregroundStyle(tintColor)

            case let .error(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(tintColor)
                    .font(.system(size: 12, weight: .semibold))

                Text(message)
                    .font(.overlayCaption())
                    .foregroundStyle(tintColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

            case let .info(message):
                Image(systemName: "hourglass")
                    .foregroundStyle(tintColor)
                    .font(.system(size: 12, weight: .semibold))

                Text(message)
                    .font(.overlayCaption())
                    .foregroundStyle(tintColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(width: pillFixedWidth)
        .background(
            Capsule()
                .fill(tintColor.opacity(0.15))
        )
        .onAppear {
            isPulsing = true
            isSpinning = true
        }
    }
}

#Preview("Recording") {
    SttIndicatorView(mode: .recording)
        .padding()
}

#Preview("Transcribing") {
    SttIndicatorView(mode: .transcribing)
        .padding()
}

#Preview("Error") {
    SttIndicatorView(mode: .error(message: "Accessibility permission required."))
        .padding()
}

#Preview("Info") {
    SttIndicatorView(mode: .info(message: "Speech recognition is still starting up."))
        .padding()
}
