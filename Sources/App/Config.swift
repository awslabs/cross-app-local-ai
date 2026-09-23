import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "config")

// MARK: - JSON Coding

/// Shared JSON encoder configured for snake_case key conversion.
let sharedJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

/// Shared JSON decoder configured for snake_case key conversion.
let sharedJSONDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

// MARK: - Config

/// Top-level application configuration persisted to `settings.json`.
struct Config: Codable, Equatable {
    var app = AppConfig()
    var llm = LlmConfig()
    var hotkeys = HotkeyConfig()
    var behavior = BehaviorConfig()
    var textInjection = TextInjectionConfig()
    var stt = SttAppConfig()
    var tts = TtsAppConfig()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decodeIfPresent(AppConfig.self, forKey: .app) ?? AppConfig()
        llm = try container.decodeIfPresent(LlmConfig.self, forKey: .llm) ?? LlmConfig()
        hotkeys = try container.decodeIfPresent(HotkeyConfig.self, forKey: .hotkeys) ?? HotkeyConfig()
        behavior = try container.decodeIfPresent(BehaviorConfig.self, forKey: .behavior) ?? BehaviorConfig()
        textInjection = try container.decodeIfPresent(TextInjectionConfig.self, forKey: .textInjection)
            ?? TextInjectionConfig()
        stt = try container.decodeIfPresent(SttAppConfig.self, forKey: .stt) ?? SttAppConfig()
        tts = try container.decodeIfPresent(TtsAppConfig.self, forKey: .tts) ?? TtsAppConfig()
    }

    /// Returns validation errors, empty if config is valid.
    func validate() -> [String] {
        var errors: [String] = []

        // The active provider must have a model id, unless local is using a
        // custom model path instead.
        if llm.activeModelId.isEmpty, llm.localModelPath == nil {
            errors.append("Model ID must not be empty")
        }

        var validProviders = ["local_llamacpp", "mock"]
        #if BEDROCK_ENABLED
            validProviders.append("bedrock")
        #endif
        if !validProviders.contains(llm.defaultProvider) {
            errors.append("Unknown provider '\(llm.defaultProvider)'. Valid: \(validProviders.joined(separator: ", "))")
        }

        if llm.defaultProvider == "local_llamacpp",
           llm.localModelId.isEmpty, llm.localModelPath == nil {
            errors.append("local_llamacpp provider requires either localModelId or localModelPath")
        }

        #if BEDROCK_ENABLED
            if llm.defaultProvider == "bedrock", llm.region.isEmpty {
                errors.append("Bedrock provider requires a non-empty region")
            }
        #endif

        if hotkeys.triggerOverlay.isEmpty {
            errors.append("Overlay hotkey must not be empty")
        }
        if hotkeys.pushToTalk.isEmpty {
            errors.append("Push-to-talk hotkey must not be empty")
        }
        if hotkeys.readAloud.isEmpty {
            errors.append("Read-aloud hotkey must not be empty")
        }
        if textInjection.clipboardDelayMs == 0 {
            errors.append("clipboardDelayMs must be > 0")
        }
        if tts.chunkTokens < 1 {
            errors.append("tts.chunkTokens must be > 0")
        }

        return errors
    }

    /// Loads config from disk, returning defaults if the file is missing or corrupt.
    static func load(from path: URL) -> Config {
        guard let data = try? Data(contentsOf: path) else {
            logger.info("No settings file at \(path.path), using defaults")
            return Config()
        }
        do {
            return try sharedJSONDecoder.decode(Config.self, from: data)
        } catch {
            logger.error("Failed to decode settings: \(error.localizedDescription, privacy: .public). Using defaults.")
            return Config()
        }
    }

    /// Persists config to disk.
    ///
    /// - Parameter path: The file URL to write to.
    /// - Throws: Encoding or file system errors.
    func save(to path: URL) throws {
        let data = try sharedJSONEncoder.encode(self)
        try data.write(to: path, options: .atomic)
    }
}

// MARK: - Sub-Configs

struct AppConfig: Codable, Equatable {
    var version = "0.1.0"
    var firstRun = true
    var telemetryEnabled = TelemetryConfig.fromMainBundle().isConfigured

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.1.0"
        firstRun = try container.decodeIfPresent(Bool.self, forKey: .firstRun) ?? true
        telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled)
            ?? TelemetryConfig.fromMainBundle().isConfigured
    }
}

/// Compile-time feature flags. Change these in code and rebuild.
/// These are NOT persisted to settings.json.
enum FeatureFlags {
    static let aiSearchEnabled = false
}

