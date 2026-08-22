# AgentMirror 桌面端 · 客户端连接契约

> 面向实现。读完本文即可接线,不必再读 `docs/protocol.md` 原文。
> 上游只读,禁止修改:`/Volumes/nvme/Projects/远程Agent安卓/`。

---

## 0. ⚠️ 权威顺序:实现 > 文档

`/Volumes/nvme/Projects/远程Agent安卓/docs/protocol.md` **有三处已被服务端实现推翻**。
按文档写会得到静默错误(字段永远 undefined / 输入发不出去)。下面三条是本文档的第一优先级。

### 0.1 `state` / `aggregate_state` 已被整体拔除

`server/internal/api/listing.go` 头部注释(060 uproot, 2026-08-15):

> the agent-state pipeline was removed wholesale … The 012 aggregation rules and
> the state fields on Session/Workspace are gone with it.

实测 `internal/protocol/frames.go`:

```go
type Workspace struct {  // 没有 AggregateState
    Cwd string; SessionCount int; Sessions []Session
}
type Session struct {
    Ref, Name, Cwd, Title string
    Status   string `json:"status,omitempty"`   // 只在 level2_frame 里被填
    Provider string `json:"provider,omitempty"` // 同上
    Rows, Cols uint16
}
```

`toSession()`(listing 的唯一构造点)只填 `Ref/Name/Cwd/Rows/Cols`。
所以 **listing / list_delta 里的 session 永远没有 status、没有 provider、`title` 恒为 `""`;
workspace 永远没有 aggregate_state**。夹具 `testdata/listing.json` 可自证(有 `title`,无 `status`)。

**后果:** 侧栏状态点不能从 listing 拿。必须走 §3.6 的 `level2_*` 直播流。
Web 端 `client.js` 里读 `s.state` / `w.aggregate_state` 的代码是**死代码**(对真 daemon 恒为 undefined),
`web/scripts/e2e.mjs` 的 "session states are closed-set" 断言对真 daemon 会 FAIL。别照抄这段渲染。

### 0.2 状态值是三值,不是五值;设计稿的 blocked/done 永远不会出现

`protocol.go` 闭集:`working` / `idle` / `unknown`。没有 `blocked`,没有 `done`。

**产品影响(需向上反馈):** 设计稿的「琥珀色脉冲点 = blocked」「标题尾绿对勾 = done」
在当前 daemon 下**永远不会被触发**。做法:渲染层保留这两个分支(未来 daemon 补上即可生效),
但验收时不要求能演示它们。侧栏聚合态由**客户端**自算(服务端不再下发):

```
workspace 聚合 = 有任一 working → working;否则有任一 idle → idle;否则 unknown
```

(即 §5.2 优先级表在三值闭集上的退化形式。未订阅 level2 的 space 一律渲染 unknown 灰空心点。)

### 0.3 `input.text` **不再追加回车**(requirement 059 直通输入)

`ws_handler.go` `handleInput` 实测三分支:

| 帧内容 | 服务端动作 |
|---|---|
| `text` 非空、无附件 | `br.TypeKeys(text)` — **打字进 CLI 输入框,不追加 Enter** |
| `text` 为空、无附件、无 keys | `br.Inject("")` — **裸 Enter**(提交) |
| `keys` 非空 | `br.SendKeys(...)` — 按一下,不追加 Enter |

`protocol.md §4.2` 写的「整条文本一次性注入并回车」**已作废**。
桌面端 InputBar 的「发送」= **两帧**,见 §3.5。

---

## 1. vendor 清单

目标目录 `/Volumes/nvme/Projects/tmux桌面端/src/vendor/agentmirror/`。
源目录 `/Volumes/nvme/Projects/远程Agent安卓/web/js/`。

| 源文件 | 判定 | 理由 |
|---|---|---|
| `binary.js` | ✅ **原样复制** | 零 DOM 依赖;只用 `TextEncoder`/`TextDecoder`/`DataView`,浏览器与 Node 22 都有。唯一 import 是 `./protocol.js`,相对路径不变。 |
| `scrollback.js` | ✅ **原样复制** | 纯函数 `fetchOlder(builder,{onLoading,onError})` / `acceptScrollback(g,frame)`;DOM 全部藏在调用方传入的 `g.showScrollbackPanel()` 回调后面。零 import。 |
| `protocol.js` | ⚠️ **复制 + 追加式补丁**(§1.1) | 零 DOM 依赖,但 `FRAME_TYPES` 缺 5 个真 daemon 会推的类型,`decodeControl` 对未知 type **抛 `unsupported_type`** → 帧被丢弃 + 刷 `onLocalError`。不补必错。 |
| `client.js` | ⚠️ **复制 + 追加式补丁**(§1.2) | 零 DOM 依赖(`WebSocket` 走可注入的 `wsFactory`,timer 有 `unref` 守卫)。需要补 level2 订阅 + 重连重放。 |
| `terminal.js` | ❌ **不 vendor,重写**(§1.3) | 三条硬依赖:① 要求 `globalThis.Terminal`(UMD `<script>` 全局),Vite 下是 `import { Terminal } from '@xterm/xterm'`;② `_charWidth()` 手工插探针 span 量宽,`@xterm/addon-fit` 做得更准;③ `document.createElement`/`window.getComputedStyle` 直接写死。 |
| `preferences.js` | ❌ **不 vendor,重写** | 数据模型是**单档** `{url, token}`,桌面端是多设备数组(§4)。函数签名对不上,复制反而误导。 |
| `app.js` | ❌ 不 vendor | 全 DOM + 依赖 `index.html` 的 `#ws-url`/`#session-panels` 等 20 余个 id。**但 `SessionPage` 是行为参照物**,§3 已逐条抽干。 |
| `overlay.js` | ❌ 不 vendor | tmux `choose-tree` 悬浮窗(需求 064/065),桌面端 v1 不做。 |

