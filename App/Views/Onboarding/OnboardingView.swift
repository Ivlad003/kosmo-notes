import SwiftUI
import AppKit

struct OnboardingView: View {
    @Binding var didOnboard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Jarvis Note")
                .font(.title)
                .bold()

            Text("Jarvis Note will request three permissions as you use it. You can grant them now or later when prompted.")
                .foregroundStyle(.secondary)

            permissionRow(
                icon: "mic.fill",
                title: "Microphone",
                description: "For recording your voice in Meeting and Dictation modes.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )

            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                description: "For recording system audio (e.g., other participants in a video call).",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )

            permissionRow(
                icon: "accessibility",
                title: "Accessibility",
                description: "For pasting transcribed text into the focused app (Dictation Mode).",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )

            HStack {
                Spacer()
                Button("Continue") {
                    didOnboard = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @ViewBuilder
    private func permissionRow(icon: String, title: String, description: String, settingsURL: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).font(.caption).foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
        }
    }
}
