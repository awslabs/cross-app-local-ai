import Testing
@testable import FastLang

@Suite("PromptUtils.estimateTokens")
struct EstimateTokensTests {

    @Test("empty string returns 1 (minimum)")
    func emptyString() {
        #expect(PromptUtils.estimateTokens("") == 1)
    }

    @Test("short text returns at least 1")
    func shortText() {
        #expect(PromptUtils.estimateTokens("hi") >= 1)
    }

    @Test("100 characters estimates ~25 tokens")
    func hundredChars() {
        let text = String(repeating: "a", count: 100)
        #expect(PromptUtils.estimateTokens(text) == 25)
    }
}

@Suite("PromptUtils.truncateToTokenBudget")
struct TruncateTests {

    @Test("short text is returned unchanged")
    func withinBudget() {
        let text = "Hello world"
        #expect(PromptUtils.truncateToTokenBudget(text, maxTokens: 100) == text)
    }

    @Test("long text is truncated with ellipsis")
    func exceedsBudget() {
        let text = String(repeating: "a", count: 100)
        let result = PromptUtils.truncateToTokenBudget(text, maxTokens: 5)
        #expect(result.count < text.count)
        #expect(result.hasSuffix("..."))
    }

    @Test("truncation respects token-to-char ratio")
    func truncationLength() {
        let text = String(repeating: "x", count: 100)
        let result = PromptUtils.truncateToTokenBudget(text, maxTokens: 10)
        // 10 tokens * 4 chars = 40 chars + "..."
        #expect(result.count == 43)
    }
}

@Suite("PromptUtils.buildUserPrompt")
struct BuildUserPromptTests {

    @Test("without selection returns raw prompt")
    func noSelection() {
        let result = PromptUtils.buildUserPrompt(
            promptText: "Write a haiku",
            selectedText: nil,
            mode: .insert
        )
        #expect(result == "Write a haiku")
    }

    @Test("with empty selection returns raw prompt")
    func emptySelection() {
        let result = PromptUtils.buildUserPrompt(
            promptText: "Write a haiku",
            selectedText: "",
            mode: .insert
        )
        #expect(result == "Write a haiku")
    }

    @Test("replace mode wraps selected text with 'Selected text:' header")
    func replaceMode() {
        let result = PromptUtils.buildUserPrompt(
            promptText: "Make professional",
            selectedText: "hey whats up",
            mode: .replace
        )
        #expect(result.contains("Selected text:"))
        #expect(result.contains("hey whats up"))
        #expect(result.contains("Instruction: Make professional"))
    }

    @Test("insert mode wraps selected text with 'Context' header")
    func insertMode() {
        let result = PromptUtils.buildUserPrompt(
            promptText: "Continue this thought",
            selectedText: "The quick brown fox",
            mode: .insert
        )
        #expect(result.contains("Context (selected text):"))
        #expect(result.contains("The quick brown fox"))
        #expect(result.contains("Instruction: Continue this thought"))
    }
}

@Suite("PromptUtils.buildRefinementPrompt")
struct BuildRefinementPromptTests {

    @Test("includes original prompt, previous output, and feedback")
    func fullRefinement() {
        let result = PromptUtils.buildRefinementPrompt(
            originalPrompt: "Write a haiku",
            generatedText: "An old silent pond...",
            feedback: "Make it about cats"
        )
        #expect(result.contains("Write a haiku"))
        #expect(result.contains("An old silent pond..."))
        #expect(result.contains("User feedback: Make it about cats"))
    }

    @Test("includes 'Previous output:' label")
    func previousOutputLabel() {
        let result = PromptUtils.buildRefinementPrompt(
            originalPrompt: "p",
            generatedText: "g",
            feedback: "f"
        )
        #expect(result.contains("Previous output:"))
    }
}
