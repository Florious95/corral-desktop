#!/bin/bash
set -eu
cd "$(dirname "$0")/../../.."
out=".team/artifacts/swift-a/N1"
mkdir -p "$out/fixture" "$out/module-cache"
cat > "$out/fixture/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><script type="module" crossorigin src="/entry.js"></script></head><body>Shell local fixture</body></html>
HTML
printf '%s' "document.body.dataset.moduleReady = 'yes';" > "$out/fixture/entry.js"
printf '%s' 'must not serve' > "$out/outside.html"
ln -sfn ../outside.html "$out/fixture/escape.html"
xcrun swiftc -swift-version 6 -D SHELL_STANDALONE_TEST_RUNNER \
  -module-cache-path "$out/module-cache" \
  native/Sources/Shell/*.swift native/Tests/ShellTests/ShellChecks.swift \
  -o "$out/ShellChecks" > "$out/compile.log" 2>&1
set +e
"$out/ShellChecks" "$out/fixture" > "$out/checks.log" 2>&1
result=$?
set -e
cat "$out/checks.log"
exit "$result"
