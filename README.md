# AgentMirror desktop

Tauri v2 + React + xterm macOS client. Protocol/UI contracts are in
[CLIENT-CONTRACT](docs/CLIENT-CONTRACT.md) and [UI-SPEC](docs/UI-SPEC.md).

```sh
npm run core:init
npm ci
npm test
npm run build
```

`deps/corral-core` is the unmodified source submodule from
https://github.com/Florious95/corral-core at
`05e234374a05aea092de6aabd9f928b3f9ddbbfc`; its license remains in that checkout.
Vite and Node directly import `web/js`. `src/core/client.js` and `protocol.js`
only adapt existing desktop extensions. No copied core or fallback is used.

Initialization fetches the recorded gitlink. Subsequent test/build/dev commands
check the pinned SHA and clean dependency locally without fetching. Preserve any
local dependency edits before restoring it with `npm run core:init`.
`node scripts/core-module-graph.mjs` reports Vite's actual resolved source graph.
