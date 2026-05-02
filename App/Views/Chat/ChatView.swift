import SwiftUI
import AIKit

// MARK: - ChatView

@available(macOS 14.0, *)
struct ChatView: View {

    @Bindable var chat: ChatState
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            messageList
            if let error = chat.lastError {
                errorBanner(error)
            }
            Divider()
            inputArea
        }
        .frame(minWidth: 540, minHeight: 600)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            // Provider switcher pill — bound to settings so change persists.
            Picker("Provider", selection: $settings.llmProvider) {
                ForEach(AppSettings.LLMProviderChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()

            // Context toggle
            Toggle("Last session", isOn: $chat.includeLastSessionContext)
                .toggleStyle(.checkbox)
                .help("Prepend the last completed recording transcript as context")
                .font(.callout)

            Spacer()

            Button(action: { chat.clear() }) {
                Label("Clear", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Clear conversation")
            .disabled(chat.messages.isEmpty && chat.lastError == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(chat.messages.enumerated()), id: \.offset) { idx, message in
                        MessageBubble(message: message)
                            .id(idx)
                    }
                    if chat.isSending {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(16)
            }
            .onChange(of: chat.messages.count) { _, _ in
                // Scroll to bottom when new messages arrive.
                withAnimation {
                    proxy.scrollTo(chat.messages.count - 1, anchor: .bottom)
                }
            }
            .onChange(of: chat.isSending) { _, sending in
                if sending {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.7)
                .progressViewStyle(.circular)
            Text("Thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Spacer()
            Button {
                chat.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Input area

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $chat.inputDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit {
                    // Cmd+Return sends; plain Return adds a newline (axis:.vertical default).
                    Task { await chat.send() }
                }
                .disabled(chat.isSending)

            Button {
                Task { await chat.send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .help("Send (Return)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canSend: Bool {
        !chat.inputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.isSending
    }
}

// MARK: - MessageBubble

@available(macOS 14.0, *)
private struct MessageBubble: View {

    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }
            Text(message.content)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(foregroundColor)
                .font(.body)
            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:
            return Color.accentColor
        case .assistant:
            return Color(NSColor.controlBackgroundColor)
        case .system:
            // System messages are not normally shown but guard the case.
            return Color(NSColor.windowBackgroundColor)
        }
    }

    private var foregroundColor: Color {
        message.role == .user ? .white : Color(NSColor.labelColor)
    }
}