### 1.1 `protocol.js` 补丁清单(全部是**追加**,不改已有行为)

1. `FRAME_TYPES` 追加:`'level2_subscribe','level2_unsubscribe','level2_frame','level2_heartbeat','pane_mode_changed','scroll_wheel','attach_preview'`
   (`overlay_*` 三项已在,保留不用。)
2. `INPUT_KEYS` 追加 `'backspace'` —— Go `protocol/keys.go` 是 **8 值**闭集,web 端漏了。
3. `ERROR_CODES` 追加 `'invalid_field'` —— Go `ErrCodeInvalidField` 会真发出来(070:不能只说 malformed frame)。
4. `KNOWN_FIELDS` 追加(字段名逐字来自 Go struct tag):

   ```js
   level2_subscribe:   ['workspace'],
   level2_unsubscribe: ['workspace'],
   level2_frame:       ['workspace', 'seq', 'sessions'],
   level2_heartbeat:   ['workspace', 'seq'],
   pane_mode_changed:  ['ref', 'in_copy_mode'],
   scroll_wheel:       ['ref', 'delta'],
   attach_preview:     ['ref', 'path'],
   // 已有的 input 追加一项:
   input: ['req_id', 'ref', 'text', 'keys', 'attachment_path'],
   ```
5. `validateFrame` 追加分支(照抄 Go `Validate`):
   `level2_subscribe`→`workspace` 非空;`level2_unsubscribe`→无约束;
   `level2_frame`→`workspace` 非空且 `seq>=1`;`level2_heartbeat`→同;
   `pane_mode_changed`→`ref` 非空;`scroll_wheel`→`ref` 非空且 `delta !== 0`;
   `attach_preview`→`ref`、`path` 均非空。
   `input` 的互斥规则改为 **(text 或 attachment_path) 与 keys 互斥**。
6. `canonicalPayload` 追加同名分支(字段顺序照 §1.1.4 的数组顺序,保住夹具字节稳定)。
7. 追加导出 `export const SESSION_STATUS = Object.freeze(['working','idle','unknown']);`。
   `AGENT_STATES`(五值)保留但标注 `@deprecated 060 uproot`,渲染层不得依赖。

> 补丁必须**只加不改**:`encodeControl/decodeControl` 的既有路径一字节不动,
> 这样 §1.4 复制过来的 golden 夹具测试仍然全绿 —— 那是协议没漂移的唯一证据。

### 1.2 `client.js` 补丁清单

1. 新方法(命名对齐既有的 `subscribeOverlay/unsubscribeOverlay`):

   ```js
   /** 订阅一个 workspace 的二级直播流。一个连接同时只能订阅一个 cwd(服务端 level2WS 是单值)。 */
   subscribeLevel2(cwd) {              // 空 cwd 拒绝并返回 false
     this.level2Workspace = cwd;
     if (!this.isReady) return true;   // 记账,READY 后重放
     return this.sendControl('level2_subscribe', { workspace: cwd });
   }
   unsubscribeLevel2() { this.level2Workspace = null; /* READY 时发 level2_unsubscribe */ }
   ```
2. `constructor` 里加 `this.level2Workspace = null;`
3. `replaySubscriptions()` 末尾追加:`if (this.level2Workspace) this.sendControl('level2_subscribe', { workspace: this.level2Workspace });`
4. 可选(桌面鼠标滚轮转发,v1 可不做):`scrollWheel(ref, delta) { return this.sendControl('scroll_wheel', { ref, delta }); }` —— 无 ack,失败以 `error` 帧回。
5. **不要动** `buildFromListing/applyDelta` 里读 `aggregate_state` 的兜底逻辑(它降级成 `'unknown'`,无害);
   但渲染层**不得读** `workspace.aggregate_state`,聚合按 §0.2 自算。

### 1.3 `TerminalView` 重写规格(`src/term/TerminalView.js`)

保留 web 版全部**语义**,只换实现底座:

```js
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';

export class TerminalView {
  constructor(container, { onResize, onHistoryBoundary, scrollback = 5000, fontSize = 13 } = {})
  open()                       // term.open(container) + fitAddon.fit();挂 onScroll 边界回调
  fit()                        // fitAddon.fit();rows/cols 变了才 _report()
  writeSnapshot(u8)            // term.reset() 然后 term.write(u8) —— 清屏重建
  writeDelta(u8)               // term.write(u8) —— 追加
  clear() / focus() / scrollToBottom() / dispose()
  get rows() / get cols()
}
```

