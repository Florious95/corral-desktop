# OPEN-1/2/3 最终反例与全量终审验收报告

- **验收提交**：`7f1d53f66de6ffc433bfd9f1abda1ed8f4c1d249`
- **验收席**：AgentMirror 桌面端无头自动化测试席
- **结论**：通过（判据 0）
- **约束**：全程只用 Node、Swift/WKWebView、Headless Chrome DevTools MCP；未驱动宿主机鼠标键盘，未操作正式桌面实例。

## 1. 门禁与顾问反例

| 检查 | 结果 | 证据 |
|---|---:|---|
| `node .team/artifacts/final/repro.mjs` | **4/4 PASS**，`executed=4 failed=0` | `.team/artifacts/final/repro.log` |
| `CI=true npm test` | **270/270 PASS**，0 fail/cancel/skip | `.team/artifacts/final/npm-test.log` |
| `swift test` | **31/31 PASS** | `.team/artifacts/final/swift-test.log` |
| `swift test -c release` | **31/31 PASS** | `.team/artifacts/final/swift-test-release.log` |
| `swift test --sanitize=thread` | **31/31 PASS** | `.team/artifacts/final/swift-test-tsan.log` |
| `swift test -c release --sanitize=thread` | **31/31 PASS** | `.team/artifacts/final/swift-test-release-tsan.log` |
| `bash native/Tests/ShellTests/run-checks.sh` | **27/27 PASS** | `.team/artifacts/final/shell-checks.log` |
| `npm run build` | 成功（仅既有 chunk size 提示） | `.team/artifacts/final/npm-build.log` |

四项 advisor 反例实测：

```text
PASS same geometry re-arms after disarm
PASS async disarm rejection is handled
PASS missing reply envelope rejected
PASS stale native event cannot replace current epoch
executed=4 failed=0
```

## 2. OPEN-1：M1 启动恢复与 UI Snapshot

### 真实 WK Probe

实际编译并运行当前 `Shell/*.swift`、`AppServices.swift`、Services 产物与当前前端 fixture，使用独立
Keychain namespace `com.agentmirror.m1.probe` / `com.agentmirror.open.probe`，未触碰正式 Keychain。

`OpenAdvisorProbe`：**14/14 PASS**（`.team/artifacts/final/open-probe.log`），覆盖：

- `bootstrap` 方法集含 `migration.loadUI/saveUI`；
- 9-key `am.*` 白名单中的合法值保存与读取 round-trip；
- 未知 key、递归敏感字段、`loadUI` 额外参数均 fail-closed `invalid_request`；
- 无效写入不覆盖既有 snapshot；
- migration 文件权限实际 `0600`，文件内容无 synthetic secret；
- App adapter 的 disarm 额外字段剥离及 native exact disarm；
- 旧 epoch 返回 `stale_geometry`，重放 request id 返回 `invalid_request`；
- runtime errors 为 0。

### M1 生产启动恢复

使用 `dist` 生产构建与注入的 `AppServices` 启动真实 WKWebView，预置 5 个合法 raw localStorage
snapshot 值。`M1StartupProbe` 实测：

```text
M1 restored=true localStorageKeys=5 rootCollapsed=true
```

即启动路径实际调用 `nativeCapabilities.migration.loadUI()` 并恢复 `am.collapsed`、`am.spacesOpen`、
`am.agentsOpen`、`am.selected`、`am.fav`；独立 snapshot 文件权限为 `0600`。

## 3. OPEN-2：disarm → 防抖 arm 与生命周期

通过 Chrome DevTools MCP 在实际 DOM 页面测量：

- resize 改变窗口宽度：`disarm` 同步出现；70ms 内无 arm；约 **122ms** 后 arm；
- `agentmirror:window-state-updated`：disarm 后约 **121ms** arm；
- 实际 Tab 新增：20ms 内仅 `{phase:"disarm"}`，约 **135ms** 后 arm；
- 实际应用 resize：20ms 内仅 disarm，约 121ms 后 arm；
- arm payload keys 精确为 `chromeRect,devicePixelRatio,dragRects,exclusionRects,phase,viewportCSS`；
- dispose：同步发最后 disarm，随后 180ms 无 arm；定时器、ResizeObserver、window listener 已清理；
- 四项反例第一项证明同几何 disarm 后可重新 arm，第二项证明异步 disarm reject 不形成 unhandled rejection。

## 4. OPEN-3：Reply 与代际安全

- advisor repro 验证缺失 Reply envelope 被拒绝；
- Node 新增测试验证 Reply `id` 不匹配返回 `invalid_response`；
- Node 新增测试验证 Reply `epoch` 不匹配返回 `stale_geometry`；
- advisor repro 验证旧代际 native event 不覆盖当前 epoch；
- WK 实际 bridge 验证错误 epoch `stale_geometry` 与重复 request id `invalid_request`；
- 所有 WK/Chrome Probe runtime errors 均为 0。

## 5. Chrome Web 端到端

后台启动 `node scripts/mock-daemon.mjs`（`ws://127.0.0.1:14395/ws`）并用 Chrome DevTools MCP
打开 Vite 页面：

- 3 个 Agent 列表加载，点击后终端 snapshot 与持续 `tick` 数据流正常；
- 侧栏折叠/展开宽度 `280 -> 0 -> 280`，ARIA label 正确；
- Tab 新增 `1 -> 2 -> 3`，`aria-selected` 正确，切回首 Tab 后终端持续工作；
- `html/body/#root/.app-root` 透明；侧栏 `rgba(235,232,227,.55)`；顶栏渐变 alpha `.4/.25`；
  终端 body `rgba(251,250,248,.94)`；xterm viewport 透明；
- Web/Mock nativeCapabilities：window close/minimize/startDragging 安全 resolve，toggleFullscreen 与
  setFullscreen(true) 返回 false；clipboard 安全默认值；secureStore 非 devices key 与非数组 fail-closed；
- 页面控制台 **Error=0、Warning=0**。仅 1 条独立 DevTools `[issue]`（Search 表单字段缺 id/name），
  不是 console error/warning，且非本次提交引入。

## 6. 独立测试包交付面

`build-swift-test-app.sh` 成功生成 `com.agentmirror.desktop.test` 独立包；`codesign --verify --deep --strict`
返回 0，`nm -m` 可见 `GlassChrome`、`DragSurface`、`SurfaceGeometry`、`ShellBridge`、`DefaultShellServices`、
`AppServices`、`UISnapshotStore` 符号。包后台启动 smoke 成功，随后按准确 PID 退出，端口夹具已清理。

## 7. 工具链判定

当前主机 Apple Swift **6.3.3**；工程要求 Swift 6.4/Xcode 26.6 release，真实 6.4 交付面按规则标记
**不可判（2）**。本次 6.3.3 normal/release/TSan 测试与独立包构建均绿，但未冒充 Swift 6.4 证明。
