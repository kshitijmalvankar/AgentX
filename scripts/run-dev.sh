#!/bin/bash
# Build AgentX (the app and its desktop widgets) with Xcode and launch it
# from build/AgentX.app.
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
APP="$ROOT/build/AgentX.app"
BUILT="$ROOT/build/DerivedData/Build/Products/$CONFIG/AgentX.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# SwiftUI macros on the macOS 27 SDK need Xcode's toolchain, not just the CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }

# agent-core dependencies
if [ ! -d "$ROOT/agent-core/node_modules/@anthropic-ai/claude-agent-sdk" ]; then
  echo "==> Installing agent-core dependencies"
  (cd "$ROOT/agent-core" && npm install)
fi

echo "==> Generating the Xcode project"
(cd "$ROOT" && xcodegen generate --quiet)

echo "==> Building AgentX and its widgets ($CONFIG)"
# -skipPackagePluginValidation: trust SwiftTerm's build plugin, as swift build does.
xcodebuild -project "$ROOT/AgentX.xcodeproj" -scheme AgentX -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" -skipPackagePluginValidation -quiet build

echo "==> Installing to $APP"
pkill -x AgentX 2>/dev/null || true
rm -rf "$APP"
cp -R "$BUILT" "$APP"
# One registered copy, so the widget gallery doesn't list AgentX twice.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

echo "==> Built $APP"
if [ "$OPEN" = 1 ]; then
  open "$APP"
fi