**必须保留的行为:**
- 窗口 `fit()` 的 `_report()` 不再驱动协议 `resize`（TerminalPane 不 `client.resize`）。
- 本地格子 **跟随主机**：`subscribe(listing.rows, listing.cols)` + snapshot `inferHostCols` → `followHostGrid`（不上抛）。
- 容器只做布局挤压（overflow / 底行可见）。0×0 不算 seed。
- `onScroll` 边界:`line <= 0 && this._lastScrollLine > 0` → 触发 `onHistoryBoundary()` → 拉更早历史。
- 重连 `replaySubscriptions()` 重放 **Map 里最新** 的 rows/cols（`subscribe` 与随后的 `resize` 都会写入）。

新增依赖:`@xterm/xterm@6`(已裁定)+ `@xterm/addon-fit`。不再需要 `postinstall.cjs` 拷 UMD。

### 1.4 测试与夹具

复制到 `/Volumes/nvme/Projects/tmux桌面端/test/`:

| 源 | 目标 | 改动 |
|---|---|---|
| `web/test/protocol.test.js` | `test/protocol.test.js` | import `../js/protocol.js` → `../src/vendor/agentmirror/protocol.js`;`FIXTURES` 见下 |
| `web/test/binary.test.js` | `test/binary.test.js` | 同上(`../js/binary.js`、`../js/protocol.js`) |
| `web/test/client.test.js` | `test/client.test.js` | 同上,三处 import |
| `web/test/scrollback.test.js` | `test/scrollback.test.js` | 同上,一处 import |
| `web/test/terminal.test.js` | `test/terminal.test.js` | **改写**:`FakeTerminal` 注入方式随 §1.3 改成 mock `@xterm/xterm` 模块;两条断言(120ms 合并、滚到顶触发历史)语义不变 |
| `preferences/app-wiring/overlay/dev-server` 四个 | ❌ 不复制 | 分别对应已弃用的单档存储 / app.js 源码正则 / overlay / web dev-server |

夹具:`server/internal/protocol/testdata/` 全部 22 个文件复制到
`/Volumes/nvme/Projects/tmux桌面端/test/fixtures/protocol/`(上游只读,不可跨仓引用路径)。
两个测试里的路径改成:

```js
const FIXTURES = fileURLToPath(new URL('./fixtures/protocol/', import.meta.url));
```

新增 `test/devices.test.js`(DeviceManager,§2)与 `test/storage.test.js`(§4)。
跑测:`node --test "test/*.test.js"`(与 web 端一致,不引测试框架)。

---

## 2. DeviceManager(`src/core/devices.js`,新写)

管 N 个 `Client` 实例,对上暴露一份跨设备合并模型。**它是 UI 与协议层之间的唯一边界。**

### 2.1 底层 `Client` 真实签名(逐条来自 `web/js/client.js`,不要凭记忆)

构造:`new Client({ url, token, wsFactory?, inputTimeoutMs?=10000, backoff?, onStateChange, onFrame, onBinary, onLocalError, onInputResult, onConnectionIssue })`

| 回调 | 签名 | 语义 |
|---|---|---|
| `onStateChange` | `(s) => void` | `s ∈ ClientState`(见下) |
| `onFrame` | `(type, payload) => void` | 已解码+已白名单过滤的控制帧。`listing`/`list_delta` 在回调**之前**已写进 `client.workspaces` |
| `onBinary` | `(frame) => void` | `frame = { kind, ref, reqId, fromLine, lineCount, data:Uint8Array }` |
| `onLocalError` | `(code, message) => void` | 本地编解码失败(`bad_magic`/`unsupported_type`/`truncated`…) |
| `onInputResult` | `(reqId, ok, reason\|null) => void` | `ok=false` 时 reason 含 `'timeout'`(10s 本地超时)与 §6 的服务端 reason |
| `onConnectionIssue` | `(reason) => void` | 每次 socket close 都触发,含自动重连中的 close |

`ClientState = { STOPPED:'stopped', CONNECTING:'connecting', AUTHENTICATING:'authenticating', READY:'ready', RECONNECTING:'reconnecting' }`

方法与返回值:

| 方法 | 返回 | 备注 |
|---|---|---|
| `connect()` | — | **仅当 STOPPED 才生效**,否则静默 no-op |
| `disconnect()` | — | 永久停;`_permanent=true`,不再重连 |
| `list()` | `bool` | 帧是否发出 |
| `subscribe(ref, rows, cols)` | `bool` | 未 READY 时**只记账并返回 true**,READY 后自动重放 |
| `unsubscribe(ref)` | `bool` | 幂等 |
| `input(ref, text)` | `reqId \| null` | `null` = 没发出去 |
| `keys(ref, key)` | `reqId \| null` | 单个键名字符串 |
| `scrollback(ref, fromLine, count)` | `reqId \| null` | 未 READY 直接返回 `null` |
| `resize(ref, rows, cols)` | `bool` | 未 READY 返回 `false` |
| `subscribeLevel2(cwd)` / `unsubscribeLevel2()` | `bool` | §1.2 补丁 |

只读属性:`isReady`、`state`、`activeRefs`(`string[]`)、`workspaces`、`sessionsByRef`(`Map`)、`session(ref)`、`lastSeq`。

### 2.2 DeviceManager API

