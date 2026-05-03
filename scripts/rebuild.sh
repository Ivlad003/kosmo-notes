#!/bin/bash
# rebuild.sh — full Release rebuild + auto-bump build number + install + TCC reset.
#
# Why this exists: ad-hoc-signed dev builds change cdhash on every build, so
# macOS TCC silently invalidates Microphone / Screen Recording / Accessibility
# grants. Without an explicit reset the user gets stuck in "I granted but app
# says denied" loops (see .omc/skills/tcc-adhoc-signing-cycle-expertise.md).
#
# Each run:
#   1. Bumps CFBundleVersion in project.yml (build number) — visible in menu
#   2. Regenerates Xcode project via xcodegen
#   3. Clean Release build (CODE_SIGNING_REQUIRED=NO so xcodebuild ignores
#      certs; we re-codesign with `--sign -` immediately after)
#   4. Installs to /Applications/KosmoNotes.app
#   5. tccutil reset All <bundle> — clears stale grants for the previous cdhash
#   6. Re-registers with LaunchServices and launches
#
# Run from repo root: ./scripts/rebuild.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT_YML="$REPO_ROOT/project.yml"
INFO_PLIST="$REPO_ROOT/App/Info.plist"
BUNDLE_ID="dev.kosmonotes.studio"
APP_NAME="KosmoNotes.app"
DERIVED="$REPO_ROOT/build/Release"
APP_DEST="/Applications/$APP_NAME"

# --- 1. Bump build number ----------------------------------------------------

CURRENT_BUILD=$(awk -F'"' '/CFBundleVersion:/ {print $2; exit}' "$PROJECT_YML")
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "Could not parse CFBundleVersion from $PROJECT_YML (got: $CURRENT_BUILD)" >&2
  exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "==> Bumping CFBundleVersion: $CURRENT_BUILD → $NEW_BUILD"

# Macro-replace in both files. project.yml is the source of truth that
# xcodegen reads; App/Info.plist is the seed file it merges into.
sed -i '' "s/CFBundleVersion: \"$CURRENT_BUILD\"/CFBundleVersion: \"$NEW_BUILD\"/" "$PROJECT_YML"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

# --- 2. Regenerate Xcode project ---------------------------------------------

echo "==> xcodegen generate"
xcodegen generate >/dev/null

# --- 3. Clean Release build --------------------------------------------------

echo "==> xcodebuild Release (build $NEW_BUILD)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "$REPO_ROOT/KosmoNotes.xcodeproj" \
  -scheme KosmoNotes \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3

NEW_APP="$DERIVED/Build/Products/Release/$APP_NAME"
if [ ! -d "$NEW_APP" ]; then
  echo "Build did not produce $NEW_APP — aborting" >&2
  exit 1
fi

# --- 4. Install to /Applications ---------------------------------------------

echo "==> Killing running instance"
pkill -9 -f "$APP_NAME/Contents/MacOS" 2>/dev/null || true
sleep 1

echo "==> Installing $APP_NAME to /Applications"
rm -rf "$APP_DEST"
cp -R "$NEW_APP" "$APP_DEST"

echo "==> Ad-hoc codesigning + clearing quarantine"
codesign --force --deep --sign - "$APP_DEST" >/dev/null 2>&1
xattr -cr "$APP_DEST"

# --- 5. TCC reset ------------------------------------------------------------

echo "==> tccutil reset All $BUNDLE_ID (cdhash changed; old grants invalid)"
tccutil reset All "$BUNDLE_ID" 2>&1 | tail -1

# --- 6. Re-register + launch -------------------------------------------------

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
echo "==> Re-registering with LaunchServices"
"$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1

sleep 1
echo "==> Launching $APP_NAME"
open "$APP_DEST"
sleep 2

PID=$(pgrep -f "$APP_NAME/Contents/MacOS/KosmoNotes" | head -1)
if [ -z "$PID" ]; then
  echo "Could not find running PID — launch may have failed" >&2
  exit 1
fi

echo ""
echo "✓ Build $NEW_BUILD installed and running (PID $PID)"
echo "  Bundle: $APP_DEST"
echo "  Version line: $(plutil -extract CFBundleShortVersionString raw "$APP_DEST/Contents/Info.plist") (build $NEW_BUILD)"
echo ""
echo "Next press of Record will show fresh macOS prompts for Mic / Screen Recording / Accessibility."
echo "Click Allow on each. Settings panel may also ask Quit & Reopen — click that."
