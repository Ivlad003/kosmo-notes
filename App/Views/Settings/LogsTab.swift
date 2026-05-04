import SwiftUI
import OSLog
import AppKit

// MARK: - LogsTab
//
// Live-ish view of the app's recent os_log entries, sourced from
// `OSLogStore(scope: .currentProcessIdentifier)`. No code rewriting required —
// every existing `Logger(subsystem: "dev.kosmonotes...")` callsite already
// writes through the unified logging system; we just read back here.
//
// Why per-process scope? `OSLogStore.local()` requires a private entitlement
// outside of Apple-signed binaries; .currentProcessIdentifier works for any
// app reading its own logs and is sufficient for in-app diagnostics.
//
// Use case: when "Dictation completed but no text appeared", the user opens
// this tab, filters by category=Dictation/AccessibilityPaster, and copies the
// last few entries into a bug report.

@available(macOS 14.0, *)
struct LogsTab: View {

    @State private var entries: [LogEntry] = []
    @State private var loading: Bool = false
    @State private var loadError: String?
    @State private var categoryFilter: String = "All"
    @State private var search: String = ""
    @State private var lastRefreshed: Date?
    @State private var sinceMinutes: Int = 30
    @State private var copiedFlash: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if loading && entries.isEmpty {
                ProgressView("Loading logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                ContentUnavailableView(
                    "Couldn't read logs",
                    systemImage: "exclamationmark.triangle",
                    description: Text(err)
                )
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "No log entries",
                    systemImage: "doc.plaintext",
                    description: Text("Try a longer time range or clear the filter.")
                )
            } else {
                logList
            }
        }
        .task { await refresh() }
    }

    // MARK: - UI sections

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Category", selection: $categoryFilter) {
                    Text("All").tag("All")
                    ForEach(availableCategories, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                }
                .frame(maxWidth: 220)

                Picker("Since", selection: $sinceMinutes) {
                    Text("Last 5 min").tag(5)
                    Text("Last 30 min").tag(30)
                    Text("Last 2 h").tag(120)
                    Text("Last 24 h").tag(60 * 24)
                }
                .frame(maxWidth: 160)

                TextField("Search (text or category)", text: $search)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(loading)

                Button {
                    copyAll()
                } label: {
                    Label(copiedFlash ? "Copied" : "Copy All", systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
                }
                .disabled(filteredEntries.isEmpty)
            }
            HStack(spacing: 8) {
                Text("\(filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let ts = lastRefreshed {
                    Text("· refreshed \(ts.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Tip: ⌘R refreshes. Use Copy All to share with the maintainer when filing a bug.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                LogRowView(entry: entry)
                    .id(entry.id)
                    .listRowSeparator(.visible)
            }
            .listStyle(.plain)
            .onChange(of: filteredEntries.count) { _, _ in
                if let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Filtering

    private var filteredEntries: [LogEntry] {
        entries.filter { entry in
            (categoryFilter == "All" || entry.category == categoryFilter)
            && (search.isEmpty
                || entry.message.localizedCaseInsensitiveContains(search)
                || entry.category.localizedCaseInsensitiveContains(search)
                || entry.subsystem.localizedCaseInsensitiveContains(search))
        }
    }

    private var availableCategories: [String] {
        let set = Set(entries.map(\.category))
        return set.sorted()
    }

    // MARK: - Actions

    private func copyAll() {
        let text = filteredEntries.map { $0.formattedLine }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run { copiedFlash = false }
        }
    }

    private func refresh() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let result = try await Self.fetchEntries(sinceMinutes: sinceMinutes)
            self.entries = result
            self.lastRefreshed = Date()
        } catch {
            self.loadError = "OSLogStore: \(error.localizedDescription)"
        }
    }

    /// Pull the last `sinceMinutes` of own-process os_log entries with
    /// `subsystem` starting `dev.kosmonotes`. The OSLogStore predicate uses
    /// NSPredicate format strings — `BEGINSWITH` is the supported operator.
    private static func fetchEntries(sinceMinutes: Int) async throws -> [LogEntry] {
        try await Task.detached(priority: .userInitiated) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-Double(sinceMinutes * 60)))
            let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", "dev.kosmonotes")
            let entries = try store.getEntries(at: position, matching: predicate)
            var rows: [LogEntry] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                rows.append(LogEntry(
                    id: UUID(),
                    timestamp: log.date,
                    level: Self.shortLevel(log.level),
                    subsystem: log.subsystem,
                    category: log.category,
                    message: log.composedMessage
                ))
            }
            return rows
        }.value
    }

    nonisolated private static func shortLevel(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "DBG"
        case .info: return "INF"
        case .notice: return "NOT"
        case .error: return "ERR"
        case .fault: return "FLT"
        case .undefined: return "?"
        @unknown default: return "?"
        }
    }
}

// MARK: - LogEntry

@available(macOS 14.0, *)
private struct LogEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let level: String
    let subsystem: String
    let category: String
    let message: String

    var formattedLine: String {
        let ts = timestamp.formatted(date: .omitted, time: .standard)
        return "\(ts) [\(level)] \(subsystem)/\(category) — \(message)"
    }
}

// MARK: - LogRowView

@available(macOS 14.0, *)
private struct LogRowView: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.level)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 32, alignment: .leading)

            Text(entry.category)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
    }

    private var levelColor: Color {
        switch entry.level {
        case "ERR", "FLT": return .red
        case "NOT":        return .orange
        case "INF":        return .secondary
        default:           return .secondary
        }
    }
}
