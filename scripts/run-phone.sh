#!/bin/bash
# Build the AgentX iPhone app and install it on your iPhone.
#
#   scripts/run-phone.sh              build, install and open it on your iPhone
#   scripts/run-phone.sh --build-only build it (checks signing) without installing
#
# Before the first run:
#   1. Your team is in Config/Local.xcconfig (see Config/Local.xcconfig.example).
#   2. Connect the iPhone by cable once (or pair it over Wi-Fi in Xcode → Window → Devices).
#   3. On the iPhone: Settings → Privacy & Security → Developer Mode → On (it restarts).
#   4. After the first install: Settings → General → VPN & Device Management →
#      your Apple Development certificate → Trust.
# With a free Apple account, iOS stops the app after 7 days: run this again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL=1
[ "${1:-}" = "--build-only" ] && INSTALL=0
BUNDLE_ID="dev.agentx.AgentX.phone"
APP="$ROOT/build/PhoneDerivedData/Build/Products/Release-iphoneos/AgentXPhone.app"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
[ -f "$ROOT/Config/Local.xcconfig" ] || {
  echo "error: iPhone apps need your team. Copy Config/Local.xcconfig.example to Config/Local.xcconfig and set AGENTX_TEAM."
  exit 1
}

echo "==> Generating the Xcode project"
(cd "$ROOT" && xcodegen generate --quiet)

# The first iPhone that's reachable now (by cable or Wi-Fi), unless AGENTX_PHONE names one.
# Prints "<CoreDevice id> <hardware UDID>".
find_phone() {
  local json
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  python3 - "$json" "${AGENTX_PHONE:-}" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
wanted = sys.argv[2]
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or conn.get("pairingState") != "paired":
        continue
    if wanted and wanted not in (d.get("identifier"), hw.get("udid")):
        continue
    # Reachable: plugged in or on Wi-Fi (an idle cable link still says "disconnected").
    if not wanted and not (conn.get("tunnelState") == "connected" or conn.get("transportType")):
        continue
    print(d["identifier"], hw.get("udid", "")); break
PY
  rm -f "$json"
}

read -r DEVICE UDID < <(find_phone) || true
if [ -z "${DEVICE:-}" ] && [ "$INSTALL" = 1 ]; then
  # A plugged-in phone's link can take a moment to come up: ask it once, then look again.
  xcrun devicectl list devices >/dev/null 2>&1 || true
  read -r DEVICE UDID < <(find_phone) || true
fi
if [ -z "${DEVICE:-}" ] && [ "$INSTALL" = 1 ]; then
  echo "error: no iPhone connected. Plug it in (or pair it over Wi-Fi in Xcode → Window → Devices), unlock it, and run this again."
  exit 1
fi

# Building for your iPhone (not "any iPhone") lets Xcode register it and make the profile.
DESTINATION='generic/platform=iOS'
[ -n "${UDID:-}" ] && DESTINATION="id=$UDID"

echo "==> Building AgentX for iPhone"
# -allowProvisioning…: let Xcode make the development profile and register your iPhone.
xcodebuild -project "$ROOT/AgentX.xcodeproj" -scheme AgentXPhone -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT/build/PhoneDerivedData" \
  -clonedSourcePackagesDirPath "$ROOT/build/DerivedData/SourcePackages" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -quiet build

[ "$INSTALL" = 1 ] || { echo "==> Built $APP"; exit 0; }

echo "==> Installing on your iPhone"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
echo "==> Opening AgentX"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || \
  echo "    Installed. If it won't open: Settings → General → VPN & Device Management → trust your developer certificate."
echo "==> Done. On your Mac: AgentX → Settings → iPhone → Pair an iPhone."
