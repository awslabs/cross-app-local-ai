import Foundation
import Testing
@testable import FastLang

@Suite("TelemetryService")
struct TelemetryServiceTests {

    /// Records every date it was asked to submit and fails deterministically
    /// for a configured set of dates, regardless of call order.
    private actor MockTelemetryReporter: TelemetrySubmitting {
        private(set) var submittedDates: [String] = []
        private let failingDates: Set<String>

        init(failingDates: Set<String> = []) {
            self.failingDates = failingDates
        }

        func submit(_ summary: DailySummary) async throws {
            submittedDates.append(summary.date)
            if failingDates.contains(summary.date) {
                throw TelemetryReporterError.httpError(statusCode: 422)
            }
        }
    }

    /// Writes a `DailySummary` to `<dataDir>/telemetry/<date>.json`, matching
    /// the on-disk format `TelemetryStore` itself produces.
    private func seedSummary(date: String, dataDir: URL) throws {
        let telemetryDir = dataDir.appendingPathComponent("telemetry")
        try FileManager.default.createDirectory(at: telemetryDir, withIntermediateDirectories: true)
        let summary = DailySummary(
            deviceId: "test-device",
            appVersion: "1.0.0",
            osVersion: "test-os",
            date: date,
            featureCounts: ["push_to_talk": 1]
        )
        let data = try sharedJSONEncoder.encode(summary)
        try data.write(to: telemetryDir.appendingPathComponent("\(date).json"))
    }

    private func makeTempDataDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("one permanently-failing summary does not block other pending summaries")
    func failingSummaryDoesNotBlockOthers() async throws {
        let dataDir = try makeTempDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        try seedSummary(date: "2026-01-01", dataDir: dataDir)
        try seedSummary(date: "2026-01-02", dataDir: dataDir)
        try seedSummary(date: "2026-01-03", dataDir: dataDir)

        let reporter = MockTelemetryReporter(failingDates: ["2026-01-01"])
        let service = TelemetryService(
            dataDir: dataDir,
            telemetryConfig: TelemetryConfig(domain: "example.com", token: "test-token"),
            deviceId: "test-device",
            appVersion: "1.0.0",
            osVersion: "test-os",
            isUserEnabled: { true },
            reporter: reporter
        )

        await service.submitPendingSummaries()

        let submittedDates = await reporter.submittedDates
        #expect(Set(submittedDates) == ["2026-01-01", "2026-01-02", "2026-01-03"])

        let telemetryDir = dataDir.appendingPathComponent("telemetry")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: telemetryDir.appendingPathComponent("2026-01-01.json").path))
        #expect(!fm.fileExists(atPath: telemetryDir.appendingPathComponent("2026-01-02.json").path))
        #expect(!fm.fileExists(atPath: telemetryDir.appendingPathComponent("2026-01-03.json").path))
    }

    @Test("disabled telemetry submits nothing even with pending summaries on disk")
    func disabledTelemetrySubmitsNothing() async throws {
        let dataDir = try makeTempDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        try seedSummary(date: "2026-01-01", dataDir: dataDir)

        let reporter = MockTelemetryReporter()
        let service = TelemetryService(
            dataDir: dataDir,
            telemetryConfig: TelemetryConfig(domain: "example.com", token: "test-token"),
            deviceId: "test-device",
            appVersion: "1.0.0",
            osVersion: "test-os",
            isUserEnabled: { false },
            reporter: reporter
        )

        await service.submitPendingSummaries()

        let submittedDates = await reporter.submittedDates
        #expect(submittedDates.isEmpty)
    }

    @Test("unconfigured telemetry (OSS build) submits nothing")
    func unconfiguredTelemetrySubmitsNothing() async throws {
        let dataDir = try makeTempDataDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }

        try seedSummary(date: "2026-01-01", dataDir: dataDir)

        let reporter = MockTelemetryReporter()
        let service = TelemetryService(
            dataDir: dataDir,
            telemetryConfig: TelemetryConfig(domain: "", token: ""),
            deviceId: "test-device",
            appVersion: "1.0.0",
            osVersion: "test-os",
            isUserEnabled: { true },
            reporter: reporter
        )

        await service.submitPendingSummaries()

        let submittedDates = await reporter.submittedDates
        #expect(submittedDates.isEmpty)
    }
}
