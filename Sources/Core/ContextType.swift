import Foundation

/// The type of application context the user is working in.
/// Determines which system prompt template is selected.
enum ContextType: String, Codable, CaseIterable {
    case email = "Email"
    case chat = "Chat"
    case document = "Document"
    case spreadsheet = "Spreadsheet"
    case code = "Code"
    case notes = "Notes"
    case generic = "Generic"
}

/// Whether the LLM should generate new content or rewrite selected text.
enum PromptMode {
    case insert
    case replace
}

/// The visual state of the overlay window.
enum OverlayState: Equatable {
    case input
    case generating
    case approval
    case error(String)
}
