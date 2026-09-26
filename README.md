# Corral Native

Independent Swift 6 / macOS 14+ application workspace. Contracts v0.1 is the shared compile-time boundary for the six production targets; see [Contracts-v0.1.md](Contracts-v0.1.md).

## Safety boundary

- Development identity: `com.corral.native.dev`
- Approved development endpoint: loopback only, port `9919`
- Port `9900` and every non-loopback endpoint are rejected by `ApprovedEndpoint`.
- No production app, service, credentials, or remote Swift package dependency is part of this workspace.

## Build

```sh
swift build
swift test
Scripts/package-app.sh
```

The packaging script writes only `.build/CorralNativeDev.app` with the isolated `com.corral.native.dev` bundle identifier. `CorralApp` is the only application composition root. Test fixtures and future fixture services must remain isolated from production.
