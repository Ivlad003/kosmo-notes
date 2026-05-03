# KosmoNotes Consumerization UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make KosmoNotes easier for office workers and managers by simplifying first-run flow, menu-bar actions, settings structure, post-recording results, and user-visible failure states without removing advanced control.

**Architecture:** Keep the existing app architecture intact, but move mainstream UX into clearer task-first flows and push advanced surfaces behind progressive disclosure. Implement this as focused view splits and presentation-layer changes in `App/`, not as a storage or provider rewrite.

**Tech Stack:** SwiftUI, AppKit, AVKit, Observation, existing `App/State/*` objects, existing package test/build flow, XcodeGen + Xcode build

---

## File map

### Existing files to modify

- `App/Views/Onboarding/OnboardingView.swift` — replace static permission-only first run with a task-first guided flow
- `App/KosmoNotesApp.swift` — rename menu actions, add clearer status text, wire menu hints to recorder state
- `App/Views/Settings/SettingsView.swift` — reduce top-level tab overload, move expert controls behind an Advanced surface
- `App/Views/Library/LibraryView.swift` — move summary/actions/share/export above transcript-heavy detail flow
- `App/State/RecorderState.swift` — expose user-visible post-processing state and partial-failure summaries
- `App/State/LibraryState.swift` — stop silently swallowing retrieval failures; surface user-readable status
- `App/State/ShareCoordinator.swift` — return user-readable sharing failures instead of only action-side effects
- `README.md` — refresh user-facing product language so the app stops sounding developer-first

### New files to create

- `App/Views/Onboarding/FirstRunGoalPicker.swift` — first-run goal chooser for Meeting / Dictation / Voice Note
- `App/Views/Settings/GeneralSettingsTab.swift` — mainstream settings entry point
- `App/Views/Settings/RecordingSettingsTab.swift` — simplified recording controls and human-readable labels
- `App/Views/Settings/AdvancedSettingsTab.swift` — home for provider routing, process tap, streaming, markdown, and agent surfaces
- `App/Views/Library/SessionResultSummaryView.swift` — result-first block for summary, actions, share, export, and ask
- `App/Views/Shared/UserFacingStatusBanner.swift` — reusable inline banner for partial-success and permission problems

### Validation files and commands

- App build: `project.yml`, generated `KosmoNotes.xcodeproj`
- Package tests: `Package.swift`
- Existing smoke reference: `docs/manual-smoke/2026-05-02-ac9b-dictation-latency-procedure.md`

---

### Task 1: Replace permission-first onboarding with a guided first success

**Files:**
- Create: `App/Views/Onboarding/FirstRunGoalPicker.swift`
- Modify: `App/Views/Onboarding/OnboardingView.swift`
- Modify: `App/KosmoNotesApp.swift`

- [ ] **Step 1: Add a first-run goal model and picker view**

```swift
import SwiftUI

enum FirstRunGoal: String, CaseIterable, Identifiable {
    case meeting
    case dictation
    case voiceNote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meeting: return "Record a meeting"
        case .dictation: return "Dictate text"
        case .voiceNote: return "Save a voice note"
        }
    }

    var subtitle: String {
        switch self {
        case .meeting: return "Capture your mic and, if needed, the other side of the call."
        case .dictation: return "Speak and paste the result into the current app."
        case .voiceNote: return "Turn speech into a structured note."
        }
    }
}

struct FirstRunGoalPicker: View {
    @Binding var goal: FirstRunGoal

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What do you want to do first?")
                .font(.headline)

            ForEach(FirstRunGoal.allCases) { option in
                Button {
                    goal = option
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.title).font(.body.weight(.medium))
                        Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .buttonStyle(.borderedProminent)
                .tint(goal == option ? .accentColor : .gray.opacity(0.2))
            }
        }
    }
}
```

- [ ] **Step 2: Rewrite onboarding around one goal and one test action**