```js
export class DeviceManager {
  constructor({ storage = globalThis.localStorage, wsFactory,
                onModelChange, onDeviceChange, onBinary, onInputResult, onError })

  // —— 设备增删改 ——
  addDevice({ name, url, token })      // → deviceId(crypto.randomUUID);落盘;默认 checked=true
  updateDevice(id, { name?, url?, token? })  // url/token 变化 → 重建 Client 并重连
  removeDevice(id)                     // disconnect + 落盘 + 清掉该设备的 fav/pane
  setChecked(id, bool)                 // 只影响聚合模型是否包含它;不断连接
  get devices()                        // → [{ id, name, url, checked, state, lastError }] ⛔ 不含 token

  // —— 连接 ——
  connectAll()                         // 对每个已存设备 new Client + connect()(含未勾选的:勾选只管显示)
  disconnectAll()
  reconnect(id)                        // 对已 STOPPED 的设备重新 connect()
  isReady(deviceId)                    // → bool

  // —— 聚合模型 ——
  get workspaces()                     // → AggregatedWorkspace[](见 2.3)
  space(spaceKey)                      // → AggregatedWorkspace | undefined
  agent(uid)                           // → AggregatedSession | undefined

  // —— 会话动作(全部按 uid 路由到对应 Client) ——
  subscribe(uid, rows, cols) / unsubscribe(uid)
  input(uid, text)                     // → { deviceId, reqId } | null
  keys(uid, key)                       // → { deviceId, reqId } | null
  scrollback(uid, fromLine, count)     // → { deviceId, reqId } | null
  resize(uid, rows, cols)              // → bool

  // —— 二级状态流 ——
  subscribeLevel2(spaceKey)            // 一台设备同一时刻只能订一个 cwd(硬约束,见 2.5)
  unsubscribeLevel2(deviceId)
}
```

**uid 是唯一寻址键:`uid = \`${deviceId}::${ref}\``。**
⛔ 绝不允许裸 `ref` 跨设备流通 —— 两台机器的 ref 都是 `socket\x1f%paneId`,不同主机重复概率极高。
`spaceKey = \`${deviceId}::${cwd}\``,同理。

### 2.3 聚合模型形状

```js
AggregatedWorkspace = {
  spaceKey, deviceId, deviceName,
  cwd,                    // 原始绝对路径
  label,                  // basename;与列表内其它 label 撞名时自动加尾部路径消歧(见下)
  sessionCount,           // = workspace.session_count(服务端权威)
  aggregateState,         // 客户端自算(§0.2),无 level2 数据时为 'unknown'
  sessions: AggregatedSession[],
}
AggregatedSession = {
  uid, deviceId, deviceName, ref,
  name, cwd, rows, cols,  // 来自 listing
  title, status, provider,// 来自 level2_frame;没订过就是 '' / 'unknown' / ''
}
```

- **并集,不合并**:不同设备下相同 cwd 是**两行**,各带自己的设备徽章。同一主机同一 cwd 才是一行。
- **label 消歧**:先全部取 `basename(cwd)`;对撞名的那一组,逐级向前补父目录(`b/a` → `c/b/a`)直到组内唯一。
- **排序**:先 deviceName,再 cwd 字典序(与服务端 `ordered` 一致,保证稳定)。
- 未勾选设备(`checked=false`)的 workspace **不进** `workspaces`,但它的 Client 仍连着(勾选是显示开关,不是连接开关 —— 取消勾选再勾回来要秒回,不能重走 auth)。

### 2.4 事件

- `onModelChange(workspaces)` —— 任一设备收到 `listing` / `list_delta` / `level2_frame`,或 `setChecked` 后触发。**做 100ms 合并**(多设备同时推会连打)。
- `onDeviceChange(devices)` —— 任一设备 `onStateChange` / `onConnectionIssue` / 增删改后触发。
- `onBinary({ deviceId, uid, frame })` —— **必须包 deviceId**;底层 `frame.ref` 单独用会串设备。
- `onInputResult({ deviceId, reqId, ok, reason })`
- `onError({ deviceId, code, message })` —— 来自 `onLocalError` 与 `error` 帧。⛔ message 里不得拼 token。

### 2.5 level2 的硬约束

服务端 `wsConn.level2WS` 是**单值字符串**,一个 WS 连接同时只跟踪一个 workspace。
再次 `level2_subscribe` 会**覆盖**上一个,不是叠加。

策略(与服务端 idle-gate 意图一致:进二级菜单才订):
- 用户在侧栏选中某个 Space → `subscribeLevel2(spaceKey)`;切走 → 自动覆盖(不必先 unsubscribe)。
- 每个 deviceId 记一个 `currentLevel2Cwd`,重复订同一个直接跳过(避免白刷一次全量扫描)。
- 未订阅的 Space:`aggregateState='unknown'`,session 的 `status='unknown'` —— 渲染成灰空心点,**不要伪造成 idle**。
- 离开会话页 / 应用进后台 → `unsubscribeLevel2()`,让 daemon 停扫(零订阅者=零 tmux 调用)。
- `level2_heartbeat` 到达 = 「没变化,连接活着」→ **只刷新存活时间戳,不清空列表**。
- `level2_frame.sessions` 是**整体替换**该 workspace 的二级视图,不是增量。
- `level2_frame.seq` 断档 → 重发 `level2_subscribe`。

---

## 3. 会话面板数据流