struct LlmConfig: Codable, Equatable {
    var defaultProvider = "local_llamacpp"
    var region = "us-east-1"
    var awsProfile: String?
    var maxTokens = 1024
    var temperature: Float = 0.7
    var timeoutSeconds = 30

    // Per-provider model selections. Kept as separate fields (rather than one
    // shared `modelId`) so switching providers can never leave a model id that
    // is invalid for the active provider — each provider always reads its own.
    //
    // Non-optional by design: the config layer is the single place a default
    // is applied (property default + decoder fallback), so every downstream
    // consumer can assume a value is present instead of re-defaulting. A
    // custom on-disk model is expressed via `localModelPath`, which overrides
    // the catalog id without needing this to be nil.
    var localModelId = LlamaCppModels.defaultModelId
    var localModelPath: String?
    var localGpuLayers: UInt32 = 999
    var localContextSize: UInt32 = 4096
    /// Default mirrors `BedrockModels.defaultModelId`. Held as a literal to
    /// avoid coupling `Config` to the `BEDROCK_ENABLED`-gated provider type;
    /// `ConfigTests` asserts the two stay in sync.
    var bedrockModelId = "us.anthropic.claude-sonnet-5"

    /// The model id for the currently selected provider. Always non-empty
    /// for a default config; both per-provider fields carry their own default.
    var activeModelId: String {
        defaultProvider == "bedrock" ? bedrockModelId : localModelId
    }

    init() {}

    /// Custom decoder for forward/backward compatibility (mirrors the pattern
    /// used by `HotkeyConfig`/`BehaviorConfig`). Missing keys fall back to
    /// defaults so older persisted configs — including those written before
    /// the `modelId` → `localModelId`/`bedrockModelId` split — still load. The
    /// legacy shared `modelId` key is intentionally ignored: `localModelId`
    /// already carries the local selection, and Bedrock falls back to its
    /// default (re-selected once if the user had a non-default Bedrock model).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultProvider = try c.decodeIfPresent(String.self, forKey: .defaultProvider) ?? "local_llamacpp"
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 1024
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature) ?? 0.7
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 30
        localModelId = try c.decodeIfPresent(String.self, forKey: .localModelId) ?? LlamaCppModels.defaultModelId
        localModelPath = try c.decodeIfPresent(String.self, forKey: .localModelPath)
        localGpuLayers = try c.decodeIfPresent(UInt32.self, forKey: .localGpuLayers) ?? 999
        localContextSize = try c.decodeIfPresent(UInt32.self, forKey: .localContextSize) ?? 4096
        bedrockModelId = try c.decodeIfPresent(String.self, forKey: .bedrockModelId)
            ?? "us.anthropic.claude-sonnet-5"
    }
}

struct HotkeyConfig: Codable, Equatable {
    var triggerOverlay = "Option+Space"
    var pushToTalk = "Cmd+Shift+Z"
    var readAloud = "Cmd+Shift+X"
    var aiSearch = "Cmd+Shift+G"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        triggerOverlay = try container.decodeIfPresent(String.self, forKey: .triggerOverlay) ?? "Option+Space"
        pushToTalk = try container.decodeIfPresent(String.self, forKey: .pushToTalk) ?? "Cmd+Shift+Z"
        readAloud = try container.decodeIfPresent(String.self, forKey: .readAloud) ?? "Cmd+Shift+X"
        aiSearch = try container.decodeIfPresent(String.self, forKey: .aiSearch) ?? "Cmd+Shift+G"
    }
}

struct WindowPosition: Codable, Equatable {
    let x: Float
    let y: Float
}

/// Discrete font size presets for the overlay UI.
enum FontScale: String, Codable, CaseIterable, Equatable {
    case small
    case medium
    case large
    case extraLarge

    /// Multiplier applied to base font sizes.
    var multiplier: CGFloat {
        switch self {
        case .small: 0.85
        case .medium: 1.0
        case .large: 1.2
        case .extraLarge: 1.4
        }
    }

    /// Human-readable label for the settings picker.
    var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
}

