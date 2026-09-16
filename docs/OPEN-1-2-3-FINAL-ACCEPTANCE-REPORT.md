# OPEN-1/2/3 全量验收通过报告

- **验收提交**：`b4658de8f67a9419441d1caf596df611bd0d4614`
- **验收席**：AgentMirror 桌面端无头自动化测试席
- **结论**：通过（判据 0）
- **输入约束**：仅使用 Node、Swift/WKWebView 与 Chrome DevTools MCP；未驱动宿主机鼠标键盘，未触碰正式桌面实例。

## 1. 构建与单测门禁

| 检查 | 结果 | 证据 |
|---|---:|---|
| `CI=true npm test` | **270/270 PASS**，0 fail/cancel/skip | `.team/artifacts/open-final/npm-test.log` |
| `swift test` | **31/31 PASS** | `.team/artifacts/open-final/swift-test.log` |
| `swift test -c release` | **31/31 PASS** | `.team/artifacts/open-final/swift-test-release.log` |
| `swift test --sanitize=thread` | **31/31 PASS** | `.team/artifacts/open-final/swift-test-tsan.log` |
| `swift test -c release --sanitize=thread` | **31/31 PASS** | `.team/artifacts/open-final/swift-test-release-tsan.log` |
| `bash native/Tests/ShellTests/run-checks.sh` | **27/27 PASS** | `.team/artifacts/open-final/shell-checks.log` |
| `npm run build` | 成功（仅既有 chunk size 提示） | `.team/artifacts/open-final/npm-build.log` |

Node 新增 OPEN-3 Reply `id` 不匹配、Reply `epoch` 不匹配断言均在日志中显示 PASS；OPEN-2/3 watcher
立即 disarm 与 dispose 清理断言显示 PASS。Swift `UISnapshotStoreTests` 六项全部 PASS，覆盖白名单、嵌套敏感字段、
0600、无损读取、过大与 fail-closed。

## 2. 独立测试包交付面

`WEB_ROOT=dist OUT_ROOT=.team/artifacts/open-final/swift-test-app CONFIGURATION=release
bash scripts/build-swift-test-app.sh` 成功生成独立包：

```text
.team/artifacts/open-final/swift-test-app/AgentMirrorTest.app
CFBundleIdentifier = com.agentmirror.desktop.test
codesign --verify --deep --strict = 0
```

后台 `open -n -g` 启动成功，能取得独立进程并已按 PID 精确退出；`nm -m` 可见
`GlassChrome`、`DragSurface`、`SurfaceGeometry`、`ShellBridge`、`DefaultShellServices`、`AppServices`、
`UISnapshotStore` 符号。无用户正式实例操作。

## 3. OPEN-1：UI Snapshot 迁移与安全门禁

在实际 `MainWindowController` + 注入 `AppServices` 的 Headless WKWebView 中，使用独立 Keychain namespace
`com.agentmirror.open.probe` 与独立 snapshot 文件执行：

- `bootstrap` 方法集包含 `migration.loadUI`、`migration.saveUI`；
- 允许的 `am.workspace.v2`、`am.fav`、`am.collapsed`、`am.selected` 保存后可 round-trip 读取；
- 未知 key、嵌套敏感字段（synthetic secret）均返回 `invalid_request`；
- 无效保存后旧 snapshot 仍可读取，内容未被清空/覆盖；
- 生成文件权限实测 `0600`，序列化内容不含 synthetic secret；
- `migration.loadUI` 带额外参数返回 `invalid_request`；
- Swift 单测覆盖严格 9 个 `am.*` 白名单、递归 token/secret/password 等敏感字段拒绝、缺失/损坏/非 0600
  fail-closed 与 256 KiB 上限。

## 4. OPEN-2：变动前 disarm 与防抖 arm

Chrome DevTools MCP + 页面实际 DOM 测量结果：

- 自定义 watcher 首次 arm 后，窗口宽度变动触发 `disarm` **立即发送**；70ms 内仍只有 disarm；约
  **123ms** 后发送 arm；
