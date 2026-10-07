# Native self-contained runtime / Windows parity

## Reused implementation and artifacts

- Windows source: `tmux桌面端@7cb91b05d5b894ca18fc0e14e7adfff05fe10a58`, `src-tauri/src/wsl.rs` and `src/App.jsx`: version-bound install → ready service → durable token → authenticated listing; never equate a PID with readiness.
- Pi payload is copied verbatim from `src-tauri/resources/nodeprobe-pi-activity.js` (c28855ea…, 6844 bytes). Swift installer is ported from that repository's `native/Sources/Services/PiProbeInstaller.swift`. Its canonical/compatibility paths and legacy duplicate cleanup are retained; existing directory permissions/user extensions are preserved and writes are atomic.
- DMG creation reuses the existing `scripts/create-dmg.sh`, not a new installer framework.
- Core a38b528 (derived from production017836) retains P0 epoch and notification fixes and accepts the Windows-verified Pi extension. Do not ship the older Windows a472 daemon, which lacks the resubscribe fix. Exact artifact coordinates live in `Resources/RuntimeSources.json`.
- Accepted Darwin nodeprobe57073fd4… is reused, not rebuilt or re-signed. Core's embedded capability, runtime manifest, binary/corpora/extension all have to agree.

## Build (arm64 macOS)

```sh
python3 Scripts/prepare-runtime.py \
  --core-repository /path/to/core-git \
  --daemon /path/to/accepted/agentmirrord-darwin-arm64 \
  --windows-repository /path/to/tmux桌面端
Scripts/package-dmg.sh .build/runtime-bundle .build/Corral-Native-arm64.dmg
```

The builder also carries tmux and its complete non-system dylib closure, relocates load paths, signs only those relocated files, and preserves licenses. A stripped-PATH `tmux -V` and `verify-runtime.py` check runtime independence. There is no runtime dependency on Homebrew/Python/Xcode. Build inputs remain pinned; an incorrect daemon/nodeprobe/plugin fails rather than rewriting the expected hash.

`package-app.sh` without `CORRAL_NATIVE_RUNTIME_RESOURCES` remains the external-daemon development build. `package-dmg.sh` requires a complete verified runtime and sets `CorralSelfContainedRuntime`; missing resources cannot silently produce an App-only DMG. Root app signing deliberately omits `--deep`, which would change the accepted nodeprobe bytes. Developer ID/notarization is not implied by this ad-hoc development DMG.

## Startup and ownership

The App shows its native window, then performs installation/process work on a non-MainActor runtime actor. Resources are validated and atomically installed under the app's private Application Support `runtime/<manifest hash>` directory, so ejecting the DMG does not remove the service executable. Pi is installed at:

- `~/.pi/agent/extensions/nodeprobe-pi-activity.js`
- `~/.pi/agent/plugins/agentmirror-probe/index.js` (compatibility)

A user-domain launchd job owns the daemon, survives UI exit, and restarts unsuccessful exits. Normal installations listen on `:<port>` (all interfaces) so the LAN/Tailscale addresses advertised by `/pair/whoami` are reachable; the native client still connects over loopback. DEBUG acceptance explicitly selects loopback-only. Ownership receipts include the listener configuration, so upgrading an older owned loopback job applies the new policy even if daemon bytes are unchanged. Only a matching private ownership receipt and registered program may be upgraded/stopped. A listening externally managed9900 is reused, never killed/replaced. The daemon owns its durable state/token file; secrets are not launchd arguments. UTF-8 locale is explicit: launchd's C locale would turn tmux's inventory separators and Unicode into underscores, breaking nodeprobe.

Self-contained normal launch always chooses local discovery. Explicit developer endpoints retain their previous behavior. A private DEBUG bootstrap mode requires the existing validated acceptance directory and a non9900 loopback endpoint; home, discovery, activity, storage and launchd label are derived from that directory, never production paths.

## Pi contract (not a new protocol)

The official extension writes per-PID schema-v2 state and answers a Unix-socket nonce challenge. Nodeprobe verifies the live process/channel, Core joins tmux structural identity, and the native client receives normal listing/delta. This is not terminal ANSI registration over a new socket. Existing Pi processes that have not loaded the extension still need official reload or their next launch; installing a file cannot inject code into a running process. Bare Pi outside a discoverable tmux PTY is not magically made mirrorable.

## Tests and real-package acceptance

```sh
swift test -Xswiftc -O
Scripts/verify-polish-issues-regression.sh
python3 TestSupport/NativeAcceptance/runtime-bootstrap.py --legacy-root /path/to/tmux桌面端
# Also pass --app /path/copied-from-readonly-DMG/Corral.app after detaching the DMG.
```

The runner uses the packaged tmux (no formatting shim), private HOME/token/port/socket and a unique launchd label. The app itself installs and starts the real daemon. Two real offline Pi processes on independent named tmux servers are launched without `--extension` or `--no-extensions`; both auto-discovered plugin states/challenges, real nodeprobe health, Core/client listing and Pi input/echo are checked. It kills only its unique job to verify crash restart, closes/reopens only its own App and verifies daemon PID/token/plugin stability. Cleanup bootouts that exact owned job and private tmux server. No9900 requests, host Pi installation or global input.

`CORRAL_TEST_RUNTIME_RESOURCES=/path/to/verified-runtime swift test -Xswiftc -O --filter BundledRuntimeListenerTests` additionally verifies the actual Core on a private port: loopback sandbox, migration of the old receipt/job, HTTP200 on active physical IPv4 addresses, and idempotent reopen. It never touches production9900.

Negative checks include corrupt bytes, outer-manifest attempts to bless a Core-incompatible plugin, symlink escape and preservation of unrelated user extensions. A private existing listener is reused without creating a service job/token or changing that service's state directory. Missing-token authentication is not bypassed. Runtime samples and process identity receipts must remain separate from unit-test assertions.

## Boundaries

- Existing external daemons are not silently upgraded; their capability/version issues remain visible and require owner-authorized deployment.
- This does not install Pi/LLM provider credentials or launch arbitrary agents for the user; it discovers existing accessible tmux nodes and equips future/reloaded Pi with the official plugin.
- Physical OS input, Developer ID signing and notarization require their own authorized acceptance; do not label them green from these app-local checks.
