import SwiftUI
import TranscriptionKit

// MARK: - WhisperKitSection

/// Settings → Transcription block for the on-device WhisperKit provider.
///
/// Three responsibilities:
///   1. Pick the active model variant (`AppSettings.whisperKitModel`).
///   2. Download / delete variants on disk via WhisperKitDownloadState.
///   3. Surface progress + errors so the user knows what's happening during a
///      multi-GB download.
///
/// Always visible regardless of the active transcription provider — the user
/// must download a model before they can switch the provider to WhisperKit,
/// and we don't want them to have to flip the radio first only to discover
/// nothing is downloaded.
@available(macOS 14.0, *)
struct WhisperKitSection: View {

    @Bindable var settings: AppSettings
    @Bindable var download: WhisperKitDownloadState

    var body: some View {
        Section("Local — WhisperKit (on-device, free)") {
            descriptionText

            if download.loadingCatalogue && download.availableVariants.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Fetching model catalogue…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                modelPicker
                downloadActionRow
                if let inFlight = download.inFlight {
                    progressView(variant: inFlight.variant, fraction: inFlight.progress)
                }
                if let err = download.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                downloadedList
            }

            footerHelp
        }
        .task {
            // Lazy refresh: only on first appearance, since fetchAvailableModels
            // hits the network and can take ~1 s.
            if download.availableVariants.isEmpty {
                await download.refreshCatalogue()
            }
        }
    }

    // MARK: - Sub-views

    private var descriptionText: some View {
        Text("Run transcription entirely on your Mac with WhisperKit (CoreML-backed Whisper). No API key, no per-minute cost, no audio leaves the machine. Apple Silicon recommended — the Neural Engine accelerates inference.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var modelPicker: some View {
        HStack {
            Text("Active model")
            Spacer()
            Picker("", selection: $settings.whisperKitModel) {
                Text("(none — pick one to download)").tag("")
                ForEach(download.availableVariants, id: \.self) { variant in
                    Text(label(for: variant)).tag(variant)
                }
            }
            .frame(maxWidth: 380)
            .labelsHidden()
        }
    }

    private var downloadActionRow: some View {
        HStack(spacing: 8) {
            let chosen = settings.whisperKitModel
            let isChosenDownloaded = download.isDownloaded(chosen)
            let busy = (download.inFlight != nil)

            Button {
                Task { await download.download(chosen) }
            } label: {
                Label(busy ? "Downloading…" : "Download", systemImage: "arrow.down.circle")
            }
            .disabled(chosen.isEmpty || busy || isChosenDownloaded)
            .help(chosen.isEmpty
                  ? "Pick a model first."
                  : (isChosenDownloaded ? "Already downloaded." : "Download \(chosen) from HuggingFace into Application Support."))

            if isChosenDownloaded {
                Button(role: .destructive) {
                    Task { await download.delete(chosen) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(busy)
                .help("Remove this model from disk. You can re-download it later.")
            }

            Button {
                Task { await download.refreshCatalogue() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(busy || download.loadingCatalogue)

            Spacer()

            if isChosenDownloaded, let size = download.formattedSize(chosen) {
                Text(size)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Bytes occupied on disk by this model")
            }
        }
    }

    private func progressView(variant: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Downloading \(variant)…")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: fraction, total: 1.0)
            Text(String(format: "%.0f%%", fraction * 100))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var downloadedList: some View {
        if !download.downloadedVariants.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloaded models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(download.downloadedVariants).sorted(), id: \.self) { v in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(v)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let size = download.formattedSize(v) {
                            Text(size)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Button("Delete", role: .destructive) {
                            Task { await download.delete(v) }
                        }
                        .controlSize(.small)
                        .disabled(download.inFlight != nil)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var footerHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let recommended = download.recommendedDefault, !recommended.isEmpty {
                Text("WhisperKit recommends `\(recommended)` for your Mac.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("Models live in `~/Library/Application Support/KosmoNotes/whisperkit/`. The first inference after picking a fresh model takes ~5–10 s to load; subsequent runs are near-instant. To activate, choose a downloaded variant above and set 'Default provider' to WhisperKit.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    /// Render the variant id together with a quality / size hint when we can
    /// recognise the family. Falls back to the raw id for unfamiliar ones so
    /// new HuggingFace uploads don't get hidden.
    private func label(for variant: String) -> String {
        let v = variant.lowercased()
        let quality = qualityHint(for: v)
        return quality.isEmpty ? variant : "\(variant) — \(quality)"
    }

    private func qualityHint(for variant: String) -> String {
        if variant.contains("tiny") { return "fastest, lowest quality (~75 MB)" }
        if variant.contains("base") { return "fast, good quality (~150 MB)" }
        if variant.contains("small") { return "balanced (~500 MB)" }
        if variant.contains("medium") { return "high quality (~1.5 GB)" }
        if variant.contains("large-v3-turbo") { return "best quality, fast (~1.6 GB)" }
        if variant.contains("large-v3") { return "best quality (~3 GB)" }
        if variant.contains("large-v2") { return "previous best (~3 GB)" }
        if variant.contains("distil") { return "distilled, English-only" }
        return ""
    }
}