- `agentmirror:window-state-updated` 触发 disarm 后约 122ms arm；
- 应用实际 Tab 新增触发：20ms 取证仅有 `{phase:"disarm"}`，约 **133ms** 后 arm；
- 应用实际 resize 触发：20ms 取证仅有 disarm，约 **121ms** 后 arm；
- arm 几何 payload keys 为 `chromeRect, devicePixelRatio, dragRects, exclusionRects, phase, viewportCSS`，
  收集的 drag/exclusion 均位于 chromeRect 内，且排除区域与拖拽区有交集；
- WK 生产 adapter 对带额外 viewport/rect 字段的 `phase:"disarm"` 调用成功，并向 native 严格下发 3 字段；
  native exact disarm 也成功。

### OPEN-3 生命周期交叉验收

调用 watcher `dispose()` 后，立即收到最后一次 disarm，180ms 内没有后续 arm；ResizeObserver、window listener、
定时器均已解除。页面变化期间无异常重排/卡住现象。

## 5. OPEN-3：Reply 严格校验与过期作废

WK Probe 通过真实桥接确认：

```text
stale epoch rejected              ok=true code=stale_geometry
replayed request id rejected      ok=true code=invalid_request
runtime errors                    ok=true count=0
```

纯 Node 新增用例进一步实测：

```text
rawCallSwiftRPC rejects reply.id mismatch       PASS (invalid_response)
rawCallSwiftRPC rejects reply.epoch mismatch     PASS (stale_geometry)
```

## 6. Headless WK Probe 总结

Probe 实际编译当前 `native/Sources/Shell/*.swift`、`AppServices.swift`、`Services` 产物与当前前端 fixture，
通过真实 WK local scheme 与 bridge 执行 **14/14**：

```text
bootstrap composition root                         ok
migration.saveUI valid whitelist                  ok
migration.loadUI round-trip                       ok
migration unknown key fail-closed                 ok (invalid_request)
migration nested sensitive field fail-closed       ok (invalid_request)
rejected migration writes preserve old snapshot    ok
migration.loadUI rejects params                   ok (invalid_request)
surface.update product disarm strips extras       ok
surface.update native exact disarm                ok
stale epoch rejected                              ok (stale_geometry)
replayed request id rejected                      ok (invalid_request)
runtime errors                                   ok count=0
migration file mode 0600                          ok
migration file has no synthetic secret            ok
executed=14 failed=0
```

完整日志：`.team/artifacts/open-final/probe-rerun.log`。

## 7. Headless Chrome Web 端到端

后台夹具为 `node scripts/mock-daemon.mjs`（端口 14395），页面为 Vite `127.0.0.1:14380`，全部通过 Chrome
DevTools MCP 完成：

- 设备/Agent 列表 3 行，点击 Agent 后终端 snapshot、持续 `tick` 数据流与鉴权正常；
- 侧栏折叠/展开宽度 `280 -> 0 -> 280`，ARIA label 正确切换；
- Tab 新增 `1 -> 2 -> 3`，`aria-selected` 切换正确，返回首 Tab 后终端仍存活；
- html/body/#root/.app-root 透明；侧栏 `rgba(235,232,227,.55)`；顶栏半透明渐变 alpha `.4/.25`；
  terminal body `rgba(251,250,248,.94)` 高遮罩；xterm viewport 透明；
- Web/Mock nativeCapabilities：window close/minimize/startDragging 安全 resolve，toggleFullscreen 与
  setFullscreen(true) 返回 false，clipboard 默认安全值，secureStore 非 devices key 与非数组 fail-closed；
- 控制台 **Error=0、Warning=0**。仅有一条独立 DevTools `[issue]`（Search 表单字段缺 id/name），不是
  console error/warning，也非本次 OPEN 改动引入；无异常 WS 错误。

## 8. 工具链判定

当前主机 Apple Swift **6.3.3**；工程要求 Swift 6.4/Xcode 26.6 release，因此真实 Swift 6.4 release 交付项
按规则标记为**不可判（2）**，未将预发布工具链构建冒充 6.4 证明。其余验收项全部通过。
