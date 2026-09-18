import AppKit
import Foundation
import OSLog
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "com.aws.fastlang", category: "appstate")

// MARK: - DownloadState

/// Tracks model download progress for the UI.
enum DownloadState: Equatable {
    case confirming(modelId: String, displayName: String, sizeBytes: UInt64)
    case active(modelId: String, percent: Int)
    case deleting(modelId: String)
    case failed(modelId: String, message: String)
}

// MARK: - AppState

/// Central observable state that drives all SwiftUI views and orchestrates
/// the capture-generate-inject pipeline.
///
/// Owns all services (LLM, STT, platform, prompt store), the agent state machine,
/// and all persistent data (config, history, preferences, quick prompts).
/// Views bind directly to published properties; no manual `objectWillChange` needed.
@MainActor
@Observable
final class AppState {

    // MARK: - Overlay State

    /// The current visual state of the overlay.
    var overlayState: OverlayState = .input

    /// Whether the overlay panel is visible.
    var isOverlayVisible = false

    /// The user's prompt text in the input field.
    var promptText = ""

    /// Text selected in the target app at hotkey activation time.
    var selectedText: String?

    /// The context type resolved for the active application.
    var contextType: ContextType = .generic

    /// The target application that was active when the overlay was triggered.
    var originalApp: AppContext?

    /// Whether the user is in refinement mode.
    var isRefining = false

    /// Whether the current generation should use the explain system prompt.
    var explainMode = false

    // MARK: - Generation State

    /// Accumulated streamed text during generation.
    var generatedText = ""

    /// Whether a generation is currently in progress.
    var isGenerating = false

    /// Error message to display, if any.
    var errorMessage: String?

    /// Suggested action for the current error, if any.
    var errorSuggestedAction: String?

    // MARK: - Alert State

    /// Whether the alert dialog is presented.
    var isAlertPresented = false

    /// Title shown in the alert dialog.
    var alertTitle = ""

    /// Body text shown in the alert dialog.
    var alertBody = ""

    // MARK: - STT State

    /// Whether push-to-talk recording is active.
    var isRecording = false

    /// Whether a transcription is in progress after recording stops.
    var isTranscribing = false

    /// Notice to surface in the floating STT indicator pill: a genuine error
    /// (injection failed, missing Accessibility permission) styled red, or a
    /// neutral status (model still warming up after launch). Read by the app
    /// scene, which calls `showSttNotice`, then cleared after display.
    var sttIndicatorNotice: SttIndicatorNotice?

    // MARK: - Read-Aloud State

    /// Whether the read-aloud panel is visible.
    var isReadAloudVisible = false

    /// The text being read aloud.
    var readAloudText: String?

    /// Character offset range of the word currently being spoken.
    var readAloudHighlightRange: Range<Int>?

    /// Current transport state of the TTS playback.
    var readAloudPlaybackState: PlaybackState = .idle

    /// Current speech rate (0.0 .. 1.0 normalized).
    var readAloudRate: Float = 0.5

    /// Error message to display in the read-aloud panel when TTS fails.
    /// Shown inline in the panel so the user sees it without needing the menu bar.
    var readAloudErrorMessage: String?

    /// The captured (and, if configured, deterministically sanitized) text,
    /// kept alongside `readAloudText` so `restoreOriginalReadAloudText()` can
    /// swap back after a summarize action.
    var readAloudOriginalText: String?

    /// Which rendition of the captured text is currently active.
    var readAloudRendition: ReadAloudRendition = .original

    /// Progress of the LLM-powered summarize action, if any.
    var readAloudSummarizeState: ReadAloudSummarizeState = .idle

    // MARK: - Settings Window

    /// Whether the settings window is shown.
    var isSettingsVisible = false

    // MARK: - Download State

    /// Current LLM model download state, if any.
    var downloadState: DownloadState?

    /// Current STT (WhisperKit) model download state, if any.
    var sttDownloadState: DownloadState?

    /// Current TTS (Kokoro) model download state, if any.
    var ttsDownloadState: DownloadState?

