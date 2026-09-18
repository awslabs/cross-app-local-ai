import Foundation
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "telemetrystore")

// MARK: - TelemetryStore

/// Manages on-disk persistence of daily telemetry summaries.
///
/// Each day accumulates into a single JSON file at
/// `<dataDir>/telemetry/<YYYY-MM-DD>.json`. Files are deleted after
/// successful submission to the API.
actor TelemetryStore {
    private let telemetryDir: URL
    private let deviceId: String
    private let appVersion: String
    private let osVersion: String

    /// In-memory accumulator for today's counts. Flushed to disk on every increment.
    private var todaySummary: DailySummary

    /// Date formatter for filenames and the `date` field (ISO calendar day).
    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        return fmt
    }()

    /// - Parameters:
    ///   - dataDir: The app's data directory (typically `AppDirs.dataDir`).
    ///   - deviceId: Stable anonymous device identifier (SHA-256 of IOPlatformUUID).
    ///   - appVersion: Current app version from Info.plist.
    ///   - osVersion: macOS version string.
    init(dataDir: URL, deviceId: String, appVersion: String, osVersion: String) {
        let dir = dataDir.appendingPathComponent("telemetry")
        self.telemetryDir = dir
        self.deviceId = deviceId
        self.appVersion = appVersion
        self.osVersion = osVersion

        let today = Self.dateFormatter.string(from: Date())
        var summary = DailySummary(
            deviceId: deviceId,
            appVersion: appVersion,
            osVersion: osVersion,
            date: today
        )

        // Inline directory creation and today-file loading (actor-isolated
        // methods cannot be called from the nonisolated init).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let filePath = dir.appendingPathComponent("\(today).json")
        if let data = try? Data(contentsOf: filePath),
           let existing = try? sharedJSONDecoder.decode(DailySummary.self, from: data) {
            summary = existing
        }

        self.todaySummary = summary
    }

    // MARK: - Recording

    /// Increments a feature counter for today.
    func recordFeature(_ feature: TelemetryFeature) {
        rollDateIfNeeded()
        todaySummary.featureCounts[feature.rawValue, default: 0] += 1
        flushToDisk()
    }

    /// Increments an error counter for today.
    func recordError(_ error: TelemetryError) {
        rollDateIfNeeded()
        todaySummary.errorCounts[error.rawValue, default: 0] += 1
        flushToDisk()
    }

    // MARK: - Retrieval & Cleanup

    /// Returns all pending daily summaries (today + any unsent previous days).
    func pendingSummaries() -> [DailySummary] {
        var results: [DailySummary] = []

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: telemetryDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let summary = try? sharedJSONDecoder.decode(DailySummary.self, from: data) else {
                continue
            }
            // Only include summaries with actual data
            if !summary.featureCounts.isEmpty || !summary.errorCounts.isEmpty {
                results.append(summary)
            }
        }

        return results
    }

    /// Deletes the on-disk file for a specific date after successful submission.
    func deleteSummary(for date: String) {
        let filePath = telemetryDir.appendingPathComponent("\(date).json")
        do {
            try FileManager.default.removeItem(at: filePath)
            logger.debug("Deleted telemetry file for \(date)")
        } catch {
            logger.error("Failed to delete telemetry file for \(date): \(error.localizedDescription, privacy: .public)")
        }

        // If we just deleted today's file, reset the in-memory accumulator
        if date == todaySummary.date {
            todaySummary.featureCounts = [:]
            todaySummary.errorCounts = [:]
        }
    }

    /// Deletes all on-disk telemetry files. Used when user opts out.
    func deleteAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: telemetryDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            try? fm.removeItem(at: file)
        }

        todaySummary.featureCounts = [:]
        todaySummary.errorCounts = [:]
        logger.info("Deleted all telemetry data")
    }

    // MARK: - Private

    /// If the date has changed since last access, flush the old day and start fresh.
    private func rollDateIfNeeded() {
        let today = Self.dateFormatter.string(from: Date())
        guard today != todaySummary.date else { return }

        // Today rolled over; start a new summary
        todaySummary = DailySummary(
            deviceId: deviceId,
            appVersion: appVersion,
            osVersion: osVersion,
            date: today
        )
    }

    /// Writes the current day's summary to disk atomically.
    private func flushToDisk() {
        let filePath = telemetryDir.appendingPathComponent("\(todaySummary.date).json")
        do {
            let data = try sharedJSONEncoder.encode(todaySummary)
            try data.write(to: filePath, options: .atomic)
        } catch {
            logger.error("Failed to flush telemetry to disk: \(error.localizedDescription, privacy: .public)")
        }
    }
}
