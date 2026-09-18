import Testing
@testable import FastLang

@Suite("BackgroundAgent")
struct BackgroundAgentTests {
    private let testApp = AppContext(
        appName: "Slack",
        bundleId: "com.tinyspeck.slackmacgap",
        processName: "Slack",
        processId: 1234,
        windowTitle: "#general"
    )

    // MARK: - Hotkey

    @Test("onHotkeyPressed transitions idle to contextCapture")
    func hotkeyFromIdle() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        let state = await agent.state
        #expect(state == .contextCapture)
    }

    @Test("onHotkeyPressed is ignored when not idle")
    func hotkeyIgnoredWhenBusy() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        await agent.onHotkeyPressed() // second press while in contextCapture
        let state = await agent.state
        #expect(state == .contextCapture)
    }

    // MARK: - Context Capture

    @Test("onContextCaptured transitions to awaitingPrompt and returns showOverlay")
    func contextCaptured() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        let event = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: "hello",
            originalApp: testApp
        )
        let state = await agent.state
        #expect(event == .showOverlay)
        #expect(state == .awaitingPrompt(
            contextType: .chat,
            selectedText: "hello",
            originalApp: testApp
        ))
    }

    @Test("onContextCaptured returns nil when not in contextCapture state")
    func contextCapturedInvalidState() async {
        let agent = BackgroundAgent()
        let event = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        #expect(event == nil)
        let state = await agent.state
        #expect(state == .idle)
    }

    // MARK: - Prompt Submission

    @Test("promptSubmitted transitions to generating")
    func promptSubmitted() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        _ = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        let event = await agent.handleUIMessage(.promptSubmitted("Write something"))
        let state = await agent.state
        #expect(event == nil)
        #expect(state == .generating(
            contextType: .chat,
            originalApp: testApp,
            generatedText: ""
        ))
    }

    // MARK: - Cancellation

    @Test("cancellation from awaitingPrompt returns to idle")
    func cancelFromAwaitingPrompt() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        _ = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        let event = await agent.handleUIMessage(.generationCancelled)
        let state = await agent.state
        #expect(event == .hideOverlay)
        #expect(state == .idle)
    }

    @Test("cancellation from generating returns to idle")
    func cancelFromGenerating() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        _ = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        _ = await agent.handleUIMessage(.promptSubmitted("Write"))
        let event = await agent.handleUIMessage(.generationCancelled)
        let state = await agent.state
        #expect(event == .hideOverlay)
        #expect(state == .idle)
    }

    // MARK: - Stream Events

    @Test("onStreamChunk accumulates text and returns streamChunk")
    func streamChunk() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        _ = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        _ = await agent.handleUIMessage(.promptSubmitted("Write"))

        let event1 = await agent.onStreamChunk("Hello ")
        #expect(event1 == .streamChunk("Hello "))

        let event2 = await agent.onStreamChunk("world")
        #expect(event2 == .streamChunk("world"))

        let state = await agent.state
        #expect(state == .generating(
            contextType: .chat,
            originalApp: testApp,
            generatedText: "Hello world"
        ))
    }

    @Test("onStreamChunk returns nil when not generating")
    func streamChunkInvalidState() async {
        let agent = BackgroundAgent()
        let event = await agent.onStreamChunk("text")
        #expect(event == nil)
    }

    @Test("onStreamComplete transitions to awaitingAction")
    func streamComplete() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        _ = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        _ = await agent.handleUIMessage(.promptSubmitted("Write"))
        _ = await agent.onStreamChunk("Result text")

        let event = await agent.onStreamComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5))
        let state = await agent.state
        #expect(event == .streamComplete)
        #expect(state == .awaitingAction(
            contextType: .chat,
            originalApp: testApp,
            generatedText: "Result text"
        ))
    }

    @Test("onStreamError resets to idle")
    func streamError() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        _ = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        _ = await agent.handleUIMessage(.promptSubmitted("Write"))

        let event = await agent.onStreamError("LLM failed")
        let state = await agent.state
        #expect(event == .streamError("LLM failed"))
        #expect(state == .idle)
    }

    // MARK: - Accept / Reject

    @Test("textAccepted transitions to injecting")
    func textAccepted() async {
        let agent = BackgroundAgent()
        await driveToAwaitingAction(agent)

        let event = await agent.handleUIMessage(.textAccepted)
        let state = await agent.state
        #expect(event == .hideOverlay)
        if case .injecting = state {
            // expected
        } else {
            Issue.record("Expected injecting state, got \(state)")
        }
    }

    @Test("textRejected resets to idle")
    func textRejected() async {
        let agent = BackgroundAgent()
        await driveToAwaitingAction(agent)

        let event = await agent.handleUIMessage(.textRejected)
        let state = await agent.state
        #expect(event == .hideOverlay)
        #expect(state == .idle)
    }

    // MARK: - Injection

    @Test("onInjectionComplete resets to idle")
    func injectionComplete() async {
        let agent = BackgroundAgent()
        await driveToAwaitingAction(agent)
        _ = await agent.handleUIMessage(.textAccepted)

        await agent.onInjectionComplete(success: true)
        let state = await agent.state
        #expect(state == .idle)
    }

    // MARK: - Refinement

    @Test("refinementSubmitted transitions from awaitingAction to generating")
    func refinement() async {
        let agent = BackgroundAgent()
        await driveToAwaitingAction(agent)

        let event = await agent.handleUIMessage(.refinementSubmitted("Make it shorter"))
        let state = await agent.state
        #expect(event == nil)
        if case let .generating(_, _, text) = state {
            #expect(text.isEmpty)
        } else {
            Issue.record("Expected generating state, got \(state)")
        }
    }

    // MARK: - Clipboard

    @Test("stores and retrieves clipboard content")
    func clipboard() async {
        let agent = BackgroundAgent()
        await agent.storeClipboard("original clipboard")
        let stored = await agent.storedClipboard
        #expect(stored == "original clipboard")
    }

    @Test("clearStoredClipboard clears the content")
    func clearClipboard() async {
        let agent = BackgroundAgent()
        await agent.storeClipboard("content")
        await agent.clearStoredClipboard()
        let stored = await agent.storedClipboard
        #expect(stored == nil)
    }

    // MARK: - Force Reset

    @Test("forceReset returns to idle from any state")
    func forceReset() async {
        let agent = BackgroundAgent()
        await agent.onHotkeyPressed()
        await agent.storeClipboard("data")
        await agent.forceReset()
        let state = await agent.state
        let clip = await agent.storedClipboard
        #expect(state == .idle)
        #expect(clip == nil)
    }

    // MARK: - Invalid State Guards

    @Test("promptSubmitted from idle returns nil")
    func promptFromIdle() async {
        let agent = BackgroundAgent()
        let event = await agent.handleUIMessage(.promptSubmitted("test"))
        #expect(event == nil)
    }

    @Test("textAccepted from idle returns nil")
    func acceptFromIdle() async {
        let agent = BackgroundAgent()
        let event = await agent.handleUIMessage(.textAccepted)
        #expect(event == nil)
    }

    @Test("textRejected from idle returns nil")
    func rejectFromIdle() async {
        let agent = BackgroundAgent()
        let event = await agent.handleUIMessage(.textRejected)
        #expect(event == nil)
    }

    @Test("refinementSubmitted from idle returns nil")
    func refinementFromIdle() async {
        let agent = BackgroundAgent()
        let event = await agent.handleUIMessage(.refinementSubmitted("test"))
        #expect(event == nil)
    }

    @Test("onStreamComplete from idle returns nil")
    func streamCompleteFromIdle() async {
        let agent = BackgroundAgent()
        let event = await agent.onStreamComplete(usage: TokenUsage())
        #expect(event == nil)
    }

    @Test("onStreamError from idle returns nil")
    func streamErrorFromIdle() async {
        let agent = BackgroundAgent()
        let event = await agent.onStreamError("fail")
        #expect(event == nil)
    }

    // MARK: - Helpers

    private func driveToAwaitingAction(_ agent: BackgroundAgent) async {
        await agent.onHotkeyPressed()
        _ = await agent.onContextCaptured(
            contextType: .chat,
            selectedText: nil,
            originalApp: testApp
        )
        _ = await agent.handleUIMessage(.promptSubmitted("Write"))
        _ = await agent.onStreamChunk("Generated text")
        _ = await agent.onStreamComplete(usage: TokenUsage(inputTokens: 10, outputTokens: 5))
    }
}