角色:`TerminalPane`(一个分裂列 = 一个 uid)、`InputBar`。全部经 DeviceManager,不直接摸 Client。

### 3.1 挂载:subscribe → snapshot → delta

```
TerminalPane.mount(uid):
  term = new TerminalView(hostEl, {
    onResize: (rows, cols) => dm.resize(uid, rows, cols),      // 见 3.4
    onHistoryBoundary: () => this.loadHistory(),               // 见 3.3
  })
  term.open()
  dm.subscribe(uid, term.rows, term.cols)     // 未 READY 也要调:Client 会记账并在 READY 后重放
  status = 'subscribing…'
```

`onBinary` 路由(`uid` 匹配才处理,否则丢弃 —— 其它分裂列的帧):

| `frame.kind` | 动作 |
|---|---|
| `1` SNAPSHOT | `term.writeSnapshot(frame.data)` → **`reset()` 清屏 + `write()` 重建** |
| `2` DELTA | `term.writeDelta(frame.data)` → 追加 |
| `3` SCROLLBACK | `acceptScrollback(this, frame)`(§3.3) |

**snapshot 的游标锚**:服务端已在字节尾追加 `ESC[row;colH`(CUP,1 基),并裁掉尾部空行。
客户端**必须整段原样喂给 xterm**,不得 trim、不得按行拆 —— 拆了游标就落错行,后续不带绝对定位的
delta(bash SIGWINCH 重绘是纯 `\r ESC[K …`)会画到快照末尾,产生残影。

字节永远是 `Uint8Array` 直喂 `term.write()`:ANSI 不转义,UTF-8 多字节序列可跨帧,xterm 自己拼。

### 3.2 卸载

```
TerminalPane.unmount():
  resizeObserver.disconnect(); term.dispose(); dm.unsubscribe(uid)
```
`unsubscribe` 幂等;连接关闭即隐式全部退订。

### 3.3 scrollback:12 字节元数据头与视口锚定

请求(直接复用 vendor 的 `fetchOlder`):

```js
fetchOlder(() => this, { onLoading: n => setStatus(`加载 ${n} 行历史…`), onError: setStatus });
```
`this` 必须提供:`term`(有 `.rows`)、`ref`、`client`(有 `.scrollback(ref,from,count)`)、
可写的 `pendingScrollback` / `nextScrollbackLine`、以及 `showScrollbackPanel(fromLine,lineCount,data)`。
> 桌面端接 DeviceManager 时,给 `fetchOlder` 传的 `client` 用一个薄 shim:
> `{ scrollback: (ref, f, c) => dm.scrollback(uid, f, c)?.reqId ?? null }`。

窗口大小:`historyLines = max(50, term.rows * 2)`,首次 `fromLine = -historyLines`。

回复是二进制 kind=3,`ref` 之后的 **12 字节大端元数据头**:

```
[req_id: 4B 无符号 BE][from_line: 4B 有符号 BE][line_count: 4B 无符号 BE][ANSI 字节…]
```

`binary.js` 已解好(`frame.reqId/fromLine/lineCount/data`)。**这三个值是服务端 clamp 后的真实区间,
不是你请求的值** —— 请求 `from=-300,count=100` 而只有 50 行历史时回 `from=-100,count=50`。

锚定规则(`acceptScrollback` 已实现,别自己算):
- `frame.reqId !== pendingScrollback.reqId` → **丢弃**(旧请求的迟到回复)。
- 匹配则 `nextScrollbackLine = fromLine - lineCount`,下一页从这里继续往前翻。
- 历史渲染进**独立只读面板**,⛔ 绝不写进活的 xterm 网格(会污染 delta 流的行对齐)。
  面板文本渲染需自己转义 `& < >`,web 版的 `renderAnsi()` 可作参照(只解 SGR 颜色,其余 ESC 吞掉)。

触发点两个:历史按钮点击;`term.onScroll` 滚到顶(`line<=0` 且上次 `>0`)。
`pendingScrollback` 非空时**不发新请求**(单请求在飞)。

### 3.4 resize → 补发 snapshot(可能不补)

`fit()` 的 `onResize` **不再**接到 `dm.resize`（#54 回炉：窗口 seed 不是主机宽度）。订阅用 listing 的主机 rows/cols；snapshot 按行宽把本地格子跟上。窗口拖拽只挤压，不发 `resize` 帧（裁定 2026-08-23）。

服务端 `handleResize` 实测（重连 replay 的 subscribe 仍会 `Resize`）:
- 只对**已订阅**的 ref 生效;未订阅 = 静默 no-op,无任何回复。
- 只有发生**真实 reflow**(几何确实变了)才补发一帧 snapshot;
  几何没变会走 `"ws: resize no-op, skip snapshot"` 分支,**什么都不回**。
- 没有独立的 resize ack —— 补发的 snapshot 就是事实回执。

⛔ 因此 UI **不得**进入「等 snapshot」的阻塞态,也不得对 resize 设超时报错。发完即忘。

### 3.5 input:两帧提交,不是一帧

**⚠️ 见 §0.3:`text` 不带回车。** InputBar 的「发送」(回车或按钮):

