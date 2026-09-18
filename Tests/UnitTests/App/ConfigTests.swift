import Foundation
import Testing
@testable import FastLang

@Suite("Config")
struct ConfigTests {

    // MARK: - Defaults

    @Test("default config has expected provider and model")
    func defaultValues() {
        let config = Config()
        #expect(config.llm.defaultProvider == "local_llamacpp")
        #expect(config.llm.localModelId == "gemma-4-e2b")
        #expect(config.llm.activeModelId == "gemma-4-e2b")
        #expect(config.llm.maxTokens == 1024)
        #expect(config.llm.temperature == 0.7)
        #expect(config.llm.timeoutSeconds == 30)
        #expect(config.llm.localGpuLayers == 999)
        #expect(config.llm.localContextSize == 4096)
    }

    @Test("default app config marks first run")
    func defaultAppConfig() {
        let config = Config()
        #expect(config.app.firstRun == true)
        #expect(config.app.telemetryEnabled == false)
        #expect(config.app.version == "0.1.0")
    }

    @Test("default hotkey config has correct keys")
    func defaultHotkeys() {
        let config = Config()
        #expect(config.hotkeys.triggerOverlay == "Option+Space")
        #expect(config.hotkeys.pushToTalk == "Cmd+Shift+Z")
    }

    @Test("default behavior config enables auto-capture and clipboard restore")
    func defaultBehavior() {
        let config = Config()
        #expect(config.behavior.autoCaptureSelection == true)
        #expect(config.behavior.restoreClipboard == true)
        #expect(config.behavior.launchAtLogin == false)
        #expect(config.behavior.windowPosition == nil)
    }

    @Test("default read-aloud dismissal settings: escape on, focus-loss off")
    func defaultReadAloudDismissal() {
        let config = Config()
        #expect(config.behavior.readAloudDismissOnEscape == true)
        #expect(config.behavior.readAloudDismissOnFocusLoss == false)
    }

    @Test("default text injection config uses clipboard strategy")
    func defaultTextInjection() {
        let config = Config()
        #expect(config.textInjection.captureStrategy == "clipboard")
        #expect(config.textInjection.injectionStrategy == "clipboard")
        #expect(config.textInjection.clipboardDelayMs == 500)
        #expect(config.textInjection.pasteDelayMs == 50)
    }

    @Test("default STT config uses whisper provider")
    func defaultStt() {
        let config = Config()
        #expect(config.stt.provider == "whisper")
        #expect(config.stt.enabled == false)
        #expect(config.stt.whisperModelId == "whisper-small")
    }

    @Test("default TTS config uses system provider")
    func defaultTts() {
        let config = Config()
        #expect(config.tts.provider == "system")
        #expect(config.tts.enabled == true)
        #expect(config.tts.rate == 0.5)
        #expect(config.tts.voiceId == nil)
        #expect(config.tts.language == "en-US")
    }

    @Test("default hotkey config includes read aloud")
    func defaultReadAloudHotkey() {
        let config = Config()
        #expect(config.hotkeys.readAloud == "Cmd+Shift+X")
    }

    // MARK: - JSON Roundtrip

    @Test("encode-decode roundtrip preserves all values")
    func jsonRoundtrip() throws {
        var config = Config()
        config.llm.maxTokens = 2048
        config.behavior.windowPosition = WindowPosition(x: 100, y: 200)
        config.stt.enabled = true

        let data = try sharedJSONEncoder.encode(config)
        let decoded = try sharedJSONDecoder.decode(Config.self, from: data)
        #expect(decoded == config)
    }

    @Test("encode-decode roundtrip preserves read-aloud dismissal overrides")
    func readAloudDismissalRoundtrip() throws {
        var config = Config()
        config.behavior.readAloudDismissOnEscape = false
        config.behavior.readAloudDismissOnFocusLoss = true

        let data = try sharedJSONEncoder.encode(config)
        let decoded = try sharedJSONDecoder.decode(Config.self, from: data)
        #expect(decoded.behavior.readAloudDismissOnEscape == false)
        #expect(decoded.behavior.readAloudDismissOnFocusLoss == true)
    }

