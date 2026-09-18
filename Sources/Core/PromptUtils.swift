import Foundation

/// Utilities for token estimation, prompt truncation, and user prompt construction.
enum PromptUtils {

    /// Rough token count estimate (~4 characters per token on average).
    ///
    /// This is a coarse heuristic used for pre-flight checks and UI display.
    /// Actual tokenization is model-specific and happens inside the provider.
    ///
    /// - Parameter text: The input text.
    /// - Returns: Estimated token count.
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// Truncates text to fit within a token budget.
    ///
    /// Truncation is character-based using the 4-chars-per-token heuristic.
    /// When truncation occurs, an ellipsis marker is appended.
    ///
    /// - Parameters:
    ///   - text: The text to potentially truncate.
    ///   - maxTokens: The maximum token budget.
    /// - Returns: The original text if it fits, or a truncated version with "..." appended.
    static func truncateToTokenBudget(_ text: String, maxTokens: Int) -> String {
        let maxChars = maxTokens * 4
        guard text.count > maxChars else { return text }
        let truncated = String(text.prefix(maxChars))
        return truncated + "..."
    }

    // MARK: - User Prompt Building

    /// Builds the user prompt sent to the LLM.
    ///
    /// - Parameters:
    ///   - promptText: The user's instruction or question.
    ///   - selectedText: Text selected in the target app, if any.
    ///   - mode: Whether we're inserting new content or replacing selected text.
    /// - Returns: The formatted user prompt.
    static func buildUserPrompt(
        promptText: String,
        selectedText: String?,
        mode: PromptMode
    ) -> String {
        guard let selected = selectedText, !selected.isEmpty else {
            return promptText
        }

        switch mode {
        case .replace:
            return """
            Selected text:
            \"\"\"
            \(selected)
            \"\"\"

            Instruction: \(promptText)
            """
        case .insert:
            return """
            Context (selected text):
            \"\"\"
            \(selected)
            \"\"\"

            Instruction: \(promptText)
            """
        }
    }

    /// Builds a refinement prompt that includes the original prompt, previous output, and user feedback.
    ///
    /// - Parameters:
    ///   - originalPrompt: The original user prompt that generated the output.
    ///   - generatedText: The LLM's previous output.
    ///   - feedback: The user's refinement instruction.
    /// - Returns: The formatted refinement prompt.
    static func buildRefinementPrompt(
        originalPrompt: String,
        generatedText: String,
        feedback: String
    ) -> String {
        """
        \(originalPrompt)

        Previous output:
        \"\"\"
        \(generatedText)
        \"\"\"

        User feedback: \(feedback)
        """
    }
}