struct BehaviorConfig: Codable, Equatable {
    var autoCaptureSelection = true
    var restoreClipboard = true
    var launchAtLogin = false
    var windowPosition: WindowPosition?
    var fontScale: FontScale = .medium
    var dismissOnHotkey = true
    var dismissOnEscape = true
    var dismissOnSpaceChange = true
    var dismissOnFocusLoss = true
    var readAloudDismissOnEscape = true
    var readAloudDismissOnFocusLoss = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoCaptureSelection = try container.decodeIfPresent(Bool.self, forKey: .autoCaptureSelection) ?? true
        restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        windowPosition = try container.decodeIfPresent(WindowPosition.self, forKey: .windowPosition)
        fontScale = try container.decodeIfPresent(FontScale.self, forKey: .fontScale) ?? .medium
        dismissOnHotkey = try container.decodeIfPresent(Bool.self, forKey: .dismissOnHotkey) ?? true
        dismissOnEscape = try container.decodeIfPresent(Bool.self, forKey: .dismissOnEscape) ?? true
        dismissOnSpaceChange = try container.decodeIfPresent(Bool.self, forKey: .dismissOnSpaceChange) ?? true
        dismissOnFocusLoss = try container.decodeIfPresent(Bool.self, forKey: .dismissOnFocusLoss) ?? true
        readAloudDismissOnEscape = try container.decodeIfPresent(Bool.self, forKey: .readAloudDismissOnEscape) ?? true
        readAloudDismissOnFocusLoss = try container
            .decodeIfPresent(Bool.self, forKey: .readAloudDismissOnFocusLoss) ?? false
    }
}

struct TextInjectionConfig: Codable, Equatable {
    var captureStrategy = "clipboard"
    var injectionStrategy = "clipboard"
    var clipboardDelayMs: UInt64 = 500
    var pasteDelayMs: UInt64 = 50
}

struct SttAppConfig: Codable, Equatable {
    var provider = "whisper"
    var language: String? = "en"
    var enabled = true
    var whisperModelId = "whisper-small"
    var whisperModelPath: String?
    /// Persistent UID of the preferred input device. `nil` means system default.
    var audioInputDeviceUid: String?
    /// Set to `true` once the user has engaged with the auto-prefetched STT
    /// model in any explicit way — a successful silent prefetch, a manual
    /// download from Settings, or a manual delete. Prevents the silent
    /// prefetch from re-pulling a model the user has explicitly removed, while
    /// still letting a previously failed prefetch retry on the next launch.
    var acknowledgedAutoPrefetch = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "whisper"
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        whisperModelId = try container.decodeIfPresent(String.self, forKey: .whisperModelId) ?? "whisper-small"
        whisperModelPath = try container.decodeIfPresent(String.self, forKey: .whisperModelPath)
        audioInputDeviceUid = try container.decodeIfPresent(String.self, forKey: .audioInputDeviceUid)
        acknowledgedAutoPrefetch = try container.decodeIfPresent(
            Bool.self,
            forKey: .acknowledgedAutoPrefetch
        ) ?? false
    }
}

/// Speech pre-processing strategy applied to captured text before it is
/// spoken by the read-aloud panel.
enum TtsPreprocessing: String, Codable, CaseIterable, Equatable {
    /// Speak the captured text verbatim, with no cleanup applied.
    case none
    /// Apply the deterministic, low-latency `SpeechTextSanitizer` policy
    /// only — no model call.
    case deterministic
    /// Route through the LLM-powered summarize action in the read-aloud
    /// panel, in addition to the deterministic cleanup.
    case llm

    /// Human-readable label for the settings picker.
    var displayName: String {
        switch self {
        case .none: "No Pre-Processing"
        case .deterministic: "Deterministic Cleanup"
        case .llm: "LLM-Powered Preprocessing"
        }
    }
}

struct TtsAppConfig: Codable, Equatable {
    var provider = "system"
    var enabled = true
    var rate: Float = 0.5
    var voiceId: String?
    var language = "en-US"
    /// Set to `true` once the user has engaged with the auto-prefetched TTS
    /// model in any explicit way — a successful silent prefetch, a manual
    /// download from Settings, or a manual delete. See `SttAppConfig` for
    /// rationale.
    var acknowledgedAutoPrefetch = false
    /// Speech pre-processing strategy applied before text is spoken.
    var preprocessing: TtsPreprocessing = .none
    /// Per-chunk token budget for `TextMapReduce` when summarizing captured
    /// text. Shared by every reduce level; see `TextMapReduce.mapReduce`.
    var chunkTokens = 1200

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "system"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        rate = try container.decodeIfPresent(Float.self, forKey: .rate) ?? 0.5
        voiceId = try container.decodeIfPresent(String.self, forKey: .voiceId)
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "en-US"
        acknowledgedAutoPrefetch = try container.decodeIfPresent(
            Bool.self,
            forKey: .acknowledgedAutoPrefetch
        ) ?? false
        preprocessing = try container.decodeIfPresent(TtsPreprocessing.self, forKey: .preprocessing) ?? .none
        chunkTokens = try container.decodeIfPresent(Int.self, forKey: .chunkTokens) ?? 1200
    }
}
