#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/.build/CorralNativeDev.app"

cd "$ROOT"
# This is a user-facing development bundle: optimize the terminal engine and
# renderer as well as the app. Keep DEBUG, symbols and the isolated acceptance
# entrypoint, but do not ship SwiftPM's default -Onone interpreter hot paths.
swift build --configuration debug --product CorralApp -Xswiftc -O
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/.build/debug/CorralApp" "$APP/Contents/MacOS/CorralApp"
cp "$ROOT/Resources/CorralApp-Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" | grep -Fx 'com.corral.native.dev' >/dev/null
printf 'Packaged isolated development app: %s\n' "$APP"
