#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 /path/to/AgentMirror.app /path/to/AgentMirror-vVERSION-macOS-arm64.dmg" >&2
  exit 2
fi

APP_PATH=$1
OUTPUT_PATH=$2
APP_NAME=AgentMirror.app
OUTPUT_DIR=$(dirname "$OUTPUT_PATH")
VOLUME_NAME=AgentMirror

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "create-dmg.sh requires macOS hdiutil" >&2
  exit 1
}
command -v hdiutil >/dev/null || {
  echo "hdiutil was not found" >&2
  exit 1
}
[[ -d "$APP_PATH" ]] || {
  echo "application bundle not found: $APP_PATH" >&2
  exit 1
}
[[ "$APP_PATH" == *.app ]] || {
  echo "application path must end in .app: $APP_PATH" >&2
  exit 1
}
[[ -f "$APP_PATH/Contents/Info.plist" ]] || {
  echo "application bundle has no Contents/Info.plist: $APP_PATH" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR"
STAGE=$(mktemp -d "$OUTPUT_DIR/.agentmirror-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUTPUT_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$OUTPUT_PATH" >/dev/null

printf 'created %s\n' "$OUTPUT_PATH"
