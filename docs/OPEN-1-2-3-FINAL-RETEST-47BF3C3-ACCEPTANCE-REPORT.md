# OPEN-1/2/3 十一项反例与全量终审验收报告

- **验收提交**：`47bf3c3c14a2d872c4aef032070f284d2308a73f`
- **验收席**：AgentMirror 桌面端无头自动化测试席
- **结论**：通过（判据 0）
- **约束**：全程只使用 Node、Swift/WKWebView、Headless Chrome DevTools MCP；未驱动宿主机鼠标键盘，未操作正式桌面实例。

## 1. 三份顾问反证与单测门禁

| 检查 | 结果 | 证据 |
|---|---:|---|
| `advisor-open-f820277/repro.mjs` | **4/4 PASS** | `.team/artifacts/final/repro.log` |
| `advisor-open-22d0d64/remaining.mjs` | **3/3 PASS** | `.team/artifacts/final/remaining.log` |
| `advisor-open-e48c77e/events.mjs` | **4/4 PASS** | `.team/artifacts/final/events.log` |
| 三份反例合计 | **11/11 PASS**，`executed=11 failed=0` | 同上 |
| `CI=true npm test` | **270/270 PASS**，0 fail/cancel/skip | `.team/artifacts/final/npm-test.log` |
| `swift test` | **31/31 PASS** | `.team/artifacts/final/swift-test.log` |
| `swift test -c release` | **31/31 PASS** | `.team/artifacts/final/swift-test-release.log` |
| `swift test --sanitize=thread` | **31/31 PASS** | `.team/artifacts/final/swift-test-tsan.log` |
| `swift test -c release --sanitize=thread` | **31/31 PASS** | `.team/artifacts/final/swift-test-release-tsan.log` |
| `bash native/Tests/ShellTests/run-checks.sh` | **27/27 PASS** | `.team/artifacts/final/shell-checks.log` |
| `npm run build` | 成功（仅既有 chunk size 提示） | `.team/artifacts/final/npm-build.log` |

顾问反例逐项结果：

```text
PASS same geometry re-arms after disarm
PASS async disarm rejection is handled
PASS missing reply envelope rejected
PASS stale native event cannot replace current epoch
PASS in-flight arm ACK cannot restore cache after disarm
PASS reply missing epoch rejected
PASS out-of-order same-epoch event cannot roll back state
PASS duplicate seq
PASS missing seq
PASS missing epoch
PASS wrong version
executed=11 failed=0
```

## 2. OPEN-1：迁移与 M1 启动恢复

真实 WK Probe 实际编译当前 `Shell/*.swift`、`AppServices.swift`、Services 产物和前端 fixture，使用独立
namespace `com.agentmirror.open.probe` / `com.agentmirror.m1.probe`，未触碰正式 Keychain：

- `bootstrap` 方法集包含 `migration.loadUI/saveUI`；
- 合法 `am.*` 白名单值保存、读取 round-trip；未知 key、递归敏感字段与额外参数均返回
  `invalid_request`；
- 无效写入不覆盖旧 snapshot；文件权限实际 `0600`，内容无 synthetic secret；
- 新版本 snapshot 与 legacy `ui-snapshot.json` fallback 均读取成功；
- `OpenAdvisorProbe`：**15/15 PASS**，`executed=15 failed=0`；
- 使用 `dist` 生产构建预置 5 项合法 raw localStorage snapshot 后启动真实 WKWebView：

```text
M1 restored=true localStorageKeys=5 rootCollapsed=true
```

证明 M1 启动路径实际调用 migration load 并恢复 UI 状态。

## 3. OPEN-2：disarm、ACK 竞态与生命周期

Chrome DevTools MCP 在实际 DOM 测量：

- resize 改变宽度：disarm 同步出现，70ms 内无 arm，约 **121ms** 后 arm；
- `agentmirror:window-state-updated`：disarm 后约 **122ms** arm；
- 实际 Tab 新增：20ms 内仅 `{phase:"disarm"}`，约 **133ms** 后 arm；
- arm payload keys 为 `chromeRect,devicePixelRatio,dragRects,exclusionRects,phase,viewportCSS`；
- dispose 同步发最后 disarm，随后 180ms 无 arm；定时器、ResizeObserver、window listeners 均清理；
- 反例验证同几何可重新 arm、在飞 arm ACK 不恢复旧 cache、异步 disarm reject 不形成 unhandled rejection。

## 4. OPEN-3：Reply、epoch、sequence 与版本守卫

- Reply 缺失完整 envelope / `v` / `id` 被 `invalid_response` 拒绝；
- Reply 缺失 epoch 被拒绝，错误 epoch 返回 `stale_geometry`；
- 旧代际 native event 不覆盖当前 epoch；
- duplicate seq、missing seq、missing epoch、wrong version 事件全部被丢弃；
- WK bridge 重放 request id 返回 `invalid_request`；
- Node 与 WK runtime errors 均为 0。

## 5. Headless Chrome Web 端到端

后台夹具为 `node scripts/mock-daemon.mjs`（`ws://127.0.0.1:14395/ws`），Vite 页面为
`http://127.0.0.1:14380/`，全部交互通过 Chrome DevTools MCP 完成：

- 3 个 Agent 列表、鉴权、终端 snapshot 与持续 `tick` 数据流正常；
- 侧栏折叠/展开宽度 `280 -> 0 -> 280`，ARIA label 正确；
- Tab 新增 `1 -> 2 -> 3`，`aria-selected` 正确，切回首 Tab 后终端保活；
- html/body/#root/.app-root 透明；侧栏 `rgba(235,232,227,.55)`；顶栏渐变 alpha `.4/.25`；终端 body
  `rgba(251,250,248,.94)` 高遮罩；xterm viewport 透明；
- Web/Mock nativeCapabilities：window close/minimize/startDragging 安全 resolve，toggleFullscreen 与
  setFullscreen(true) 返回 false；clipboard 默认值安全；secureStore 非 devices key 与非数组 fail-closed；
- 页面控制台 **Error=0、Warning=0**。唯一 `[issue]` 是既有 Search 表单字段缺 id/name，不是 console
  error/warning，也非本次提交引入。

## 6. 独立测试包交付面

`build-swift-test-app.sh` 成功生成独立 `com.agentmirror.desktop.test` 包；`codesign --verify --deep --strict`
返回 0，`nm -m` 可见 `GlassChrome`、`DragSurface`、`SurfaceGeometry`、`ShellBridge`、`DefaultShellServices`、
`AppServices`、`UISnapshotStore` 符号。测试包后台启动 smoke 成功，随后按准确 PID 退出；端口夹具已清理。

## 7. 工具链判定

当前主机 Apple Swift **6.3.3**；工程要求 Swift 6.4/Xcode 26.6 release，真实 6.4 交付面按规则标记
**不可判（2）**。本次 6.3.3 normal/release/TSan 测试与独立包构建全绿，但未冒充 Swift 6.4 证明。
