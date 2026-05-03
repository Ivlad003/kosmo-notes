---
name: tcc-adhoc-signing-cycle
description: TCC denies ad-hoc-signed dev apps via auth_reason=5 ServicePolicy even when System Settings shows the toggle ON, because grants are keyed by mach-o cdhash that changes on every rebuild
triggers:
  - "user declined TCCs for application, window, display capture"
  - "auth_reason 5"
  - "kTCCServiceScreenCapture"
  - "TeamIdentifier=not set"
  - permission keeps asking
  - granted access but app says denied
  - tccutil reset
  - SCShareableContent failed
  - cdhash mismatch
  - KosmoNotes screen recording denied
---

# TCC Ad-hoc Signing Cycle (macOS Sonoma+)

## The Insight

macOS TCC binds permission grants to the binary's **mach-o cdhash**, not its bundle identifier alone. With ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`, `TeamIdentifier=not set`) every rebuild produces a new cdhash, which silently invalidates every prior grant — *even though the toggle in System Settings still appears ON for "the app"*.

When the new binary requests Microphone / Screen Recording / Accessibility, TCC sees:
- A bundle ID it has an entry for
- A cdhash that doesn't match the entry's stored requirement
- Result: deny with `auth_reason=5` (`kTCCAuthReasonServicePolicy`) and `prompt_type=0` — the user is **never asked**, the request just fails silently. The app's own preflight `CGPreflightScreenCaptureAccess()` returns `false` and the user sees an in-app modal that contradicts what they see in System Settings.

This is by-design TCC security, not a bug.

## Why This Matters

In the KosmoNotes rebuild loop (`xcodebuild` → install to `/Applications` → `codesign --force --deep --sign -` → relaunch), every iteration changes the cdhash. The user clicks Record → "user declined TCCs" → goes to Settings → the toggle is already ON → does nothing → tries Record → same denial. This loop wastes 30+ minutes per session if you don't recognize what's happening.

The trap: the System Settings UI **lies**. It shows the toggle as ON because the bundle ID has *some* entry; it doesn't visualize the cdhash mismatch. There's no UI signal that the entry is bound to a different binary hash. Sometimes the icon in the list shows as a generic placeholder — that's the only visible hint that TCC's metadata doesn't match the running binary.

## Recognition Pattern

Triggered when ALL of these are true:
- Project has `CODE_SIGN_IDENTITY: "-"` in `project.yml` or no Apple Development / Developer ID cert
- `codesign -dvv path/to/App.app` shows `TeamIdentifier=not set`
- User reports "I granted access but app still says denied" or "permission prompt won't appear"
- `log show --predicate 'process == "App" AND subsystem == "com.apple.TCC"'` shows requests with `auth_reason=5, result=false, prompt_type=0`
- The icon in System Settings → Privacy looks generic/placeholder rather than the app's real icon

## The Approach

There are three real options. Pick by user constraints:

**1. Accept the cycle (default for dev iteration)**

After every rebuild, before testing:
```sh
pkill -9 -f "App.app/Contents/MacOS"
tccutil reset All bundle.identifier
codesign --force --deep --sign - /path/to/App.app
xattr -cr /path/to/App.app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /path/to/App.app
open /path/to/App.app
```
Then user grants fresh on the system prompt. TCC will bind to the current cdhash. Holds until next rebuild.

**2. Switch to Apple Development cert**

Free Apple ID → Xcode → Settings → Accounts → `+` → Manage Certificates → `+` → Apple Development. Then `project.yml` uses:
```yaml
DEVELOPMENT_TEAM: "<TeamID>"
CODE_SIGN_STYLE: "Automatic"
```
**Caveat**: Apple Development cert is rejected by Gatekeeper for standalone .app launches (`spctl -a` returns "rejected"). TCC's ServicePolicy then blocks Screen Recording for these binaries when launched outside Xcode. Only useful if you launch via Xcode `Cmd+R` debug session.

**3. Pay for Apple Developer Program ($99/yr)**

Get Developer ID Application cert. `spctl -a` accepts it, TCC binds grants stably across rebuilds. Industry standard for distribution; only path for non-Xcode launches that survive rebuilds.

## Anti-patterns to avoid

- **Changing bundle ID to "fix" TCC**: tried `dev.kosmonotes.studio` → `dev.kosmonotes.studio.app`. Made it worse — TCC's ServicePolicy is even stricter for unknown new identifiers; gets `auth_reason=5` even faster. Revert; the original ID had earned partial trust through earlier interactions.

- **Stale `/Applications` copies**: leaving an old `KosmoNotes.app` (or `.OLD-stale-do-not-launch`) in `/Applications` causes LaunchServices to resolve `open` calls to the wrong bundle. Always:
  ```sh
  lsregister -dump | grep "path:.*App\.app"
  ```
  to see all registered copies; `lsregister -u <path>` to drop stale ones; physically remove old bundles.

- **Direct TCC.db manipulation via sqlite3**: macOS protects `~/Library/Application Support/com.apple.TCC/TCC.db` — you can't read or write it without Full Disk Access for sqlite3 itself. Use `tccutil` only.

- **Restart `tccd`**: requires sudo; not worth it. `tccutil reset All <bundle>` is enough.

## Diagnostic Commands

```sh
# Read TCC verdicts in real time
log stream --predicate 'process == "AppName" AND subsystem == "com.apple.TCC"' --info

# Confirm signature identity
codesign -dvv /Applications/AppName.app | grep -E "Identifier|TeamIdentifier|CDHash|Authority"

# Check Gatekeeper assessment
spctl -a -vvv /Applications/AppName.app

# List all LaunchServices-registered paths for one bundle
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -dump | grep "path:.*AppName"
```

## auth_reason values (private TCC enum, partial)

- 0: None
- 1: Error
- 2: User Consent (granted via system prompt)
- 3: User Set (manually toggled in Settings)
- 4: System Set
- **5: Service Policy** (system policy override — most common for ad-hoc dev apps)
- 6: MDM Policy
- 7: Override Policy
- 8: Missing Usage String
