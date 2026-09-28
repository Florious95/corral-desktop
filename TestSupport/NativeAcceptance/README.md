# Isolated packaged-app acceptance

This runner launches the candidate `.app` executable, a real daemon built from
the desktop-pinned Corral Core commit, and four real tmux PTYs. It uses only
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

The server builder extracts exactly `a472d4437885060bc0eaf1838c9149e5242948cb`
from Git without changing that repository, then records the source tree,
compiler and binary hash. The older `Fixtures/bin/agentmirrord` is unsuitable
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
