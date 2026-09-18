import Foundation

// MARK: - LLM Errors

/// Errors from LLM providers (local inference or Bedrock).
enum LlmError: LocalizedError, Equatable {
    case authentication(message: String, provider: String)
    case rateLimit(message: String, retryAfterSecs: Int?)
    case modelNotFound(modelId: String, availableModels: [String])
    case modelNotInstalled(modelId: String)
    case providerInitFailed(modelId: String, underlying: String)
    case unknownProvider(name: String)
    case network(message: String)
    case invalidRequest(message: String)
    case provider(message: String, provider: String)
    case configuration(message: String)
    case timeout(seconds: Int)
    case contentFiltered
    case modelFile(message: String)

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case let .authentication(message, _): "Authentication failed: \(message)"
        case let .rateLimit(message, _): "Rate limited: \(message)"
        case let .modelNotFound(modelId, _): "Model not found: \(modelId)"
        case let .modelNotInstalled(modelId):
            "Language model '\(modelId)' is not installed"
        case let .providerInitFailed(modelId, underlying):
            "Failed to load language model '\(modelId)': \(underlying)"
        case let .unknownProvider(name):
            "Unknown language model provider '\(name)'"
        case let .network(message): "Network error: \(message)"
        case let .invalidRequest(message): "Invalid request: \(message)"
        case let .provider(message, _): "Provider error: \(message)"
        case let .configuration(message): "Configuration error: \(message)"
        case let .timeout(seconds): "Request timed out after \(seconds) seconds"
        case .contentFiltered: "Content was filtered by safety settings"
        case let .modelFile(message): "Model file error: \(message)"
        }
    }

    var suggestedAction: String? {
        switch self {
        case .authentication: "Check your AWS credentials in Settings"
        case .rateLimit: "Wait and retry"
        case .modelNotFound: "Select a different model in Settings"
        case .modelNotInstalled: "Open Settings to download it"
        case .providerInitFailed: "Open Settings to reinstall the model"
        case .unknownProvider: "Check the language model provider in Settings"
        case .network: "Check your internet connection"
        case .invalidRequest: nil
        case .provider: nil
        case .configuration: "Open Settings and verify configuration"
        case .timeout: "Try again or increase timeout in Settings"
        case .contentFiltered: "Modify your prompt and try again"
        case .modelFile: "Check model path or re-download"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .rateLimit, .network, .timeout: true
        default: false
        }
    }
}

// MARK: - STT Errors

/// Errors from speech-to-text providers.
enum SttError: LocalizedError, Equatable {
    case notConfigured
    case recordingFailed(message: String)
    case transcriptionFailed(message: String)
    case modelNotFound(modelId: String)
    case modelNotInstalled(modelId: String)
    case providerInitFailed(modelId: String, underlying: String)
    case unknownProvider(name: String)
    case permissionDenied
    case startingUp
    /// Model file failed SHA-256 integrity verification.
    case modelIntegrityFailed(modelId: String)

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case .notConfigured: "Speech-to-text is not configured"
        case let .recordingFailed(message): "Recording failed: \(message)"
        case let .transcriptionFailed(message): "Transcription failed: \(message)"
        case let .modelNotFound(modelId): "STT model not found: \(modelId)"
        case let .modelNotInstalled(modelId):
            "Speech recognition model '\(modelId)' is not installed"
        case let .providerInitFailed(modelId, underlying):
            "Failed to load speech recognition model '\(modelId)': \(underlying)"
        case let .unknownProvider(name):
            "Unknown speech recognition provider '\(name)'"
        case .permissionDenied: "Microphone access was denied"
        case .startingUp:
            "Speech recognition is still starting up"
        case let .modelIntegrityFailed(modelId):
            "Speech model '\(modelId)' failed integrity verification and was deleted. "
                + "Please re-download the model."
        }
    }

    var suggestedAction: String? {
        switch self {
        case .notConfigured: "Enable STT in Settings"
        case .recordingFailed: "Check microphone permissions in System Settings"
        case .transcriptionFailed: "Try again or check the STT model"
        case .modelNotFound: "Download the model in Settings"
        case .modelNotInstalled: "Open Settings to download it"
        case .providerInitFailed: "Open Settings to reinstall the model"
        case .unknownProvider: "Check the speech recognition provider in Settings"
        case .permissionDenied: "Grant microphone access in System Settings > Privacy & Security"
        case .startingUp: "Try again in a few seconds"
        case .modelIntegrityFailed: "Open Settings to re-download the model"
        }
    }
}

// MARK: - Hotkey Errors

