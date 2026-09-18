import SwiftUI

/// Displays each WhisperKit model with download/delete controls and progress.
///
/// Mirrors `ModelStatusSection` for the LLM tab but backed by
/// `WhisperKitModels` and `WhisperKitModelManager`.
struct SttModelStatusSection: View {
    let selectedModelId: String
    let downloadState: DownloadState?
    /// Dependency token. Not used for its value; reading it in `body`
    /// forces SwiftUI to re-evaluate cache-status checks (which hit
    /// the filesystem) after a delete or download completes.
    let modelCacheVersion: Int
    let onStartDownload: (String) -> Void
    let onConfirmDownload: () -> Void
    let onCancelDownload: () -> Void
    let onRequestDelete: (String) -> Void

    @State private var confirmingDownloadId: String?

    var body: some View {
        // Establish a SwiftUI dependency on the cache-version counter so
        // filesystem-backed `isModelCached(...)` reads inside `modelRow`
        // re-run when we bump the counter.
        let _ = modelCacheVersion
        return Section("WhisperKit Models") {
            ForEach(WhisperKitModels.modelRegistry, id: \.id) { entry in
                modelRow(entry)
            }
        }
        .alert(
            "Download Model",
            isPresented: Binding(
                get: { confirmingDownloadId != nil },
                set: { if !$0 { confirmingDownloadId = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmingDownloadId = nil }
            Button("Download") {
                if let id = confirmingDownloadId {
                    onStartDownload(id)
                    onConfirmDownload()
                    confirmingDownloadId = nil
                }
            }
        } message: {
            if let id = confirmingDownloadId, let entry = WhisperKitModels.findModel(id) {
                Text("Download \(entry.displayName) (\(ModelFormatting.formatBytes(entry.sizeBytes)))?")
            }
        }
    }

    private func modelRow(_ entry: LocalModelEntry) -> some View {
        let isCached = WhisperKitModelManager.isModelCached(entry.id)
        let isDownloading = downloadingModelId == entry.id
        let failedMessage = failedMessageForModel(entry.id)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                modelInfo(entry, isCached: isCached)
                Spacer()
                modelActions(entry, isCached: isCached, isDownloading: isDownloading)
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

    private func modelInfo(_ entry: LocalModelEntry, isCached: Bool) -> some View {
        let sizeText = ModelFormatting.formatBytes(entry.sizeBytes)
        let memText = ModelFormatting.formatBytes(UInt64(entry.memoryMB) * 1_000_000)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.displayName).fontWeight(.medium)
                tierBadge(entry.tier)
                if selectedModelId == entry.id {
                    activeBadge
                }
                if selectedModelId == entry.id, !isCached {
                    downloadRequiredBadge
                }
            }
            Text("\(entry.description) -- \(sizeText) disk, ~\(memText) memory")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isCached, let diskSize = WhisperKitModelManager.cachedModelSize(entry.id) {
                Text("Cached: \(ModelFormatting.formatBytes(diskSize))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelActions(
        _ entry: LocalModelEntry,
        isCached: Bool,
        isDownloading: Bool
    ) -> some View {
        if isDownloading {
            Button("Cancel") { onCancelDownload() }
                .controlSize(.small)
        } else if isCached {
            cachedActions(entry)
        } else {
            Button("Download") { confirmingDownloadId = entry.id }
                .controlSize(.small)
        }
    }

    private func cachedActions(_ entry: LocalModelEntry) -> some View {
        HStack(spacing: 8) {
            Text("Downloaded")
                .font(.caption)
                .foregroundStyle(.green)
            Button(role: .destructive) {
                onRequestDelete(entry.id)
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

    private var activeBadge: some View {
        Text("Active")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.qgAccent.opacity(0.2)))
            .foregroundStyle(Color.qgAccent)
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

    private func failedMessageForModel(_ modelId: String) -> String? {
        guard case let .failed(failedId, message) = downloadState,
              failedId == modelId else { return nil }
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

    // MARK: - Helpers

    private var downloadingModelId: String? {
        guard case let .active(modelId, _) = downloadState else { return nil }
        return modelId
    }

    private func tierColor(_ tier: ModelTier) -> Color {
        switch tier {
        case .edge: .orange
        case .default: .blue
        case .quality: .purple
        }
    }
}

// MARK: - SttSettingsTab

/// Full Speech settings form with model picker, language, input device, and model cards.
struct SttSettingsTab: View {
    @Binding var config: Config
    var availableSttModels: [ModelInfo]
    var sttDownloadState: DownloadState?
    var modelCacheVersion = 0
    var onStartSttDownload: (String) -> Void
    var onConfirmSttDownload: () -> Void
    var onCancelSttDownload: () -> Void
    var onDeleteSttModel: (String) -> Void

    @State private var inputDevices: [AudioInputDevice] = []
    @State private var showDeleteConfirmation = false
    @State private var modelToDelete: String?

    var body: some View {
        Form {
            Toggle("Enable speech-to-text", isOn: $config.stt.enabled)

            if config.stt.enabled {
                Section("Input Device") {
                    Picker(
                        "Microphone",
                        selection: Binding(
                            get: { config.stt.audioInputDeviceUid ?? "" },
                            set: { config.stt.audioInputDeviceUid = $0.isEmpty ? nil : $0 }
                        )
                    ) {
                        Text("System Default").tag("")
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }

                Section("WhisperKit") {
                    if !availableSttModels.isEmpty {
                        Picker("Model", selection: $config.stt.whisperModelId) {
                            ForEach(availableSttModels, id: \.id) { model in
                                sttModelLabel(for: model).tag(model.id)
                            }
                        }
                    }

                    TextField(
                        "Language",
                        text: Binding(
                            get: { config.stt.language ?? "en" },
                            set: { config.stt.language = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                SttModelStatusSection(
                    selectedModelId: config.stt.whisperModelId,
                    downloadState: sttDownloadState,
                    modelCacheVersion: modelCacheVersion,
                    onStartDownload: onStartSttDownload,
                    onConfirmDownload: onConfirmSttDownload,
                    onCancelDownload: onCancelSttDownload,
                    onRequestDelete: { id in
                        modelToDelete = id
                        showDeleteConfirmation = true
                    }
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { inputDevices = AudioDeviceEnumerator.inputDevices() }
        .alert("Delete STT Model", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = modelToDelete {
                    onDeleteSttModel(id)
                    modelToDelete = nil
                }
            }
        } message: {
            if let id = modelToDelete,
               let entry = WhisperKitModels.findModel(id) {
                Text("Delete \(entry.displayName)? The model files will be removed from disk.")
            }
        }
    }

    @ViewBuilder
    private func sttModelLabel(for model: ModelInfo) -> some View {
        if let entry = WhisperKitModels.findModel(model.id) {
            let diskLabel = ModelFormatting.formatBytes(entry.sizeBytes)
            let memLabel = ModelFormatting.formatBytes(UInt64(entry.memoryMB) * 1_000_000)
            VStack(alignment: .leading) {
                Text(model.displayName)
                Text("\(diskLabel) disk / ~\(memLabel) memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(model.displayName)
        }
    }
}
