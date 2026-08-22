#!/bin/sh
# Headless Chrome 8-cell layout shots. No HID. Bind unused port; never kill occupier.
set -e
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
wt=$(CDPATH= cd -- "$here/../../.." && pwd)
out="$here/shots"
mkdir -p "$out"
PORT=${AM_PILL_PORT:-18773}
CHROME=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT busy, pick another via AM_PILL_PORT" >&2
  exit 2
fi
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$wt" >"$here/http.log" 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT
i=0
while [ "$i" -lt 40 ]; do
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
  sleep 0.1
  i=$((i + 1))
done
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || { echo "http never listened"; exit 2; }

: > "$out/titles.txt"
ok_all=1
for cell in 1 2 3 4; do
  for hover in 0 1; do
    tag="g${cell}-$( [ "$hover" = 1 ] && echo hover || echo idle )"
    url="http://127.0.0.1:${PORT}/.team/nodes/pill/pill-layout.html?cell=${cell}&hover=${hover}"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
      --window-size=1000,640 \
      --virtual-time-budget=8000 \
      --screenshot="$out/${tag}.png" \
      --dump-dom "$url" > "$out/${tag}.dom.html" 2>"$out/${tag}.chrome.err"
    python3 - <<PY
from pathlib import Path
p = Path("$out/${tag}.dom.html").read_text(errors="replace")
i = p.find('id="out"')
print("${tag}", "has_out", i>=0)
if i>=0:
    j = p.find(">", i) + 1
    k = p.find("</pre>", j)
    print(p[j:k][:800])
PY
  done
done
echo "SHOTS_DONE $out"
