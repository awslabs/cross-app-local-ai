import SwiftUI

// MARK: - Color Palette

extension Color {
    /// Semi-transparent dark background for the overlay panel.
    static let overlayBackground = Color.black.opacity(0.85)

    /// Subtle border color for overlay elements.
    static let overlayBorder = Color.white.opacity(0.15)

    /// Accent color used for primary actions and active states.
    static let qgAccent = Color.accentColor

    /// Muted text color for secondary labels and placeholders.
    static let qgSecondary = Color.secondary

    /// Destructive action color (reject, cancel).
    static let qgDestructive = Color.red

    /// Success/approve color.
    static let qgSuccess = Color.green

    /// Warning/recording indicator color.
    static let qgWarning = Color.orange

    /// Text field background within the overlay.
    static let fieldBackground = Color.white.opacity(0.08)
}

extension EnvironmentValues {
    /// The active font scale for overlay views.
    @Entry var overlayFontScale: FontScale = .medium
}

// MARK: - Typography

extension Font {
    /// Primary prompt input text.
    static func overlayBody(scale: FontScale = .medium) -> Font {
        .system(size: 14 * scale.multiplier, weight: .regular)
    }

    /// Section headers within the overlay.
    static func overlayHeading(scale: FontScale = .medium) -> Font {
        .system(size: 12 * scale.multiplier, weight: .semibold)
    }

    /// Small labels and context indicators.
    static func overlayCaption(scale: FontScale = .medium) -> Font {
        .system(size: 11 * scale.multiplier, weight: .regular)
    }

    /// Generated text display.
    static func overlayOutput(scale: FontScale = .medium) -> Font {
        .system(size: 13 * scale.multiplier, weight: .regular, design: .default)
    }

    /// Error messages.
    static func overlayError(scale: FontScale = .medium) -> Font {
        .system(size: 12 * scale.multiplier, weight: .medium)
    }

    /// Button label text.
    static func overlayButton(scale: FontScale = .medium) -> Font {
        .system(size: 12 * scale.multiplier, weight: .semibold)
    }
}

// MARK: - Dimensions

enum OverlayMetrics {
    static func panelWidth(scale: FontScale = .medium) -> CGFloat {
        640 * scale.multiplier
    }

    static func panelMinHeight(scale: FontScale = .medium) -> CGFloat {
        120 * scale.multiplier
    }

    static func panelMaxHeight(scale: FontScale = .medium) -> CGFloat {
        650 * scale.multiplier
    }

    static func panelPadding(scale: FontScale = .medium) -> CGFloat {
        16 * scale.multiplier
    }

    static func fieldPadding(scale: FontScale = .medium) -> CGFloat {
        10 * scale.multiplier
    }

    static func spacing(scale: FontScale = .medium) -> CGFloat {
        12 * scale.multiplier
    }

    static func smallSpacing(scale: FontScale = .medium) -> CGFloat {
        6 * scale.multiplier
    }

    static let panelCornerRadius: CGFloat = 12
    static let fieldCornerRadius: CGFloat = 8
    static let buttonCornerRadius: CGFloat = 6
}

// MARK: - Button Styles

/// Primary action button (Submit, Accept).
struct QGPrimaryButtonStyle: ButtonStyle {
    var isEnabled = true
    @Environment(\.overlayFontScale) private var fontScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.overlayButton(scale: fontScale))
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.5))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.buttonCornerRadius)
                    .fill(isEnabled ? Color.qgAccent : Color.qgAccent.opacity(0.4))
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// Secondary action button (Cancel, Reject, Refine).
struct QGSecondaryButtonStyle: ButtonStyle {
    @Environment(\.overlayFontScale) private var fontScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * fontScale.multiplier, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.buttonCornerRadius)
                    .fill(Color.fieldBackground)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

/// Destructive action button (Reject with emphasis).
struct QGDestructiveButtonStyle: ButtonStyle {
    @Environment(\.overlayFontScale) private var fontScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * fontScale.multiplier, weight: .medium))
            .foregroundStyle(Color.qgDestructive)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.buttonCornerRadius)
                    .fill(Color.qgDestructive.opacity(0.15))
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - View Modifiers

/// Applies the standard overlay card appearance (blurred material, subtle
/// border, rounded corners). The width is parameterized so longer-form
/// surfaces (e.g. the read-aloud panel) can share the same visual system
/// without introducing a second card style.
struct OverlayCardModifier: ViewModifier {
    @Environment(\.overlayFontScale) private var fontScale
    /// Override the default panel width. Defaults to the compact overlay
    /// width; read-aloud uses a wider value from `ReadAloudMetrics`.
    let widthOverride: CGFloat?

    init(widthOverride: CGFloat? = nil) {
        self.widthOverride = widthOverride
    }

    func body(content: Content) -> some View {
        content
            .padding(OverlayMetrics.panelPadding(scale: fontScale))
            .frame(width: widthOverride ?? OverlayMetrics.panelWidth(scale: fontScale))
            .background(
                RoundedRectangle(cornerRadius: OverlayMetrics.panelCornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: OverlayMetrics.panelCornerRadius)
                            .stroke(Color.overlayBorder, lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    /// Applies the standard overlay card styling with the compact width.
    func overlayCard() -> some View {
        modifier(OverlayCardModifier())
    }

    /// Applies the standard overlay card styling with a custom width.
    /// Use for wider surfaces like the read-aloud panel that share the
    /// same material / border treatment but need more horizontal room.
    func overlayCard(width: CGFloat) -> some View {
        modifier(OverlayCardModifier(widthOverride: width))
    }
}
