import SwiftUI

/// Displays the Kokoro TTS model with download/delete controls and progress.
///
/// Kokoro has a single model (82M), so this shows one card rather than
/// iterating over a registry. Mirrors the `ModelStatusSection` pattern.
struct TtsModelStatusSection: View {
    let downloadState: DownloadState?
    /// Dependency token. Same role as in SttModelStatusSection.
    let modelCacheVersion: Int
    let onStartDownload: () -> Void
    let onConfirmDownload: () -> Void
    let onCancelDownload: () -> Void
    let onRequestDelete: () -> Void

    @State private var showDownloadConfirmation = false

    var body: some View {
        let _ = modelCacheVersion
        return Section("Kokoro Model") {
            modelRow
        }
        .alert(
            "Download Model",
            isPresented: $showDownloadConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Download") {
                onStartDownload()
                onConfirmDownload()
            }
        } message: {
            let entry = KokoroModelManager.modelEntry
            Text("Download \(entry.displayName) (\(ModelFormatting.formatBytes(entry.sizeBytes)))?")
        }
    }

    private var entry: LocalModelEntry {
        KokoroModelManager.modelEntry
    }

    private var modelRow: some View {
        let isCached = KokoroModelManager.isModelCached()
        let isDownloading: Bool = {
            guard case .active = downloadState else { return false }
            return true
        }()

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                modelInfo(isCached: isCached)
                Spacer()
                modelActions(isCached: isCached, isDownloading: isDownloading)
            }
            if isDownloading, case let .active(_, percent) = downloadState {
                downloadProgress(percent: percent)
            }
            if let message = failedMessage {
                downloadFailedBanner(message: message)
            }
        }
        .padding(.vertical, 2)
    }

    private func modelInfo(isCached: Bool) -> some View {
        let sizeText = ModelFormatting.formatBytes(entry.sizeBytes)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.displayName).fontWeight(.medium)
                tierBadge(entry.tier)
                if !isCached {
                    downloadRequiredBadge
                }
            }
            Text("\(entry.description) -- \(sizeText) download")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isCached, let diskSize = KokoroModelManager.cachedModelSize() {
                Text("Cached: \(ModelFormatting.formatBytes(diskSize))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelActions(isCached: Bool, isDownloading: Bool) -> some View {
        if isDownloading {
            Button("Cancel") { onCancelDownload() }
                .controlSize(.small)
        } else if isCached {
            cachedActions
        } else {
            Button("Download") { showDownloadConfirmation = true }
                .controlSize(.small)
        }
    }

    private var cachedActions: some View {
        HStack(spacing: 8) {
            Text("Downloaded")
                .font(.caption)
                .foregroundStyle(.green)
            Button(role: .destructive) {
                onRequestDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func downloadProgress(percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView()
                .progressViewStyle(.linear)
            Text("Downloading... \(percent)%")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Badges

    private func tierBadge(_ tier: ModelTier) -> some View {
        Text(tier.rawValue)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tierColor(tier).opacity(0.15)))
            .foregroundStyle(tierColor(tier))
    }

    private var downloadRequiredBadge: some View {
        Text("Download required")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .foregroundStyle(.orange)
    }

    // MARK: - Failed State

    private var failedMessage: String? {
        guard case let .failed(_, message) = downloadState else { return nil }
        return message
    }

    private func downloadFailedBanner(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.08))
        )
    }

    private func tierColor(_ tier: ModelTier) -> Color {
        switch tier {
        case .edge: .orange
        case .default: .blue
        case .quality: .purple
        }
    }
}

// MARK: - TtsSettingsTab

/// Full Read Aloud settings form with provider, playback, voice, and model cards.
struct TtsSettingsTab: View {
    @Binding var config: Config
    var ttsDownloadState: DownloadState?
    var modelCacheVersion = 0
    @Binding var showDeleteConfirmation: Bool
    var onStartTtsDownload: () -> Void
    var onConfirmTtsDownload: () -> Void
    var onCancelTtsDownload: () -> Void

    var body: some View {
        Form {
            Toggle("Enable read aloud", isOn: $config.tts.enabled)

            if config.tts.enabled {
                Section("Provider") {
                    Picker("Engine", selection: $config.tts.provider) {
                        Text("System (AVSpeech)").tag("system")
                        Text("Kokoro (Neural)").tag("kokoro")
                    }
                }

                Section("Playback") {
                    HStack {
                        Text("Speaking Rate")
                        Spacer()
                        Slider(
                            value: $config.tts.rate,
                            in: 0.1 ... 0.9,
                            step: 0.05
                        )
                        .frame(width: 150)
                        Text(ttsRateLabel)
                            .frame(width: 40, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Speech Preprocessing") {
                    Picker("Preprocessing", selection: $config.tts.preprocessing) {
                        ForEach(TtsPreprocessing.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Text(preprocessingDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Voice") {
                    if config.tts.provider == "kokoro" {
                        Picker("Voice", selection: kokoroVoiceBinding) {
                            ForEach(KokoroVoicePreset.all, id: \.id) { voice in
                                Text(voice.label).tag(voice.id)
                            }
                        }
                    } else {
                        TextField("Language", text: $config.tts.language)
                            .textFieldStyle(.roundedBorder)

                        TextField(
                            "Voice ID (optional)",
                            text: Binding(
                                get: { config.tts.voiceId ?? "" },
                                set: { config.tts.voiceId = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                }

                if config.tts.provider == "kokoro" {
                    TtsModelStatusSection(
                        downloadState: ttsDownloadState,
                        modelCacheVersion: modelCacheVersion,
                        onStartDownload: onStartTtsDownload,
                        onConfirmDownload: onConfirmTtsDownload,
                        onCancelDownload: onCancelTtsDownload,
                        onRequestDelete: { showDeleteConfirmation = true }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var preprocessingDescription: String {
        switch config.tts.preprocessing {
        case .none:
            "Speak the captured text verbatim."
        case .deterministic:
            "Strip formatting (code fences, list markers) before speaking. No model call."
        case .llm:
            "Strip formatting, and offer an in-panel Summarize action powered by the LLM."
        }
    }

    private var ttsRateLabel: String {
        let mapped = 0.25 + Double(config.tts.rate) * 1.75
        return String(format: "%.1fx", mapped)
    }

    private var kokoroVoiceBinding: Binding<String> {
        Binding(
            get: { config.tts.voiceId ?? "af_heart" },
            set: { config.tts.voiceId = $0 }
        )
    }
}
