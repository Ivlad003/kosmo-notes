import SwiftUI
import StorageKit

// MARK: - SessionPickerSheet

/// Sheet for manually attaching recorded sessions to the chat context.
/// Lists the most recent 100 sessions, supports client-side filtering by date
/// string, and multi-select via row taps.
@available(macOS 14.0, *)
struct SessionPickerSheet: View {

    let database: AppDatabase
    @Binding var selectedIds: Set<String>
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var sessions: [SessionRecord] = []
    @State private var searchText: String = ""
    @State private var isLoading: Bool = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter sessions…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSessions.isEmpty {
                Text(sessions.isEmpty ? "No recorded sessions yet." : "No sessions match your filter.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSessions, id: \.id) { session in
                    SessionPickerRow(
                        session: session,
                        isSelected: selectedIds.contains(session.id),
                        formatter: Self.dateFormatter
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSelection(session.id) }
                }
                .listStyle(.plain)
            }

            Divider()

            // Action buttons
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIds.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 440, minHeight: 400)
        .task { await loadSessions() }
    }

    // MARK: - Helpers

    private var filteredSessions: [SessionRecord] {
        guard !searchText.isEmpty else { return sessions }
        let lower = searchText.lowercased()
        return sessions.filter { session in
            Self.dateFormatter.string(from: session.recordedAt).lowercased().contains(lower)
                || session.mode.rawValue.contains(lower)
        }
    }

    private var confirmTitle: String {
        selectedIds.isEmpty ? "Add session" : "Add \(selectedIds.count) session\(selectedIds.count == 1 ? "" : "s")"
    }

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func loadSessions() async {
        defer { isLoading = false }
        sessions = (try? await database.listSessions(limit: 100)) ?? []
    }
}

// MARK: - SessionPickerRow

@available(macOS 14.0, *)
private struct SessionPickerRow: View {

    let session: SessionRecord
    let isSelected: Bool
    let formatter: DateFormatter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(formatter.string(from: session.recordedAt))
                    .font(.body)
                HStack(spacing: 6) {
                    Text(session.mode.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if session.durationSecs > 0 {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(formattedDuration(session.durationSecs))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let lang = session.language {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(lang.uppercased())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func formattedDuration(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        let m = total / 60
        let s = total % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
