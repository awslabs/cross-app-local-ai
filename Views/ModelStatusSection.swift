import SwiftUI

// MARK: - ModelStatusSection

/// Displays each registry model with download/delete controls and progress.
struct ModelStatusSection: View {
    let selectedModelId: String
    let downloadState: DownloadState?
    /// Dependency token. Same role as in SttModelStatusSection.
    let modelCacheVersion: Int
    let onStartDownload: (String) -> Void
    let onConfirmDownload: () -> Void
    let onCancelDownload: () -> Void
    let onRequestDelete: (String) -> Void
    var onRetryDownload: ((String) -> Void)?
    var onDismissDownloadError: (() -> Void)?

    @State private var confirmingDownloadId: String?

    var body: some View {
        let _ = modelCacheVersion
        return Section("Models") {
            ForEach(LlamaCppModels.modelRegistry, id: \.id) { entry in
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
            if let id = confirmingDownloadId, let entry = LlamaCppModels.findModel(id) {
                Text("Download \(entry.displayName) (\(ModelFormatting.formatBytes(entry.sizeBytes)))?")
            }
        }
    }

    private func modelRow(_ entry: LocalModelEntry) -> some View {
        let isCached = LlamaCppModels.isModelCached(entry.id)
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
                downloadFailedBanner(message: message, modelId: entry.id)
            }
        }
        .padding(.vertical, 2)
    }

    private func modelInfo(_ entry: LocalModelEntry, isCached: Bool) -> some View {
        let sizeText = ModelFormatting.formatBytes(entry.sizeBytes)
        let scoreText = String(format: "%.1f", entry.qualityScore)

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
            Text("\(entry.description) -- \(sizeText), score \(scoreText)")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func downloadFailedBanner(message: String, modelId: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
            if let onRetryDownload {
                Button("Retry") { onRetryDownload(modelId) }
                    .controlSize(.small)
            }
            if let onDismissDownloadError {
                Button {
                    onDismissDownloadError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
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

// MARK: - ModelFormatting

enum ModelFormatting {
    static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000.0
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000.0
        return String(format: "%.0f MB", mb)
    }
}