```
send(text):
  if (!dm.isReady(deviceId)) { status='未连接,未发送'; return }   // ⛔ 必须先判,见 §6
  if (text === '') { dm.input(uid, ''); return }                 // 裸 Enter = 直接提交 CLI 输入框
  const a = dm.input(uid, text)                                  // 帧1:打字进 CLI 输入框(无 Enter)
  if (!a) { status='未发送'; return }
  待 onInputResult(a.reqId) 回 ok === true 后:
    dm.input(uid, '')                                            // 帧2:裸 Enter 提交
```

**为什么要等第一帧的 ack**:同一连接的帧是顺序处理的,但若帧1 因 `not_subscribed`/`inject_failed` 失败,
帧2 会把 CLI 输入框里**已有的旧内容**给提交掉。等 ack 才可判定。ack 一般在毫秒级返回。
(若实测延迟不可接受,可退化为背靠背发两帧 —— 但必须在代码里留 `ponytail:` 注释写明这个风险。)

多行文本:含 `\n` 的 `text` **不要在客户端拆行**,整段交给服务端(走 `paste-buffer -p` 括号粘贴)。
目标 CLI 不声明 `?2004` 时会退化成逐行执行 —— 这是已知且已裁定的风险,不在客户端补偿。

**keys 闭集(8 值,不是 7)**:`esc` / `ctrl_c` / `tab` / `up` / `down` / `left` / `right` / `backspace`。
`text` 与 `keys` **互斥**,同帧带两者 = 协议错(服务端回 `error: bad_frame`,**不回 input_ack**,
你的 pending 会挂到 10s 超时)。vendor 的 `client.keys(ref, key)` 一次只发一个键,够用。
keys **不追加 Enter** —— 「按一下那个键」。

**xterm 应答不上行（裁定 2026-08-23）**：`term.onData` 会混进仿真器对 OSC 11/10/12/4、DA、CPR、DSR、DCS 的自动应答。那些字节不是用户按键。共享入口 `consumeTerminalReplies`（`NativeInputPump.onData` 与 `TerminalView` 的 `term.onData`）丢掉后再交给 `parseOnData`。方向键 `ESC [ A/B/C/D` 保留；CPR 是 `ESC [ … R`。应答不上行后远端查询超时、回落默认主题，与「不支持该查询的终端」一致，可接受。⛔ 不得把应答当 `input.text` 或把前导 ESC 当 `keys:esc`。

**input_ack 必达 + 超时**:
- 每个 `input()`/`keys()` 注册一个 **10s** 本地定时器(`inputTimeoutMs`)。
- 超时 → `onInputResult(reqId, false, 'timeout')`,pending 清除。**这不代表服务端没执行**,只代表不可判定;
  UI 文案用「未收到回执」而不是「发送失败」。
- 连接断开 → `clearPending('connection lost')`,所有在飞的 input 立刻以 `ok=false` 回调。
- 服务端 reason 闭集见 §6。

**copy-mode**:服务端在注入前会自动退出 tmux copy-mode,并主动推 `pane_mode_changed {ref, in_copy_mode:false}`。
桌面端 v1 可以只把它记进日志(不渲染指示器),但 **protocol.js 必须认识这个 type**,否则每次都刷 `unsupported_type`。

### 3.6 列表:listing / list_delta / seq 断档

- 进入应用 / 手动刷新 → `client.list()`。服务端 `handleList` **每次都真扫一遍 tmux**(不是读缓存)。
- 服务端**主动推** `list_delta`(无轮询)。四组字段两两不相交:
  `added_sessions` / `removed_refs` / `changed_sessions`(整体 replace)/ `changed_workspaces`(只带 cwd + session_count)。
- `seq` 单调递增。vendor `client.js` 已实现:`payload.seq !== lastSeq + 1`(含 delta 早于任何 listing 到达)
  → **自动重发 `list()` 并丢弃这条 delta**。⛔ 不要在 DeviceManager 里重复实现,会双倍 list。
- `client.workspaces` 在 `onFrame` 回调**之前**就已更新,所以 `onFrame('listing'|'list_delta')` 里直接读即可。

### 3.7 重连:指数退避 + 订阅重放

vendor `client.js` 已实现,DeviceManager 只需转发状态:

- 退避参数:`baseMs=1000, factor=2, maxMs=30000, jitter=0.3`(即 1s→2s→4s…封顶 30s,±30% 抖动)。
- READY 时自动:`list()` + 重放全部 `activeSubscriptions`(每个 ref 带原 rows/cols)+ 重放 overlay。
  **补丁后还要重放 level2**(§1.2.3)。
- 重连 = 重新 auth + 重新 subscribe = 重新 snapshot(整屏重放)。服务端不保存任何客户端状态,
  **不存在「消息丢了」**。TerminalPane 收到新 snapshot 自动 `reset()`,无需自己清屏。
- `auth_ack {ok:false}` → `_permanent=true` → **不重连**,进 STOPPED。UI 要提示「token 无效」并让用户改配置。
  服务端拒绝后立刻关连接,所以「auth 后立即断开」也当作拒绝处理。
- 重连期间 `subscribe()` 仍可调用(记账),`input()`/`scrollback()`/`resize()` 会失败返回 null/false。

---

## 4. 持久化 schema(localStorage)

`src/core/storage.js`。键前缀 `agentmirror.desktop.v1.`,单个 key 一个 JSON。

