#!/bin/bash
# Build **AgentX Dev** from your working copy (the app and its widgets) and
# launch it from build/AgentX Dev.app. It runs next to the installed AgentX
# (scripts/install.sh) with its own data, ⌃⌥Space hotkey and agentx-dev:// links,
# and its automations start paused.
#
#   scripts/run-dev.sh            optimized (Release) build + launch
#   scripts/run-dev.sh --debug    Debug build (for the debugger) + launch
#   scripts/run-dev.sh --no-open  build only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=Release
OPEN=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=Debug ;;
    --no-open) OPEN=0 ;;
  esac
done
NAME="AgentX Dev"
APP="$ROOT/build/$NAME.app"
BUILT="$ROOT/build/DerivedData/Build/Products/$CONFIG/$NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# SwiftUI macros on the macOS 27 SDK need Xcode's toolchain, not just the CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }

if [ ! -f "$ROOT/Config/Local.xcconfig" ]; then
  echo "note: building with an ad-hoc signature, so macOS forgets permissions (Accessibility, Screen Recording) after each build."
  echo "      To keep them: add your Apple ID in Xcode → Settings → Accounts, then copy Config/Local.xcconfig.example to Config/Local.xcconfig."
fi

# agent-core dependencies
if [ ! -d "$ROOT/agent-core/node_modules/@anthropic-ai/claude-agent-sdk" ]; then
  echo "==> Installing agent-core dependencies"
  (cd "$ROOT/agent-core" && npm ci --ignore-scripts)
fi

echo "==> Generating the Xcode project"
(cd "$ROOT" && xcodegen generate --quiet)

# Start from a fresh app bundle: when only signing settings change, Xcode can
# leave an old copy of the widget extension inside it ("Embedded binary is not
# signed with the same certificate"). Compiled code is kept, so this is cheap.
rm -rf "$BUILT" "$ROOT/build/DerivedData/Build/Products/$CONFIG/AgentXWidgets.appex"

echo "==> Building $NAME and its widgets ($CONFIG)"
# -skipPackagePluginValidation: trust SwiftTerm's build plugin, as swift build does.
xcodebuild -project "$ROOT/AgentX.xcodeproj" -scheme AgentX -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" -skipPackagePluginValidation -quiet build

echo "==> Installing to $APP"
pkill -x "$NAME" 2>/dev/null || true
# The pre-channel dev build was build/AgentX.app; retire it so there's one dev
# copy (but never pull it out from under a running app).
OLD="$ROOT/build/AgentX.app"
if [ -d "$OLD" ]; then
  if pgrep -f "$OLD/Contents/MacOS/" >/dev/null; then
    echo "note: the old build/AgentX.app is still running; quit it and run this again to remove it."
  else
    "$LSREGISTER" -u "$OLD" >/dev/null 2>&1 || true
    rm -rf "$OLD"
  fi
fi
rm -rf "$APP"
cp -R "$BUILT" "$APP"
# One registered copy, so Launch Services doesn't see two AgentX Devs.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
# Only the installed AgentX offers widgets; hide the Dev copy's from the gallery.
pluginkit -e ignore -i dev.agentx.AgentX.dev.Widgets >/dev/null 2>&1 || true

echo "==> Built $APP"
if [ "$OPEN" = 1 ]; then
  open "$APP"
fi
