import Foundation

/// Describes the frontmost application at the time of hotkey activation.
struct AppContext: Equatable {
    var appName = ""
    var bundleId: String?
    var processName = ""
    var processId: UInt32 = 0
    var windowTitle = ""
    var windowBounds: WindowBounds?
}

/// Screen-space rectangle of the target application's key window.
struct WindowBounds: Equatable {
    var x: Int32 = 0
    var y: Int32 = 0
    var width: Int32 = 0
    var height: Int32 = 0
}

/// Token consumption reported after LLM generation completes.
struct TokenUsage {
    var inputTokens = 0
    var outputTokens = 0
}

/// The internal state of the `BackgroundAgent` state machine.
///
/// Each case carries the data accumulated up to that point in the flow.
/// `Equatable` conformance is synthesized because all associated values are `Equatable`.
enum AgentState: Equatable {
    case idle
    case contextCapture
    case awaitingPrompt(
        contextType: ContextType,
        selectedText: String?,
        originalApp: AppContext
    )
    case generating(
        contextType: ContextType,
        originalApp: AppContext,
        generatedText: String
    )
    case awaitingAction(
        contextType: ContextType,
        originalApp: AppContext,
        generatedText: String
    )
    case injecting(
        originalApp: AppContext,
        text: String
    )
}

/// Events emitted by the `BackgroundAgent` to drive UI state changes.
///
/// The `@MainActor` `AppState` pattern-matches on these to update the overlay.
enum UIEvent: Equatable {
    case showOverlay
    case hideOverlay
    case streamChunk(String)
    case streamComplete
    case streamError(String)
}

/// Messages sent from the UI layer into the `BackgroundAgent`.
enum UIMessage {
    case promptSubmitted(String)
    case generationCancelled
    case textAccepted
    case textRejected
    case refinementSubmitted(String)
}
