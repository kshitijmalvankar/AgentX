#!/bin/bash
# Build the installed **AgentX** from a committed state and put it in
# /Applications. Your working copy stays free for AgentX Dev (scripts/run-dev.sh).
#
#   scripts/install.sh                 build HEAD and install it
#   scripts/install.sh --ref v0.2.0    build a tag, branch or commit instead
#   scripts/install.sh --allow-dirty   build the working copy as it is (to test changes to this script)
#   scripts/install.sh --rollback      put the previously installed version back
#   scripts/install.sh --no-open       don't launch it afterwards
#   scripts/install.sh --build-only    build and check it, but don't install (prints where it is)
#
# What it does:
#   1. checks out the ref into a temporary git worktree (uncommitted edits never ship)
#   2. stages agent-core with production dependencies only (npm ci --omit=dev --ignore-scripts)
#      and runs npm audit, stopping on high or critical advisories
#   3. checks the Claude Code engine binary is signed by Anthropic
#   4. builds Release with Config/Stable.xcconfig, embedding agent-core in the app before signing
#   5. quits AgentX, keeps the old version for --rollback, installs, relaunches
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/AgentX.app"
KEEP="$HOME/Library/Application Support/AgentX/Previous"
WORK="$ROOT/build/release"
BUNDLE_ID="dev.agentx.AgentX"
ANTHROPIC_TEAM="Q6L2SF6YDW"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

REF="HEAD"
ALLOW_DIRTY=0
ROLLBACK=0
OPEN=1
BUILD_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --rollback) ROLLBACK=1 ;;
    --no-open) OPEN=0 ;;
    --build-only) BUILD_ONLY=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

quit_installed() {
  if pgrep -x AgentX >/dev/null; then
    say "Quitting AgentX"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -x AgentX >/dev/null || return 0; sleep 0.25; done
    pkill -x AgentX 2>/dev/null || true
  fi
}

if [ "$ROLLBACK" = 1 ]; then
  [ -d "$KEEP/AgentX.app" ] || fail "No previous version to roll back to."
  quit_installed
  TMP="$(mktemp -d)"
  [ -d "$DEST" ] && mv "$DEST" "$TMP/AgentX.app"
  mv "$KEEP/AgentX.app" "$DEST"
  [ -d "$TMP/AgentX.app" ] && mv "$TMP/AgentX.app" "$KEEP/AgentX.app"
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  say "Rolled back to $(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "$DEST/Contents/Info.plist" CFBundleVersion))"
  [ "$OPEN" = 1 ] && open "$DEST"
  exit 0
fi

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v xcodegen >/dev/null || fail "Install XcodeGen first: brew install xcodegen"
command -v npm >/dev/null || fail "npm not found (install Node.js: brew install node)"

# 1. Source: a clean checkout of the ref, or the working copy with --allow-dirty.
mkdir -p "$WORK"
if [ "$ALLOW_DIRTY" = 1 ]; then
  SRC="$ROOT"
  say "Building the working copy as it is (--allow-dirty)"
else
  if [ "$REF" = "HEAD" ] && { ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; }; then
    fail "You have uncommitted changes. Commit them first (they'd be left out), or use --allow-dirty to build the working copy."
  fi
  SRC="$WORK/src"
  git -C "$ROOT" worktree remove --force "$SRC" >/dev/null 2>&1 || rm -rf "$SRC"
  git -C "$ROOT" worktree prune
  say "Checking out $REF ($(git -C "$ROOT" rev-parse --short "$REF"))"
  git -C "$ROOT" worktree add --detach "$SRC" "$REF" >/dev/null
  trap 'git -C "$ROOT" worktree remove --force "$SRC" >/dev/null 2>&1 || true' EXIT
  # Signing settings are local and git-ignored: bring them along.
  [ -f "$ROOT/Config/Local.xcconfig" ] && cp "$ROOT/Config/Local.xcconfig" "$SRC/Config/Local.xcconfig"
fi
[ -f "$SRC/Config/Stable.xcconfig" ] || fail "$REF predates installable builds (no Config/Stable.xcconfig)."
BUILD_NUMBER="$(git -C "$SRC" rev-list --count HEAD)"
COMMIT="$(git -C "$SRC" rev-parse --short HEAD)"

