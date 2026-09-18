import AppKit
import SwiftUI

/// The content displayed in the menu bar dropdown.
///
/// Uses plain `Button` children compatible with `MenuBarExtra`'s default
/// menu-style rendering. Custom views and layout modifiers are not
/// supported in the menu style -- only `Button`, `Divider`, `Toggle`,
/// `Picker`, and `Text` are rendered.
struct MenuBarView: View {
    var providerName: String
    var isGenerating: Bool
    var isRecording: Bool
    var isTranscribing: Bool
    var availableUpdate: UpdateInfo?
    var onDismissUpdate: () -> Void = {}

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let update = availableUpdate, let version = update.latestVersion {
            Text("Update available: v\(version)")
            if let url = update.downloadUrl, let downloadURL = URL(string: url) {
                Button("Download Update") {
                    NSWorkspace.shared.open(downloadURL)
                }
            }
            Button("Dismiss") {
                onDismissUpdate()
            }
            Divider()
        }

        Text("Provider: \(providerName)")

        if isGenerating || isTranscribing {
            Text("Generating...")
        }

        if isRecording {
            Text("Recording...")
        }

        Divider()

        Button("Settings...") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit FastLang") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
