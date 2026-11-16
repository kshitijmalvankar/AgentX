#!/bin/bash
# Build AgentX (the app and its desktop widgets) with Xcode and launch it
# from build/AgentX.app.
#
#   scripts/run-dev.sh            build + launch
#   scripts/run-dev.sh --no-open  build only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AgentX.app"
BUILT="$ROOT/build/DerivedData/Build/Products/Debug/AgentX.app"
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

echo "==> Building AgentX and its widgets"
# -skipPackagePluginValidation: trust SwiftTerm's build plugin, as swift build does.
xcodebuild -project "$ROOT/AgentX.xcodeproj" -scheme AgentX -configuration Debug \
  -derivedDataPath "$ROOT/build/DerivedData" -skipPackagePluginValidation -quiet build

echo "==> Installing to $APP"
pkill -x AgentX 2>/dev/null || true
rm -rf "$APP"
cp -R "$BUILT" "$APP"
# One registered copy, so the widget gallery doesn't list AgentX twice.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

echo "==> Built $APP"
if [ "${1:-}" != "--no-open" ]; then
  open "$APP"
fi
