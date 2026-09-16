# A0 toolchain contract

The release shell is built with Swift 6.4 and a pinned Xcode/macOS SDK in CI.
The package deployment target is macOS 14.0; Liquid Glass is selected only at
runtime on macOS 26.0 or newer and has an AppKit vibrancy fallback below it.
The release architecture matrix is arm64 + x86_64.

The current validation host is intentionally recorded as a failed A0
precondition until the new toolchain is installed:

- Xcode 26.6
- macOS SDK 26.5
- `swift --version`: Apple Swift 6.3.3

The test-app script warns and continues with that host solely to validate the
A1 structure and WebView behavior. A release build must run with Swift 6.4;
the warning is not a release acceptance signal.
