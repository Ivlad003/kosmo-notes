---
name: macos-uitest-headless-bootstrap
description: macOS XCUITest runners cannot bootstrap in headless CLI sessions because the ad-hoc-signed XCTRunner.app needs interactive Accessibility TCC; xcodebuild test reports "signal kill before establishing connection" with no actionable diagnostic
triggers:
  - "Test crashed with signal kill before establishing connection"
  - "Early unexpected exit, operation never finished bootstrapping"
  - "no restart will be attempted"
  - KosmoNotesUITests-Runner encountered an error
  - XCUITest runner crashes immediately
  - xcodebuild test crashes before any test
  - test bundle never starts
  - xcodebuild build-for-testing succeeds but test fails
---

# macOS XCUITest Cannot Run in a Headless CLI Session

## The Insight

XCUITest needs **two** things macOS only grants in an interactive Xcode session:

1. **Accessibility TCC for the test runner** — XCTRunner.app uses CGEventTap-style APIs to drive the host app. Without Accessibility, the runner is killed by macOS before its xpc bootstrap completes.
2. **A real WindowServer connection** — the runner uses XCUIApplication queries that talk to the system accessibility tree, which only exists for processes attached to a logged-in user session with WindowServer.

Ad-hoc-signed runners (`TeamIdentifier=not set`) are doubly hard: even if you grant TCC interactively once, the cdhash changes on every `build-for-testing` run, invalidating the grant. There's no way to grant it persistently from CLI — `tccutil` won't accept a future cdhash, and macOS won't pop the grant prompt unless a real user is at the keyboard.

## Why This Matters

The failure mode is opaque. `xcodebuild test-without-building` exits non-zero with this single line of guidance:

```
KosmoNotesUITests-Runner (PID) encountered an error
  (Early unexpected exit, operation never finished bootstrapping
   - no restart will be attempted.
   (Underlying Error: Test crashed with signal kill before establishing connection.))
```

There is no crash report, no stderr from the runner, no hint about TCC. It's tempting to chase ghosts: re-codesign manually, suspect the host app crashes on launch (it doesn't — `open` it directly and it runs fine), suspect the runner binary is missing (it isn't — `codesign -dv` reads it cleanly).

A subtle red herring: after a failed test run, **xcodebuild deletes the runner.app from build products**. If you check `Build/Products/Debug/` later, you'll see only `KosmoNotes.app`, no `KosmoNotesUITests-Runner.app`. That makes it look like the build is broken when really the test phase merely cleaned up. Re-run `xcodebuild build-for-testing` and the runner.app reappears.

## Recognition Pattern

ALL of these together = headless CLI TCC issue, not a code bug:

- `xcodebuild build-for-testing` succeeds with `** TEST BUILD SUCCEEDED **`
- `xcodebuild test-without-building` immediately fails with "signal kill before establishing connection"
- The host app (`KosmoNotes.app`) launches manually via `open` and stays running
- `codesign -dv KosmoNotesUITests-Runner.app` shows `TeamIdentifier=not set` (ad-hoc) for the inner xctest bundle (`adhoc,linker-signed`)
- You're running from a remote shell, CI runner, ssh session, or autonomous agent (no interactive WindowServer prompt loop)

If host app DOES crash at launch, that's a different problem — debug the host first.

## The Approach

**Stop trying to make UI tests run from CLI on this Mac.** The decision-making heuristic:

- **Compile-only verification is the right CI gate.** `xcodebuild build-for-testing` catches stale element queries, API breakage, removed identifiers — everything except actual runtime behavior. That's what CI gets, and it's enough to prevent test-code rot.
- **Actual UI test execution belongs in Xcode (Cmd+U).** A human at the Mac sees the TCC prompt for the runner the first time, grants Accessibility, and from then on tests run. The grant survives until the next runner cdhash change (i.e. until the next `build-for-testing` rebuild — at which point Xcode handles re-prompting).
- **Don't add a `xcodebuild test` step to GitHub Actions.** Fresh CI runners can't grant TCC and there's no way to pre-seed it. Compile-only is the supported pattern; document this in CI yaml so the next person doesn't try.

When reporting status to a user, be explicit: "build verified, runtime behavior NOT verified by automation — needs Xcode Cmd+U on a developer Mac." Don't claim the tests "pass" just because they compile.

## Workaround Options Considered (and why they don't help)

- **Pre-grant TCC via `tccutil`** — needs the cdhash, which changes on every rebuild. Useless for ad-hoc.
- **Sign with Apple Development cert** — would stabilize the cdhash, but adds a real signing identity requirement that breaks the "single-user no-codesign" stack invariant in CLAUDE.md.
- **Run test in `xvfb`-style headless display** — macOS has no equivalent; WindowServer is single-instance per logged-in user.
- **`expect`-script the TCC prompt** — TCC dialogs are not Accessibility-targetable from another non-trusted process. Chicken-and-egg.

The supported answer is "compile in CI, run in Xcode." That's the constraint, not a workaround gap.

## Related

- `tcc-adhoc-signing-cycle-expertise` — same root cause (cdhash invalidates TCC grants on rebuild) for the runtime app permissions, not the runner.
