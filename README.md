# Corral Native

Independent Swift 6 / macOS 14+ application workspace. Contracts v0.1 is the shared compile-time boundary for the six production targets; see [Contracts-v0.1.md](Contracts-v0.1.md).

## Safety boundary

- Development identity: `com.corral.native.dev`
- Default endpoint policy: loopback only, port `9919`; all non-loopback endpoints are rejected.
- Manual acceptance can explicitly opt into only `ws://127.0.0.1:9900/ws` with `CORRAL_NATIVE_ENDPOINT` set to that exact URL or `CORRAL_ALLOW_PRODUCTION=1`. This runtime endpoint is not persisted; stored devices remain subject to the default policy.
- No production app, service, or credentials are part of this workspace.

## Build

```sh
swift build
swift test
Scripts/package-app.sh
```

The live vertical-slice test is opt-in via `CORRAL_NATIVE_E2E_TOKEN_FILE=/tmp/corral-gw-test-home/test-token`; it accepts only the isolated fixture token path and uses `127.0.0.1:9919`, never port `9900`.

The packaging script writes only `.build/CorralNativeDev.app` with the isolated `com.corral.native.dev` bundle identifier. `CorralApp` is the only application composition root. Test fixtures and future fixture services must remain isolated from production.
