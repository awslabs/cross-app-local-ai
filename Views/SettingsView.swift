import SwiftUI

// Test

/// The settings window for configuring LLM, STT, TTS, hotkeys, and behavior.
///
/// Reads and writes through a `Config` binding. The parent persists
/// changes to disk when the binding value changes.
struct SettingsView: View {
    @Binding var config: Config
    @Binding var preferences: AppPreferences
    @Binding var quickPrompts: QuickPrompts
    @Binding var history: History
    var availableLlmModels: [ModelInfo]
    var availableSttModels: [ModelInfo]
    var downloadState: DownloadState?
    /// Bumped by AppState whenever a model is deleted or a download
    /// finishes. Model status sections read this so SwiftUI
    /// re-evaluates their body and picks up filesystem changes that
    /// aren't otherwise observable.
    var modelCacheVersion = 0
    var onStartDownload: (String) -> Void
    var onConfirmDownload: () -> Void
    var onCancelDownload: () -> Void
    var onDeleteModel: (String) -> Void
    var onRetryDownload: (String) -> Void
    var onDismissDownloadError: () -> Void

    // STT model downloads
    var sttDownloadState: DownloadState?
    var onStartSttDownload: (String) -> Void
    var onConfirmSttDownload: () -> Void
    var onCancelSttDownload: () -> Void
    var onDeleteSttModel: (String) -> Void

    // TTS model downloads
    var ttsDownloadState: DownloadState?
    var onStartTtsDownload: () -> Void
    var onConfirmTtsDownload: () -> Void
    var onCancelTtsDownload: () -> Void
    var onDeleteTtsModel: () -> Void

    /// Called when the user clicks Regenerate in the Memory tab. The
    /// parent triggers an async extraction via
    /// `AppState.regeneratePreferences(for:)`.
    var onRegeneratePreference: (String) -> Void = { _ in }

