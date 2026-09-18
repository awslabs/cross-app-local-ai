import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "telemetryservice")

/// Minimum interval between telemetry submission attempts (1 hour).
private let submissionIntervalSeconds: TimeInterval = 3600

/// Delay after app launch before attempting first submission (60 seconds).
/// Avoids network activity during startup.
private let initialSubmissionDelaySeconds: UInt64 = 60

// MARK: - TelemetryService

/// Orchestrates telemetry collection and periodic submission.
///
/// The service is always constructed regardless of config — when telemetry
/// is disabled (user opt-out or unconfigured OSS build), `record*` calls
/// are no-ops. This keeps call sites unconditional.
actor TelemetryService {
    private let store: TelemetryStore
    private let reporter: TelemetryReporter
    private let config: TelemetryConfig
    private let isUserEnabled: @MainActor () -> Bool

    private var lastSubmissionAttempt: Date = .distantPast
    private var submissionTask: Task<Void, Never>?

    /// - Parameters:
    ///   - dataDir: App's data directory for telemetry JSON files.
    ///   - telemetryConfig: Build-time API config (domain + token).
    ///   - deviceId: Stable anonymous device identifier.
    ///   - appVersion: App version from Info.plist.
    ///   - osVersion: macOS version string.
    ///   - isUserEnabled: Closure that returns the current user opt-in state.
    ///     Evaluated at each operation, so toggling in Settings takes effect immediately.
    init(
        dataDir: URL,
        telemetryConfig: TelemetryConfig,
        deviceId: String,
        appVersion: String,
        osVersion: String,
        isUserEnabled: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.config = telemetryConfig
        self.reporter = TelemetryReporter(config: telemetryConfig)
        self.isUserEnabled = isUserEnabled
        self.store = TelemetryStore(
            dataDir: dataDir,
            deviceId: deviceId,
            appVersion: appVersion,
            osVersion: osVersion
        )
    }

    // MARK: - Recording

    /// Records a feature usage event. No-op if telemetry is disabled.
    func recordFeature(_ feature: TelemetryFeature) async {
        guard await isEnabled() else { return }
        await store.recordFeature(feature)
    }

    /// Records an error event. No-op if telemetry is disabled.
    func recordError(_ error: TelemetryError) async {
        guard await isEnabled() else { return }
        await store.recordError(error)
    }

    // MARK: - Submission

    /// Starts the periodic submission loop. Call once after initialization.
    func startPeriodicSubmission() {
        submissionTask?.cancel()
        submissionTask = Task { [weak self] in
            // Initial delay to avoid network during startup
            try? await Task.sleep(nanoseconds: initialSubmissionDelaySeconds * 1_000_000_000)

            while !Task.isCancelled {
                guard let self else { break }
                await self.submitPendingSummaries()
                // Sleep for submission interval
                try? await Task.sleep(nanoseconds: UInt64(submissionIntervalSeconds) * 1_000_000_000)
            }
        }
    }

    /// Submits all pending summaries to the API. Deletes files on success.
    func submitPendingSummaries() async {
        guard await isEnabled() else { return }

        let now = Date()
        guard now.timeIntervalSince(lastSubmissionAttempt) >= submissionIntervalSeconds else {
            return
        }
        lastSubmissionAttempt = now

        let summaries = await store.pendingSummaries()
        guard !summaries.isEmpty else { return }

        logger.info("Submitting \(summaries.count) pending telemetry summaries")

        for summary in summaries {
            do {
                try await reporter.submit(summary)
                await store.deleteSummary(for: summary.date)
                logger.debug("Successfully submitted and cleared telemetry for \(summary.date)")
            } catch {
                logger
                    .error(
                        "Failed to submit telemetry for \(summary.date): \(error.localizedDescription, privacy: .public)"
                    )
                // Stop on first failure; retry next cycle
                break
            }
        }
    }

    /// Deletes all local telemetry data. Called when user opts out.
    func purgeLocalData() async {
        await store.deleteAll()
        logger.info("Purged all local telemetry data")
    }

    // MARK: - Private

    /// Whether telemetry is both configured (build-time) and enabled (user preference).
    private func isEnabled() async -> Bool {
        guard config.isConfigured else { return false }
        return await isUserEnabled()
    }
}