```jsonc
// agentmirror.desktop.v1.devices
[{ "id": "uuid", "name": "MacBook", "url": "ws://192.168.1.5:9900/ws", "token": "…" }]

// agentmirror.desktop.v1.checkedDevices
["uuid-a", "uuid-b"]

// agentmirror.desktop.v1.favorites   —— 收藏的是 Space
["uuid-a::/Users/me/proj/x"]

// agentmirror.desktop.v1.ui
{
  "sidebarCollapsed": false,
  "panes": ["uuid-a::/tmp/tmux-501/default%3"],   // 分裂列,uid 数组,顺序即列序
  "activePane": "uuid-a::…",
  "lastSpace": "uuid-a::/Users/me/proj/x"
}
```

读写规则:
- 每个 loader 都 `try/catch` 吞掉 `JSON.parse` 与 storage 异常,**返回稳定缺省值**(空数组 / 缺省对象),
  照抄 `preferences.js` 的容错姿势。坏数据不能白屏。
- schema 校验:`devices` 里 `id/name/url/token` 任一非字符串 → **整条丢弃**,不做部分修补。
- 版本前缀 `v1` 是未来迁移的钩子;不写迁移代码,不认识的键直接忽略。

### token 安全

- token **只**存在两个地方:localStorage 的 `devices` 条目、`Client` 实例的 `this.token`(只在 `auth` 帧上行一次)。
- ⛔ `console.log` / toast / 错误文案 / 状态栏 / 崩溃上报 **一律不得**出现 token。
  `DeviceManager.devices` getter **必须**返回剥掉 token 的投影(见 §2.2),UI 层永远拿不到它。
- 设备编辑表单里 token 输入框 `type="password"`;已保存的设备回填时显示占位符而非明文,留空 = 不修改。
- 服务端侧同样禁止回显/落日志(§9),`auth_ack` 里没有 token 字段。
- Tauri release 构建关掉 devtools。

---

## 5. mock daemon 规格(`scripts/mock-daemon.mjs`)

Node + `ws`(devDependency),给单测与本地冒烟用,**不依赖真 tmux**。
`node scripts/mock-daemon.mjs`,env:`PORT`(默认 9911)、`TOKEN`(默认 `mock-token`)、`DELTA_MS`(默认 800)。

### 5.1 行为

| 收到 | 回 |
|---|---|
| `auth` | `token` 匹配 → `auth_ack {ok:true}`;不匹配 → `auth_ack {ok:false, reason:"invalid token"}` **然后立刻 close** |
| 非 `auth` 且未认证 | `error {code:"unauthorized", reason:"not authenticated"}` |
| `list` | `listing {req_id, seq: ++seq, workspaces: FIXTURE}` |
| `subscribe {ref,rows,cols}` | ref 不在夹具 → `error {code:"session_not_found"}`;否则**立即**一帧 binary snapshot,随后每 `DELTA_MS` 一帧 binary delta |
| `unsubscribe {ref}` | 停该 ref 的 delta 定时器。幂等,无回复 |
| `input {req_id, ref, text?, keys?}` | 未订阅 → `input_ack {ok:false, reason:"not_subscribed"}`;否则 `input_ack {req_id, ok:true}`,并把回显内容当作一帧 delta 推出去 |
| `scrollback {req_id, ref, from_line, count}` | 一帧 binary kind=3,**故意 clamp**:`from_line=-100, line_count=50`(照 `scrollback.bin` 夹具),验证客户端用回复里的区间而不是请求值 |
| `resize {ref,rows,cols}` | 已订阅且 rows/cols 与上次不同 → 补发一帧 binary snapshot;相同 → **什么都不回**(复刻真 daemon 的 no-op 分支) |
| `level2_subscribe {workspace}` | 立刻一帧 `level2_frame {workspace, seq, sessions}`(带 `status`/`provider`/`title`);随后每 2s:变了推 frame,没变每 8s 推 `level2_heartbeat` |
| `level2_unsubscribe` | 停该连接的 level2 定时器 |
| 未知 type / 坏 JSON | `error {code:"unsupported_type"}` / `error {code:"bad_frame"}` |
| `v !== 1` | `error {code:"unsupported_version"}` 然后 close |

### 5.2 夹具数据(两 workspace / 三 session)

对齐 `testdata/listing.json` 的形状,但 **ref 用真实格式**(带 `\x1f`),以暴露 uid 拼接与转义 bug:

```js
const REFS = { a1: '/tmp/tmux-501/default%1',
               a2: '/tmp/tmux-501/default%2',
               b1: '/tmp/tmux-501/work%7' };

// listing:session 只带 ref/name/cwd/title:""/rows/cols —— ⛔ 不带 status,复刻 §0.1
workspaces = [
  { cwd: '/proj/a', session_count: 2, sessions: [
      { ref: REFS.a1, name: 'claude', cwd: '/proj/a', title: '', rows: 40, cols: 100 },
      { ref: REFS.a2, name: 'codex',  cwd: '/proj/a', title: '', rows: 24, cols: 80 } ]},
  { cwd: '/proj/b', session_count: 1, sessions: [
      { ref: REFS.b1, name: 'claude', cwd: '/proj/b', title: '', rows: 30, cols: 90 } ]},
];

// level2_frame:同样的 session,补上三个字段
// status ∈ working|idle|unknown;provider ∈ claude_code|codex|cursor|copilot|grok|pi
{ ref: REFS.a1, name:'claude', cwd:'/proj/a', title:'✳ Thinking…', status:'working', provider:'claude_code', rows:40, cols:100 }
```

