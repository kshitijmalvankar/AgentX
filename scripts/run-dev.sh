#!/bin/bash
# Build AgentX with SwiftPM and launch it as a real .app bundle
# (notifications and macOS permission prompts need a bundle).
#
#   scripts/run-dev.sh            build + launch
#   scripts/run-dev.sh --no-open  build only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AgentX.app"
BUNDLE_ID="dev.agentx.AgentX"

# SwiftUI macros on the macOS 27 SDK need Xcode's toolchain, not just the CLT.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# agent-core dependencies
if [ ! -d "$ROOT/agent-core/node_modules/@anthropic-ai/claude-agent-sdk" ]; then
  echo "==> Installing agent-core dependencies"
  (cd "$ROOT/agent-core" && npm install)
fi

echo "==> Building AgentXDev"
swift build --package-path "$ROOT/AgentXKit" --product AgentXDev
BIN="$(swift build --package-path "$ROOT/AgentXKit" --product AgentXDev --show-bin-path)/AgentXDev"

echo "==> Assembling $APP"
pkill -x AgentX 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentX"
# SwiftPM resource bundles (MarkdownUI etc.) sit next to the binary.
find "$(dirname "$BIN")" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

sed -e "s#\$(EXECUTABLE_NAME)#AgentX#" \
    -e "s#\$(PRODUCT_BUNDLE_IDENTIFIER)#$BUNDLE_ID#" \
    -e "s#\$(MACOSX_DEPLOYMENT_TARGET)#26.0#" \
    -e "s#\$(AGENTX_CORE_PATH)#$ROOT/agent-core#" \
    "$ROOT/App/Info.plist" > "$APP/Contents/Info.plist"

codesign --force --sign - --entitlements "$ROOT/App/AgentX.entitlements" "$APP" >/dev/null

echo "==> Built $APP"
if [ "${1:-}" != "--no-open" ]; then
  open "$APP"
fi
