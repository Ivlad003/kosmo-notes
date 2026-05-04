import SwiftUI
import StorageKit

// MARK: - PopoverView

/// Primary quick-action surface: mode picker, Record/Stop button, live mic
/// level bar, and a live-transcript tail (empty until v1.1 streaming lands).
///
/// Presented from the status-bar button on left-click. The full settings /
/// library / chat surfaces are still accessible via the right-click menu.
@available(macOS 14.0, *)
struct PopoverView: View {
    let recorder: RecorderState

    // Mode selection persists only for the lifetime of the popover view;
    // it resets to .meeting when a session ends (onChange below).
    @State private var selectedMode: SessionMode = .meeting

    private var transcriptTail: [String] {
        let lines = recorder.liveTranscript
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        return Array(lines.suffix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Mode picker — Dictation is wired in Phase C; greyed out here.
            VStack(alignment: .leading, spacing: 4) {
                Picker("Mode", selection: $selectedMode) {
                    Text("Meeting").tag(SessionMode.meeting)
                    Text("Dictation").tag(SessionMode.dictation)
                }
                .pickerStyle(.segmented)
                .disabled(recorder.isRecording)

                if selectedMode == .dictation {
                    Text("Dictation ships in Phase C.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Record / Stop
            Button {
                Task { @MainActor in
                    if recorder.isRecording {
                        await recorder.stop()
                    } else {
                        await recorder.start(mode: selectedMode)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: recorder.isRecording
                          ? "stop.circle.fill" : "record.circle")
                    Text(recorder.isRecording ? "Stop" : "Record")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .controlSize(.large)
            // Dictation is disabled until Phase C.
            .disabled(!recorder.isRecording && selectedMode == .dictation)

            // Mic level bar — only shown while a recording is in flight.
            if recorder.isRecording {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.18))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width
                                   * max(0, min(1, recorder.micLevel)))
                    }
                }
                .frame(height: 6)
                // Fast linear animation matches the ~33 ms update interval of
                // MicLevelMeter so the bar tracks voice peaks without lag.
                .animation(.linear(duration: 0.033), value: recorder.micLevel)
            }

            // Live transcript tail — visible only once streaming is wired in
            // (v1.1). The section is hidden when liveTranscript is empty so
            // the popover doesn't grow an empty text block in v1.0.
            if !recorder.liveTranscript.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(transcriptTail.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 260)
        // Reset mode to Meeting after each session so stale mode doesn't
        // carry into the next recording. Also suppresses the Dictation
        // "Phase C" hint when the user leaves the popover between sessions.
        .onChange(of: recorder.isRecording) { _, isNowRecording in
            if !isNowRecording { selectedMode = .meeting }
        }
    }
}
