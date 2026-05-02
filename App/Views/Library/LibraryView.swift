import SwiftUI
import AppKit
import AVKit
import AVFoundation
import StorageKit
import TranscriptionKit

// MARK: - LibraryView

@available(macOS 14.0, *)
struct LibraryView: View {

    @Bindable var state: LibraryState

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let sid = state.selectedSessionId,
               let session = state.sessions.first(where: { $0.id == sid }) {
                SessionDetailView(session: session, state: state)
                    // Re-create the detail view when selection changes so player resets.
                    .id(sid)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "waveform",
                    description: Text("Choose a session from the sidebar.")
                )
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .task {
            // Initial load when window opens.
            await state.refresh()
        }
    }
}

// MARK: - SidebarView

@available(macOS 14.0, *)
private struct SidebarView: View {

    @Bindable var state: LibraryState

    var body: some View {
        VStack(spacing: 0) {
            // Search field at top of sidebar.
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts…", text: $state.query)
                    .textFieldStyle(.plain)
                if !state.query.isEmpty {
                    Button {
                        state.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            // Mode filter picker.
            Picker("Filter", selection: $state.modeFilter) {
                ForEach(ModeFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if state.sessions.isEmpty {
                Spacer()
                Text(state.query.isEmpty ? "No sessions yet." : "No results.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            } else {
                List(state.sessions, id: \.id, selection: $state.selectedSessionId) { session in
                    SessionRowView(session: session)
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Library")
    }
}

// MARK: - SessionRowView

@available(macOS 14.0, *)
private struct SessionRowView: View {

    let session: SessionRecord
    @State private var hasScreenRecording: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(session.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .fontWeight(.medium)
                if hasScreenRecording {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Screen recording available")
                }
            }
            HStack(spacing: 6) {
                Label(session.mode.rawValue.capitalized,
                      systemImage: session.mode == .meeting ? "person.2" : "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(formatDuration(session.durationSecs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .task(id: session.id) {
            // Check for screen.mp4 sidecar using the standard recordings path.
            let root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("JarvisNote/recordings")
                .appendingPathComponent(session.id)
            let screenURL = root?.appendingPathComponent("screen.mp4")
            if let url = screenURL {
                hasScreenRecording = FileManager.default.fileExists(atPath: url.path)
            }
        }
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - SessionDetailView

@available(macOS 14.0, *)
private struct SessionDetailView: View {

    let session: SessionRecord
    @Bindable var state: LibraryState

    // Player state lives here, not in LibraryState, because it's ephemeral UI-only.
    @State private var playerModel = PlayerModel()
    @State private var segments: [TranscriptSegment] = []
    @State private var segmentsLoading = true
    @State private var hasScreenVideo: Bool = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SessionHeaderView(session: session)
                .padding()

            Divider()

            // Audio player
            AVPlayerRepresentable(model: playerModel)
                .frame(height: 44)
                .padding(.horizontal)
                .padding(.vertical, 8)

            // Skip buttons + Export menu + Open in Finder.
            HStack(spacing: 16) {
                Button {
                    playerModel.skip(by: -15)
                } label: {
                    Label("−15s", systemImage: "gobackward.15")
                }
                .buttonStyle(.borderless)

                Button {
                    playerModel.skip(by: 15)
                } label: {
                    Label("+15s", systemImage: "goforward.15")
                }
                .buttonStyle(.borderless)

                Spacer()

                Menu {
                    Button("Markdown bundle (.md)") { Task { await runExport(format: .markdown) } }
                    Button("Plain transcript (.txt)") { Task { await runExport(format: .plainText) } }
                    Button("Audio file (.m4a)") { Task { await runExport(format: .audio) } }
                    if hasScreenVideo {
                        Button("Screen recording (.mp4)") { Task { await runExport(format: .screenVideo) } }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .menuStyle(.button)

                Button {
                    openInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Transcript
            if segmentsLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if segments.isEmpty {
                ContentUnavailableView(
                    "No Transcript",
                    systemImage: "doc.text",
                    description: Text("Transcription may still be in progress or did not complete.")
                )
            } else {
                TranscriptView(segments: segments, playerModel: playerModel)
            }
        }
        .task {
            await loadAudio()
            await loadTranscript()
            // Check for screen.mp4 sidecar to decide whether to show the export option.
            let audioURL = await state.audioFileURL(for: session.id)
            let screenURL = audioURL.deletingLastPathComponent().appendingPathComponent("screen.mp4")
            hasScreenVideo = FileManager.default.fileExists(atPath: screenURL.path)
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func loadAudio() async {
        let audioURL = await state.audioFileURL(for: session.id)
        // Prefer screen.mp4 when present — it contains both video and the system audio track.
        let screenURL = audioURL.deletingLastPathComponent().appendingPathComponent("screen.mp4")
        let urlToLoad: URL
        if FileManager.default.fileExists(atPath: screenURL.path) {
            urlToLoad = screenURL
        } else if FileManager.default.fileExists(atPath: audioURL.path) {
            urlToLoad = audioURL
        } else {
            return
        }
        playerModel.load(url: urlToLoad)
    }

    private func loadTranscript() async {
        defer { segmentsLoading = false }
        do {
            segments = try await state.loadSegments(for: session.id)
        } catch {
            print("[SessionDetailView] loadSegments failed: \(error)")
        }
    }

    private func openInFinder() {
        Task {
            let audioURL = await state.audioFileURL(for: session.id)
            NSWorkspace.shared.activateFileViewerSelecting([audioURL])
        }
    }

    private func runExport(format: SessionExporter.Format) async {
        do {
            let dir = await state.audioFileURL(for: session.id).deletingLastPathComponent()
            try await SessionExporter.exportSession(session, sessionDir: dir, format: format)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - SessionHeaderView

@available(macOS 14.0, *)
private struct SessionHeaderView: View {

    let session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.recordedAt.formatted(date: .complete, time: .standard))
                    .font(.headline)
                Spacer()
                StatusBadge(status: session.status)
            }
            HStack(spacing: 12) {
                Label(session.mode.rawValue.capitalized,
                      systemImage: session.mode == .meeting ? "person.2" : "text.bubble")
                Label(formatDuration(session.durationSecs), systemImage: "clock")
                if let lang = session.language {
                    Label(lang.uppercased(), systemImage: "globe")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - StatusBadge

@available(macOS 14.0, *)
private struct StatusBadge: View {

    let status: SessionStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor.opacity(0.15))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case .complete: return .green
        case .recording: return .red
        case .transcribing: return .orange
        case .failed: return .secondary
        }
    }
}

// MARK: - TranscriptView

@available(macOS 14.0, *)
private struct TranscriptView: View {

    let segments: [TranscriptSegment]
    @Bindable var playerModel: PlayerModel

    var body: some View {
        ScrollViewReader { proxy in
            List(segments.indices, id: \.self) { index in
                let seg = segments[index]
                let isActive = isActive(seg)
                TranscriptRowView(segment: seg, isActive: isActive)
                    .id(index)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Seek to the start of the tapped segment.
                        playerModel.seek(to: seg.start)
                    }
                    .listRowBackground(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .listStyle(.plain)
            // When the active segment changes, scroll it into view.
            .onChange(of: activeIndex) { _, newIndex in
                if let idx = newIndex {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }

    private func isActive(_ seg: TranscriptSegment) -> Bool {
        let t = playerModel.currentTime
        return t >= seg.start && t < seg.end
    }

    // Compute the active index once so onChange can compare integers, not segments.
    private var activeIndex: Int? {
        let t = playerModel.currentTime
        return segments.indices.first { segments[$0].start <= t && t < segments[$0].end }
    }
}

// MARK: - TranscriptRowView

@available(macOS 14.0, *)
private struct TranscriptRowView: View {

    let segment: TranscriptSegment
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(formatTimestamp(segment.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 2)

            Text(segment.text)
                .font(.callout)
                .foregroundStyle(isActive ? Color.primary : Color.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func formatTimestamp(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - PlayerModel

/// Holds the AVPlayer and exposes current time for the live-highlight UI.
///
/// @Observable so SwiftUI automatically re-renders transcript rows when
/// `currentTime` changes via the periodic time observer.
@available(macOS 14.0, *)
@Observable
@MainActor
final class PlayerModel {

    // Exposed to AVPlayerRepresentable for the underlying view.
    let player = AVPlayer()

    /// Updated by a periodic time observer at 100 ms resolution.
    var currentTime: TimeInterval = 0

    private var timeObserverToken: Any?

    init() {
        // 100 ms polling matches the ±100 ms seek accuracy requirement from AC-11.
        let interval = CMTime(value: 1, timescale: 10)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }

    /// Explicit cleanup. Call from `.onDisappear`; deinit can't touch
    /// `@MainActor` state in Swift 6 strict concurrency mode.
    func invalidate() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player.pause()
    }

    func load(url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
    }

    func skip(by seconds: TimeInterval) {
        let current = player.currentTime()
        let target = CMTimeAdd(current, CMTimeMakeWithSeconds(seconds, preferredTimescale: 600))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(to seconds: TimeInterval) {
        let target = CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - AVPlayerRepresentable

/// NSViewRepresentable wrapping AVPlayerView with floating controls.
@available(macOS 14.0, *)
struct AVPlayerRepresentable: NSViewRepresentable {

    @Bindable var model: PlayerModel

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // Player reference is stable; no update needed on re-render.
        if nsView.player !== model.player {
            nsView.player = model.player
        }
    }
}
