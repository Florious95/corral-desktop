# Integrated interaction acceptance

The product combines the Opus server-ACK motion gate / fresh-catalog pinned viewport with Astra's source-aware input classification, unsent-tail replacement, explicit grid ownership during font/frame changes, and 2Hz optional telemetry. It deliberately does **not** add local 60Hz selection/NSScroller throttling or another Pane container.

## Invariants and regression findings

- Only engine-generated pointer reports can be coalesced. Literal typed/pasted SGR-looking bytes remain exact, even when repeated.
- Any press/release/key/wheel barrier resets position deduplication and flushes the latest position before itself. Deduplication never crosses gestures.
- `input_ack` is the consumption receipt. The former unconditional 250ms reopen was removed: a 500ms/operation Core otherwise accumulated five inputs. A stalled ACK holds at most the latest motion; key/button barriers still proceed. Stop/reconnect reset the gate, and a late async send cannot install a gate for a different connection/generation.
- Pinned grids suppress automatic font/frame-derived engine resize. Without that guard a larger font briefly shrank Pi's alternate screen, irreversibly losing bottom rows before the fixed grid was restored. Ordinary desktop-owned grids retain existing sizing behavior.
- A mobile takeover during an awaited adaptation nudge suppresses the subsequent desktop resize.

`PointerMotionBackpressureTests` contains red/green oracles for duplicate gestures, literal ESC text and slow server consumption. `IntegratedPinnedGridTests` uses the actual alternate screen and persistent bottom-row content across font changes. `NativeTerminalClipboardAndSelectionTests` additionally exercises 360 cross-line native Shift-selection events while SGR1003 is enabled: each event's endpoint is immediate, release stops movement, copied text is exact, and no remote input leaks.

## Two selection paths

Ordinary Pi mouse tracking routes body selection and its own scrollbar through SGR motion → Core/tmux → Pi; their shared injection bottleneck is ACK-controlled. Pi selection has its own anchor/focus state and inverse-video rendering, and must be tested separately from scrolling.

Mouse-report off, or Shift bypass without mouseShiftCapture, uses local SwiftTerm selection; it never waits for a remote ACK. Its callbacks and selection endpoints must remain immediate.

## Real Pi + WindowServer checks

```sh
Scripts/package-app.sh
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/desktop --case mouse-drag-backlog
python3 TestSupport/NativeAcceptance/selection-run.py --legacy-root /path/to/desktop --pi-session /authorized/long-session.jsonl --mode selection
python3 TestSupport/NativeAcceptance/selection-run.py --legacy-root /path/to/desktop --pi-session /authorized/long-session.jsonl --mode scrollbar
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/desktop --pi-session /authorized/long-session.jsonl --case mobile-shared-anchor
python3 TestSupport/NativeAcceptance/run.py --legacy-root /path/to/desktop --case session-liveness
```

The Pi run is offline, without extensions/skills/context files, on a private copy deleted by cleanup. Do not commit transcripts or capture unrelated windows.

`selection-run.py` samples only the candidate WindowServer window's body ROI throughout a 1200-event full-range drag and after release. It checks actual inverse-video selection spans against the SGR press/release cell coordinates, final motion before release, visible changing pixels, and the next selection gesture. It records ACK tail and a **sampled pixel-settling upper bound** separately. Screenshot interval/overhead is reported; neither ANSI delta arrival nor a repaint request counts as a screen presentation receipt. The <=500ms gates are post-release, not permission for the reported 27-second replay after a ten-second gesture.

This is `PASS_APP_LOCAL` using in-app NSEvents, real Pi/PTY and actual WindowServer pixels. Global HID/physical OS device dispatch is not exercised on the shared host. A 50-session liveness run can take several minutes (many OCR captures); use a sufficient command timeout and scoped-clean the private tmux socket if interrupted.

## Unresolved backend boundary

A desktop opening a ref **after a phone is already subscribed** still sends a size in the initial subscribe, before presence arrives. Avoiding that first size takeover requires Core to preserve current geometry for desktop subscribe when mobile subscribers exist (or an atomic keep-grid subscription contract). The client cannot retroactively prevent it. The current presence/catalog heuristic also does not provide an atomic snapshot geometry generation. Report those separately; never claim that the client package alone fixes them or modify/restart production 9900 to make acceptance pass.
