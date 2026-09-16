#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PACKAGE="$ROOT/native"
WEB_ROOT=${WEB_ROOT:-"$ROOT/dist"}
OUT_ROOT=${OUT_ROOT:-"$ROOT/.team/artifacts/swift-shell-skeleton"}
CONFIGURATION=${CONFIGURATION:-release}

if [[ ! -f "$WEB_ROOT/index.html" ]]; then
  echo "missing $WEB_ROOT/index.html; run npm run build or set WEB_ROOT" >&2
  exit 1
fi

swift_version=$(swift --version)
printf 'swift toolchain: %s\n' "${swift_version//$'\n'/; }"
if [[ "$swift_version" != *"Swift version 6.4"* && "$swift_version" != *"Apple Swift version 6.4"* ]]; then
  echo "WARNING: Swift 6.4 is required for release; this build is a pre-6.4 skeleton check" >&2
fi

swift build --package-path "$PACKAGE" --configuration "$CONFIGURATION"
BIN_DIR=$(swift build --package-path "$PACKAGE" --configuration "$CONFIGURATION" --show-bin-path)
BIN="$BIN_DIR/AgentMirrorApp"
[[ -x "$BIN" ]] || { echo "missing executable: $BIN" >&2; exit 1; }

mkdir -p "$OUT_ROOT"
STAGE=$(mktemp -d "$OUT_ROOT/.stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/AgentMirrorTest.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentMirrorApp"
cp "$PACKAGE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$WEB_ROOT" "$APP/Contents/Resources/web"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing makes the isolated test bundle launchable without touching the
# user's signed AgentMirror.app. Distribution signing belongs to xcodebuild.
codesign --force --deep --sign - "$APP" >/dev/null

FINAL="$OUT_ROOT/AgentMirrorTest.app"
if [[ -e "$FINAL" ]]; then
  PREVIOUS="$OUT_ROOT/.previous-$(date +%s)-AgentMirrorTest.app"
  mv "$FINAL" "$PREVIOUS"
  echo "previous bundle moved to $PREVIOUS"
fi
mv "$APP" "$FINAL"
trap - EXIT
rm -rf "$STAGE"

echo "built $FINAL"
/usr/bin/plutil -p "$FINAL/Contents/Info.plist"
file "$FINAL/Contents/MacOS/AgentMirrorApp"
