#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PACKAGE="$ROOT/native"
WEB_ROOT=${WEB_ROOT:-"$ROOT/dist"}
OUT_ROOT=${OUT_ROOT:-"$ROOT/.team/artifacts/swift-shell-release"}
CONFIGURATION=${CONFIGURATION:-release}
VERSION=${VERSION:-}
REQUIRE_SWIFT_6_4=${REQUIRE_SWIFT_6_4:-0}

if [[ -z "$VERSION" ]]; then
  echo "VERSION is required (for example VERSION=0.1.0)" >&2
  exit 1
fi
if [[ ! -f "$WEB_ROOT/index.html" ]]; then
  echo "missing $WEB_ROOT/index.html; run npm run build or set WEB_ROOT" >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "the macOS arm64 release must be built on an arm64 runner (found $(uname -m))" >&2
  exit 1
fi

swift_version=$(swift --version)
printf 'swift toolchain: %s\n' "${swift_version//$'\n'/; }"
if [[ "$swift_version" != *"Swift version 6.4"* && "$swift_version" != *"Apple Swift version 6.4"* ]]; then
  if [[ "$REQUIRE_SWIFT_6_4" == "1" ]]; then
    echo "Swift 6.4 is required for the production release" >&2
    exit 1
  fi
  echo "WARNING: Swift 6.4 is required for the production release; this toolchain is a local pre-6.4 check" >&2
fi

swift build --package-path "$PACKAGE" --configuration "$CONFIGURATION"
BIN_DIR=$(swift build --package-path "$PACKAGE" --configuration "$CONFIGURATION" --show-bin-path)
BIN="$BIN_DIR/AgentMirrorApp"
[[ -x "$BIN" ]] || { echo "missing executable: $BIN" >&2; exit 1; }

mkdir -p "$OUT_ROOT"
STAGE=$(mktemp -d "$OUT_ROOT/.stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/AgentMirror.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentMirrorApp"
sed "s/__VERSION__/$VERSION/g" \
  "$PACKAGE/Resources/Release-Info.plist" > "$APP/Contents/Info.plist"
cp -R "$WEB_ROOT" "$APP/Contents/Resources/web"
cp "$ROOT/src-tauri/resources/agentmirror-probe.js" "$APP/Contents/Resources/agentmirror-probe.js"
if [[ -f "$ROOT/src-tauri/icons/icon.icns" ]]; then
  cp "$ROOT/src-tauri/icons/icon.icns" "$APP/Contents/Resources/AgentMirror.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing keeps the CI artifact launchable. Set CODESIGN_IDENTITY to a
# Developer ID identity for a signed distribution.
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:--}
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP" >/dev/null

FINAL="$OUT_ROOT/AgentMirror.app"
if [[ -e "$FINAL" ]]; then
  PREVIOUS="$OUT_ROOT/.previous-$(date +%s)-AgentMirror.app"
  mv "$FINAL" "$PREVIOUS"
  echo "previous bundle moved to $PREVIOUS"
fi
mv "$APP" "$FINAL"
trap - EXIT
rm -rf "$STAGE"

/usr/bin/plutil -p "$FINAL/Contents/Info.plist"
file "$FINAL/Contents/MacOS/AgentMirrorApp"
file "$FINAL/Contents/MacOS/AgentMirrorApp" | grep -q 'arm64' || {
  echo "production app executable is not arm64" >&2
  exit 1
}
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$FINAL/Contents/Info.plist" | grep -Fxq "$VERSION"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$FINAL/Contents/Info.plist" | grep -Fxq 'com.agentmirror.desktop'
printf 'built %s\n' "$FINAL"
