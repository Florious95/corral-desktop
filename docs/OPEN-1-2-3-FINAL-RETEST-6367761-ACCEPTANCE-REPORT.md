# OPEN-1/2/3 七项反例与全量终审验收报告

- **验收提交**：`6367761f2156c7447168f35805724bc87fb399bc`
- **验收席**：AgentMirror 桌面端无头自动化测试席
- **结论**：通过（判据 0）
- **约束**：全程只用 Node、Swift/WKWebView、Headless Chrome DevTools MCP；未驱动宿主机鼠标键盘，未操作正式桌面实例。

## 1. 反例与单测门禁

| 检查 | 结果 | 证据 |
|---|---:|---|
| `advisor-open-f820277/repro.mjs` | **4/4 PASS**，`executed=4 failed=0` | `.team/artifacts/final/repro.log` |
| `advisor-open-22d0d64/remaining.mjs` | **3/3 PASS**，`executed=3 failed=0` | `.team/artifacts/final/remaining.log` |
| `CI=true npm test` | **270/270 PASS**，0 fail/cancel/skip | `.team/artifacts/final/npm-test.log` |
| `swift test` | **31/31 PASS** | `.team/artifacts/final/swift-test.log` |
| `swift test -c release` | **31/31 PASS** | `.team/artifacts/final/swift-test-release.log` |
| `swift test --sanitize=thread` | **31/31 PASS** | `.team/artifacts/final/swift-test-tsan.log` |
| `swift test -c release --sanitize=thread` | **31/31 PASS** | `.team/artifacts/final/swift-test-release-tsan.log` |
| `bash native/Tests/ShellTests/run-checks.sh` | **27/27 PASS** | `.team/artifacts/final/shell-checks.log` |
| `npm run build` | 成功（仅既有 chunk size 提示） | `.team/artifacts/final/npm-build.log` |

两份顾问反证脚本合计 **7/7 PASS**：

```text
PASS same geometry re-arms after disarm
PASS async disarm rejection is handled
PASS missing reply envelope rejected
PASS stale native event cannot replace current epoch
PASS in-flight arm ACK cannot restore cache after disarm
PASS reply missing epoch rejected
PASS out-of-order same-epoch event cannot roll back state
executed=7 failed=0
```

## 2. OPEN-1：迁移、白名单与 M1 启动恢复

真实 WK Probe 实际编译当前 `Shell/*.swift`、`AppServices.swift`、Services 产物和前端 fixture，使用独立
Keychain namespace `com.agentmirror.open.probe` / `com.agentmirror.m1.probe`：

- `bootstrap` 方法集包含 `migration.loadUI/saveUI`；
- 9 个 `am.*` 白名单中的合法值保存并 round-trip 读取；
- 未知 key、递归敏感字段、带额外参数的 load 全部 fail-closed `invalid_request`；
- 无效迁移写入不覆盖既有 snapshot；
- snapshot 文件实际为 `0600`，序列化内容不含 synthetic secret；
- 使用 `dist` 生产构建预置 5 项合法 raw localStorage snapshot 后启动真实 WKWebView，实测：

```text
M1 restored=true localStorageKeys=5 rootCollapsed=true
```

即 M1 启动路径确实调用 `nativeCapabilities.migration.loadUI()` 并恢复 UI 状态。完整 Probe：

```text
OpenAdvisorProbe: executed=14 failed=0
M1StartupProbe: restored=true
```

## 3. OPEN-2：disarm、ACK 竞态与生命周期

Chrome DevTools MCP 实测页面实际 watcher：

- resize 改变宽度：disarm 同步出现，70ms 内无 arm，约 **122ms** 后 arm；
- `agentmirror:window-state-updated`：disarm 后约 **122ms** arm；
- 实际 Tab 新增：20ms 内仅 `{phase:"disarm"}`，约 **134ms** 后 arm；
- arm payload keys 为 `chromeRect,devicePixelRatio,dragRects,exclusionRects,phase,viewportCSS`；
- dispose 同步发最后 disarm，随后 180ms 无 arm；计时器、ResizeObserver、window listeners 清理；
- 两项反例证明：同几何 disarm 后可重新 arm；在飞 arm ACK 不能恢复旧去重缓存；异步 disarm rejection 不产生
  `unhandledRejection`。

## 4. OPEN-3：Reply、epoch 与事件代际

- Reply 缺失完整 envelope（包括缺 `v/id`）被 `invalid_response` 拒绝；
- Reply `id` 不匹配被 `invalid_response` 拒绝；
- Reply 缺失或不匹配 epoch 被拒绝；
- 旧 epoch native event 不覆盖当前 epoch；
- 同 epoch 乱序 seq 事件不回滚较新的 geometryGeneration；
- WK 实桥错误 epoch 返回 `stale_geometry`，重放 request id 返回 `invalid_request`；
- Node 与 WK runtime errors 均为 0。

## 5. Web Headless Chrome 端到端

后台夹具：`node scripts/mock-daemon.mjs`（`ws://127.0.0.1:14395/ws`）；页面：Vite
`http://127.0.0.1:14380/`；所有交互通过 Chrome DevTools MCP：

- 3 个 Agent 列表、鉴权、终端 snapshot 与持续 `tick` 数据流正常；
- 侧栏折叠/展开宽度 `280 -> 0 -> 280`，ARIA label 正确；
- Tab 新增 `1 -> 2 -> 3`，`aria-selected` 正确，切回首 Tab 后终端仍保活；
- html/body/#root/.app-root 透明；侧栏 `rgba(235,232,227,.55)`；顶栏 alpha `.4/.25`；终端 body
  `rgba(251,250,248,.94)` 高遮罩；xterm viewport 透明；
- Web/Mock nativeCapabilities：window close/minimize/startDragging 安全 resolve，toggleFullscreen 与
  setFullscreen(true) 返回 false；clipboard 默认值安全；secureStore 非 devices key 与非数组 fail-closed；
- 页面控制台 **Error=0、Warning=0**。唯一一条 DevTools `[issue]` 为既有 Search 表单字段缺 id/name，非 console
  error/warning，也非本次修复引入。

## 6. 独立测试包交付面

`build-swift-test-app.sh` 成功生成独立包 `com.agentmirror.desktop.test`；`codesign --verify --deep --strict`
返回 0，`nm -m` 可见 `GlassChrome`、`DragSurface`、`SurfaceGeometry`、`ShellBridge`、`DefaultShellServices`、
`AppServices`、`UISnapshotStore` 符号。包后台启动 smoke 成功，随后按准确 PID 退出，端口夹具已清理。

## 7. 工具链判定

当前主机 Apple Swift **6.3.3**；工程要求 Swift 6.4/Xcode 26.6 release，真实 6.4 交付面按规则标记
**不可判（2）**。本次 6.3.3 normal/release/TSan 测试与独立包构建均全绿，但未冒充 Swift 6.4 证明。
