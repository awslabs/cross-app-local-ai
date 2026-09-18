import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.aws.fastlang", category: "app")

/// Application delegate that configures the app as an accessory (no Dock icon)
/// and registers global hotkeys at launch.
///
/// SwiftUI `App` scenes do not reliably fire lifecycle callbacks on app start
/// for menu bar apps. `NSApplicationDelegate.applicationDidFinishLaunching`
/// is the correct hook for one-time setup that must happen at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onLaunch: (() -> Void)?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onLaunch?()
    }
}

@main
struct FastLangApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var appState = AppState()
    @State private var hotkeyManager = HotkeyManager()
    @State private var overlayController: OverlayPanelController?
    @State private var readAloudController: ReadAloudPanelController?
    @State private var saveDebounceTask: Task<Void, Never>?

    init() {}

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                providerName: appState.config.llm.defaultProvider,
                isGenerating: appState.isGenerating,
                isRecording: appState.isRecording,
                isTranscribing: appState.isTranscribing,
                availableUpdate: appState.availableUpdate,
                onDismissUpdate: { appState.dismissUpdateNotification() }
            )
            .alert(
                appState.alertTitle,
                isPresented: $appState.isAlertPresented
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.alertBody)
            }
        } label: {
            MenuBarLabel(
                isGenerating: appState.isGenerating,
                isTranscribing: appState.isTranscribing,
                onAppear: { registerHotkeys() }
            )
        }

        Settings {
            SettingsView(
                config: Binding(
                    get: { appState.config },
                    set: { newValue in
                        appState.config = newValue
                        // Persisted on settings-window close via
                        // `saveSettings()` in `.onDisappear`, which also
                        // reconstructs services and re-registers hotkeys.
                    }
                ),
                preferences: Binding(
                    get: { appState.preferences },
                    set: { newValue in
                        appState.preferences = newValue
                        appState.savePreferences()
                    }
                ),
                quickPrompts: Binding(
                    get: { appState.quickPrompts },
                    set: { newValue in
                        appState.quickPrompts = newValue
                        appState.saveQuickPrompts()
                    }
                ),
                history: Binding(
                    get: { appState.history },
                    set: { newValue in
                        appState.history = newValue
                        try? appState.history.save(to: appState.dirs.sessionsPath)
                    }
                ),
                availableLlmModels: LlmService.modelsForProvider(
                    appState.config.llm.defaultProvider
                ),
                availableSttModels: WhisperKitModels.staticModels(),
                downloadState: appState.downloadState,
                modelCacheVersion: appState.modelCacheVersion,
                onStartDownload: { modelId in
                    appState.showDownloadConfirmation(modelId: modelId)
                },
                onConfirmDownload: {
                    Task { await appState.confirmDownload() }
                },
                onCancelDownload: {
                    appState.cancelDownload()
                },
                onDeleteModel: { modelId in
                    Task { await appState.deleteModel(modelId: modelId) }
                },
                onRetryDownload: { modelId in
                    appState.retryDownload(modelId: modelId)
                },
                onDismissDownloadError: {
                    appState.dismissDownloadError()
                },
                sttDownloadState: appState.sttDownloadState,
                onStartSttDownload: { modelId in
                    appState.showSttDownloadConfirmation(modelId: modelId)
                },
                onConfirmSttDownload: {
                    Task { await appState.confirmSttDownload() }
                },
                onCancelSttDownload: {
                    appState.cancelSttDownload()
                },
                onDeleteSttModel: { modelId in
                    Task { await appState.deleteSttModel(modelId: modelId) }
                },
                ttsDownloadState: appState.ttsDownloadState,
                onStartTtsDownload: {
                    appState.showTtsDownloadConfirmation()
                },
                onConfirmTtsDownload: {
                    Task { await appState.confirmTtsDownload() }
                },
                onCancelTtsDownload: {
                    appState.cancelTtsDownload()
                },
                onDeleteTtsModel: {
                    Task { await appState.deleteTtsModel() }
                },
                onRegeneratePreference: { appKey in
                    Task { await appState.regeneratePreferences(for: appKey) }
                }
            )
            .font(.system(size: 13 * appState.config.behavior.fontScale.multiplier))
            .onAppear {
                logger.info("Settings window appeared")
                NSApp.activate()
            }
            .onDisappear {
                saveDebounceTask?.cancel()
                saveDebounceTask = nil
                logger.info("Settings window disappeared; flushing saveSettings()")
                Task {
                    await appState.saveSettings()
                    logger.info("saveSettings() completed after window close")
                }
            }
            .onChange(of: appState.config.hotkeys) { _, _ in registerHotkeys() }
            .onChange(of: appState.config) { _, _ in
                debounceSaveSettings()
            }
        }
    }

    private func debounceSaveSettings() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await appState.saveSettings()
            logger.debug("Debounced saveSettings() completed")
        }
    }

    private func registerHotkeys() {
        let controller = ensureOverlayController()

        hotkeyManager.register(
            config: appState.config.hotkeys,
            aiSearchEnabled: FeatureFlags.aiSearchEnabled,
            onOverlayToggle: { [self] in
                Task { await handleOverlayToggle(controller: controller) }
            },
            onPttDown: { [self] in
                Task { await handlePttDown(controller: controller) }
            },
            onPttUp: { [self] in
                Task { await handlePttUp(controller: controller) }
            },
            onReadAloud: { [self] in
                Task { await handleReadAloud() }
            },
            onAiSearchDown: { [self] in
                Task { await handleAiSearchDown(controller: controller) }
            },
            onAiSearchUp: { [self] in
                Task { await handleAiSearchUp(controller: controller) }
            }
        )
        logger.info("Hotkeys registered")
    }

    private func handleOverlayToggle(controller: OverlayPanelController) async {
        await appState.toggleOverlay()
        if appState.isOverlayVisible { controller.show() } else { controller.hide() }
    }

    private func handlePttDown(controller: OverlayPanelController) async {
        await appState.handleSttHotkeyPressed()
        if appState.isRecording {
            controller.showSttIndicator()
        } else if let notice = appState.sttIndicatorNotice {
            appState.sttIndicatorNotice = nil
            controller.showSttNotice(notice)
        }
    }

    private func handlePttUp(controller: OverlayPanelController) async {
        // Only show "Transcribing…" if a recording was actually in progress.
        // If STT wasn't ready, key-down already showed a notice pill (e.g.
        // "still starting up") and there's nothing to transcribe — showing the
        // transcribing indicator here would clobber that pill instantly.
        let wasRecording = appState.isRecording
        if wasRecording { controller.showSttTranscribingIndicator() }

        await appState.handleSttHotkeyReleased()

        if let notice = appState.sttIndicatorNotice {
            appState.sttIndicatorNotice = nil
            controller.showSttNotice(notice)
        } else if wasRecording {
            controller.hideSttIndicator()
        }
        // If nothing was recording and no new notice, leave the down-handler's
        // notice pill visible for its full duration.
    }

    private func handleReadAloud() async {
        await appState.triggerReadAloud()
        if appState.isReadAloudVisible {
            let raController = ensureReadAloudController()
            raController.show()
        }
    }

    private func handleAiSearchDown(controller: OverlayPanelController) async {
        await appState.handleAiSearchPressed()
        if appState.isRecording {
            controller.showSttIndicator()
        } else if let notice = appState.sttIndicatorNotice {
            appState.sttIndicatorNotice = nil
            controller.showSttNotice(notice)
        }
    }

    private func handleAiSearchUp(controller: OverlayPanelController) async {
        // See handlePttUp: only show "Transcribing…" if recording was active,
        // so a warming-up notice pill from key-down isn't clobbered. Still call
        // the release handler regardless — it manages the early-release flag.
        let wasRecording = appState.isRecording
        if wasRecording { controller.showSttTranscribingIndicator() }

        await appState.handleAiSearchReleased()

        if let notice = appState.sttIndicatorNotice {
            appState.sttIndicatorNotice = nil
            controller.showSttNotice(notice)
        } else if wasRecording {
            controller.hideSttIndicator()
        }
    }

    private func ensureOverlayController() -> OverlayPanelController {
        if let existing = overlayController {
            return existing
        }
        let controller = OverlayPanelController(
            appState: appState,
            onSubmit: { prompt in
                Task { await appState.handleGenerate(prompt: prompt) }
            },
            onCancel: {
                Task {
                    await appState.cancelGeneration()
                    await appState.hideOverlay()
                    overlayController?.hide()
                }
            },
            onAccept: {
                Task {
                    appState.isOverlayVisible = false
                    overlayController?.hide()
                    await appState.acceptGeneration()
                }
            },
            onReject: {
                Task {
                    await appState.rejectGeneration()
                    overlayController?.hide()
                }
            },
            onRefine: { refinement in
                Task { await appState.submitRefinement(feedback: refinement) }
            },
            onDismiss: {
                Task {
                    await appState.cancelGeneration()
                    await appState.hideOverlay()
                    overlayController?.hide()
                }
            }
        )
        overlayController = controller
        return controller
    }

    private func ensureReadAloudController() -> ReadAloudPanelController {
        if let existing = readAloudController {
            return existing
        }

        let controller = ReadAloudPanelController(
            appState: appState,
            onPlay: {
                Task { await appState.startSpeaking() }
            },
            onPause: {
                Task { await appState.pauseSpeaking() }
            },
            onResume: {
                Task { await appState.resumeSpeaking() }
            },
            onStop: {
                Task { await appState.stopSpeaking() }
            },
            onSeek: { offset in
                Task { await appState.seekToWord(characterOffset: offset) }
            },
            onRateChange: { rate in
                Task { await appState.setReadAloudRate(rate) }
            },
            onSummarize: {
                appState.summarizeReadAloudText()
            },
            onRestoreOriginal: {
                appState.restoreOriginalReadAloudText()
            },
            onDismiss: {
                Task {
                    await appState.dismissReadAloud()
                    readAloudController?.hide()
                }
            }
        )
        readAloudController = controller
        return controller
    }
}

// MARK: - Menu Bar Label

/// Extracted view to ensure `MenuBarExtra` re-renders the icon when
/// processing state changes. Inline closures in `MenuBarExtra.label`
/// have known reactivity issues with `@Observable` on macOS.
private struct MenuBarLabel: View {
    let isGenerating: Bool
    let isTranscribing: Bool
    var onAppear: (() -> Void)?

    private var isProcessing: Bool {
        isGenerating || isTranscribing
    }

    var body: some View {
        Image(systemName: isProcessing ? "text.bubble.fill" : "text.bubble")
            .symbolRenderingMode(.palette)
            .foregroundStyle(isProcessing ? .green : .primary)
            .onAppear {
                onAppear?()
            }
    }
}
