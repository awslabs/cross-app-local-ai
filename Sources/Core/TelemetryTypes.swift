import CryptoKit
import Foundation

// MARK: - Feature Codes

/// Predefined feature codes matching the server-side allowed set.
/// Keys in `DailySummary.featureCounts`.
enum TelemetryFeature: String, Codable, CaseIterable, Sendable {
    case llmGenerate = "llm_generate"
    case sttTranscribe = "stt_transcribe"
    case ttsSpeak = "tts_speak"
    case readAloud = "read_aloud"
    case overlayTrigger = "overlay_trigger"
    case pushToTalk = "push_to_talk"
}

// MARK: - Error Codes

/// Predefined error codes matching the server-side allowed set.
/// Keys in `DailySummary.errorCounts`.
enum TelemetryError: String, Codable, CaseIterable, Sendable {
    case llmLoadFailed = "llm_load_failed"
    case llmGenerateFailed = "llm_generate_failed"
    case sttLoadFailed = "stt_load_failed"
    case sttTranscribeFailed = "stt_transcribe_failed"
    case ttsLoadFailed = "tts_load_failed"
    case ttsSpeakFailed = "tts_speak_failed"
    case modelDownloadFailed = "model_download_failed"
    case permissionDenied = "permission_denied"
}

// MARK: - Daily Summary

/// A single day's accumulated telemetry, matching the API's `POST /v1/events` schema.
struct DailySummary: Codable, Equatable, Sendable {
    var deviceId: String
    var appVersion: String
    var osVersion: String
    var date: String
    var featureCounts: [String: Int]
    var errorCounts: [String: Int]

    init(
        deviceId: String,
        appVersion: String,
        osVersion: String,
        date: String,
        featureCounts: [String: Int] = [:],
        errorCounts: [String: Int] = [:]
    ) {
        self.deviceId = deviceId
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.date = date
        self.featureCounts = featureCounts
        self.errorCounts = errorCounts
    }
}

// MARK: - Update Response

/// Response from `GET /v1/updates`.
struct UpdateInfo: Codable, Equatable, Sendable {
    let updateAvailable: Bool
    let latestVersion: String?
    let releaseNotes: String?
    let downloadUrl: String?
    let severity: UpdateSeverity?
}

/// Severity level for available updates.
enum UpdateSeverity: String, Codable, Sendable {
    case optional
    case recommended
    case critical
}

// MARK: - Telemetry Configuration

/// Runtime telemetry configuration read from the app bundle's Info.plist.
/// Empty `domain` or `token` disables telemetry (OSS builds).
struct TelemetryConfig: Equatable, Sendable {
    let domain: String
    let token: String

    /// Whether telemetry is structurally possible (non-empty credentials baked in at build time).
    var isConfigured: Bool {
        !domain.isEmpty && !token.isEmpty
    }

    /// Reads telemetry config from the main bundle's Info.plist.
    /// Returns an unconfigured instance if keys are missing (OSS builds).
    static func fromMainBundle() -> TelemetryConfig {
        let bundle = Bundle.main
        let domain = bundle.object(forInfoDictionaryKey: "TelemetryAPIDomain") as? String ?? ""
        let token = bundle.object(forInfoDictionaryKey: "TelemetryAPIToken") as? String ?? ""
        return TelemetryConfig(domain: domain, token: token)
    }
}

// MARK: - Device ID

/// Generates a stable, anonymous device identifier by hashing the IOPlatformUUID.
/// Returns a 64-character lowercase hex string (SHA-256).
func generateDeviceId() -> String {
    let platformUUID = fetchIOPlatformUUID() ?? UUID().uuidString
    let data = Data(platformUUID.utf8)
    let hash = SHA256.hash(data: data)
    return hash.map { String(format: "%02x", $0) }.joined()
}

/// Reads the IOPlatformUUID from IOKit. Returns nil if unavailable.
private func fetchIOPlatformUUID() -> String? {
    let service = IOServiceGetMatchingService(
        kIOMasterPortDefault,
        IOServiceMatching("IOPlatformExpertDevice")
    )
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    guard let uuidRef = IORegistryEntryCreateCFProperty(
        service,
        kIOPlatformUUIDKey as CFString,
        kCFAllocatorDefault,
        0
    ) else { return nil }

    return uuidRef.takeRetainedValue() as? String
}
