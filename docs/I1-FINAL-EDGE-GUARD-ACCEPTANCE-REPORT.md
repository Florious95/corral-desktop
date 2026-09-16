# I1 最终边缘守卫验收通过报告

- **验收提交**：`52ed496c8f311f308e572d6c9b325be6ecb63a57`
- **验收席**：AgentMirror 桌面端无头自动化测试席
- **结论**：通过（判据 0）
- **输入约束**：仅使用 Node、Swift/WKWebView 与 Chrome DevTools MCP；未驱动宿主机鼠标键盘。

## 1. 纯 Node 与 Swift 门禁

| 检查 | 结果 | 证据 |
|---|---:|---|
| `npm test` | **267/267 PASS**，0 fail/skip | `.team/artifacts/i1-final/npm-test.log` |
| `swift test` | **25/25 PASS** | `.team/artifacts/i1-final/swift-test.log` |
| `swift test -c release` | **25/25 PASS** | `.team/artifacts/i1-final/swift-test-release.log` |
| `swift test --sanitize=thread` | **25/25 PASS** | `.team/artifacts/i1-final/swift-test-tsan.log` |
| `swift test -c release --sanitize=thread` | **25/25 PASS** | `.team/artifacts/i1-final/swift-test-release-tsan.log` |
| `bash native/Tests/ShellTests/run-checks.sh` | **27/27 PASS** | `.team/artifacts/i1-final/shell-checks.log` |

## 2. I1 Headless WK Probe

使用独立测试命名空间 `com.agentmirror.i1.probe`（未触碰正式设备 Keychain），实际编译当前
`native/Sources/Shell`、`AppServices.swift` 与当前前端 `nativeCapabilities.js` 后运行 WKWebView
探针。结果：

```text
bootstrap=true; methods 包含 devices.load/save、secureStore.get/set、clipboard.*、upload(.http)、surface.update 与 window.*
devices.load via product                  ok=true
clipboard.image via product               ok=true
clipboard.files via product               ok=true
upload via product (body alias)            ok=true observed=unreachable
upload under 15MiB bridge cap              ok=true observed=unreachable
upload over 15MiB bridge cap               ok=true observed=too_large
surface.disarm exact payload               ok=true
secureStore.set value array alias          ok=true
secureStore.set non-array fail-closed       ok=true
native secureStore.set value route         ok=true observed=ok
native secureStore.set forbidden key       ok=true observed=invalid_request
native secureStore.set non-array route      ok=true observed=invalid_request
canonical devices.load with valid epoch    ok=true
runtime errors                             ok=true count=0
executed=16 failed=0
```

`127.0.0.1:1` 无上传服务；`unreachable` 是真实 URLSession 网络错误映射，按既定 Oracle 判定为通过，
不是内部 `invalid_request`/`unavailable` 阻断。

## 3. Headless Chrome DevTools MCP 回归

后台夹具：`node scripts/mock-daemon.mjs`（`ws://127.0.0.1:14395/ws`），Vite 页面：
`http://127.0.0.1:14380/`。通过 Chrome DevTools MCP 完成：

- Mock daemon 鉴权、Agent 列表 3 项、点击 Agent 后终端快照与持续 `tick` 数据流；
- 侧栏折叠/展开：宽度约 `280 -> 48.94 -> 280`；
- Tab 新增、切换：`1 -> 2`，`aria-selected` 正确切换；
- 背景契约：`html/body/#root/.app-root` 透明；`.app-left` 为
  `rgba(235,232,227,.55)`；顶栏渐变 alpha 为 `.4/.25`；终端工作区为
  `rgba(251,250,248,.94)` 高遮罩，xterm viewport 透明；
- `nativeCapabilities` Mock：window close/minimize/startDragging 安全 resolve，
  `toggleFullscreen()` 与 `setFullscreen(true)` 返回 `false`；clipboard 默认值安全；
  非 `devices` key 拒绝；非数组 devices 写入 fail-closed；
- `surfaceGeometry`：初始/resize/window-state/Tab 变化均约 120ms 防抖（实测 122/123/121ms），
  payload keys 精确为 `chromeRect,devicePixelRatio,dragRects,exclusionRects,phase,viewportCSS`，
  drag/exclusion 均在 chromeRect 内且排除区域与拖拽区域相交；
- 导航资源均返回 200，WS 数据流正常；页面控制台 **Error=0、Warning=0**。

Chrome 仅报告 1 条既有 DevTools `[issue]`（Search 表单字段缺 id/name），不是 console error/warning，
不属于本次 I1 接缝改动。

## 4. 独立测试包交付面

`build-swift-test-app.sh` 成功生成：

```text
.team/artifacts/i1-final/swift-test-app/AgentMirrorTest.app
CFBundleIdentifier = com.agentmirror.desktop.test
codesign --verify --deep --strict = 0
```

独立测试包后台启动 smoke 成功，随后按 PID 精确退出；未操作用户正式实例。产物包含
`GlassChrome`、`DragSurface`、`SurfaceGeometry`、`ShellBridge`、`DefaultShellServices`、`AppServices`
符号（`nm -m` 可见）。

## 5. 工具链判定

当前主机为 Apple Swift **6.3.3**；工程要求的 Swift 6.4/Xcode 26.6 release 判定为**不可判（2）**，
并未将本机预发布 skeleton 构建冒充 6.4 交付证明。其余可执行验收项全部通过。
