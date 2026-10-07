#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# -ne 2 ]]; then
  echo "usage: $0 /path/to/verified-runtime /path/to/Corral-Native-arm64.dmg" >&2
  exit 2
fi
[[ $(uname -m) == arm64 ]] || { echo 'arm64 build host required' >&2; exit 1; }
RUNTIME=$(cd "$1" && pwd)
python3 "$ROOT/Scripts/verify-runtime.py" "$RUNTIME"
CORRAL_NATIVE_RUNTIME_RESOURCES="$RUNTIME" "$ROOT/Scripts/package-app.sh"
APP="$ROOT/.build/CorralNativeDev.app"
"$ROOT/Scripts/create-dmg.sh" "$APP" "$2"
hdiutil verify "$2" >/dev/null
shasum -a 256 "$APP/Contents/MacOS/CorralApp" "$2"
echo 'Self-contained development DMG built. Developer ID/notarization is not implied.'