可选:启动 30s 后推一条 `list_delta`(新增一个 session)以验证增量渲染;
再推一条 **seq 跳号**的 delta 以验证客户端自动 re-list(§3.6)。

### 5.3 二进制帧字节构造要点

```js
function encodeBinary(kind, ref, payload, meta) {          // meta 仅 kind=3
  const r = Buffer.from(ref, 'utf8');                       // ⚠️ 按 UTF-8 字节数,不是 .length
  if (r.length === 0 || r.length > 255) throw new Error('bad ref');
  const head = Buffer.from([0x52, 0x41, 0x01, kind, r.length]);   // 'R','A',version=1,kind,reflen
  const parts = [head, r];
  if (kind === 3) {
    const m = Buffer.alloc(12);
    m.writeUInt32BE(meta.reqId, 0);        // ≥1
    m.writeInt32BE(meta.fromLine, 4);      // 有符号!负值 = 屏上历史
    m.writeUInt32BE(meta.lineCount, 8);    // ≥1
    parts.push(m);
  }
  parts.push(Buffer.from(payload));        // 原始 ANSI 字节,⛔ 不 JSON 转义
  return Buffer.concat(parts);             // 总 payload ≤ 1 MiB
}
```

- `kind`:`1`=snapshot、`2`=delta、`3`=scrollback。
- `ws.send(Buffer)` 自动发 **binary** 帧;`ws.send(string)` 发 **text** 帧。别搞反 —— 客户端按消息类型分流。
- snapshot 尾部**要追加游标锚** `\x1b[${row};${col}H`(1 基),复刻真 daemon;并裁掉尾部空行。
  不加的话客户端跑得通,但测不出 §3.1 的残影路径。
- 三个夹具可直接当自检 golden:`snapshot.bin` / `delta.bin` / `scrollback.bin`(§1.4 已复制)。

---

## 6. 陷阱清单

1. **未知 JSON 字段必须忽略,未知 type 必须报错。** vendor `protocol.js` 用 `KNOWN_FIELDS` 白名单挑字段,
   未知 type 抛 `ProtocolError('unsupported_type')`。→ 所以**服务端新增的 type 必须先补进 FRAME_TYPES**(§1.1),
   否则整帧被吞 + 每次刷一条 `onLocalError`。这是最容易踩的一个。
2. **二进制帧 magic `RA` + version 字节 = 1**,先验 magic/version 再信任何字节。校验失败抛,不静默续读 —— 
   坏镜像流必须浮出来,不能污染终端网格。
3. **ref ≤ 255 字节**(UTF-8 字节数,不是字符数);`reflen=0` 非法。
4. **单帧 payload ≤ 1 MiB**(`MAX_BINARY_PAYLOAD = 1<<20`)。
5. **状态永不进二进制通道。** `status` 只在 `level2_frame`(控制帧)里。状态判不出**不影响**镜像与输入 —— 
   状态层挂了终端照样能用,不要把两者耦合成一个 loading 态。
6. **token 不回显、不落日志。** 见 §4。`auth` 帧是它唯一的上行出口。
7. **`input()` 不检查 `isReady`** —— 只检查 `ws.readyState===1`。AUTHENTICATING 期间发 input 会被服务端
   回 `error: unauthorized`(**没有 input_ack**),你的 pending 挂到 10s 超时。→ UI 必须自己先判 `dm.isReady()`。
8. **`error` 帧不带 req_id**,无法关联到具体请求。只能当全局告警渲染。
9. **`Client.connect()` 仅当 STOPPED 生效**,重复调静默 no-op;`disconnect()` 后要重连必须再调 `connect()`。
10. **`onConnectionIssue` 在自动重连的每次 close 都触发** —— 直接弹 toast 会刷屏。只更新设备行状态。
11. `input_ack.reason` 闭集:`session_not_found` / `not_subscribed` / `inject_failed` / `too_large` / `internal`,
    再加客户端本地的 `'timeout'` 与 `'connection lost'`。
12. `error.code` 闭集:`unauthorized` / `bad_frame` / `invalid_field` / `unsupported_version` / `unsupported_type` /
    `session_not_found` / `internal`。(`invalid_field` 文档漏了,实现有。)
13. **`subscribe` 对同一 ref 幂等**,重订 = 重放 snapshot + 重流。可以放心用它做「刷新这一列」。
14. **图片上传走 HTTP,不走 WS**:`POST /upload`(同端口),头 `Authorization: Bearer <token>`,
    回 `{"path":"/绝对/路径"}`;再把 path 作为 `input.attachment_path` 提交。桌面端 v1 不做,字段名先记在这。
15. **协议 v1 不支持远程创建 Agent**。「新建 Agent」对话框的创建按钮 → toast
    「当前 daemon 协议不支持远程创建 Agent」。没有对应帧类型,别去发明。
16. **不要跨仓引用上游路径**。夹具必须复制进本仓 `test/fixtures/protocol/`;
    `/Volumes/nvme/Projects/远程Agent安卓/` 只读,且不能成为本仓构建期依赖。
