import AppKit
import Foundation

// MARK: - RunningAppInfo

/// One currently-running macOS app, surfaced to the per-process audio-tap
/// picker. Only apps with a regular UI activation policy and a real bundle
/// ID are listed — daemons, helpers, and Finder-style background processes
/// are filtered out so the picker doesn't drown in noise.
struct RunningAppInfo: Sendable, Hashable, Identifiable {
    let bundleID: String
    let name: String
    /// `nil` for apps without a discoverable bundle path (rare). The Settings
    /// row uses this to grab the Finder icon at render time.
    let bundleURL: URL?

    var id: String { bundleID }
}

// MARK: - RunningAppsEnumerator

/// Lists the macOS apps that the per-process Core Audio Tap (14.4+) can target.
///
/// Uses `NSWorkspace.runningApplications`, filters to regular foreground apps
/// with a non-empty bundle ID, dedups by bundle ID (some apps spawn helper
/// processes with the same ID), and sorts by display name for a stable picker.
enum RunningAppsEnumerator {

    /// Snapshot of currently-running pickable apps. Cheap to call repeatedly.
    static func runningApps() -> [RunningAppInfo] {
        let raw = NSWorkspace.shared.runningApplications
        var seen: Set<String> = []
        var out: [RunningAppInfo] = []
        for app in raw {
            guard app.activationPolicy == .regular else { continue }
            guard let bid = app.bundleIdentifier, !bid.isEmpty else { continue }
            // Skip our own bundle — recording your own audio is meaningless
            // and macOS won't allow the tap on the requesting process anyway.
            if bid == "dev.kosmonotes.studio" { continue }
            if seen.contains(bid) { continue }
            seen.insert(bid)

            let name = app.localizedName
                ?? (app.bundleURL?.deletingPathExtension().lastPathComponent)
                ?? bid
            out.append(RunningAppInfo(bundleID: bid, name: name, bundleURL: app.bundleURL))
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return out
    }
}