```swift
@State private var goal: FirstRunGoal = .meeting

var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        Text("Welcome to KosmoNotes")
            .font(.title)
            .bold()

        FirstRunGoalPicker(goal: $goal)

        PermissionChecklist(goal: goal)

        Button(buttonTitle(for: goal)) {
            didOnboard = true
            NotificationCenter.default.post(
                name: .startFirstRunDemo,
                object: goal
            )
        }
        .keyboardShortcut(.defaultAction)
    }
    .padding(24)
    .frame(width: 520)
}

private func buttonTitle(for goal: FirstRunGoal) -> String {
    switch goal {
    case .meeting: return "Try a 10-second meeting test"
    case .dictation: return "Try dictation"
    case .voiceNote: return "Create a first voice note"
    }
}
```

- [ ] **Step 3: Gate permissions by goal instead of always showing all three**

```swift
@ViewBuilder
private func PermissionChecklist(goal: FirstRunGoal) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        permissionRow(
            icon: "mic.fill",
            title: "Microphone",
            description: "Needed for all three modes.",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )

        if goal == .meeting {
            permissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                description: "Needed only if you want system audio from calls.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )
        }

        if goal == .dictation {
            permissionRow(
                icon: "accessibility",
                title: "Accessibility",
                description: "Needed to paste the dictated text into the active app.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        }
    }
}
```

- [ ] **Step 4: Handle the first-run notification in the app delegate**

```swift
extension Notification.Name {
    static let startFirstRunDemo = Notification.Name("startFirstRunDemo")
}

NotificationCenter.default.addObserver(
    forName: .startFirstRunDemo,
    object: nil,
    queue: .main
) { [weak self] note in
    guard let goal = note.object as? FirstRunGoal else { return }
    switch goal {
    case .meeting:
        self?.recordToggleAction()
    case .dictation:
        self?.showSettings(nil)
    case .voiceNote:
        self?.voiceNoteToggleAction()
    }
}
```

- [ ] **Step 5: Build the app and confirm the new onboarding path compiles**

Run:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme KosmoNotes -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add App/Views/Onboarding/FirstRunGoalPicker.swift App/Views/Onboarding/OnboardingView.swift App/KosmoNotesApp.swift
git commit -m "feat(onboarding): guide first-run setup by task"
```

---

### Task 2: Rename menu-bar actions and expose clearer live state

**Files:**
- Modify: `App/KosmoNotesApp.swift`
- Create: `App/Views/Shared/UserFacingStatusBanner.swift`

- [ ] **Step 1: Replace technical menu labels with task-first labels**

```swift
let recordItem = NSMenuItem(
    title: "Record meeting",
    action: #selector(recordToggleAction),
    keyEquivalent: "r"
)

let voiceNoteItem = NSMenuItem(
    title: "Quick voice note",
    action: #selector(voiceNoteToggleAction),
    keyEquivalent: "n"
)

let libraryItem = NSMenuItem(
    title: "My recordings…",
    action: #selector(openLibraryAction),
    keyEquivalent: "l"
)
```

- [ ] **Step 2: Add one disabled helper item that explains the selected action**

```swift
let helperItem = NSMenuItem(title: "Meeting mode records your mic and optional call audio.", action: nil, keyEquivalent: "")
helperItem.isEnabled = false
helperItem.identifier = NSUserInterfaceItemIdentifier("helperCopy")
menu.addItem(helperItem)
```

- [ ] **Step 3: Update `menuNeedsUpdate` so titles reflect current state**

```swift
if let recordItem = menu.item(withIdentifier: .init("recordToggle")) {
    recordItem.title = recorder.status.isBusy ? "Stop recording" : "Record meeting"
}

if let helperItem = menu.item(withIdentifier: .init("helperCopy")) {
    helperItem.title = switch recorder.status {
    case .idle: "Ready to capture a meeting."
    case .recording: "Recording in progress."
    case .processing: "Processing transcript and summary."
    default: "Choose a task to begin."
    }
}
```

- [ ] **Step 4: Add a reusable inline status banner for views that need partial-success messaging**

```swift
import SwiftUI