    /// Bump this whenever a model is deleted or a download finishes.
    /// Views that render cache status by calling
    /// `WhisperKitModelManager.isModelCached(...)`, `LlamaCppModels.isModelCached(...)`,
    /// or `KokoroModelManager.isModelCached()` read a filesystem fact
    /// that SwiftUI can't observe. By reading this counter in the view
    /// body we force a recompute on the next mutation, keeping the UI
    /// in sync with disk without a heavier refactor.
    var modelCacheVersion = 0

    // MARK: - Persisted Data

    var config: Config
    var quickPrompts: QuickPrompts
    var history: History
    var preferences: AppPreferences

    // MARK: - Services (set during async init)

    // Set during async init and after settings changes
    var llmService: LlmService?
    var sttService: SttService?
    var ttsService: TtsService?
    var telemetryService: TelemetryService?
    var updateChecker: UpdateChecker?
    var updateNotifier: UpdateNotifier?

    // Last config each service was constructed with; used by saveSettings()
    // to detect whether a service actually needs reconstruction.
    var activeLlmConfig: LlmServiceConfig?
    var activeSttConfig: SttServiceConfig?
    var activeTtsConfig: TtsServiceConfig?

    // MARK: - Update Notification State

    /// Available update info to display in the UI. `nil` means no update banner.
    var availableUpdate: UpdateInfo?

    // MARK: - Internal Components

    let platformService: MacPlatformService
    let audioRecorder: AudioRecorder
    let agent: BackgroundAgent
    let appResolver: AppResolver
    let promptStore: SystemPromptStore?
    let dirs: AppDirs
    var sleepWakeObserver: SleepWakeObserver?

    /// Whether services are currently suspended due to system sleep.
    /// Prevents wake-reconstruction from racing with a user-triggered
    /// `reconstructLlmService` call. Set only by `suspendForSleep()` and
    /// `resumeFromWake()` in `AppState+Services.swift`.
    var isSuspendedForSleep = false

    // MARK: - Session-Scoped State

    var originalClipboard: String?
    var capturedViaClipboard = false
    var sessionOriginalPrompt = ""
    var sessionOriginalResponse = ""
    var sessionRefinements: [Refinement] = []
    var previousGeneratedText = ""
    var generationTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    var cancelDownloadFn: (@Sendable () -> Void)?
    var sttTargetApp: AppContext?
    var aiSearchReleasedEarly = false
    var promptMode: PromptMode = .insert
    var readAloudTask: Task<Void, Never>?
    var readAloudPreprocessTask: Task<Void, Never>?
    var preferenceExtractionTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        // Phase 1: Load persistent data (synchronous, fast)
        var resolvedDirs: AppDirs
        do {
            resolvedDirs = try AppDirs.resolve()
            try resolvedDirs.ensureDirs()
        } catch {
            logger.error("Failed to resolve app dirs: \(error.localizedDescription, privacy: .public)")
            resolvedDirs = AppDirs(
                dataDir: FileManager.default.temporaryDirectory
                    .appendingPathComponent("com.aws.fastlang")
            )
            try? resolvedDirs.ensureDirs()
        }
        self.dirs = resolvedDirs

        let loadedConfig = Config.load(from: resolvedDirs.settingsPath)
        self.config = loadedConfig
        self.quickPrompts = QuickPrompts.load(from: resolvedDirs.quickPromptsPath)
        self.history = History.load(from: resolvedDirs.sessionsPath)
        self.preferences = AppPreferences.load(from: resolvedDirs.appRulesPath)

        // Phase 2: Initialize pure services
        let mappings = AppResolver.loadMappings(from: resolvedDirs.appMappingsPath)
        self.appResolver = AppResolver(mappings: mappings)
        self.platformService = MacPlatformService()
        self.audioRecorder = AudioRecorder(preferredDeviceUID: loadedConfig.stt.audioInputDeviceUid)
        self.agent = BackgroundAgent()