    @Test("snake_case keys are used in JSON output")
    func snakeCaseKeys() throws {
        let config = Config()
        let data = try sharedJSONEncoder.encode(config)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"default_provider\""))
        #expect(json.contains("\"max_tokens\""))
        #expect(json.contains("\"first_run\""))
        #expect(json.contains("\"trigger_overlay\""))
        #expect(json.contains("\"clipboard_delay_ms\""))
        #expect(json.contains("\"whisper_model_id\""))
    }

    @Test("decodes from snake_case JSON with missing optional fields")
    func decodeWithMissingOptionals() throws {
        let json = """
        {
            "app": { "version": "0.1.0", "first_run": false, "telemetry_enabled": false },
            "llm": { "default_provider": "mock", "model_id": "test", "region": "us-east-1",
                      "max_tokens": 512, "temperature": 0.5, "timeout_seconds": 10,
                      "local_gpu_layers": 0, "local_context_size": 2048 },
            "hotkeys": { "trigger_overlay": "Cmd+Space", "push_to_talk": "Cmd+R" },
            "behavior": { "auto_capture_selection": false, "restore_clipboard": false, "launch_at_login": false },
            "text_injection": { "capture_strategy": "clipboard", "injection_strategy": "clipboard",
                                "clipboard_delay_ms": 300, "paste_delay_ms": 25 },
            "stt": { "provider": "mock", "enabled": false, "whisper_model_id": "whisper-tiny" }
        }
        """
        let decoded = try sharedJSONDecoder.decode(Config.self, from: Data(json.utf8))
        #expect(decoded.llm.defaultProvider == "mock")
        #expect(decoded.llm.maxTokens == 512)
        #expect(decoded.llm.awsProfile == nil)
        #expect(decoded.llm.localModelPath == nil)
        #expect(decoded.behavior.windowPosition == nil)
        #expect(decoded.behavior.fontScale == .medium)
        #expect(decoded.behavior.dismissOnHotkey == true)
        #expect(decoded.behavior.dismissOnEscape == true)
        #expect(decoded.behavior.dismissOnSpaceChange == true)
        #expect(decoded.behavior.dismissOnFocusLoss == true)
        #expect(decoded.behavior.readAloudDismissOnEscape == true)
        #expect(decoded.behavior.readAloudDismissOnFocusLoss == false)
    }

    // MARK: - Validation

    @Test("default config validates without errors")
    func defaultValidates() {
        let config = Config()
        #expect(config.validate().isEmpty)
    }

    @Test("empty model ID is a validation error")
    func emptyModelId() {
        var config = Config()
        // Default provider is local; empty active model with no custom path.
        config.llm.localModelId = ""
        config.llm.localModelPath = nil
        let errors = config.validate()
        #expect(errors.contains { $0.contains("Model ID") })
    }

    #if BEDROCK_ENABLED
        @Test("bedrockModelId default matches BedrockModels.defaultModelId")
        func bedrockDefaultInSync() {
            #expect(Config().llm.bedrockModelId == BedrockModels.defaultModelId)
        }
    #endif

    @Test("unknown provider is a validation error")
    func unknownProvider() {
        var config = Config()
        config.llm.defaultProvider = "openai"
        let errors = config.validate()
        #expect(errors.contains { $0.contains("Unknown provider") })
    }

    @Test("local_llamacpp without model ID or path is a validation error")
    func localWithoutModel() {
        var config = Config()
        config.llm.defaultProvider = "local_llamacpp"
        // `localModelId` is non-optional; an empty id with no custom path is
        // the "no local model selected" state the validator must reject.
        config.llm.localModelId = ""
        config.llm.localModelPath = nil
        let errors = config.validate()
        #expect(errors.contains { $0.contains("localModelId or localModelPath") })
    }

    @Test("empty overlay hotkey is a validation error")
    func emptyOverlayHotkey() {
        var config = Config()
        config.hotkeys.triggerOverlay = ""
        let errors = config.validate()
        #expect(errors.contains { $0.contains("Overlay hotkey") })
    }

    @Test("zero clipboard delay is a validation error")
    func zeroClipboardDelay() {
        var config = Config()
        config.textInjection.clipboardDelayMs = 0
        let errors = config.validate()
        #expect(errors.contains { $0.contains("clipboardDelayMs") })
    }

    @Test("empty read-aloud hotkey is a validation error")
    func emptyReadAloudHotkey() {
        var config = Config()
        config.hotkeys.readAloud = ""
        let errors = config.validate()
        #expect(errors.contains { $0.contains("Read-aloud hotkey") })
    }

    @Test("JSON decode with missing tts key uses defaults")
    func decodeMissingTtsKey() throws {
        let json = """
        {
            "app": { "version": "0.1.0", "first_run": true, "telemetry_enabled": false },
            "llm": { "default_provider": "local_llamacpp", "model_id": "gemma-4-e2b",
                      "region": "us-east-1", "max_tokens": 1024, "temperature": 0.7,
                      "timeout_seconds": 30, "local_model_id": "gemma-4-e2b",
                      "local_gpu_layers": 999, "local_context_size": 4096 },
            "hotkeys": { "trigger_overlay": "Option+Space", "push_to_talk": "Cmd+Shift+Z" },
            "behavior": { "auto_capture_selection": true, "restore_clipboard": true,
                          "launch_at_login": false, "font_scale": "medium" },
            "text_injection": { "capture_strategy": "clipboard", "injection_strategy": "clipboard",
                                "clipboard_delay_ms": 500, "paste_delay_ms": 50 },
            "stt": { "provider": "whisper", "enabled": false, "whisper_model_id": "whisper-small" }
        }
        """
        let decoded = try sharedJSONDecoder.decode(Config.self, from: Data(json.utf8))
        #expect(decoded.tts.provider == "system")
        #expect(decoded.tts.enabled == true)
        #expect(decoded.tts.rate == 0.5)
        #expect(decoded.hotkeys.readAloud == "Cmd+Shift+X")
    }

    // MARK: - Load/Save

    @Test("load returns defaults for missing file")
    func loadMissingFile() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nonexistent.json")
        let config = Config.load(from: path)
        #expect(config == Config())
    }

    @Test("save then load roundtrips")
    func saveLoadRoundtrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("settings.json")
        var config = Config()
        config.llm.maxTokens = 4096
        try config.save(to: path)

        let loaded = Config.load(from: path)
        #expect(loaded.llm.maxTokens == 4096)
    }
}

@Suite("WindowPosition")
struct WindowPositionTests {

    @Test("equatable compares x and y")
    func equatable() {
        #expect(WindowPosition(x: 1, y: 2) == WindowPosition(x: 1, y: 2))
        #expect(WindowPosition(x: 1, y: 2) != WindowPosition(x: 3, y: 4))
    }

    @Test("codable roundtrip")
    func codable() throws {
        let pos = WindowPosition(x: 100.5, y: 200.3)
        let data = try sharedJSONEncoder.encode(pos)
        let decoded = try sharedJSONDecoder.decode(WindowPosition.self, from: data)
        #expect(decoded == pos)
    }
}
