# Issue #211 — Windows 5090 clean-install/startup gate

This is a test-only harness. It does not modify product code and must run only with the independently built Tauri bundle `com.agentmirror.desktop.test`.

## Files

- `scripts/windows-5090-test-tauri.conf.json` — CLI config override for the test-only bundle identity.
- `scripts/windows-5090-startup-fixture.ps1` — creates/removes only an exact `am-e2e-<run-id>` tmux session and records the expected row count.
- `scripts/windows-5090-clean-install-timing.ps1` — fail-closed clean install, exact test-path/PID cleanup, WebView2 CDP launch and service-PID sampling.
- `scripts/windows-5090-startup-receipt.mjs` — read-only CDP receipt; observes protocol frames and existing DOM selectors, never dispatches input.

## Build the isolated installer

Run from the candidate worktree. Do not mutate `src-tauri/tauri.conf.json`:

```powershell
$cfg = (Resolve-Path scripts/windows-5090-test-tauri.conf.json)
$env:CARGO_TARGET_DIR = (Resolve-Path .team/windows-5090-cargo-target)
$env:CI = 'true'
npm run tauri build -- --ci --no-sign --bundles nsis --config $cfg
```

Before using the installer, verify the generated package identity is `com.agentmirror.desktop.test` and retain the installer SHA-256 in the run artifact. The harness refuses a system install path and requires an explicit `-AllowTestCleanup` switch.

## 5090 run

Use a unique run id, an artifact directory inside the worktree, and a high local WebView2 debug port that is not occupied. The service must not already be running: the harness refuses to touch a pre-existing WSL service because `agentmirrord` is not distinguishable from a production instance by process name alone.

```powershell
$run = '20260921-<unique>'
$art = (Resolve-Path .team/artifacts/windows-5090-issue-211) 
$session = "am-e2e-$run"

powershell -NoProfile -File scripts/windows-5090-startup-fixture.ps1 `
  -Distro Ubuntu -Session $session -ArtifactDir $art -Create
$fixture = Get-Content "$art/fixture-$session.json" | ConvertFrom-Json

powershell -NoProfile -File scripts/windows-5090-clean-install-timing.ps1 `
  -InstallerPath 'C:\path\AgentMirror-Test-setup.exe' `
  -TestInstallRoot "C:\Users\<user>\AgentMirror-e2e-$run" `
  -ArtifactDir $art -ServiceDistro Ubuntu `
  -ExpectedRows $fixture.expectedRows -DebugPort 19250 `
  -AllowTestCleanup

powershell -NoProfile -File scripts/windows-5090-startup-fixture.ps1 `
  -Distro Ubuntu -Session $session -ArtifactDir $art -Cleanup
```

Do not replace `<unique>` with a pre-existing session name. Do not run the harness against `9900`, the production bundle, or a generic `AgentMirror` install directory.

## Gate

`windows-5090-clean-install-timing.json` is PASS only when all are true:

- installer exit code is 0 and the test executable is under the exact test root;
- CDP is available on the dedicated high port;
- an inbound `listing` frame is observed (payloads are token-redacted);
- the sidebar is visible/online and the listing track reaches the fixture expected row count;
- the state is stable for 500 ms;
- visible `.tb-tab[data-blank="true"]` count is 0;
- the WSL service has exactly one observed PID and `pidChanges=0`;
- all timing fields are present: process start → CDP ready → listing frame → first row → listing settled.

If the independent bundle, high-port isolation, expected row count, or service identity cannot be established, report `NOT-RUN` rather than weakening the gate.

## Safety

No token, auth payload, terminal bytes, command line, or user input is collected. Only exact test install paths, exact test PIDs, WSL service PIDs, frame types/metadata, and existing UI geometry/state are recorded. The old `windows-release-smoke.ps1` is intentionally not used; it kills by process name and removes generic app-data paths.