        // SystemPromptStore can throw; fall back to nil
        do {
            self.promptStore = try SystemPromptStore(dirs: resolvedDirs)
        } catch {
            logger.error("Failed to load system prompt store: \(error.localizedDescription, privacy: .public)")
            self.promptStore = nil
        }

        // Phase 3: Async service construction
        Task { [self] in
            await initializeAsync()
        }

        // Phase 4: Telemetry and update checking — runs independently so it is
        // never blocked behind multi-GB model loading in Phase 3.
        Task { [self] in
            await initializeTelemetry()
        }
    }

    /// Test-only initializer that accepts injected dependencies.
    init(
        config: Config,
        dirs: AppDirs,
        platformService: MacPlatformService,
        audioRecorder: AudioRecorder,
        agent: BackgroundAgent,
        appResolver: AppResolver,
        promptStore: SystemPromptStore?
    ) {
        self.dirs = dirs
        self.config = config
        self.quickPrompts = QuickPrompts.defaults
        self.history = History()
        self.preferences = AppPreferences()
        self.platformService = platformService
        self.audioRecorder = audioRecorder
        self.agent = agent
        self.appResolver = appResolver
        self.promptStore = promptStore
    }

    private func initializeAsync() async {
        // Warm the microphone input path off the main actor and in parallel
        // with service construction. The Bluetooth SCO codec switch it triggers
        // is ~500ms; it must not block launch and depends on no service.
        let recorder = audioRecorder
        Task.detached { recorder.prewarm() }

        // Construct the async services concurrently. None depends on another,
        // so serializing them needlessly delays STT readiness (and the first
        // PTT) behind the LLM load — which can be a multi-GB local model.
        let llmConfig = buildLlmServiceConfig()
        let sttConfig = buildSttServiceConfig()
        async let llmServiceTask = LlmService(config: llmConfig)
        async let sttServiceTask = SttService(config: sttConfig)

        let llm = await llmServiceTask
        self.llmService = llm
        self.activeLlmConfig = llmConfig
        let llmProviderName = await llm.providerName
        logger.info("LLM service ready (provider: \(llmProviderName))")

        let stt = await sttServiceTask
        self.sttService = stt
        self.activeSttConfig = sttConfig
        let sttProviderName = await stt.providerName
        logger.info("STT service ready (provider: \(sttProviderName))")

        let ttsConfig = buildTtsServiceConfig()
        let tts = TtsService(config: ttsConfig)
        self.ttsService = tts
        self.activeTtsConfig = ttsConfig
        let ttsProviderName = await tts.providerName
        logger.info("TTS service ready (provider: \(ttsProviderName))")

        readAloudRate = config.tts.rate

        syncLoginItem()

        // Silently prefetch the auto-prefetch target models (Whisper
        // Small for STT, Kokoro 82M for TTS) if they aren't already
        // cached. Fire-and-forget; see `prefetchSmallModelsIfNeeded` for
        // the full invariant this honors.
        prefetchSmallModelsIfNeeded()

        await handleFirstLaunchFlows()

        // Verify accessibility permission on every launch and surface
        // actionable guidance when it's missing or stale.
        if !PermissionChecker.hasAccessibilityPermission {
            logger.warning("Accessibility permission not granted")
            PermissionChecker.requestAccessibilityPermission()
            presentAlert(
                title: "Accessibility Permission Required",
                body: "FastLang needs Accessibility permission to capture and insert text. "
                    + "Please enable it in System Settings > Privacy & Security > Accessibility."
            )
        } else if !MacPlatformService.verifyEventDelivery() {
            // Permission appears granted but event posting is blocked
            // (stale TCC entry after reinstall or code-signature change).
            logger.warning("Accessibility permission is stale — event delivery verification failed")
            PermissionChecker.openAccessibilitySettings()
            presentAlert(
                title: "Accessibility Permission Needs Refresh",
                body: "FastLang's accessibility access needs to be refreshed. "
                    +
                    "Please remove FastLang from the list and re-add it in the Accessibility settings that just opened."
            )
        }

        sleepWakeObserver = SleepWakeObserver(
            onSleep: { [weak self] in
                await self?.suspendForSleep()
            },
            onWake: { [weak self] in
                await self?.resumeFromWake()
            }
        )

        await maybeExtractPreferences()
        schedulePeriodicExtraction()
    }

    /// First-launch onboarding and pkg-marker handling.
    ///
    /// Runs after the real services are constructed so the UI can drive
    /// real downloads through them. Three possible paths:
    ///
    /// 1. **Pkg marker present, target model not cached**: the installer
    ///    chose an LLM for us. Apply the chosen model to the config,
    ///    grant permissions if first run, open Settings, auto-start the
    ///    download.
    /// 2. **First run, active LLM model not cached**: open Settings with
    ///    a download prompt so the user can pick and download.
    /// 3. **Not first run, active LLM model not cached**: queue a
    ///    confirmation prompt (user might delete from Settings and we
    ///    want them to see they can redownload).
    /// 4. **All cached**: nothing to do.
    private func handleFirstLaunchFlows() async {
        let pkgChoseModel = applyPkgModelMarker()
        // First-launch flow concerns the local model download specifically.
        let activeModelId = config.llm.localModelId
        let modelCached = LlamaCppModels.isModelCached(activeModelId)

        if pkgChoseModel, !modelCached {
            logger.info("Pkg install marker applied; auto-starting \(activeModelId) download")
            completeFirstRunSetupIfNeeded()
            isSettingsVisible = true
            showDownloadConfirmation(modelId: activeModelId)
            await confirmDownload()
            return
        }

        if config.app.firstRun {
            completeFirstRunSetupIfNeeded()
            if !modelCached {
                isSettingsVisible = true
                showDownloadConfirmation(modelId: activeModelId)
                logger.info("First launch with no cached model; opened settings with download prompt")
            }
        } else if !modelCached {
            showDownloadConfirmation(modelId: activeModelId)
        }
    }

    /// Requests accessibility permission, flips `firstRun` to `false`, and
    /// persists the config. No-op on subsequent runs.
    private func completeFirstRunSetupIfNeeded() {
        guard config.app.firstRun else { return }
        PermissionChecker.requestAccessibilityPermission()
        config.app.firstRun = false
        try? config.save(to: dirs.settingsPath)
    }

    /// The WhisperKit model ID that gets silently prefetched on first
    /// launch. This matches `SttAppConfig.whisperModelId`'s default so the
    /// STT service works out of the box once the prefetch completes;
    /// otherwise the service falls back to mock even with a cached Base
    /// model. Referenced by `prefetchSmallModelsIfNeeded` and by the
    /// user-action handlers (`confirmSttDownload`, `deleteSttModel`) that
    /// need to flip `SttAppConfig.acknowledgedAutoPrefetch` only when the
    /// user's action concerns this specific model.
    static let sttAutoPrefetchModelId = "whisper-small"

    /// Kicks off background downloads for the auto-prefetched auxiliary
    /// models (Whisper Small for STT, Kokoro 82M for TTS) if they aren't
    /// already cached. Fire-and-forget: no UI, no blocking, no state
    /// mutation on `sttDownloadState` / `ttsDownloadState`.
    ///
    /// ## Invariant
    ///
    /// > On launch, if the user has never engaged with an auxiliary model
    /// > and it's missing, acquire it silently. If they've explicitly
    /// > downloaded or deleted it, respect that choice forever.
    ///
    /// Per-feature `acknowledgedAutoPrefetch` flags on `SttAppConfig` and
    /// `TtsAppConfig` track engagement. A prefetch is attempted iff:
    ///
    /// 1. The feature is enabled in config, AND
    /// 2. The model is not already on disk, AND
    /// 3. The user hasn't acknowledged (via prior successful prefetch,
    ///    manual download, or manual delete).
    ///
    /// The acknowledgement flag flips on three events: a successful silent
    /// prefetch (`.complete` below), a manual download from Settings, or a
    /// manual delete of the prefetch target. This means a prefetch that
    /// fails or is interrupted mid-download will retry on the next launch,
    /// but a user who has explicitly downloaded or deleted the model never
    /// sees a silent re-pull.
    private func prefetchSmallModelsIfNeeded() {
        let sttModelId = Self.sttAutoPrefetchModelId
        if config.stt.enabled,
           !config.stt.acknowledgedAutoPrefetch,
           !WhisperKitModelManager.isModelCached(sttModelId) {
            logger.info("Silent prefetch: starting \(sttModelId) download")
            Task.detached(priority: .background) { [weak self] in
                let stream = WhisperKitModelManager.startModelDownload(modelId: sttModelId)
                for await progress in stream {
                    switch progress {
                    case .complete:
                        logger.info("Silent prefetch: \(sttModelId) completed")
                        // Delay before reconstructing the service.
                        // `WhisperKit.download(...)` yields `.complete` when
                        // the `.mlmodelc` bundle directories exist, but the
                        // large `weight.bin` inside each bundle can still be
                        // flushing to disk for another 30+ seconds. If we
                        // reconstruct immediately, `WhisperKit(config)` init
                        // fails with "STT model not found" and the user sees
                        // a stale "not installed" error for the next PTT.
                        //
                        // A fixed sleep is a bandaid for a library timing
                        // quirk, not a fundamental fix. Worth reviewing if
                        // WhisperKit's download stream becomes accurate.
                        try? await Task.sleep(for: .seconds(5))
                        await self?.reconstructSttService()
                        await self?.acknowledgeSttPrefetch()
                    case let .error(message):
                        logger
                            .error(
                                "Silent prefetch: \(sttModelId, privacy: .public) failed: \(message, privacy: .public)"
                            )
                    case .progress:
                        break
                    }
                }
            }
        }

        if config.tts.enabled,
           !config.tts.acknowledgedAutoPrefetch,
           !KokoroModelManager.isModelCached() {
            logger.info("Silent prefetch: starting kokoro-82m download")
            Task.detached(priority: .background) { [weak self] in
                let stream = KokoroModelManager.startModelDownload()
                for await progress in stream {
                    switch progress {
                    case .complete:
                        logger.info("Silent prefetch: kokoro-82m completed")
                        // Reconstruct so the freshly downloaded model is picked
                        // up now, mirroring the STT prefetch path.
                        await self?.reconstructTtsService()
                        await self?.acknowledgeTtsPrefetch()
                    case let .error(message):
                        logger.error("Silent prefetch: kokoro-82m failed: \(message, privacy: .public)")
                    case .progress:
                        break
                    }
                }
            }
        }
    }

    /// Marks the STT auto-prefetch as acknowledged, bumps the UI cache
    /// counter, and persists the config. Called on successful silent
    /// prefetch, manual download, or manual delete of the prefetch target.
    func acknowledgeSttPrefetch() {
        guard !config.stt.acknowledgedAutoPrefetch else {
            modelCacheVersion &+= 1
            return
        }
        config.stt.acknowledgedAutoPrefetch = true
        modelCacheVersion &+= 1
        do {
            try config.save(to: dirs.settingsPath)
        } catch {
            logger.error("Failed to persist STT prefetch ack: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Marks the TTS auto-prefetch as acknowledged. See `acknowledgeSttPrefetch`.
    func acknowledgeTtsPrefetch() {
        guard !config.tts.acknowledgedAutoPrefetch else {
            modelCacheVersion &+= 1
            return
        }
        config.tts.acknowledgedAutoPrefetch = true
        modelCacheVersion &+= 1
        do {
            try config.save(to: dirs.settingsPath)
        } catch {
            logger.error("Failed to persist TTS prefetch ack: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads any pkg-install marker left by the installer, applies the
    /// chosen model to `config.llm.localModelId` + `modelId`, persists
    /// the config, and removes the marker. Returns `true` if a marker
    /// was applied.
    ///
    /// If both markers exist (shouldn't happen — installer postinstalls
    /// each remove the other's marker before writing their own), E4B
    /// wins as the "larger choice". Markers are consumed on read
    /// regardless of whether the chosen model is already cached.
    private func applyPkgModelMarker() -> Bool {
        let fm = FileManager.default
        var chosen: String?

        if fm.fileExists(atPath: dirs.pkgMarkerE2B.path) {
            try? fm.removeItem(at: dirs.pkgMarkerE2B)
            chosen = "gemma-4-e2b"
        }
        if fm.fileExists(atPath: dirs.pkgMarkerE4B.path) {
            try? fm.removeItem(at: dirs.pkgMarkerE4B)
            chosen = "gemma-4-e4b"
        }

        guard let modelId = chosen else { return false }

        // The pkg installer only offers local models (E2B / E4B).
        config.llm.localModelId = modelId
        do {
            try config.save(to: dirs.settingsPath)
            logger.info("Applied pkg marker: localModelId -> \(modelId)")
        } catch {
            logger.error("Failed to save config after marker apply: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// Constructs the telemetry service and update checker from build-time config.
    /// No-op if telemetry credentials are absent (OSS builds).
    private func initializeTelemetry() async {
        let telemetryConfig = TelemetryConfig.fromMainBundle()
        logger
            .error(
                "Initializing telemetry and update checker (domain=\(telemetryConfig.domain, privacy: .public), configured=\(telemetryConfig.isConfigured))"
            )

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let deviceId = generateDeviceId()

        let service = TelemetryService(
            dataDir: dirs.dataDir,
            telemetryConfig: telemetryConfig,
            deviceId: deviceId,
            appVersion: appVersion,
            osVersion: osVersion,
            isUserEnabled: { [weak self] in
                self?.config.app.telemetryEnabled ?? false
            }
        )
        self.telemetryService = service
        await service.startPeriodicSubmission()

        guard telemetryConfig.isConfigured else {
            logger.info("Telemetry not configured (OSS build); skipping update checker")
            return
        }

        let notifier = UpdateNotifier()
        UNUserNotificationCenter.current().delegate = notifier
        self.updateNotifier = notifier

        let checker = UpdateChecker(
            telemetryConfig: telemetryConfig,
            currentVersion: appVersion,
            dataDir: dirs.dataDir,
            notifier: notifier
        )
        await checker.set(onUpdateAvailable: { [weak self] info in
            self?.availableUpdate = info
        })
        self.updateChecker = checker
        await checker.startPeriodicChecks()
        logger.info("Telemetry and update checker initialized")
    }

    /// Schedules periodic preference extraction every 4 hours.
    private func schedulePeriodicExtraction() {
        preferenceExtractionTask?.cancel()
        preferenceExtractionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4 * 60 * 60 * 1_000_000_000) // 4 hours
                guard !Task.isCancelled, let self else { break }
                await self.maybeExtractPreferences()
            }
        }
    }

    // MARK: - Service Config Builders

    func buildLlmServiceConfig() -> LlmServiceConfig {
        // `mockMode` stays false here. The LLM service surfaces
        // `modelNotInstalled` / `providerInitFailed` errors from the real
        // providers when things go wrong, rather than silently returning
        // mock generations. The `mockMode` flag remains on the config for
        // tests to exercise `MockLlmProvider` directly.
        LlmServiceConfig(
            provider: config.llm.defaultProvider,
            region: config.llm.region,
            awsProfile: config.llm.awsProfile,
            maxTokens: config.llm.maxTokens,
            temperature: config.llm.temperature,
            mockMode: false,
            localModelId: config.llm.localModelId,
            localModelPath: config.llm.localModelPath,
            localGpuLayers: config.llm.localGpuLayers,
            localContextSize: config.llm.localContextSize,
            bedrockModelId: config.llm.bedrockModelId
        )
    }

    func buildSttServiceConfig() -> SttServiceConfig {
        SttServiceConfig(
            provider: config.stt.provider,
            language: config.stt.language,
            mockMode: !config.stt.enabled,
            whisperModelId: config.stt.whisperModelId,
            whisperModelPath: config.stt.whisperModelPath
        )
    }

    func buildTtsServiceConfig() -> TtsServiceConfig {
        TtsServiceConfig(
            provider: config.tts.provider,
            voiceId: config.tts.voiceId,
            rate: config.tts.rate,
            language: config.tts.language,
            mockMode: !config.tts.enabled
        )
    }

    // MARK: - UIEvent Handling

    /// Processes a `UIEvent` from the `BackgroundAgent` and updates view state.
    func handleEvent(_ event: UIEvent) {
        switch event {
        case .showOverlay:
            isOverlayVisible = true
            overlayState = .input
            generatedText = ""
            errorMessage = nil
            errorSuggestedAction = nil
            isGenerating = false
            logger.debug("Overlay shown (input)")

        case .hideOverlay:
            isOverlayVisible = false
            promptText = ""
            selectedText = nil
            generatedText = ""
            isGenerating = false
            errorMessage = nil
            errorSuggestedAction = nil
            overlayState = .input
            logger.debug("Overlay hidden")

        case let .streamChunk(text):
            generatedText += text
            if !isGenerating {
                isGenerating = true
                overlayState = .generating
            }

        case .streamComplete:
            isGenerating = false
            overlayState = .approval
            logger.info("Generation complete, showing approval (\(self.generatedText.count) chars)")

        case let .streamError(message):
            isGenerating = false
            logger.error("Stream error: \(message, privacy: .public)")
            presentAlert(title: "Generation", body: message)
        }
    }

    // MARK: - Reset

    /// Resets session-scoped state. Called when overlay hides.
    func resetSessionState() {
        promptText = ""
        selectedText = nil
        generatedText = ""
        isGenerating = false
        isRefining = false
        errorMessage = nil
        errorSuggestedAction = nil
        overlayState = .input
        sessionOriginalPrompt = ""
        sessionOriginalResponse = ""
        sessionRefinements = []
        previousGeneratedText = ""
        originalApp = nil
        contextType = .generic
        originalClipboard = nil
        capturedViaClipboard = false
        promptMode = .insert
        explainMode = false
    }

    /// Sets the text to be read aloud and resets playback so a stale
    /// word-highlight range from the previous text can't survive the swap.
    ///
    /// The single choke point for updating `readAloudText`. Used both for
    /// the initially captured selection and, later, for swapping in a
    /// preprocessed or summarized rendition -- it intentionally leaves
    /// `readAloudRate` untouched so a mid-session rate adjustment survives
    /// a rendition swap.
    ///
    /// - Parameter text: The text to display and speak.
    func setReadAloudText(_ text: String) {
        readAloudTask?.cancel()
        readAloudTask = nil
        readAloudPlaybackState = .idle
        readAloudHighlightRange = nil
        readAloudText = text
    }

    /// Resets read-aloud session state.
    func resetReadAloudState() {
        readAloudTask?.cancel()
        readAloudTask = nil
        readAloudPreprocessTask?.cancel()
        readAloudPreprocessTask = nil
        readAloudText = nil
        readAloudOriginalText = nil
        readAloudRendition = .original
        readAloudSummarizeState = .idle
        readAloudHighlightRange = nil
        readAloudPlaybackState = .idle
        readAloudErrorMessage = nil
        isReadAloudVisible = false
    }

    /// Full reset including services. Used for error recovery.
    func reset() {
        isOverlayVisible = false
        isRecording = false
        resetSessionState()
        resetReadAloudState()
        Task {
            // resetReadAloudState() cancels the read-aloud task and clears the
            // UI, but it does not stop the audio engine or finish the playback
            // stream. Explicitly stop TTS so audio doesn't keep playing after
            // an error-recovery reset and the session continuation isn't leaked.
            await ttsService?.stop()
            await agent.forceReset()
        }
    }

    // MARK: - Alert Presentation

    /// Shows a native macOS alert dialog with a title and body message.
    ///
    /// - Parameters:
    ///   - title: Short heading for the alert (e.g. "Speech Recognition").
    ///   - body: Descriptive message explaining the issue and any suggested action.
    func presentAlert(title: String, body: String) {
        alertTitle = title
        alertBody = body
        isAlertPresented = true
    }
}
