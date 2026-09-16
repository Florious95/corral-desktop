# AgentMirror Swift shell (A0/A1)

This is the isolated AppKit + WKWebView shell skeleton. It does not replace
`src-tauri` yet and does not implement the native RPC capabilities.

## Toolchain contract

- Release toolchain: Swift 6.4, pinned in CI together with the Xcode/macOS SDK.
- Deployment target: macOS 14.0.
- Liquid Glass: `NSGlassEffectView`/`NSGlassEffectContainerView` at runtime on
  macOS 26.0+, with `NSVisualEffectView` fallback below macOS 26.
- The current development host may have an older Swift toolchain. A warning
  from the test-app script is not evidence of Swift 6.4 acceptance.

## Build an isolated test app

From the repository root:

```sh
npm run build
WEB_ROOT="$PWD/dist" OUT_ROOT="$PWD/.team/artifacts/swift-shell-skeleton" \
  sh scripts/build-swift-test-app.sh
```

The result is `AgentMirrorTest.app` with bundle identifier
`com.agentmirror.desktop.test`. The script stages the app before an atomic
replacement and never touches the installed production app.

The app locates bundled resources at `Contents/Resources/web`. During a local
`swift run`, it also falls back to `./dist`. WebView navigation is restricted
to files below that root; WebSocket traffic remains in the embedded JS page.
