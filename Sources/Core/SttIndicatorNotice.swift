import Foundation

/// A message to surface in the floating STT indicator pill, tagged with a
/// severity that controls how the pill is styled.
struct SttIndicatorNotice: Equatable, Sendable {
    /// Visual severity of an STT indicator notice.
    enum Kind: Sendable {
        /// A genuine failure (e.g. injection failed, missing Accessibility
        /// permission). Styled as a red error pill.
        case error
        /// A transient, non-failure status (e.g. the STT model still warming
        /// up after launch). Styled neutrally so it doesn't read as an error.
        case info
    }

    let text: String
    let kind: Kind
}