struct UserFacingStatusBanner: View {
    let title: String
    let detail: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
```

- [ ] **Step 5: Rebuild and smoke-test the menu flow**

Run:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme KosmoNotes -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

Manual check:
- menu shows “Record meeting”
- menu changes to “Stop recording” while busy
- helper copy changes between idle / recording / processing

- [ ] **Step 6: Commit**

```bash
git add App/KosmoNotesApp.swift App/Views/Shared/UserFacingStatusBanner.swift
git commit -m "feat(menu): use task-first labels and live status copy"
```

---

### Task 3: Split settings into mainstream and advanced surfaces

**Files:**
- Create: `App/Views/Settings/GeneralSettingsTab.swift`
- Create: `App/Views/Settings/RecordingSettingsTab.swift`
- Create: `App/Views/Settings/AdvancedSettingsTab.swift`
- Modify: `App/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Reduce the top-level tab list to four mainstream tabs plus Advanced**

```swift
TabView {
    GeneralSettingsTab(settings: settings)
        .tabItem { Label("General", systemImage: "slider.horizontal.3") }

    RecordingSettingsTab(settings: settings)
        .tabItem { Label("Recording", systemImage: "waveform") }

    AIProvidersTab(settings: settings)
        .tabItem { Label("AI & Transcription", systemImage: "sparkles") }

    PrivacyTab()
        .tabItem { Label("Privacy & Sharing", systemImage: "lock.shield") }

    AdvancedSettingsTab(settings: settings)
        .tabItem { Label("Advanced", systemImage: "gearshape.2") }
}
```

- [ ] **Step 2: Move simple user-facing preferences into `GeneralSettingsTab`**

```swift
struct GeneralSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Default action") {
                Picker("When I open KosmoNotes", selection: $settings.recordingMode) {
                    Text("Record meeting").tag(AppSettings.RecordingMode.audioOnly)
                    Text("Record meeting with screen").tag(AppSettings.RecordingMode.audioAndScreen)
                }
            }

            Section("Hotkeys") {
                HotkeysTab(settings: settings)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 3: Keep expert controls, but move them behind an Advanced container**

```swift
struct AdvancedSettingsTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            DisclosureGroup("Capture internals") {
                Text("Adjust providers, codecs, and process-specific capture.")
                TranscriptionInternalsSection(settings: settings)
            }

