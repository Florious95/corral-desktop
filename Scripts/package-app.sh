#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/CorralNativeDev.app"

cd "$ROOT"
swift build --configuration debug --product CorralApp
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/debug/CorralApp" "$APP/Contents/MacOS/CorralApp"
cp "$ROOT/Resources/CorralApp-Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" | grep -Fx 'com.corral.native.dev' >/dev/null
printf 'Packaged isolated development app: %s\n' "$APP"
