import AppKit
import OSLog

private let logger = Logger(subsystem: "com.aws.fastlang", category: "sleepwake")

/// Observes macOS sleep/wake transitions and invokes callbacks so the app can
/// release heavy resources (GPU-resident models) before the system enters sleep.
///
/// Without this, the app's ~3-5 GB Metal memory footprint makes it a prime
/// Jetsam target during sleep — macOS aggressively kills high-memory background
/// processes when the system is under memory pressure at lid-close.
@MainActor
final class SleepWakeObserver {
    private let onSleep: @MainActor () async -> Void
    private let onWake: @MainActor () async -> Void

    // Stored for deinit cleanup (deinit is nonisolated, can't access
    // MainActor-isolated properties without these being nonisolated(unsafe)).
    private nonisolated(unsafe) var sleepObservation: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObservation: NSObjectProtocol?
    private nonisolated(unsafe) let notificationCenter: NotificationCenter

    /// Creates the observer and begins listening immediately.
    ///
    /// - Parameters:
    ///   - onSleep: Called on the main actor when the system is about to sleep.
    ///   - onWake: Called on the main actor when the system wakes from sleep.
    init(
        onSleep: @escaping @MainActor () async -> Void,
        onWake: @escaping @MainActor () async -> Void
    ) {
        self.onSleep = onSleep
        self.onWake = onWake
        self.notificationCenter = NSWorkspace.shared.notificationCenter
        startObserving()
    }

    deinit {
        if let sleepObservation {
            notificationCenter.removeObserver(sleepObservation)
        }
        if let wakeObservation {
            notificationCenter.removeObserver(wakeObservation)
        }
    }

    private func startObserving() {
        sleepObservation = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            logger.info("System will sleep — releasing heavy resources")
            Task { @MainActor in
                await self.onSleep()
            }
        }

        wakeObservation = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            logger.info("System did wake — scheduling resource reload")
            Task { @MainActor in
                await self.onWake()
            }
        }

        logger.info("Sleep/wake observer registered")
    }
}