# 2. agent-core with production dependencies only, exactly as locked.
STAGE="$WORK/agent-core"
say "Staging agent-core (npm ci --omit=dev --ignore-scripts)"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$SRC/agent-core/src" "$STAGE/src"
cp "$SRC/agent-core/package.json" "$SRC/agent-core/package-lock.json" "$STAGE/"
(cd "$STAGE" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error)
rm -rf "$STAGE/node_modules/.bin"

say "Checking dependencies for known vulnerabilities (npm audit)"
AUDIT_JSON="$(cd "$STAGE" && npm audit --omit=dev --json 2>/dev/null || true)"
SEVERE="$(printf '%s' "$AUDIT_JSON" | node -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    try { const v = JSON.parse(s).metadata.vulnerabilities; console.log((v.high || 0) + (v.critical || 0)); }
    catch { console.log("unknown"); }
  });')"
if [ "$SEVERE" = "unknown" ]; then
  echo "warning: npm audit couldn't run (offline?). Continuing without it."
elif [ "$SEVERE" != "0" ]; then
  (cd "$STAGE" && npm audit --omit=dev) || true
  fail "npm audit found $SEVERE high or critical advisories. Update agent-core's dependencies first."
fi

# 3. The Claude Code engine must be Anthropic's.
ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH="x64"
ENGINE="$STAGE/node_modules/@anthropic-ai/claude-agent-sdk-darwin-$ARCH/claude"
[ -x "$ENGINE" ] || fail "The Claude Code engine binary is missing from agent-core ($ENGINE)."
codesign --verify --strict "$ENGINE" || fail "The Claude Code engine's signature is invalid."
codesign -dv "$ENGINE" 2>&1 | grep -q "TeamIdentifier=$ANTHROPIC_TEAM" || fail "The Claude Code engine isn't signed by Anthropic."
say "Claude Code engine signed by Anthropic ($ANTHROPIC_TEAM)"

# 4. Build Release with the stable channel settings.
say "Generating the Xcode project"
(cd "$SRC" && xcodegen generate --quiet)
# Fresh app bundle (compiled code is kept): a stale embedded widget extension
# breaks the build when signing settings change.
rm -rf "$WORK/DerivedData/Build/Products/Release/AgentX.app" "$WORK/DerivedData/Build/Products/Release/AgentXWidgets.appex"
say "Building AgentX $COMMIT (build $BUILD_NUMBER)"
xcodebuild -project "$SRC/AgentX.xcodeproj" -scheme AgentX -configuration Release \
  -derivedDataPath "$WORK/DerivedData" \
  -clonedSourcePackagesDirPath "$ROOT/build/DerivedData/SourcePackages" \
  -xcconfig "$SRC/Config/Stable.xcconfig" \
  -skipPackagePluginValidation -quiet \
  AGENTX_EMBED_CORE_FROM="$STAGE" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build
APP="$WORK/DerivedData/Build/Products/Release/AgentX.app"

[ "$(defaults read "$APP/Contents/Info.plist" AgentXChannel)" = "stable" ] || fail "Built app isn't the stable channel."
[ "$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "Built app has the wrong bundle id."
[ -f "$APP/Contents/Resources/agent-core/src/index.ts" ] || fail "agent-core wasn't embedded."
codesign --verify --strict "$APP" || fail "The built app's signature doesn't verify."

if [ "$BUILD_ONLY" = 1 ]; then
  say "Built and checked $APP (not installed: --build-only)"
  exit 0
fi

# 5. Install, keeping the previous version for --rollback.
quit_installed
mkdir -p "$KEEP"
chmod 700 "$HOME/Library/Application Support/AgentX" 2>/dev/null || true
rm -rf "$KEEP/AgentX.app"
[ -d "$DEST" ] && mv "$DEST" "$KEEP/AgentX.app"
ditto "$APP" "$DEST"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true

say "Installed $DEST ($(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString), build $BUILD_NUMBER, $COMMIT)"
[ -d "$KEEP/AgentX.app" ] && echo "    Previous version kept for: scripts/install.sh --rollback"
[ "$OPEN" = 1 ] && open "$DEST"
exit 0