/// Errors from hotkey registration and parsing.
enum HotkeyError: LocalizedError, Equatable {
    case registrationFailed(hotkey: String)
    case parseError(input: String)
    case conflict(hotkey: String, existingOwner: String)

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case let .registrationFailed(hotkey): "Failed to register hotkey: \(hotkey)"
        case let .parseError(input): "Invalid hotkey format: \(input)"
        case let .conflict(hotkey, owner): "Hotkey \(hotkey) conflicts with \(owner)"
        }
    }
}

// MARK: - Injection Errors

/// Errors from text injection into target apps.
enum InjectionError: LocalizedError, Equatable {
    case targetAppNotFound
    case focusFailed(appName: String)
    case pasteFailed(message: String)

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case .targetAppNotFound: "Target application is no longer running"
        case let .focusFailed(appName): "Failed to focus \(appName)"
        case let .pasteFailed(message): "Paste failed: \(message)"
        }
    }
}

// MARK: - Capture Errors

/// Errors from text selection capture.
enum CaptureError: LocalizedError, Equatable {
    case accessibilityDenied
    case noSelection
    case clipboardTimeout
    case unknownError(message: String)

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case .accessibilityDenied: "Accessibility access is required to capture selected text"
        case .noSelection: "No text is selected"
        case .clipboardTimeout: "Clipboard capture timed out"
        case let .unknownError(message): "Capture error: \(message)"
        }
    }

    var suggestedAction: String? {
        switch self {
        case .accessibilityDenied:
            "Grant accessibility access in System Settings > Privacy & Security > Accessibility"
        case .noSelection: nil
        case .clipboardTimeout: "Try again"
        case .unknownError: nil
        }
    }
}

// MARK: - Top-Level Error

/// Top-level error type that wraps all domain-specific errors.
enum FastLangError: LocalizedError {
    case config(message: String)
    case platform(message: String)
    case llm(LlmError)
    case ui(message: String)
    case hotkey(HotkeyError)
    case injection(InjectionError)
    case capture(CaptureError)
    case stt(SttError)

    var errorDescription: String? {
        userMessage
    }

    var userMessage: String {
        switch self {
        case let .config(message): "Configuration error: \(message)"
        case let .platform(message): "Platform error: \(message)"
        case let .llm(error): error.userMessage
        case let .ui(message): "UI error: \(message)"
        case let .hotkey(error): error.userMessage
        case let .injection(error): error.userMessage
        case let .capture(error): error.userMessage
        case let .stt(error): error.userMessage
        }
    }

    var suggestedAction: String? {
        switch self {
        case .config: "Open Settings and verify configuration"
        case .platform: nil
        case let .llm(error): error.suggestedAction
        case .ui: nil
        case .hotkey: nil
        case .injection: nil
        case let .capture(error): error.suggestedAction
        case let .stt(error): error.suggestedAction
        }
    }

    var isRetryable: Bool {
        switch self {
        case let .llm(error): error.isRetryable
        default: false
        }
    }
}

// MARK: - Error Enrichment

/// Parses raw error strings for known patterns and appends user-friendly hints.
///
/// This is critical for good UX when Bedrock calls fail with opaque AWS exception names.
///
/// - Parameter rawMessage: The original error message from a provider or framework.
/// - Returns: An enriched message with actionable hints, or the original if no pattern matched.
func enrichErrorMessage(_ rawMessage: String) -> String {
    let lowered = rawMessage.lowercased()

    #if BEDROCK_ENABLED
        if lowered.contains("accessdeniedexception") || lowered.contains("expiredtokenexception") {
            return "\(rawMessage)\n\nHint: Check your AWS credentials. "
                + "Run `aws configure` or verify your profile in Settings."
        }
        if lowered.contains("throttlingexception") {
            return "\(rawMessage)\n\nHint: You've been rate-limited. Wait a moment and try again."
        }
        if lowered.contains("validationexception") {
            return "\(rawMessage)\n\nHint: The request was rejected. "
                + "Check your model selection and parameters in Settings."
        }
        if lowered.contains("resourcenotfoundexception") {
            return "\(rawMessage)\n\nHint: The model or resource was not found. "
                + "Verify the region and model ID in Settings."
        }
    #endif

    if lowered.contains("nokvcacheslot") || lowered.contains("prompt is too long") {
        return "\(rawMessage)\n\nHint: The prompt exceeds the model's context window. "
            + "Try a shorter prompt or increase the context size in Settings."
    }

    if lowered.contains("timed out") || lowered.contains("timeout") {
        return "\(rawMessage)\n\nHint: The request timed out. "
            + "Check your connection or increase the timeout in Settings."
    }

    if lowered.contains("network") || lowered.contains("connection") {
        return "\(rawMessage)\n\nHint: A network error occurred. Check your internet connection."
    }

    return rawMessage
}