            DisclosureGroup("Automation and export") {
                MarkdownExportTab(settings: settings)
                AgentTab(settings: settings)
                StreamingTab(settings: settings)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 4: Build and confirm the settings window no longer shows nine peer tabs**

Run:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme KosmoNotes -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

Manual check:
- tabs read General / Recording / AI & Transcription / Privacy & Sharing / Advanced
- provider and agent controls are still reachable
- power-user surfaces are no longer first-class tabs

- [ ] **Step 5: Commit**

```bash
git add App/Views/Settings/GeneralSettingsTab.swift App/Views/Settings/RecordingSettingsTab.swift App/Views/Settings/AdvancedSettingsTab.swift App/Views/Settings/SettingsView.swift
git commit -m "feat(settings): separate mainstream controls from advanced ones"
```

---

### Task 4: Replace provider-first labels with user-goal language

**Files:**
- Modify: `App/Views/Settings/SettingsView.swift`
- Modify: `App/State/AppSettings.swift`

- [ ] **Step 1: Rename provider-facing labels in the recording settings**

```swift
Section("Recording quality") {
    Picker("Preset", selection: $settings.storageProfile) {
        Text("Best quality").tag(AppSettings.StorageProfile.quality)
        Text("Balanced").tag(AppSettings.StorageProfile.balanced)
        Text("Save space").tag(AppSettings.StorageProfile.compact)
    }
    .pickerStyle(.segmented)
}

Section("Transcription quality and speed") {
    Picker("Mode", selection: $settings.transcriptionProvider) {
        Text("Live transcript").tag(AppSettings.TranscriptionProviderChoice.deepgram)
        Text("Best language coverage").tag(AppSettings.TranscriptionProviderChoice.openaiWhisper)
        Text("One-step transcript + summary").tag(AppSettings.TranscriptionProviderChoice.gemini)
        Text("Use my OpenRouter setup").tag(AppSettings.TranscriptionProviderChoice.openrouterAudio)
    }
}
```

- [ ] **Step 2: Keep exact provider names available as helper copy, not as the main control**

```swift
Text("Advanced: Live transcript uses Deepgram. Best language coverage uses OpenAI Whisper. One-step transcript + summary uses Gemini.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 3: Update `AppSettings` display strings so shared labels stay consistent**

```swift
var consumerFacingName: String {
    switch self {
    case .quality: return "Best quality"
    case .balanced: return "Balanced"
    case .compact: return "Save space"
    }
}
```

- [ ] **Step 4: Rebuild and do a terminology smoke pass**

Run:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme KosmoNotes -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

Manual check:
- a new user can understand settings labels without knowing model or provider names
- advanced labels still preserve the technical mapping

- [ ] **Step 5: Commit**

```bash
git add App/Views/Settings/SettingsView.swift App/State/AppSettings.swift
git commit -m "feat(copy): present recording choices in user-facing language"
```

---

### Task 5: Make the library result-first instead of transcript-first

**Files:**
- Create: `App/Views/Library/SessionResultSummaryView.swift`
- Modify: `App/Views/Library/LibraryView.swift`

- [ ] **Step 1: Create a summary-first block for the session detail screen**

```swift
import SwiftUI
import StorageKit

struct SessionResultSummaryView: View {
    let session: SessionRecord
    let onShare: () -> Void
    let onExport: () -> Void
    let onAsk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Result").font(.headline)
            Text(session.status == .ready ? "Your transcript and summary are ready." : "This recording is still processing.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Share", action: onShare)
                Button("Export", action: onExport)
                Button("Ask", action: onAsk)
            }
        }
        .padding()
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: Insert the result block above the player and transcript**

```swift
VStack(alignment: .leading, spacing: 0) {
    SessionHeaderView(session: session)
        .padding()

    SessionResultSummaryView(
        session: session,
        onShare: { Task { await runShare() } },
        onExport: { Task { await runExport(format: .markdown) } },
        onAsk: { state.openInChat(sessionID: session.id) }
    )
    .padding(.horizontal)
    .padding(.bottom, 8)

    Divider()
    AVPlayerRepresentable(model: playerModel)
```

- [ ] **Step 3: Keep transcript and playback below the result block, not at the top of the page**

```swift
if segmentsLoading {
    ProgressView("Loading transcript…")
} else if segments.isEmpty {
    ContentUnavailableView(
        "No Transcript Yet",
        systemImage: "doc.text",
        description: Text("The recording exists, but the transcript is not ready yet.")
    )
} else {
    TranscriptView(segments: segments, playerModel: playerModel)
}
```

- [ ] **Step 4: Build and manually verify a completed session opens with useful output first**

Run:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme KosmoNotes -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

Manual check:
- completed session opens to summary/action area first
- share/export are visible without scrolling
- transcript is still accessible and seekable

- [ ] **Step 5: Commit**

```bash
git add App/Views/Library/SessionResultSummaryView.swift App/Views/Library/LibraryView.swift
git commit -m "feat(library): prioritize result actions above transcript detail"
```

---

### Task 6: Surface partial failures and permission problems in plain language

**Files:**
- Modify: `App/State/RecorderState.swift`
- Modify: `App/State/LibraryState.swift`
- Modify: `App/State/ShareCoordinator.swift`
- Modify: `App/Views/Library/LibraryView.swift`
- Modify: `App/Views/Settings/SettingsView.swift`
- Modify: `App/Views/Shared/UserFacingStatusBanner.swift`

- [ ] **Step 1: Add a simple user-facing issue model**

```swift
struct UserFacingIssue: Identifiable, Equatable {
    enum Tone {
        case info
        case warning
        case error
    }

    let id = UUID()
    let title: String
    let detail: String
    let tone: Tone
}
```

- [ ] **Step 2: Store the latest issue in recorder and library state instead of only printing**

```swift
@Observable
@MainActor
final class LibraryState {
    var activeIssue: UserFacingIssue?

    private func setSemanticSearchUnavailable(_ error: Error) {
        activeIssue = UserFacingIssue(
            title: "Basic search is still available",
            detail: "Semantic search is unavailable right now. You can still search transcripts normally.",
            tone: .warning
        )
        print("[LibraryState] semantic search unavailable: \(error)")
    }
}
```

- [ ] **Step 3: Return a concrete share failure from the coordinator**

```swift
func share(sessionId: String) async {
    do {
        try await service.share(sessionId: sessionId)
    } catch {
        issueSink?(
            UserFacingIssue(
                title: "Sharing is unavailable",
                detail: "Finish cloud storage setup in Settings before sharing a recording.",
                tone: .warning
            )
        )
    }
}
```

- [ ] **Step 4: Render issues in the library and settings with the shared banner**

```swift
if let issue = state.activeIssue {
    UserFacingStatusBanner(
        title: issue.title,
        detail: issue.detail,
        tone: issue.tone == .warning ? .yellow : .red
    )
    .padding(.horizontal)
    .padding(.top, 8)
}
```

- [ ] **Step 5: Build and run one failure-path smoke test**

Run:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme KosmoNotes -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`

Manual check:
- with sharing unconfigured, the user sees “Sharing is unavailable”
- with semantic search failing, the user sees “Basic search is still available”
- with missing system-audio permission, the user sees a clear next step

- [ ] **Step 6: Commit**

```bash
git add App/State/RecorderState.swift App/State/LibraryState.swift App/State/ShareCoordinator.swift App/Views/Library/LibraryView.swift App/Views/Settings/SettingsView.swift App/Views/Shared/UserFacingStatusBanner.swift
git commit -m "feat(status): surface partial failures in plain language"
```

---

### Task 7: Align user-facing documentation with the simplified product story

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace developer-first language in the “What it does” section**

```md
## What it does

- **Record meeting** — capture your mic and, if needed, call audio, then get a transcript and summary
- **Dictate text** — speak and paste the result into the current app
- **Quick voice note** — turn a spoken thought into a structured note
- **Library** — find, replay, export, and share past recordings
```

- [ ] **Step 2: Move provider-specific language down into an advanced or technical section**

```md
## Advanced setup

KosmoNotes supports multiple transcription and AI providers, including Deepgram, OpenAI, Gemini, OpenRouter, and Ollama. Most users can ignore this section and start with the default path.
```

- [ ] **Step 3: Refresh privacy wording so it remains honest but easier to understand**

```md
## Privacy

Your recordings are stored locally on your Mac. Transcription still uses a cloud provider, so audio leaves the device during transcription. If you need fully local transcription, this is not the right tool yet.
```

- [ ] **Step 4: Run the fastest relevant verification**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Expected: build completes successfully and docs edits did not require package changes

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(readme): describe KosmoNotes in mainstream product language"
```

---

## Self-review

### Spec coverage

- first-run guided success: Task 1
- task-first menu language: Task 2
- mainstream vs advanced settings split: Tasks 3 and 4
- result-first library flow: Task 5
- plain-language partial failures: Task 6
- mainstream product wording: Task 7

No spec requirement is left without a task.

### Placeholder scan

- no `TODO`, `TBD`, or “implement later” placeholders remain
- every code-changing step includes concrete code
- every validation step includes exact commands

### Type consistency

- `FirstRunGoal` is introduced once and reused consistently
- `UserFacingIssue` is introduced once and reused consistently
- “Record meeting / Dictate text / Quick voice note / My recordings” are the same labels across onboarding, menu, and docs

