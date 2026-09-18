import AppKit
import Foundation
import os
import OSLog
import UserNotifications

private let logger = Logger(subsystem: "com.aws.fastlang", category: "updatenotifier")

// MARK: - UpdateNotifier

/// Posts macOS system notifications when an app update is available.
///
/// Rate-limits to one notification per version: if the user dismisses the
/// system notification, it does not re-fire on the next 24-hour check cycle.
/// The menu bar banner (MenuBarView) remains the fallback for users who
/// miss the notification.
final class UpdateNotifier: NSObject, Sendable, UNUserNotificationCenterDelegate {

    /// Notification category identifier for update actions.
    private static let categoryId = "APP_UPDATE"
    /// Action identifier for the "Download" button on the notification.
    private static let downloadActionId = "DOWNLOAD_UPDATE"

    /// Tracks which versions have already triggered a system notification
    /// to avoid re-posting on every 24-hour check cycle.
    private let notifiedVersions = OSAllocatedUnfairLock(initialState: Set<String>())

    override init() {
        super.init()
        registerCategories()
    }

    // MARK: - Public API

    /// Posts a system notification for the given update, if not already posted for this version.
    ///
    /// - Parameter info: The update information from the server.
    func postIfNeeded(for info: UpdateInfo) {
        guard let version = info.latestVersion else { return }

        let alreadyNotified = notifiedVersions.withLock { versions in
            if versions.contains(version) {
                return true
            }
            versions.insert(version)
            return false
        }

        guard !alreadyNotified else {
            logger.debug("System notification already posted for v\(version), skipping")
            return
        }

        requestAuthorizationAndPost(info: info, version: version)
    }

    /// Resets tracked state for a version (e.g. after user dismisses via menu bar).
    func clearNotifiedVersion(_ version: String) {
        notifiedVersions.withLock { _ = $0.remove(version) }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification actions when the user taps "Download".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == Self.downloadActionId else { return }

        let userInfo = response.notification.request.content.userInfo
        guard let urlString = userInfo["download_url"] as? String,
              let url = URL(string: urlString) else {
            logger.warning("Download action triggered but no valid URL in notification userInfo")
            return
        }

        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    /// Show notifications even when the app is in the foreground (menu bar apps
    /// are technically always "foreground").
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // MARK: - Private

    private func registerCategories() {
        let downloadAction = UNNotificationAction(
            identifier: Self.downloadActionId,
            title: "Download",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [downloadAction],
            intentIdentifiers: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func requestAuthorizationAndPost(info: UpdateInfo, version: String) {
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization error: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard granted else {
                logger.info("Notification permission denied by user")
                return
            }

            self.postNotification(info: info, version: version)
        }
    }

    private func postNotification(info: UpdateInfo, version: String) {
        let content = UNMutableNotificationContent()
        content.title = "FastLang Update Available"
        content.body = "Version \(version) is ready to download."
        if let notes = info.releaseNotes, !notes.isEmpty {
            content.body += " \(notes)"
        }
        content.sound = .default
        content.categoryIdentifier = Self.categoryId

        var userInfo: [String: String] = ["version": version]
        if let url = info.downloadUrl {
            userInfo["download_url"] = url
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "update-\(version)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to post update notification: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Posted system notification for update v\(version)")
            }
        }
    }
}
