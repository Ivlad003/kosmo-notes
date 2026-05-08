# KosmoNotes library share links design

**Date:** 2026-05-08
**Scope:** add per-share artifact selection and show saved shared links in Library
**Primary goal:** let the user choose what to upload, then surface the resulting links inside the session detail view

## Problem

The current Library flow has one `Share to S3` action with no choice of artifacts. It uploads a fixed set of files when they exist and only shows the resulting links in a success alert.

That leaves two gaps:

1. the user cannot choose which files to share for a given session
2. the Library does not retain or display the links after the alert closes

The result feels temporary. A user who wants to copy a link later has to re-share the session even when the URL was already generated.

## Design goal

The Library should support a simple per-session sharing flow:

1. the user clicks `Share to S3`
2. the app shows a one-time picker for the files that exist in that session
3. the app uploads only the selected files
4. the app saves the exact presigned URLs for that share
5. the session detail view shows those saved links until a later share replaces them

## Scope

### In scope

- one-time artifact selection before each share
- saved share metadata in the session directory
- Library detail UI for viewing, opening, and copying saved links
- replacement of saved links on repeated share

### Out of scope

- automatic refresh or re-signing of expired URLs
- share history with multiple past share runs
- database schema changes
- filtering or searching the Library by shared state

## Storage decision

Share metadata should live in a new sidecar file:

`<session-dir>/shared-links.json`

This follows the project rule that the filesystem is the source of truth and SQLite is a rebuildable index. Share data belongs beside the shared artifacts, not in the database.

The file should store the exact URLs returned by the successful share flow, even though they may expire later. This matches the product decision for this feature: show the saved URLs as-is and do not regenerate them automatically.

## Data model

Add a small codable model dedicated to share state. Keep it separate from `SessionRecord` so session identity and recording lifecycle metadata stay stable.

Suggested shape:

```swift
struct SharedLinkRecord: Codable, Equatable, Sendable {
    let kind: SharedArtifactKind
    let url: URL
}

enum SharedArtifactKind: String, Codable, CaseIterable, Sendable {
    case audio
    case video
    case summary
    case transcript
}

struct SharedLinksSnapshot: Codable, Equatable, Sendable {
    let sharedAt: Date
    let links: [SharedLinkRecord]
}
```

This model should be used only for Library sharing state. It should not be folded into `SessionRecord`.

## Architecture

### 1. SharingService

`SharingService` should stop deciding the artifact set on its own. Instead, it should accept an explicit list of artifact kinds to upload. It should still skip files that are missing at the filesystem boundary only when the selection and disk state drift between picker time and upload time.

The share result should stay typed and map cleanly to the sidecar model.

### 2. ShareCoordinator

`ShareCoordinator` should own the AppKit share picker flow.

Responsibilities:

- validate S3 settings
- inspect the session directory
- build the list of available artifacts
- show a modal dialog with checkboxes for those artifacts
- call `SharingService` with the selected set
- persist `shared-links.json` only after a successful share
- present a success alert after persistence

If the user cancels the picker, the flow ends without side effects.

### 3. SessionStore

Add focused read/write helpers for `shared-links.json` on `SessionStore`. The helper should:

- read the saved snapshot for a session
- write a full snapshot atomically
- delete or overwrite by writing the latest successful snapshot

### 4. LibraryState

`LibraryState` should expose an async read for the saved shared links of a selected session. The state does not need to index this in SQLite for v1.

### 5. LibraryView

The session detail pane should gain a `Shared Links` section directly below the existing action bar.

Each saved link row should show:

- artifact label
- the URL text, truncated in the UI if needed
- `Open`
- `Copy`

If there is no saved share snapshot, the section can stay hidden.

## User flow

### Share flow

1. user clicks `Share to S3`
2. app inspects the session directory
3. app shows checkboxes only for artifacts that exist:
   - `Audio (.m4a)`
   - `Screen recording (.mp4)` when present
   - `Summary (.md)` when present
   - `Transcript (.txt)` when present
4. user confirms the selection
5. app uploads only those artifacts
6. app writes `shared-links.json`
7. app refreshes the detail view so the saved links appear immediately
8. app shows the success alert with copy actions

### Repeat share flow

A later successful share replaces the old snapshot. The Library shows the latest saved URLs only.

## Error handling

- Keep the `Share to S3` button disabled when S3 is not configured.
- If no shareable artifacts exist, show a warning and do not start upload.
- If the user confirms with no boxes selected, show a warning and do not start upload.
- If upload fails, leave the previous `shared-links.json` untouched.
- If `shared-links.json` is missing or invalid, treat it as “no saved links” and do not crash the detail view.
- If the saved URLs expire later, still show them as saved URLs. Do not auto-refresh or re-sign them.

## UI notes

- The picker should be a plain AppKit modal, consistent with the existing alert-driven share flow.
- Default the checkboxes to selected for all available artifacts to preserve the current “share everything available” bias while still giving control.
- Keep the main call to action label as `Share to S3`.
- The Library detail view should not become a full share manager. Show the current saved links and lightweight actions only.

## Testing

Add focused coverage for:

1. artifact discovery from the session directory
2. selected-artifact upload behavior in `SharingService`
3. atomic write and read of `shared-links.json`
4. replacement of saved links on repeated share
5. graceful handling of invalid or missing share sidecar data
6. Library-side loading of saved links for the selected session

UI automation is not required for the first pass. Test the picker-adjacent logic at the coordinator and helper level.

## Result

This design keeps sharing state local to the session, preserves the current storage invariant, and makes S3 sharing feel persistent inside the Library without adding a database migration or a more complex share-history feature.
