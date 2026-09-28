# Isolated packaged-app acceptance

This runner launches the candidate `.app` executable, a real daemon built from
the pinned Corral Core commit, and four real tmux PTYs. It uses only
events addressed to that application's own AppKit window. It never activates
the app, posts global HID events, opens port 9900, uses the general clipboard,
or opens the user's device/workspace stores.

Prerequisites: macOS arm64 with an unlocked Retina GUI session, Xcode command
line tools, Go, Python 3 with Pillow/OpenCV/NumPy, Node, Homebrew tmux, and a
Corral desktop checkout with `ws` installed and the unmodified
`scripts/verify_font_sharpness.py`.

```sh
python3 TestSupport/NativeAcceptance/build-server.py --repository /path/to/corral-core-git
Scripts/package-app.sh
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/corral-desktop
swift test
```

`package-app.sh` builds the actual development bundle with `-O`, including
SwiftTerm. It retains DEBUG and symbols for this private acceptance entrypoint.
SwiftPM's default unoptimized build is useful for stepping through source, but
must not be substituted for the packaged binary in throughput acceptance.
Use `swift test -Xswiftc -O` to check the same optimized Swift build settings.

P0 regression cases use the same packaged app, daemon, PTYs and WindowServer
capture path:

```sh
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/corral-desktop --case many-sessions
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/corral-desktop --case many-sessions-stress
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/corral-desktop --case session-liveness
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/corral-desktop --case window-resize
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/corral-desktop --case window-resize --no-resize
```

The ten-session cases check each preview, permanent Tab and reverse return by
screenshot OCR and fresh input echo or advancing output; a stale snapshot
cannot satisfy the live-stream assertion. Departed previews must release their subscriptions; permanent
Tabs retain them. The stress case keeps nine PTYs producing output, starts the
sixth completely empty, verifies actual input/echo, and performs 54 rapid
sidebar clicks before opening all ten permanent Tabs. Window resizing covers
1400 down to 480 points with two panes at a 1:2 ratio, local terminal grids and
real PTY geometry; `--no-resize` requires local reflow with no network resize.
An optional `--server-binary` must name a private `.build` binary copy whose
SHA256 matches its adjacent `build.json`; this can test a deployed binary
without contacting or restarting its production process.

`session-liveness` uses 50 distinct, continuously writing PTYs. It checks all
50 previews and permanent Tabs with fresh output, screenshot OCR, actual input,
focus and hit testing, then 150 rapid preview and 150 warm Tab switches. Every
local click must update the visible session within 100 ms of mouse-down dispatch;
the probe retains the separate row-locating/scroll/layout preparation time and
the original total duration in each `switchSamples` entry. Every measured key
must reach the WebSocket proxy within 100 ms. Full input must reach the real
PTY within 3 s. `latency.json` separately records the fixture's actual read
timestamp, P95 and maximum; native socket latency is not end-to-end PTY latency.
Abandoned previews release both subscriptions and physical views; all 50
permanent view identities survive warm switching. The observer reads cells
only from visible panes so it does not introduce hidden-screen scanning work.

The server builder extracts exactly `f664ec3fde8c96b8d326802dfc92020a2ff818a3`
from Git without changing that repository, then records the source tree,
compiler and binary hash. This includes the connection-scoped reflow epoch
fix: older daemons can silently discard all new deltas after a resized session
is unsubscribed and reopened. Updating the client alone does not fix that
server-side failure. Fetch `fix/native-preview-epoch` from Corral Core if the
pinned object is missing. The older `Fixtures/bin/agentmirrord` is unsuitable
for input acceptance: it ACKs unsupported `input.bytes` as successful bare
Enter. The runner forwards protocol frames unchanged; it does not emulate or
repair the service. The nodeprobe tmux adapter rejects all sockets except its
own and normalizes tmux 3.7's formatting of the discovery field separator.

Each run prints a private `/tmp/corral-native-acceptance-*` directory containing
command receipts, redacted WebSocket frames, screenshots, OCR, raw PTY input,
source/app/server identity and `summary.json`. Owned processes and the private
tmux server are stopped even on failure. The retained directory is evidence;
the daemon's pairing output and private stores must not be published wholesale.

Assertions cover preview versus host state, persistent Tabs, window shortcuts,
warm view identity and wire silence, five destination zones, visible highlight
pixels, both pane outputs, PTY geometry, splitter, ordinary/control keys,
Chinese/Japanese text composition, text/file/image paste, first-click SGR mouse,
precise scroll accumulation, and ordered output in a hidden Tab.

Sharpness uses an unscaled fixed 80-column by 25-row text ROI from the exact
WindowServer window screenshot. It also requires the same image downsampled to
1x and enlarged back to fail the unchanged verifier. This is a text-region
measurement, not a claim that blank pixels in the whole stage pass a density
metric. A stale A screenshot must fail the B-session OCR oracle.
OCR preserves its raw output and normalizes a fixed set of visual homoglyphs
(Vision may read Latin A/B/C as Cyrillic). Session letters remain distinct;
the identical normalization is used by both positive and negative controls.

`PASS_APP_LOCAL` is deliberately narrower than complete human interaction
acceptance. `NSDraggingInfo` destination calls are synthetic; source gesture
tracking through the OS drag manager is not certified. Text composition calls
exercise `NSTextInputClient`, not the system input-method candidate UI. Scroll
events reach the hit-tested terminal handler directly because no global event
is permitted; OS wheel dispatch is not certified. A dedicated macOS VM or
test machine is required to certify these OS paths
without taking the shared host's keyboard and mouse.
