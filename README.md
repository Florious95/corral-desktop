# Corral Native

Independent Swift 6 / macOS 14+ application workspace. Contracts v0.1 is the shared compile-time boundary for the six production targets; see [Contracts-v0.1.md](Contracts-v0.1.md).

## Safety boundary

- Development identity: `com.corral.native.dev`
- Endpoint validation accepts WebSocket URLs on `127.0.0.1` or `::1` at `/ws` on any valid port, including `9900`; there is no product-level port block.
- Live integration traffic uses only the isolated `127.0.0.1:9919` fixture. Tests may validate or mock `9900`, but never send network traffic to it.
- No production app, service, or credentials are part of this workspace.

## Build

```sh
swift build
swift test
Scripts/package-app.sh
```

The live vertical-slice test is opt-in via `CORRAL_NATIVE_E2E_TOKEN_FILE=/tmp/corral-gw-test-home/test-token`; it accepts only the isolated fixture token path and uses `127.0.0.1:9919`, never port `9900`.

The packaging script writes only `.build/CorralNativeDev.app` with the isolated `com.corral.native.dev` bundle identifier. `CorralApp` is the only application composition root. Test fixtures and future fixture services must remain isolated from production.