    @State private var selectedTab = SettingsTab.general
    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: String?
    @State private var showTtsDeleteConfirmation = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)

            llmTab
                .tabItem { Label("LLM", systemImage: "brain") }
                .tag(SettingsTab.llm)

            sttTab
                .tabItem { Label("Speech", systemImage: "mic") }
                .tag(SettingsTab.stt)

            ttsTab
                .tabItem { Label("Read Aloud", systemImage: "speaker.wave.2") }
                .tag(SettingsTab.tts)

            hotkeysTab
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsTab.hotkeys)

            promptsTab
                .tabItem { Label("Prompts", systemImage: "text.badge.star") }
                .tag(SettingsTab.prompts)

            memoryTab
                .tabItem { Label("Memory", systemImage: "brain.head.profile") }
                .tag(SettingsTab.memory)
        }
        .frame(width: 620, height: 540)
        .fixedSize()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: $config.behavior.launchAtLogin)
            Toggle("Auto-capture selected text", isOn: $config.behavior.autoCaptureSelection)
            Toggle("Restore clipboard after paste", isOn: $config.behavior.restoreClipboard)

            Section("Overlay Font Size") {
                Picker("Size", selection: $config.behavior.fontScale) {
                    ForEach(FontScale.allCases, id: \.self) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Overlay Dismissal") {
                Toggle("Dismiss when hotkey pressed again", isOn: $config.behavior.dismissOnHotkey)
                Toggle("Dismiss on Escape key", isOn: $config.behavior.dismissOnEscape)
                Toggle("Dismiss when switching desktops", isOn: $config.behavior.dismissOnSpaceChange)
                Toggle("Dismiss when clicking outside", isOn: $config.behavior.dismissOnFocusLoss)
            }

            Section("Read Aloud Dismissal") {
                Toggle("Dismiss on Escape key", isOn: $config.behavior.readAloudDismissOnEscape)
                Toggle("Dismiss when clicking outside", isOn: $config.behavior.readAloudDismissOnFocusLoss)
            }

            Section("Text Injection") {
                Picker("Strategy", selection: $config.textInjection.injectionStrategy) {
                    Text("Clipboard").tag("clipboard")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Text(appVersionLabel)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        if build == "1" || build == version {
            return "FastLang v\(version)"
        }
        return "FastLang v\(version) (build \(build))"
    }

    // MARK: - LLM Tab

    private var llmTab: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $config.llm.defaultProvider) {
                    Text("Local (llama.cpp)").tag("local_llamacpp")
                    #if BEDROCK_ENABLED
                        Text("AWS Bedrock").tag("bedrock")
                    #endif
                }

                if !availableLlmModels.isEmpty {
                    // Binds to the active provider's own model field, so the
                    // selection is always a valid tag for the shown options —
                    // no cross-provider mismatch or "invalid selection" churn.
                    Picker("Model", selection: activeModelBinding) {
                        ForEach(availableLlmModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
            }

            Section("Generation") {
                LabeledContent("Max Tokens") {
                    TextField("", value: $config.llm.maxTokens, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Temperature")
                    Spacer()
                    Slider(value: $config.llm.temperature, in: 0 ... 1.5, step: 0.1)
                        .frame(width: 150)
                    Text(String(format: "%.1f", config.llm.temperature))
                        .frame(width: 30)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Timeout (seconds)") {
                    TextField("", value: $config.llm.timeoutSeconds, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if config.llm.defaultProvider == "local_llamacpp" {
                modelStatusSection
            }

            #if BEDROCK_ENABLED
                if config.llm.defaultProvider == "bedrock" {
                    Section("AWS") {
                        TextField("Region", text: $config.llm.region)
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                        TextField(
                            "AWS Profile (optional)",
                            text: Binding(
                                get: { config.llm.awsProfile ?? "" },
                                set: { config.llm.awsProfile = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            #endif
        }
        .formStyle(.grouped)
        .padding()
        .alert("Delete Model", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = modelToDelete {
                    onDeleteModel(id)
                    modelToDelete = nil
                }
            }
        } message: {
            if let id = modelToDelete,
               let entry = LlamaCppModels.findModel(id) {
                Text("Delete \(entry.displayName)? The model file will be removed from disk.")
            }
        }
    }

    // MARK: - Model Status Section

    /// Reads/writes the model id belonging to the currently selected provider,
    /// so the model picker never holds an id from the other provider.
    private var activeModelBinding: Binding<String> {
        Binding(
            get: {
                config.llm.defaultProvider == "bedrock"
                    ? config.llm.bedrockModelId
                    : config.llm.localModelId
            },
            set: { newValue in
                if config.llm.defaultProvider == "bedrock" {
                    config.llm.bedrockModelId = newValue
                } else {
                    config.llm.localModelId = newValue
                }
            }
        )
    }

    private var modelStatusSection: some View {
        // Only rendered for the local provider, so the local model id drives it.
        ModelStatusSection(
            selectedModelId: config.llm.localModelId,
            downloadState: downloadState,
            modelCacheVersion: modelCacheVersion,
            onStartDownload: onStartDownload,
            onConfirmDownload: onConfirmDownload,
            onCancelDownload: onCancelDownload,
            onRequestDelete: { id in
                modelToDelete = id
                showDeleteConfirmation = true
            },
            onRetryDownload: onRetryDownload,
            onDismissDownloadError: onDismissDownloadError
        )
    }

    // MARK: - STT Tab

    private var sttTab: some View {
        SttSettingsTab(
            config: $config,
            availableSttModels: availableSttModels,
            sttDownloadState: sttDownloadState,
            modelCacheVersion: modelCacheVersion,
            onStartSttDownload: onStartSttDownload,
            onConfirmSttDownload: onConfirmSttDownload,
            onCancelSttDownload: onCancelSttDownload,
            onDeleteSttModel: onDeleteSttModel
        )
    }

    // MARK: - TTS Tab

    private var ttsTab: some View {
        TtsSettingsTab(
            config: $config,
            ttsDownloadState: ttsDownloadState,
            modelCacheVersion: modelCacheVersion,
            showDeleteConfirmation: $showTtsDeleteConfirmation,
            onStartTtsDownload: onStartTtsDownload,
            onConfirmTtsDownload: onConfirmTtsDownload,
            onCancelTtsDownload: onCancelTtsDownload
        )
        .alert("Delete TTS Model", isPresented: $showTtsDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDeleteTtsModel()
            }
        } message: {
            let entry = KokoroModelManager.modelEntry
            Text("Delete \(entry.displayName)? The model files will be removed from disk.")
        }
    }

    // MARK: - Hotkeys Tab

    private var hotkeysTab: some View {
        Form {
            Section("Shortcuts") {
                HStack {
                    Text("Toggle Overlay")
                    Spacer()
                    HotkeyRecorderView(hotkeyString: $config.hotkeys.triggerOverlay)
                        .frame(width: 160, height: 24)
                }

                HStack {
                    Text("Push to Talk")
                    Spacer()
                    HotkeyRecorderView(hotkeyString: $config.hotkeys.pushToTalk)
                        .frame(width: 160, height: 24)
                }

                HStack {
                    Text("Read Aloud")
                    Spacer()
                    HotkeyRecorderView(hotkeyString: $config.hotkeys.readAloud)
                        .frame(width: 160, height: 24)
                }

                if FeatureFlags.aiSearchEnabled {
                    HStack {
                        Text("Voice to Google AI")
                        Spacer()
                        HotkeyRecorderView(hotkeyString: $config.hotkeys.aiSearch)
                            .frame(width: 160, height: 24)
                    }
                }
            }

            Section {
                Text("Click a shortcut field, then press the key combination you want to assign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Prompts Tab

    private var promptsTab: some View {
        QuickPromptsSettingsView(quickPrompts: $quickPrompts)
    }

    // MARK: - Memory Tab

    private var memoryTab: some View {
        MemoryView(
            preferences: $preferences,
            history: $history,
            onRegenerate: onRegeneratePreference
        )
    }
}

// MARK: - SettingsTab

private enum SettingsTab: Hashable {
    case general
    case llm
    case stt
    case tts
    case hotkeys
    case prompts
    case memory
}

// MARK: - SttLanguage

/// Languages supported by WhisperKit for the language picker.
private struct SttLanguage {
    let code: String
    let name: String

    static let all: [SttLanguage] = [
        SttLanguage(code: "en", name: "English"),
        SttLanguage(code: "zh", name: "Chinese"),
        SttLanguage(code: "de", name: "German"),
        SttLanguage(code: "es", name: "Spanish"),
        SttLanguage(code: "ru", name: "Russian"),
        SttLanguage(code: "ko", name: "Korean"),
        SttLanguage(code: "fr", name: "French"),
        SttLanguage(code: "ja", name: "Japanese"),
        SttLanguage(code: "pt", name: "Portuguese"),
        SttLanguage(code: "tr", name: "Turkish"),
        SttLanguage(code: "pl", name: "Polish"),
        SttLanguage(code: "ca", name: "Catalan"),
        SttLanguage(code: "nl", name: "Dutch"),
        SttLanguage(code: "ar", name: "Arabic"),
        SttLanguage(code: "sv", name: "Swedish"),
        SttLanguage(code: "it", name: "Italian"),
        SttLanguage(code: "id", name: "Indonesian"),
        SttLanguage(code: "hi", name: "Hindi"),
        SttLanguage(code: "fi", name: "Finnish"),
        SttLanguage(code: "vi", name: "Vietnamese"),
        SttLanguage(code: "he", name: "Hebrew"),
        SttLanguage(code: "uk", name: "Ukrainian"),
        SttLanguage(code: "el", name: "Greek"),
        SttLanguage(code: "ms", name: "Malay"),
        SttLanguage(code: "cs", name: "Czech"),
        SttLanguage(code: "ro", name: "Romanian"),
        SttLanguage(code: "da", name: "Danish"),
        SttLanguage(code: "hu", name: "Hungarian"),
        SttLanguage(code: "ta", name: "Tamil"),
        SttLanguage(code: "no", name: "Norwegian"),
        SttLanguage(code: "th", name: "Thai"),
        SttLanguage(code: "ur", name: "Urdu"),
        SttLanguage(code: "hr", name: "Croatian"),
        SttLanguage(code: "bg", name: "Bulgarian"),
        SttLanguage(code: "lt", name: "Lithuanian"),
        SttLanguage(code: "la", name: "Latin"),
        SttLanguage(code: "sk", name: "Slovak"),
        SttLanguage(code: "sl", name: "Slovenian"),
        SttLanguage(code: "et", name: "Estonian"),
        SttLanguage(code: "lv", name: "Latvian"),
    ]
}

// MARK: - Previews

@MainActor
private func settingsPreview(downloadState: DownloadState? = nil) -> SettingsView {
    SettingsView(
        config: .constant(Config()),
        preferences: .constant(AppPreferences()),
        quickPrompts: .constant(.defaults),
        history: .constant(History()),
        availableLlmModels: [ModelInfo(id: "gemma-4-e2b", displayName: "Gemma 4 E2B IT Q4")],
        availableSttModels: [ModelInfo(id: "whisper-small", displayName: "Whisper Small")],
        downloadState: downloadState,
        onStartDownload: { _ in },
        onConfirmDownload: {},
        onCancelDownload: {},
        onDeleteModel: { _ in },
        onRetryDownload: { _ in },
        onDismissDownloadError: {},
        sttDownloadState: nil,
        onStartSttDownload: { _ in },
        onConfirmSttDownload: {},
        onCancelSttDownload: {},
        onDeleteSttModel: { _ in },
        ttsDownloadState: nil,
        onStartTtsDownload: {},
        onConfirmTtsDownload: {},
        onCancelTtsDownload: {},
        onDeleteTtsModel: {}
    )
}

#Preview("Settings") { settingsPreview() }
#Preview("Settings - Downloading") { settingsPreview(downloadState: .active(modelId: "gemma-4-e2b", percent: 40)) }
#Preview("Settings - Download Failed") {
    settingsPreview(downloadState: .failed(modelId: "gemma-4-e2b", message: "Network connection lost"))
}
