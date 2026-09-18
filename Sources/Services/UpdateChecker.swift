import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "updatechecker")

/// Minimum interval between update checks (24 hours).
private let checkIntervalSeconds: TimeInterval = 86400

/// Cooldown before showing a dismissed version notification again (7 days).
private let dismissCooldownSeconds: TimeInterval = 604_800

/// Delay after app launch before first update check (2 minutes).
private let initialCheckDelaySeconds: UInt64 = 120

// MARK: - UpdateChecker

/// Periodically checks for app updates and manages notification state.
///
/// Rate limits:
/// - Checks at most once per 24 hours.
/// - After a user dismisses an update notification, that specific version
///   is suppressed for 7 days (unless severity is `critical`).
actor UpdateChecker {
    private let reporter: TelemetryReporter
    private let notifier: UpdateNotifier
    private let currentVersion: String
    private let persistenceURL: URL

    private var lastCheckDate: Date = .distantPast
    private var dismissedVersions: [String: Date] = [:]
    private var checkTask: Task<Void, Never>?

    /// Callback invoked on the main actor when an update should be shown.
    private var onUpdateAvailable: (@MainActor @Sendable (UpdateInfo) -> Void)?

    /// Sets the callback for update availability notifications.
    func set(onUpdateAvailable callback: @escaping @MainActor @Sendable (UpdateInfo) -> Void) {
        onUpdateAvailable = callback
    }

    /// - Parameters:
    ///   - telemetryConfig: Build-time API config (domain + token).
    ///   - currentVersion: App's current version string.
    ///   - dataDir: App's data directory for persistence.
    ///   - notifier: System notification manager for posting update alerts.
    init(
        telemetryConfig: TelemetryConfig,
        currentVersion: String,
        dataDir: URL,
        notifier: UpdateNotifier
    ) {
        self.reporter = TelemetryReporter(config: telemetryConfig)
        self.notifier = notifier
        self.currentVersion = currentVersion
        let url = dataDir.appendingPathComponent("update_checker_state.json")
        self.persistenceURL = url

        // Inline state loading (actor-isolated `loadState()` cannot be
        // called from the nonisolated init).
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.lastCheckDate = state.lastCheckDate
            self.dismissedVersions = state.dismissedVersions
        }
    }

    // MARK: - Periodic Check

    /// Starts the periodic update check loop. Call once after initialization.
    func startPeriodicChecks() {
        let version = currentVersion
        logger
            .error(
                "Starting periodic update checks (delay=\(initialCheckDelaySeconds)s, version=\(version, privacy: .public))"
            )
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: initialCheckDelaySeconds * 1_000_000_000)

            while !Task.isCancelled {
                guard let self else { break }
                await self.checkForUpdates()
                try? await Task.sleep(nanoseconds: UInt64(checkIntervalSeconds) * 1_000_000_000)
            }
        }
    }

    /// Performs a single update check if the interval has elapsed.
    func checkForUpdates() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastCheckDate)
        logger.error("Update check triggered (elapsed=\(Int(elapsed))s, threshold=\(Int(checkIntervalSeconds))s)")
        guard elapsed >= checkIntervalSeconds else {
            return
        }

        lastCheckDate = now
        saveState()

        do {
            let info = try await reporter.checkForUpdates(currentVersion: currentVersion)
            guard info.updateAvailable, let version = info.latestVersion else { return }

            if shouldShowNotification(for: version, severity: info.severity) {
                logger.info("Update available: \(version) (severity: \(info.severity?.rawValue ?? "nil"))")
                notifier.postIfNeeded(for: info)
                if let callback = onUpdateAvailable {
                    await callback(info)
                }
            } else {
                logger.debug("Update \(version) suppressed (dismissed or in cooldown)")
            }
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Dismissal

    /// Records that the user dismissed a notification for a specific version.
    func dismissVersion(_ version: String) {
        dismissedVersions[version] = Date()
        saveState()
        logger.debug("User dismissed update notification for \(version)")
    }

    // MARK: - Private

    private func shouldShowNotification(for version: String, severity: UpdateSeverity?) -> Bool {
        // Critical updates always bypass cooldown
        if severity == .critical {
            return true
        }

        guard let dismissDate = dismissedVersions[version] else {
            return true
        }

        return Date().timeIntervalSince(dismissDate) >= dismissCooldownSeconds
    }

    // MARK: - State Persistence

    private struct PersistedState: Codable {
        var lastCheckDate: Date
        var dismissedVersions: [String: Date]
    }

    private func saveState() {
        let state = PersistedState(
            lastCheckDate: lastCheckDate,
            dismissedVersions: dismissedVersions
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }
}
