# Corral Native isolated fixture harness (staging)

Staged here until `native-integration` creates its worktree, then sync into `TestSupport/Fixtures/`. All runtime state is isolated at `/tmp/corral-gw-test-home`; the only authorized service endpoint is `127.0.0.1:9919`.

## Lifecycle and receipts

```sh
./start-isolated-daemon.sh
./verify-isolation.sh
node ./capture-golden-frames.mjs
./stop-isolated-daemon.sh
```

`start-isolated-daemon.sh` runs a byte-for-byte copy of the real `agentmirrord` binary, with `-listen 127.0.0.1:9919`, a dedicated test token, explicit nodeprobe inputs, `HOME`/`TMPDIR`/`TMUX_TMPDIR` under the fixture home, and `AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS` set to only its private `tmux-UID` directory. It starts five named sessions (60-line static output, ANSI 256/truecolor, CJK/Emoji/ZWJ, continuous stream, and split workspace) with six panes. The tiny executable named `codex` emits deterministic fixture text only; it is not a real Codex process and makes no model/network requests.

The pinned nodeprobe build expects a C0 unit-separator from `tmux -F`, but the installed tmux 3.7c sanitizes C0 format bytes to `_`. `runtime/nodeprobe/tmux` is a fail-closed pass-through compatibility shim: it refuses every socket except this fixture's exact `-S` path/`-L` name; only for that one list-panes format it asks the real `/opt/homebrew/bin/tmux` to use `|`, then restores the separator in actual output bytes. All other authorized tmux calls `exec` the real binary unchanged; fixture fields contain no `|`. This fixes the measured tool incompatibility without faking session data or permitting a default-socket fallback.

The daemon PID is recorded at `/tmp/corral-gw-test-home/daemon-9919.pid`. Stop reads only that PID receipt, checks its start time and exact executable path before signaling, and addresses tmux only through the recorded private socket/inode. It does not use `pkill`, process-name searches, the default tmux socket, or broad directory deletion. It removes only known runtime files after confirming port/socket ownership is gone.

`verify-isolation.sh` performs read-only `lsof`/process identity snapshots of production `9900` before fixture start and after verification. It requires listener PID `87692` to remain identical and compares the existing established-socket fingerprint plus listed Corral.app PID identities (`72646`, `90213`). It opens no 9900 connection and sends no test request there. Its `:9900` refusal test exits `64` before any inspection or network operation. Receipts are written under `receipts/` without tokens or terminal payloads. These snapshots can prove stable observed identities, but cannot prove an unobserved transient disconnect did not occur.

The final run (`20260926T060055Z`) had a passing read at 06:01:04 UTC and a fail-closed recheck at 06:01:05: listener identity, established-socket count (2), and listed client identities were stable, but the opaque established-socket fingerprint changed. A heartbeat or OS TCP-state transition is a plausible explanation, not proven by these snapshots. The before/first-pass/recheck values are preserved in the `isolation-20260926T060055Z.*` receipts; do not describe the full interval as an unchanged connection or attribute this drift to the fixture without new evidence.

## Golden protocol bytes

`capture-golden-frames.mjs` uses Node's built-in WebSocket client against only the hard-coded loopback endpoint. It stores actual server-to-client bytes (UTF-8, hex, and base64 for control frames; hex/base64 for binary frames), validates `RA 01 01` SNAPSHOT and `RA 01 02` DELTA headers, and rejects any capture containing the test token. Semantic keys `auth_ok` and `session_list` map to the daemon's actual wire discriminators `auth_ack` and `listing`; no wire bytes are relabeled. The auth request/token are not included. `golden-frames.json` is generated only after all four real frames arrive.

The frozen fixture checkout HEAD is `a472d4437885060bc0eaf1838c9149e5242948cb`; its included executable has SHA-256 `00b0534278f6b0a4e4b569151dcc2782f7cc9bf6dd9b97d84c8e86bf87411f96`, Go build revision `40527e45ed9762286eeebc8cfd8c656a8ef6ff20` (`vcs.modified=true`, build time 2026-08-15). That revision contains the explicit discovery-directory isolation bridge, but the binary's build revision does not equal the staged source checkout HEAD; receipts disclose this provenance caveat rather than implying a reproducible matching build. The captured listing bytes are consequently this executable's real v1 schema (`ref/name/cwd/state/rows/cols`), not the newer fields in the staged checkout; consumers must not treat the frame as evidence that the current checkout was built.

## Resource ledger

```sh
./collect-resource-ledger.sh <native-app-pid> --mode idle --duration 30 --interval 1
```

The collector refuses protected production PIDs and any executable under `/Applications/Corral.app`. It samples `footprint --pid PID --format bytes` and `vmmap -summary PID`, extracting Physical footprint, IOSurface, Metal/IOAccelerator regions, and Malloc dirty bytes. JSON and Markdown reports are written to `ledgers/`. No raw `vmmap` output, command arguments, terminal contents, or credentials are saved.

GPU submission count and render FPS are **not** guessed from RSS, IOSurface memory, or machine-wide GPU percentage. They remain `null` until an instrumented app writes a matching receipt and the collector receives `--metrics-json PATH`, with schema:

```json
{"schema_version":1,"pid":123,"mode":"idle","window_duration_seconds":30,"metal_submission_count":0,"rendered_frames":0,"view_state":"idle"}
```

Only a matching idle receipt with zero Metal submissions and zero rendered frames is marked as a proven idle window. The current staging task has no native app build, so it cannot produce app-attributed Metal/FPS values or claim the M2 budget.

## Pinned runtime inputs

The copied daemon's accepted nodeprobe helper and corpora are checksum-verified by the start script: nodeprobe `57073f…ffb2a3`, titles `cff45d…22b58`, providers `c9e02d…1ee7e`, and Pi extension `c28855…7b714`. The daemon, helper and fixture panes never inherit `TMUX`, Tailscale credentials, user shell configuration, or the production endpoint.

This is a macOS arm64 staging harness. It intentionally fails closed if `9919` is occupied or the protected production listener is not PID `87692`; it never attempts to free a port or repair stale state automatically.
