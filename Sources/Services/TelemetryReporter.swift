import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "telemetryreporter")

// MARK: - TelemetryReporterError

enum TelemetryReporterError: LocalizedError, Sendable {
    case notConfigured
    case httpError(statusCode: Int)
    case networkError(underlying: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Telemetry is not configured (missing domain or token)"
        case let .httpError(statusCode):
            "Telemetry API returned HTTP \(statusCode)"
        case let .networkError(underlying):
            "Network error: \(underlying)"
        }
    }
}

// MARK: - TelemetryReporter

/// Sends accumulated daily summaries to the telemetry API.
///
/// Stateless: each `submit` call constructs a fresh URLRequest. The caller
/// (TelemetryService) decides when and how often to invoke this.
struct TelemetryReporter: Sendable {
    private let config: TelemetryConfig
    private let session: URLSession

    /// - Parameters:
    ///   - config: Build-time telemetry configuration (domain + token).
    ///   - session: URLSession to use for requests (injectable for tests).
    init(config: TelemetryConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Submits a single daily summary to `POST /v1/events`.
    ///
    /// - Parameter summary: The daily summary to submit.
    /// - Throws: `TelemetryReporterError` on failure.
    func submit(_ summary: DailySummary) async throws {
        guard config.isConfigured else {
            throw TelemetryReporterError.notConfigured
        }

        guard let url = URL(string: "https://\(config.domain)/v1/events") else {
            throw TelemetryReporterError.networkError(underlying: "Invalid telemetry URL from domain: \(config.domain)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(summary)

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw TelemetryReporterError.networkError(underlying: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelemetryReporterError.networkError(underlying: "Non-HTTP response")
        }

        guard httpResponse.statusCode == 202 else {
            throw TelemetryReporterError.httpError(statusCode: httpResponse.statusCode)
        }

        logger.debug("Submitted telemetry for \(summary.date)")
    }

    /// Checks for available updates via `GET /v1/updates`.
    ///
    /// - Parameter currentVersion: The app's current version string.
    /// - Returns: Update information from the server.
    /// - Throws: `TelemetryReporterError` on failure.
    func checkForUpdates(currentVersion: String) async throws -> UpdateInfo {
        guard config.isConfigured else {
            throw TelemetryReporterError.notConfigured
        }

        guard var components = URLComponents(string: "https://\(config.domain)/v1/updates") else {
            throw TelemetryReporterError.networkError(underlying: "Invalid update URL from domain: \(config.domain)")
        }
        components.queryItems = [URLQueryItem(name: "current_version", value: currentVersion)]

        guard let url = components.url else {
            throw TelemetryReporterError.networkError(underlying: "Failed to construct update URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TelemetryReporterError.networkError(underlying: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelemetryReporterError.networkError(underlying: "Non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            throw TelemetryReporterError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UpdateInfo.self, from: data)
    }
}
