import SwiftUI

// MARK: - AgentConsoleView

/// SwiftUI body for the floating Agent Console window. Streams events from
/// `AgentSessionState`, color-codes by Kind, and exposes a text input that
/// pipes into `AgentSessionState.inject(_:)` so the user can nudge the agent
/// mid-run ("now run the tests", "actually skip step 3", etc).
@available(macOS 14.0, *)
struct AgentConsoleView: View {
    @Bindable var session: AgentSessionState
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            log
            Divider()
            inputBar
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 320, idealHeight: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text(statusText)
                .font(.headline)
            Spacer()
            if case .running = session.status {
                Button(role: .destructive) {
                    Task { await session.requestStop() }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if session.events.isEmpty {
                        Text("Hold ⌘⇧A and speak — or use the Chat window's “Run as agent” button — to launch the agent. Each event the agent emits — your message, its replies, tool calls, tool results — appears here in real time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    // Stable event.id keeps SwiftUI from recycling rows in
                    // the wrong place when events arrive in bursts.
                    ForEach(session.events) { event in
                        AgentEventRow(event: event)
                            .id(event.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: session.events.count) { _, newCount in
                guard newCount > 0, let last = session.events.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("Inject an instruction…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { sendInjection() }
            Button("Send") { sendInjection() }
                .buttonStyle(.bordered)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canInject)
        }
        .padding(10)
    }

    private var canInject: Bool {
        if case .running = session.status { return true }
        return false
    }

    private func sendInjection() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canInject else { return }
        draft = ""
        Task { await session.inject(text) }
    }

    private var statusText: String {
        switch session.status {
        case .idle:
            return "Agent idle"
        case .running(let id):
            return "Agent running · \(String(id.prefix(8)))"
        case .finished(let id):
            return "Agent finished · \(String(id.prefix(8)))"
        case .failed(let msg):
            return "Agent failed: \(msg)"
        }
    }

    private var statusDot: some View {
        let color: Color
        switch session.status {
        case .idle:           color = .gray
        case .running:        color = .green
        case .finished:       color = .blue
        case .failed:         color = .red
        }
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

// MARK: - AgentEventRow

@available(macOS 14.0, *)
struct AgentEventRow: View {
    let event: AgentEvent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            badge
                .frame(width: 110, alignment: .leading)
            Text(event.text)
                .font(.system(.callout, design: event.kind == .toolResult || event.kind == .toolCall ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private var badge: some View {
        let (label, color, icon): (String, Color, String) = {
            switch event.kind {
            case .userMessage:   return ("User",       .blue,    "person.fill")
            case .assistantText: return ("Assistant",  .purple,  "sparkles")
            case .toolCall:      return ("Tool call",  .orange,  "wrench.and.screwdriver")
            case .toolResult:    return ("Tool result",.gray,    "arrow.uturn.left")
            case .error:         return ("Error",      .red,     "exclamationmark.triangle.fill")
            case .stop:          return ("Stop",       .secondary,"checkmark.circle")
            }
        }()
        return HStack(spacing: 3) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(color)
            if let toolName = event.toolName {
                Text("\(toolName)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
