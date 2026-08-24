# AgentMirror macOS 桌面端 · UI 实现规格书

本文件是**唯一 UI 事实来源**。实现者不需要再打开 `design-handoff/` 里的设计稿——所有像素、颜色、动画、SVG 路径、交互分支都在这里。

- 设计稿出处：`design-handoff/cross-platform-desktop-ui-mockups/project/Agent App Prototype.dc.html`（主）+ `Desktop Mockups.dc.html` 的 `#1c 窗口 chrome 规格`。
- 技术栈：Tauri v2 + Vite + React（JSX，**无 TypeScript**）+ `@xterm/xterm` 6。包管理 npm。
- 仅 macOS，仅亮色主题，界面文案中文。
- 协议：`/Volumes/nvme/Projects/远程Agent安卓/docs/protocol.md`（v1，只读参考）。

---

## 0. 术语与数据形状（所有组件共用）

协议 → 产品映射（已裁定，不要重新设计）：

| 产品概念 | 协议对应 | 说明 |
|---|---|---|
| Device | 一个 `agentmirrord` 连接（ws URL + token） | 多设备 = 多个 Client 实例并行 |
| Space | `workspace`（按 cwd 聚合） | 行名 = cwd basename |
| Agent | `session` | `ref` / `name` / `state` |

```js
/** @typedef {'working'|'blocked'|'done'|'idle'|'unknown'} AgentState */

/** @typedef {Object} Device
 *  @property {string}  id        本地生成的稳定 id（uid()）
 *  @property {string}  name      用户填的显示名，如 "Mac Studio @ Home"
 *  @property {string}  url       ws:// 或 wss:// 地址
 *  @property {string}  token     配对 token（⛔ 永不明文上屏、永不进日志）
 *  @property {string}  sub       副标题，形如 "10.10.10.87:9900 · WebSocket"（由 url 推导）
 *  @property {boolean} online    Client 当前是否 connected
 *  @property {boolean} checked   是否勾选（参与聚合）
 */

/** @typedef {Object} Space
 *  @property {string}     key        `${deviceId}::${cwd}`  ← 列表 key、右键菜单目标
 *  @property {string}     deviceId
 *  @property {string}     deviceName
 *  @property {string}     cwd
 *  @property {string}     name       cwd basename；同名冲突时为 "parent/base"（见 §5.2 消歧）
 *  @property {number}     count      session_count
 *  @property {AgentState} state      aggregate_state（服务端已算好，客户端只渲染）
 */

/** @typedef {Object} Agent
 *  @property {string}     key        `${deviceId}::${ref}`
 *  @property {string}     ref        协议 ref（寻址 subscribe/input/resize）
 *  @property {string}     deviceId
 *  @property {string}     deviceName
 *  @property {string}     spaceKey
 *  @property {string}     spaceName
 *  @property {string}     title      = session.name 原样
 *  @property {string|null} provider  inferProvider(session.name) 结果，认不出为 null
 *  @property {AgentState} state
 *  @property {boolean}    fav        本地收藏
 */
```

**收藏 key 必须稳定**：daemon 重启后 `ref` 会变，所以 fav 存 `${deviceId}::${cwd}::${session.name}`，不存 ref。

---

## 1. 设计 token（`src/styles/tokens.css`）

全部写进 `:root`。**组件里一律引用变量名，禁止裸 hex / 裸 px（尺寸类 px 除外，见下）。**
共 **138 个 token**：中性色阶 12 · 表面/文字/图标 21 · 强调色 26 · 叠加与边框 17 · 玻璃与阴影 13 · 圆角 11 · 字体字号 11 · 间距 14 · 动画 13。

### 1.1 中性色阶（raw ramp，仅供语义 token 引用）

```css
--ink-900:#201e1d;  --ink-800:#3a3835;  --ink-700:#5d5a54;  --ink-600:#6d6a63;
--ink-500:#7a766e;  --ink-400:#8a867e;  --ink-300:#9a968e;  --ink-250:#a09c93;
--ink-200:#a8a49b;  --ink-150:#b0aca3;  --ink-100:#b8b4ab;  --ink-060:#c4c0b7;
```

### 1.2 表面 / 文字 / 图标

```css
--bg:#fbfaf8;                 /* 窗口主体、main、终端背景 */
--sidebar-bg:#ebe8e3;
--titlebar-top:#eeebe6;
--titlebar-bottom:#e9e6e1;
--titlebar-grad:linear-gradient(180deg,var(--titlebar-top),var(--titlebar-bottom));
--bar-bg:#f7f5f1;             /* 次级工具条表面 */
--surface-sunken:#f0ede8;     /* 空态 44×44 图标盒 */
--field-bg:#ffffff;           /* input / textarea */

--text:var(--ink-800);        /* 正文、菜单项 */
--text-secondary:var(--ink-600);
--text-muted:var(--ink-400);  /* 次要说明、meta */
--text-faint:var(--ink-150);  /* 空态文案 / 禁用项 #b0aca3 */
--text-hover:var(--ink-700);  /* 次要文字 hover 后加深 */
--label:var(--ink-300);       /* 弹层分组小标题 */

--icon:var(--ink-400);        /* 默认描边 */
--icon-strong:var(--ink-700);
--icon-titlebar:var(--ink-500);
--icon-placeholder:var(--ink-250);
--icon-idle:var(--ink-200);   /* 认不出的 provider 空闲态描边 */
--dot-hollow:var(--ink-100);  /* 空心状态点边框 */
--checkbox-border:var(--ink-060);
```

### 1.3 强调色

```css
--green:#34c759;              /* working 状态点 */
--green-ring:rgba(52,199,89,.55);
--green-deep:#3f7a4c;         /* done 对勾、分裂徽章文字 */
--green-badge-bg:#e5efe2;     /* 分裂徽章底 */
--amber:#f0b429;              /* 收藏星、blocked 状态点 */
--amber-ring:rgba(240,180,41,.55);
--amber-deep:#b08a1e;         /* 「取消收藏」菜单项文字 */
--danger:#c42b1c;             /* 「关闭」菜单项、表单错误 */
--brand:#d97757;              /* Claude 橙：Bypass 开关开启态、claude 兜底描边 */
--warn-text:#a4542e;          /* "Bypass permissions" 标题 */
--gold:#8a713d;               /* 链接、远端设备徽章文字 */
--gold-hover:#6d5930;
--input-focus:#b8a273;
--input-focus-ring:rgba(184,162,115,.25);

--badge-local-bg:#e9e6e0;   --badge-local-fg:var(--ink-600);
--badge-remote-bg:#f1e8d8;  --badge-remote-fg:var(--gold);

/* provider 兜底首字母圆圈的色调（仅 ProviderIcon fallback 用） */
--tint-claude:#d97757; --tint-grok:#3a3835;  --tint-codex:#6d6a63;
--tint-opencode:#7a8a6e; --tint-cursor:#6d6a63; --tint-zai:#6b83b5;
--tint-kimi:#8a713d;   --tint-default:#6d6a63;
```

### 1.4 叠加层 / 边框

```css
--hover-1:rgba(0,0,0,.04);    /* 侧栏底部 Devices 条 */
--hover-2:rgba(0,0,0,.05);    /* 分组标题、弹层行、厂家格子 */
--hover-3:rgba(0,0,0,.055);   /* 侧栏 Search 行（v1 不用） */
--hover-4:rgba(0,0,0,.06);    /* 图标按钮、次要按钮 */
--hover-5:rgba(0,0,0,.07);    /* Space/Agent 行、菜单项 */
--active-1:rgba(0,0,0,.11);   /* 菜单项 :active、快捷键 chip :active */
--sel-bg:rgba(0,0,0,.07);     /* 选中行底色（与 hover-5 同值，语义不同） */
--fill-subtle:rgba(0,0,0,.04);/* Bypass 行底 */
--toggle-off:rgba(0,0,0,.15);

--border-hairline:rgba(0,0,0,.06);
--border:rgba(0,0,0,.07);
--border-strong:rgba(0,0,0,.08);
--border-input:rgba(0,0,0,.12);
--ring-hairline:inset 0 0 0 0.5px rgba(0,0,0,.06);   /* 设备徽章 */
--ring-tile:0 0 0 0.5px rgba(0,0,0,.08);              /* 厂家格子未选中 */
--ring-tile-sel:0 0 0 1.5px var(--ink-800);           /* 厂家格子选中 */
--ring-chip:inset 0 0 0 1px rgba(0,0,0,.1);           /* 快捷键 chip */
```

### 1.5 玻璃层 / 阴影

```css
--glass-menu:rgba(250,249,246,.78);
--glass-popover:rgba(252,251,249,.85);
--glass-dialog:rgba(252,251,249,.92);
--blur-menu:blur(24px) saturate(1.6);
--blur-popover:blur(26px) saturate(1.6);
--blur-dialog:blur(30px) saturate(1.5);
--scrim:rgba(40,35,25,.28);
--scrim-blur:blur(3px);

--shadow-menu:0 0 0 0.5px rgba(0,0,0,.16),inset 0 0 0 0.5px rgba(255,255,255,.5),0 16px 44px rgba(0,0,0,.2),0 2px 8px rgba(0,0,0,.08);
--shadow-popover:0 0 0 0.5px rgba(0,0,0,.16),inset 0 0 0 0.5px rgba(255,255,255,.5),0 16px 44px rgba(0,0,0,.22),0 2px 8px rgba(0,0,0,.08);
--shadow-dialog:0 0 0 0.5px rgba(0,0,0,.18),inset 0 0 0 0.5px rgba(255,255,255,.55),0 24px 70px rgba(0,0,0,.3);
--shadow-knob:0 1px 3px rgba(0,0,0,.25);
--titlebar-inset:inset 0 1px 0 rgba(255,255,255,.55);
```

⛔ **不要**移植设计稿里外层 1400px 卡片的 `border-radius:12px` + 四层投影 + body 的 `radial-gradient` 背景——那是画布演示，真实窗口由 macOS 画圆角和阴影。

### 1.6 圆角

```css
--r-4:4px;   /* 复选框 */      --r-5:5px;   /* 分组标题按钮 */
--r-6:6px;   /* 图标按钮、chip */ --r-7:7px;  /* 列表行、菜单项 */
--r-8:8px;   /* 输入框、按钮、弹层行 */
--r-9:9px;   /* Agent 行、厂家格子、Bypass 行 */
--r-10:10px; /* Toast */       --r-11:11px; /* 右键菜单 */
--r-12:12px; /* Devices 弹层、空态图标盒 */
--r-14:14px; /* 对话框 */      --r-pill:99px;
```

### 1.7 字体与字号

```css
--font-ui:-apple-system,'SF Pro Text','PingFang SC','Segoe UI',sans-serif;
--font-mono:ui-monospace,'SF Mono',Menlo,monospace;

--fs-10:10px;    /* 设备徽章 */
--fs-105:10.5px; /* 分裂徽章、弹层分组标题、厂家名 */
--fs-11:11px;    /* Agent 第二行 meta、弹层副标题、chip */
--fs-115:11.5px; /* 表单 label、空态副行 */
--fs-12:12px;    /* 分组标题、空态主行 */
--fs-125:12.5px; /* 标题栏品牌名、Bypass 标题、Toast、pane 头 */
--fs-13:13px;    /* 主要正文、菜单项、按钮、输入框 */
--fs-135:13.5px; /* 侧栏 Search / Space 行 */
--fs-15:15px;    /* 对话框标题 */
/* 字重：400 常规 / 500 徽章 / 600 强调（绝大多数）/ 700 对话框标题、兜底首字母 */
```

### 1.8 间距（本设计的实际取值集合）

```css
--sp-1:2px;  --sp-2:3px;  --sp-3:4px;  --sp-4:6px;  --sp-5:7px;  --sp-6:8px;
--sp-7:10px; --sp-8:11px; --sp-9:12px; --sp-10:14px; --sp-11:16px; --sp-12:18px;
--sp-13:20px; --sp-14:28px;
```

### 1.9 动画（`src/styles/tokens.css` 尾部，全局 keyframes）

```css
--ease:cubic-bezier(.2,.8,.2,1);   /* 全站唯一自定义缓动 */
--d-fast:.12s;    /* 平台按钮/caption 背景（已删，保留供 chip 用） */
--d-menu:.13s;    /* 右键菜单入场 */
--d-pop:.14s;     /* Devices 弹层入场 */
--d-hover:.15s;   /* 背景色过渡、scrim 入场(.15s) */
--d-dialog:.16s;  /* 对话框入场 */
--d-row:.18s;     /* Agent 行 opacity/transform */
--d-close:190;    /* ms，JS setTimeout：关闭动画后再卸载 */
--d-toggle:.2s;   /* 开关、rowIn */
--d-chevron:.22s; /* chevron 旋转、Agent 行 rowIn */
--d-sidebar:.28s; /* 侧栏宽度、paneIn */
--d-icon:.3s;     /* provider 图标 opacity */
--d-reorder:.38s; /* Agent 行 top 重排 */
```

```css
@keyframes menuIn { from { opacity:0; transform:scale(.96) translateY(-4px) } }
@keyframes paneIn { from { opacity:0; transform:translateX(28px) } }
@keyframes rowIn  { from { opacity:0; transform:translateY(5px) } }
@keyframes pulse {
  0%   { box-shadow:0 0 0 0 var(--green-ring) }
  70%  { box-shadow:0 0 0 5px rgba(52,199,89,0) }
  100% { box-shadow:0 0 0 0 rgba(52,199,89,0) }
}
@keyframes pulseAmber {
  0%   { box-shadow:0 0 0 0 var(--amber-ring) }
  70%  { box-shadow:0 0 0 5px rgba(240,180,41,0) }
  100% { box-shadow:0 0 0 0 rgba(240,180,41,0) }
}
```
pulse 用法固定为 `pulse 1.8s ease-out infinite`（amber 同）。

全局补充（`src/styles/app.css` 顶部）：
```css
::-webkit-scrollbar{width:0;height:0} *{scrollbar-width:none}   /* 全站隐藏滚动条 */
html,body,#root{height:100%;margin:0;overflow:hidden}
body{background:var(--bg);color:var(--text);font-family:var(--font-ui);
     -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
@media (prefers-reduced-motion:reduce){
  *,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;
                       transition-duration:.01ms!important}
}
```

---

## 2. 窗口 chrome（macOS，来自 Desktop Mockups `#1c`）

- 标题栏高 **38px**。（2026-08-22 用户裁定：顶部去界化，标题条收窄。原 46px 作废。）
- **悬浮胶囊 chrome**（裁定 2026-08-22，用户确认 `mockup.html`）：系统 traffic lights **隐藏但仍保留 NSWindow 标准按钮**（⛔ 不许 `decorations: false`），自绘运动场形胶囊（`border-radius:999px`）。顺序：红关 / 黄最小化 / 绿切换全屏 / 分隔线 / 展开侧栏。**默认不可见**，鼠标进入左上热区（窗口 `top:0`；全屏 `top:62px` = 主屏菜单 30pt + overlay 32px，落在系统顶栏之下）才浮现；从热区移到胶囊不中断；移开 **160ms** 后隐藏。红钮 = **真关闭**（`window.close()`，进程退出，Dock 不留残留）。⛔ 不许 `prevent_close` + `hide()`。Cmd+W 关窗、Cmd+Q 退出。Cmd+B 本地折叠，⛔ 不进 CLI。
- `tauri.conf.json` 仍为 Overlay（藏灯在 Rust `setHidden`，不改 decorations）：
  ```json
  { "titleBarStyle": "Overlay", "hiddenTitle": true, "trafficLightPosition": { "x": 14, "y": 13 } }
  ```
- **标题条只占左侧栏宽度**（2026-08-22 用户裁定：不通栏；右侧终端从窗口内容区顶边开始，上方无条、无线）。拖拽区只在这条上。⛔ 不要把 drag-region 铺到终端上。标题条不再为系统灯留 93px。
- **侧栏折叠**：`.app-left` 宽 **0**，无常驻窄列。展开钮只在胶囊里。折叠后终端顶到内容区顶边（系统灯已隐藏，不再 `padding-top:38px`）。
- **Cmd+B**：本地切换侧栏折叠/展开（任何窗口状态）。⛔ 不发给远端 CLI。
- 侧栏是独立一列 `height:100%; display:flex; flex-direction:column`；Agent 列表 `flex:1; min-height:0; overflow:auto`；All Devices 条是列的最后一个子元素，钉在窗口底部（不要 absolute）。
- 关闭 = 销毁窗口并退出进程（红钮 / Cmd+W 走 `close()`）。⛔ 不许 hide 后 Dock 残留。Quit = Cmd+Q。

---

## 3. 文件规划

```
src/
  main.jsx                      入口，挂载 <App/>
  App.jsx                       全局状态 + 组合所有组件
  styles/tokens.css             §1 全部 token + keyframes
  styles/app.css                全局 reset、滚动条、reduced-motion、xterm 覆盖
  components/
    ProviderIcon.jsx            §8
    chrome/TitleBar.jsx         §4.1
    chrome/DevicesPopover.jsx   §4.2
    chrome/AddDeviceDialog.jsx  §4.3
    chrome/NewAgentDialog.jsx   §4.4
    chrome/ContextMenu.jsx      §4.5
    chrome/Toast.jsx            §4.6
    sidebar/Sidebar.jsx         §5.1
    sidebar/SpacesList.jsx      §5.2
    sidebar/AgentsList.jsx      §5.3
    terminal/SplitPanes.jsx     §6.1
    terminal/TerminalPane.jsx   §6.2
  lib/
    provider.js                 inferProvider() + PROVIDER_LABEL
    providerIcons.js            slug → 本地 svg URL 映射（Vite 打包，不走 CDN）
    icons.jsx                   §9 全部内联 SVG 组件
    store.js                    localStorage 读写（见 §7.4）
    aggregate.js                多设备 listing → Space[]/Agent[] 聚合与去重
  assets/provider/*.svg         vendor 自 @lobehub/icons-static-svg
```

组件签名一律 JSDoc 注释 + 解构 props，无 TypeScript。

---

## 4. chrome 组件

### 4.1 `chrome/TitleBar.jsx`

```js
/**
 * @param {boolean} sidebarCollapsed
 * @param {() => void} onToggleSidebar
 */
```
内部状态：无（纯展示）。标题条只占左侧栏宽度，不横切终端。（2026-08-22 用户裁定：顶部去界化，标题条收窄。）

| 部件 | 规格 |
|---|---|
| 根 | `height:38px; flex:none; display:flex; align-items:center; gap:12px; padding:0 10px; background:var(--titlebar-grad); border-bottom:1px solid var(--border-strong); box-shadow:var(--titlebar-inset)`，带 `data-tauri-drag-region`。只排在侧栏列顶，不延伸到主区。折叠/窗口钮改在悬浮胶囊。 |
| 侧栏开关 | 排在**左侧条最右端**。`28×26px; border-radius:var(--r-6); display:flex;center; cursor:pointer; color:var(--icon-titlebar)`；hover `background:var(--hover-4)`；`title="折叠/展开侧栏"`；图标 `<SidebarIcon size={16}/>` stroke 1.8 |
| 品牌名 | **不渲染**（2026-08-22 用户裁定：不要展示产品名）。 |
| 分裂徽章 | **不渲染**（去界化后不再占用标题条）。 |
| 拖动区 | 左侧条剩余宽度 `<div class="tb-drag" data-tauri-drag-region/>`。**不要**把 drag-region 铺到终端上（否则无法选文本）。 |

### 4.2 `chrome/DevicesPopover.jsx`

```js
/**
 * @param {Device[]} devices
 * @param {(id:string, next:boolean) => void} onToggle       单设备勾选
 * @param {(next:boolean) => void} onToggleAll               All Devices 全选/全不选
 * @param {() => void} onAddDevice                           打开 AddDeviceDialog
 * @param {() => void} onClose
 */
```
内部状态：无。

- **遮罩**：`position:fixed; inset:0; z-index:30`；`onClick` 与 `onContextMenu` 都调 `onClose`（右键也关，且 `preventDefault`）。
- **弹层**：`position:absolute; left:10px; bottom:54px; z-index:31; width:300px; background:var(--glass-popover); backdrop-filter:var(--blur-popover)`（同时写 `-webkit-backdrop-filter`）；`border-radius:var(--r-12); box-shadow:var(--shadow-popover); padding:6px; animation:menuIn var(--d-pop) ease-out`。定位基准 = App 根元素 `position:relative`。
- **分组标题**：`Devices`，`font-size:var(--fs-105); font-weight:600; letter-spacing:.05em; text-transform:uppercase; color:var(--label); padding:8px 12px 6px`。
- **行**（All 行 + 每设备一行）：`display:flex; align-items:center; gap:10px; padding:8px 12px; border-radius:var(--r-8); cursor:pointer; transition:background-color var(--d-hover)`；hover `background-color:var(--hover-2)`。
  - 左图标 16px stroke `var(--icon-strong)` 1.8：All 行 = `<LayersIcon/>`，设备行 = `<MonitorIcon/>`。
  - 中间：`flex:1;min-width:0`。第一行 `font-size:var(--fs-13); font-weight:600; display:flex; gap:6px` = 名字 + 在线点（All 行**不显示**点）；在线点 `6px` 圆，在线 `background:var(--green)`，离线 `background:transparent;border:1.5px solid var(--dot-hollow)`。第二行 `font-size:var(--fs-11); color:var(--text-muted)` 省略号。
  - 右勾选：选中 = `<CheckIcon size={15} stroke=var(--text) strokeWidth=2.2/>`；未选 = `<span style="width:14px;height:14px;border-radius:var(--r-4);border:1.5px solid var(--checkbox-border);box-sizing:border-box">`。
  - All 行 `sub` = `` `${devices.length} devices · ${onlineCount} connected` ``；`on = devices.every(d => d.checked)`。
- **Add Device… 行**：`border-top:1px solid var(--border); margin-top:4px; padding:8px 12px; display:flex; gap:10px; font-size:var(--fs-13); color:var(--text-secondary); cursor:pointer; border-radius:0 0 var(--r-8) var(--r-8)`；hover `var(--hover-2)`；`<PlusIcon size={14}/>`。

### 4.3 `chrome/AddDeviceDialog.jsx`

```js
/**
 * @param {boolean} open
 * @param {(d:{name:string,url:string,token:string}) => void} onSubmit
 * @param {() => void} onCancel
 */
```
内部状态：`name`、`url`、`token`、`error`。

复用 §4.4 的对话框外壳（scrim + 420px 卡片，规格见下）。内容：

- 标题 `添加设备`（`--fs-15`/700），副标题 `填写 agentmirrord 打印的地址与配对 Token`（`--fs-12`/`--text-muted`，`margin-bottom:14px`）。
- 三组「label + input」，label `font-size:var(--fs-115); font-weight:600; color:var(--text-muted); margin-bottom:6px`。
  1. `显示名称（可选）` — placeholder `Mac Studio @ Home`
  2. `WebSocket 地址` — placeholder `ws://192.168.31.116:9900/ws`，`spellcheck=false`，`autoFocus`
  3. `配对 Token` — **`type="password"`**（🔴 token 不上屏明文，不进日志、不进错误文案）
- **输入框统一样式**：`width:100%; box-sizing:border-box; font-size:var(--fs-13); font-family:inherit; padding:8px 10px; border:1px solid var(--border-input); border-radius:var(--r-8); background:var(--field-bg); outline:none; color:var(--text); margin-bottom:14px`；`:focus` → `border-color:var(--input-focus); box-shadow:0 0 0 3px var(--input-focus-ring)`。
- **校验**（提交时）：`url` 必须以 `ws://` 或 `wss://` 开头，否则 `error='地址必须以 ws:// 或 wss:// 开头'`；`url` 为空同样报错。错误文案 `font-size:var(--fs-115); color:var(--danger); margin:-8px 0 12px`。
- 按钮行 `display:flex; justify-content:flex-end; gap:8px`：`取消`（次要按钮）/ `添加`（主按钮）。样式见 §4.4。
- `Esc` 关闭，`Enter`（在任意 input 内）= 提交。

### 4.4 `chrome/NewAgentDialog.jsx`

```js
/**
 * @param {boolean} open
 * @param {string}  spaceName                     目标 Space 显示名
 * @param {(v:{name:string,provider:string,bypass:boolean}) => void} onCreate
 * @param {() => void} onCancel
 */
```
内部状态：`name:''`、`provider:'claude-code'`、`bypass:false`（每次 open 重置）。

- **scrim**：`position:fixed; inset:0; z-index:50; background:var(--scrim); backdrop-filter:var(--scrim-blur); animation:menuIn var(--d-hover) ease-out`；点击 = `onCancel`。
- **卡片**：`position:fixed; left:50%; top:50%; transform:translate(-50%,-50%); z-index:51; width:420px; background:var(--glass-dialog); backdrop-filter:var(--blur-dialog); border-radius:var(--r-14); box-shadow:var(--shadow-dialog); padding:20px; animation:menuIn var(--d-dialog) var(--ease)`。
- 标题 `新建 Agent`（`--fs-15`/700/`margin-bottom:2px`）；副标题 `在「{spaceName}」中创建`（`--fs-12`/`--text-muted`/`margin-bottom:14px`）。
- 名称输入框：placeholder `任务名称（可留空）`，`autoFocus`，样式同 §4.3 输入框。
- 小标题 `选择厂家`：`font-size:var(--fs-115); font-weight:600; color:var(--text-muted); margin-bottom:8px`。
- **厂家网格**：`display:grid; grid-template-columns:repeat(4,1fr); gap:8px; margin-bottom:14px`。7 项（4+3 两行）：
  `claude-code/Claude Code`、`codex/Codex`、`grok/Grok`、`opencode/OpenCode`、`cursor/Cursor`、`zai/Z Code`、`kimi/Kimi Code`。
  格子：`display:flex; flex-direction:column; align-items:center; gap:6px; padding:10px 4px 8px; border-radius:var(--r-9); cursor:pointer; transition:background var(--d-hover),box-shadow var(--d-hover)`；未选 `background:transparent; box-shadow:var(--ring-tile)`；选中 `background:var(--hover-4); box-shadow:var(--ring-tile-sel)`；hover `background:var(--hover-2)`。图标 `<ProviderIcon size={20} active/>`，名字 `font-size:var(--fs-105); color:var(--icon-strong); white-space:nowrap`。
- **Bypass 行**：`display:flex; align-items:center; gap:10px; padding:10px 12px; border-radius:var(--r-9); background:var(--fill-subtle); margin-bottom:16px`。
  - 左文：`Bypass permissions`（`--fs-125`/600/`var(--warn-text)`）+ `允许 Agent 不经确认执行 shell 命令`（`--fs-11`/`--text-muted`/`margin-top:1px`）。
  - 开关：`38×23px; border-radius:var(--r-pill); position:relative; cursor:pointer; flex:none; transition:background var(--d-toggle)`；关 `background:var(--toggle-off)`，开 `background:var(--brand)`。旋钮 `position:absolute; top:2px; left:2px→17px; width:19px; height:19px; border-radius:50%; background:#fff; box-shadow:var(--shadow-knob); transition:left var(--d-toggle) var(--ease)`。
- **按钮行**：`display:flex; justify-content:flex-end; gap:8px`。
  - 次要按钮：`padding:7px 14px; border-radius:var(--r-8); font-size:var(--fs-13); font-weight:600; color:var(--icon-strong); cursor:pointer`；hover `background:var(--hover-4)`。
  - 主按钮：`padding:7px 16px; border-radius:var(--r-8); font-size:var(--fs-13); font-weight:600; color:#fff; background:var(--ink-800); cursor:pointer`；hover `background:var(--ink-900)`；active `background:#000`。
- **「创建」行为（协议裁定）**：`onCreate` 由 App 实现为「关闭对话框 + `toast('当前 daemon 协议不支持远程创建 Agent')`」。协议 v1 无远程创建能力，**不要**发任何帧。

### 4.5 `chrome/ContextMenu.jsx`

```js
/**
 * @param {boolean} open
 * @param {number} x @param {number} y            已由 openMenu() 夹取过的视口坐标
 * @param {Array<{key:string,label:string,icon:JSX.Element,color:string,
 *                disabled?:boolean,separator?:boolean,onClick:()=>void}>} items
 * @param {() => void} onClose
 */
```
内部状态：无。

- 遮罩 `position:fixed; inset:0; z-index:40`，`onClick`/`onContextMenu` → `onClose`（右键 `preventDefault`）。
- 菜单体：`position:fixed; left:{x}px; top:{y}px; z-index:41; min-width:176px; background:var(--glass-menu); backdrop-filter:var(--blur-menu); border-radius:var(--r-11); box-shadow:var(--shadow-menu); padding:5px; animation:menuIn var(--d-menu) ease-out`。
- 菜单项：`display:flex; align-items:center; gap:9px; padding:6.5px 10px; border-radius:var(--r-7); font-size:var(--fs-13); cursor:pointer; color:{item.color}`；hover `background:var(--hover-5)`；active `background:var(--active-1)`。`separator:true` 的项额外加 `border-top:1px solid var(--border-strong); margin-top:4px`。
- `disabled:true` → `color:var(--text-faint)`，保留 hover 底色，点击只 `onClose()`（与原型一致：置灰项点了就关菜单）。
- **坐标夹取**（App 里的 `openMenu(e, kind, id)`）：
  ```js
  e.preventDefault(); e.stopPropagation();
  const MW = 180, MH = 130;
  const x = Math.min(e.clientX, window.innerWidth  - MW - 8);
  const y = Math.min(e.clientY, window.innerHeight - MH - 8);
  setMenu({ kind, id, x, y });
  ```

### 4.6 `chrome/Toast.jsx`

```js
/** @param {string|null} message  非空即显示；@param {() => void} onDone */
```
内部状态：定时器。`message` 变化 → 重置 2600ms 定时器 → `onDone()`。**单条，不排队**（新消息覆盖旧的）。

`position:fixed; left:50%; bottom:22px; transform:translateX(-50%); z-index:60; max-width:420px; padding:9px 14px; border-radius:var(--r-10); background:rgba(58,56,53,.92); backdrop-filter:blur(12px); color:#fff; font-size:var(--fs-125); box-shadow:var(--shadow-menu); pointer-events:none; animation:rowIn var(--d-toggle) ease-out`。

---

## 5. 侧栏

### 5.1 `sidebar/Sidebar.jsx`

```js
/**
 * @param {boolean} collapsed
 * @param {boolean} spacesOpen @param {() => void} onToggleSpaces
 * @param {boolean} agentsOpen @param {() => void} onToggleAgents
 * @param {string}  selected                      'all' | 'fav' | Space.key
 * @param {(key:string) => void} onSelect
 * @param {Space[]} spaces
 * @param {Agent[]} agents                        已按 selected 过滤后的可见集合
 * @param {string[]} openKeys                     当前在分裂列里的 Agent.key
 * @param {(e:MouseEvent, spaceKey:string) => void} onSpaceMenu
 * @param {(e:MouseEvent, agentKey:string) => void} onAgentMenu
 * @param {(key:string) => void} onOpenAgent
 * @param {string} deviceLabel                    §7.2 规则算好的底部文案
 * @param {boolean} anyDeviceOnline
 * @param {() => void} onToggleDevices
 * @param {boolean} multiDevice                   勾选设备 > 1（决定是否显示徽章）
 */
```
内部状态：无（全部提到 App）。

- `<aside>`：`width:{collapsed?0:280}px; flex:none; overflow:hidden; background:var(--sidebar-bg); border-right:1px solid var(--border); display:flex; flex-direction:column; transition:width var(--d-sidebar) var(--ease)`。
- **内层固定 280px**：`<div style="width:280px;flex:1;display:flex;flex-direction:column;min-height:0">` —— 折叠时内容不重排，只被裁掉。
- **Search 占位行**（v1 无功能）：`display:flex; align-items:center; gap:10px; margin:10px 10px 2px; padding:6px 10px; border-radius:var(--r-7); font-size:var(--fs-135); cursor:default`（**不加 hover 态**，避免暗示可点）+ `<SearchIcon size={15} stroke="var(--icon-titlebar)"/>` + 文字 `Search`。
- **Spaces 分组头**：`display:flex; align-items:center; justify-content:space-between; padding:12px 20px 4px`。左侧可点 span：`display:inline-flex; align-items:center; gap:4px; font-size:var(--fs-12); font-weight:600; color:var(--text-muted); cursor:pointer; border-radius:var(--r-5); padding:2px 6px; margin-left:-6px`；hover `background:var(--hover-2); color:var(--icon-strong)`。chevron：`<ChevronDown size={11} strokeWidth={2.2}/>`，`transform:rotate({spacesOpen?0:-90}deg); transition:transform var(--d-chevron) var(--ease)`。**右侧「新建文件夹」按钮删除**（见 §10）。
- `spacesOpen` 为真时渲染 `<SpacesList/>`。
- **Agents 分组头**：`padding:14px 20px 4px; display:flex; align-items:center; min-width:0`。文案：`selected==='all'` → `Agents`；`'fav'` → `收藏的 Agents`；否则 `` `${spaceName} 的 Agents` ``。文字 span 需 `white-space:nowrap;overflow:hidden;text-overflow:ellipsis`，chevron `flex:none`，其余同 Spaces 头。
- `agentsOpen` 为真时渲染 `<AgentsList/>`。
- **弹性占位**：`<div style={{flex: agentsOpen ? '0 1 0px' : '1 1 0px'}}/>` —— Agents 收起时把底部 Devices 条推到底。
- **Devices 底条**：`border-top:1px solid var(--border-strong); display:flex; align-items:center; gap:8px; padding:11px 16px; font-size:var(--fs-13); font-weight:600; flex:none; cursor:pointer; transition:background var(--d-hover)`；hover `background:var(--hover-1)`；点击 = `onToggleDevices`。内容：`<LayersIcon size={15} stroke="var(--icon-strong)"/>` + label（省略号）+ 状态点 `7px` 圆（`anyDeviceOnline` → `var(--green)`，否则 `border:1.5px solid var(--dot-hollow);background:transparent`）+ `<GearIcon size={15} stroke="var(--icon)"/>`（`margin-left:auto`）。

### 5.2 `sidebar/SpacesList.jsx`

```js
/**
 * @param {Space[]} spaces
 * @param {number} allCount @param {number} favCount
 * @param {string} selected
 * @param {(key:string) => void} onSelect
 * @param {(e:MouseEvent, key:string) => void} onContextMenu
 * @param {boolean} multiDevice
 */
```
内部状态：无。

- 容器：`padding:0 10px; display:flex; flex-direction:column; overflow-y:auto; flex:none; max-height:clamp(96px, 100vh - 464px, 288px)`。
- **两个虚拟行置顶**（不可右键，`onContextMenu` 只 `preventDefault`）：
  1. `all` / `All Spaces` / `<GridIcon size={15} stroke="var(--icon-strong)"/>` / count = 可见 Agent 总数
  2. `fav` / `收藏` / `<StarIcon size={15} fill="var(--amber)"/>` / count = 收藏数
- **真实 Space 行**：图标 `<FolderIcon size={15} stroke="var(--icon)"/>`。
- 行样式：`display:flex; align-items:center; gap:10px; height:32px; flex:none; box-sizing:border-box; padding:0 10px; border-radius:var(--r-7); font-size:var(--fs-135); cursor:pointer; transition:background var(--d-hover); animation:rowIn var(--d-toggle) ease-out`；选中 `background:var(--sel-bg); font-weight:600`，未选 `background:transparent; font-weight:400`；hover `background:var(--hover-5)`。
- 名字 span：`overflow:hidden; text-overflow:ellipsis; white-space:nowrap`。
- 右侧（从右往左）：count `font-size:var(--fs-12); color:var(--text-muted); font-weight:400; flex:none`，其左依次是
  - **设备徽章**（仅 `multiDevice` 时渲染）：pill，`font-size:var(--fs-10); font-weight:500; padding:1px 6px; border-radius:var(--r-pill); margin-right:6px; box-shadow:var(--ring-hairline)`；本机 `background:var(--badge-local-bg); color:var(--badge-local-fg)`，远端 `background:var(--badge-remote-bg); color:var(--badge-remote-fg)`。
  - **聚合状态**（`state` 为 `working`/`blocked`/`done` 时才渲染，`idle`/`unknown` 不渲染，保持行干净）：`working`→6px 绿点 + `pulse`，`blocked`→6px 琥珀点 + `pulseAmber`，`done`→`<CheckIcon size={12} stroke="var(--green-deep)" strokeWidth={2.2}/>`；`margin-right:6px; flex:none`。
- **重名消歧**：先按 `basename(cwd)` 分组；某个 basename 出现 >1 次时，这组内所有行的 `name` 改为 `` `${basename(dirname(cwd))}/${basename(cwd)}` ``；若仍冲突，再往上追加一级路径。逻辑放 `lib/aggregate.js`，SpacesList 只渲染 `space.name`。

### 5.3 `sidebar/AgentsList.jsx`

```js
/**
 * @param {Agent[]} agents                  可见集合，顺序 = 稳定的原始顺序（勿排序）
 * @param {string[]} openKeys
 * @param {Object<string,boolean>} closing  key → 正在播关闭动画
 * @param {(key:string) => void} onOpen
 * @param {(e:MouseEvent, key:string) => void} onContextMenu
 * @param {boolean} multiDevice
 * @param {string} emptyHint                空态第二行文案
 */
```
内部状态：`vpH`（可视高度，初值 108）。

**行高 54px，绝对定位 + top 过渡，是这套列表的灵魂，不要改成普通流式布局。**

- **外层**（挂 `ref`，被 `ResizeObserver` 观测）：`padding:0 10px; flex:1; min-height:108px; overflow:hidden; box-sizing:border-box`。
- **量化视口**：
  ```js
  const h = Math.max(108, Math.floor(el.clientHeight / 54) * 54);
  ```
  只在变化时 `setVpH(h)`。中层 `<div style={{height:vpH, overflowY:'auto'}}>` —— 保证永远只露出整数行，不出现半行。
- **轨道**：`position:relative; height:{agents.length * 54}px`。
- **排序**：`sorted = [...agents].sort((a,b)=>(b.fav?1:0)-(a.fav?1:0))`（稳定排序，收藏置顶）。**DOM 顺序仍用 `agents` 原序**，只把 `top = sorted.indexOf(ag) * 54` 写进样式 —— 这样 React key 不动，重排走 `top` 过渡。
- **行样式**：
  ```
  position:absolute; left:0; right:0; top:{top}px; height:54px; box-sizing:border-box;
  border:2px solid transparent; background-clip:padding-box;
  display:flex; flex-direction:column; justify-content:center; padding:0 8px;
  border-radius:var(--r-9); cursor:pointer;
  background-color:{openKeys.includes(key) ? var(--sel-bg) : transparent};
  opacity:{closing?0:1}; transform:scale({closing?0.94:1});
  transition:background-color var(--d-hover),opacity var(--d-row),transform var(--d-row),top var(--d-reorder) var(--ease);
  animation:rowIn var(--d-chevron) ease-out;
  ```
  hover `background-color:var(--hover-5)`。
- **第一行**：`display:flex; align-items:center; gap:8px; font-size:var(--fs-13); font-weight:600; min-width:0`
  - `<ProviderIcon provider={provider} size={18} active={state==='working'||state==='blocked'}/>`
  - title span（省略号）
  - 尾部容器 `margin-left:auto; display:inline-flex; align-items:center; gap:5px; flex:none`：`state==='done'` → `<CheckIcon size={12} stroke="var(--green-deep)" strokeWidth={2.4}/>`；`fav` → `<StarIcon size={12} fill="var(--amber)"/>`。两者可同时出现（对勾在左，星在右）。
- **第二行**：`display:flex; align-items:center; gap:6px; font-size:var(--fs-11); color:var(--text-muted); margin-top:3px`
  - **状态点** `8px` 圆，`border-radius:var(--r-pill); flex:none`：
    | state | 样式 | title |
    |---|---|---|
    | working | `background:var(--green); animation:pulse 1.8s ease-out infinite` | 运行中 |
    | blocked | `background:var(--amber); animation:pulseAmber 1.8s ease-out infinite` | 等待确认 |
    | done | `background:var(--green-deep)`（实心，无动画） | 已完成 |
    | idle | `background:transparent; border:1.5px solid var(--dot-hollow)` | 空闲 |
    | unknown | `background:transparent; border:1.5px solid var(--ink-060)` | 状态未知 |
  - meta 文本：`` `${PROVIDER_LABEL[provider] ?? title} · ${spaceName}` ``；若 `PROVIDER_LABEL[provider] === title`（重复）则只显示 `spaceName`。
  - **设备徽章**（仅 `multiDevice`）：`margin-left:auto; font-size:var(--fs-10); font-weight:500; padding:2px 8px; border-radius:var(--r-pill); flex:none; box-shadow:var(--ring-hairline)`；配色同 §5.2。
- **空态**（`agents.length === 0`，渲染在轨道之后）：`padding:18px 10px; font-size:var(--fs-12); color:var(--text-faint); text-align:center`，两行：`这个空间还没有 Agent` / `{emptyHint}`（默认 `在 Space 上右键 → 新建 Agent`）。

---

## 6. 主区（分裂列）

### 6.1 `terminal/SplitPanes.jsx`

```js
/**
 * @param {Agent[]} panes                       按左→右顺序
 * @param {(key:string) => void} onClosePane
 * @param {(e:MouseEvent, key:string) => void} onPaneMenu
 * @param {(agent:Agent) => JSX.Element} renderPane
 */
```
内部状态：无。

- 容器：`flex:1; display:flex; min-height:0`。
- **每列**：`flex:1; min-width:0; display:flex; flex-direction:column; border-left:1px solid var(--border); position:relative; animation:paneIn var(--d-sidebar) var(--ease)`；`:first-child { border-left:none }`（侧栏已有 border-right，避免双线——对设计稿的微调）。列宽严格 flex 均分，**不做拖拽调宽**。
- **关闭钮**：`position:absolute; top:8px; right:8px; width:24px; height:24px; border-radius:var(--r-6); display:flex;center; cursor:pointer; color:var(--text-faint); z-index:3; opacity:0; transition:opacity var(--d-hover)`；列 hover 或钮 `:focus-visible` → `opacity:1`；钮自身 hover → `background:var(--hover-4); color:var(--icon-strong)`；`title="关闭此列"`；`<XIcon size={12} strokeWidth={2}/>`。
- `onContextMenu` 挂在列根上 → `onPaneMenu(e, key)`。
- **空态**（`panes.length === 0`）：`flex:1; display:flex; align-items:center; justify-content:center`，文本居中 `font-size:var(--fs-13); color:var(--text-faint)`：第一行 `从左侧选择一个 Agent`，第二行 `<span style="font-size:var(--fs-115)">右键可分裂展示、收藏或关闭</span>`。

### 6.2 `terminal/TerminalPane.jsx`

```js
/**
 * @param {Agent} agent
 * @param {Object} client                        该设备的协议 Client 实例
 * @param {boolean} focused                      是否为键盘焦点列
 * @param {(rows:number, cols:number) => void} [onResize]
 */
```
内部状态：xterm 实例、FitAddon、订阅生命周期、`ready`（是否收到首帧 snapshot）。

- **列头**（设计稿把 `title/iconEl/statusEl` 算了但没渲染，这里补上——分裂列不标名字没法用）：
  `height:34px; flex:none; display:flex; align-items:center; gap:8px; padding:0 40px 0 12px; border-bottom:1px solid var(--border-hairline)`；
  `<ProviderIcon size={17}/>` + title（`--fs-125`/600/`var(--text-secondary)`/省略号）+ 8px 状态点（规格同 §5.3）+ 设备徽章（仅 `multiDevice`）。
- **终端区**：`flex:1; min-height:0; padding:8px 10px 0; background:var(--bg)`。
  xterm 选项：`fontFamily:'ui-monospace, SF Mono, Menlo, monospace'`、`fontSize:13`、`lineHeight:1.25`、`cursorBlink:false`、`scrollback:0`（历史走协议 `scrollback` 帧）、`convertEol:false`。snapshot 重放在写入 xterm 前仅为每个裸 LF 补一个隐含 CR，使 capture-pane 的行间换行回到第 0 列；delta 仍按原始字节追加，不做该转换、不裁行、不改宽度计算。
  `theme:{ background:'#fbfaf8', foreground:'#3a3835', cursor:'#3a3835', selectionBackground:'rgba(0,0,0,.12)' }`。
  尺寸变化 → `fit()` 目标 cols/rows **120ms 落定后再** `term.resize`（裁定 2026-08-23）。首帧立刻落到格子。
  **同宽不变量（裁定 2026-08-23）**：每一帧画进 xterm 的 snapshot，其捕获宽度必须等于当时网格宽度。①几何落定之后才 `subscribe`（点开瞬间的过渡宽度不下订）②本地网格变了就重发 `subscribe`（协议 `resize` 在主机几何未变时 no-op、不补快照）③旧快照在改宽前 `reset`，捕获宽度 ≠ 网格宽度的 snapshot/delta 不下笔。⛔ 不裁行、不改宽度计算。频繁切列时过渡宽度 ⛔ 不把旧 snapshot 本地 reflow。
- **未就绪占位**（`!ready`）：居中，`44×44px; border-radius:var(--r-12); background:var(--surface-sunken); border:1px solid var(--border-hairline); display:flex;center; margin:0 auto 12px` + `<TerminalIcon size={20} stroke="var(--icon-placeholder)"/>`；下方 `正在连接会话…`（`--fs-13`/600/`var(--text-muted)`）+ `订阅 {ref} · 等待首帧快照`（`--fs-115`/`var(--text-faint)`/`margin-top:3px`）。
- 挂载：网格落定后 `subscribe(ref, rows, cols)`；改宽重订；卸载 `unsubscribe(ref)`。断线重连由 Client 侧 `replaySubscriptions()` 负责。

**终端列回车与 `input_ack`（裁定 2026-08-22）**：xterm 把可打印段先 `input.text`，再发空 `input`（裸 Enter）。等上一段的 ack **必须有界**（5s，与本地发送 `pending` 超时一致）。超时返回 `{ok:false, reason:'ack_timeout'}`，toast「上一条未确认，回车未发出，再按一次强制发送」，**清掉 pending**，下一次回车立刻发出。设备状态变化（重连 / READY 迁移）清 `inputWaiters` / 早到 ack / `lastTextByUid`，在等的 waiter 以 `ack_cleared` 结掉。⛔ 不许无超时 `await` 把回车永久扣押。`ok:false` 仍不把失败旧缓冲再提交一次。

**xterm 应答不上行（裁定 2026-08-23）**：我方是被动镜像，⛔ 不许替远端终端回答 OSC/CSI 查询。xterm 自动生成的 OSC（含 4/10/11/12）、DA（`CSI … c`）、CPR（`CSI … R`）、DSR（`CSI … n`）、DCS 在 `NativeInputPump` / `TerminalView.onData` **丢掉，不发 `input.text` / `input.keys`**。方向键是 `CSI A/B/C/D`（终字节大写），与 CPR 的 `R`、DA 的 `c` 分开。远端拿不到颜色应答会回落到默认主题，可接受。⛔ 修前 OSC 11 应答会变成输入行垃圾并可能打出 `esc`。

**粘贴（裁定 2026-08-24，B 预贴修订）**：Cmd+V 始终是文本：DOM `paste` 只读 `text/plain`，即使剪贴板含图片也不上传、不发
`attachment_path`；图片-only 时提示「图片请用 Ctrl+V」。Ctrl+V 单独拦 keydown，图片字节经原生 `upload_http`
上传后只发 `attach_preview {ref,path}`，不发 `input.attachment_path`、`input.text` 或空 `input`，也不自动 Enter；图片留在远端 CLI 输入框，用户后续真实回车才提交。Ctrl+V 纯文本响亮提示无图片且不发帧。主区不再挂载底部图片条、图片加号或键位说明。原生 HTTP 不经过 WebView，故不放宽 loopback `connect-src`。

### 6.3 终端输入

终端列直接承接 xterm 的键盘输入和粘贴事件；主区不挂载额外的底部图片条。

---

## 7. 交互状态机（全部由 `App.jsx` 持有）

### 7.1 侧栏与分组折叠

| 动作 | 结果 |
|---|---|
| 点标题栏侧栏钮 | `collapsed = !collapsed`；`<aside>` width `280 ⇄ 0`，`transition:width .28s cubic-bezier(.2,.8,.2,1)` |
| 点 `Spaces` 头 | `spacesOpen` 取反；chevron `rotate(0 ⇄ -90deg)`，`.22s var(--ease)`；列表整体挂载/卸载（不是 height 动画） |
| 点 `Agents` 头 | `agentsOpen` 取反；同上；同时占位 div 的 flex 由 `0 1 0px` 变 `1 1 0px` |

三者各自持久化到 localStorage。

### 7.2 Devices 弹层

- 点侧栏底条 → `devicesOpen = !devicesOpen`。点遮罩 / 右键任意处 / 选择 `Add Device…` → 关闭。
- **勾选逻辑**：
  - `All Devices` 行：`on = devices.every(d => d.checked)`；点击 → 把**所有**设备的 `checked` 设为 `!on`（全选 ⇄ 全不选）。
  - 单设备行：只翻转自己。
- **底部 label 规则**（`deviceLabel`）：
  ```js
  const on = devices.filter(d => d.checked);
  if (on.length === devices.length && devices.length > 0) return 'All Devices';
  if (on.length === 0) return '未勾选设备';
  return on.map(d => d.name).join(' · ');
  ```
  设备列表为空时显示 `未添加设备`。
- 未勾选的设备，其 workspace / session **完全不进** Spaces/Agents 聚合（但 Client 连接不断开）。

### 7.3 右键菜单三种

**A. Space 行**（虚拟行 `all`/`fav` 不弹）
| 项 | 图标 | 颜色 | 行为 |
|---|---|---|---|
| 新建 Agent | plus | `var(--text)` | 关菜单 + 打开 `NewAgentDialog`（`spaceName` = 该行名） |

**B. Agent 行**
| 项 | 图标 | 颜色 | 行为 |
|---|---|---|---|
| 分裂展示 | split | `var(--text)` | `panes.includes(key) ? panes : [...panes, key]` |
| 收藏 / 取消收藏 | star / starFill | 未收藏 `var(--text)`；已收藏 `var(--amber-deep)` | 翻转 fav 并持久化 |
| 关闭 | x | `var(--danger)` | **`separator:true`**（上边框 + `margin-top:4px`）。行为见下 |

**「关闭」的语义（协议偏差裁定）**：协议 v1 **没有** kill session 能力，所以「关闭」= *关闭这个 Agent 打开的所有分裂列 + 取消订阅*，不动远端会话。`panes.includes(key) === false` 时该项 `disabled:true`（`var(--text-faint)`）。
设计稿的 190ms 关闭动画**保留**，用在**行因服务端 `list_delta` 消失**时：先 `closing[key]=true`（opacity→0、scale→.94，`.18s`），`setTimeout(190)` 后再从数组里移除，并同步剔除 `panes` 里的该 key。

**C. 分裂列（pane）**
设 `idx = panes.indexOf(id)`：
| 项 | 图标 | 可用条件 | 结果 |
|---|---|---|---|
| 关闭左侧所有 | closeL | `idx > 0` | `panes.slice(idx)` |
| 关闭右侧所有 | closeR | `idx < panes.length - 1` | `panes.slice(0, idx + 1)` |
| 关闭其他 | x | `panes.length > 1` | `[id]` |
不满足条件 → `disabled:true`，`color:var(--text-faint)`（`#b0aca3`），点击只关菜单。

### 7.4 App 状态与持久化

```js
// 内存态
devices[], clients:Map<deviceId,Client>, listings:Map<deviceId,Workspace[]>,
menu:{kind:'space'|'agent'|'pane', id, x, y} | null,
newAgentSpace:string|null, addDeviceOpen:boolean, toast:string|null, closing:{}

// localStorage（前缀 am.）
am.devices        Device[]（⛔ token 不放这里，见下）
am.deviceChecks   { [deviceId]: boolean }
am.fav            string[]  形如 `${deviceId}::${cwd}::${sessionName}`
am.panes          string[]  Agent.key
am.selected       'all' | 'fav' | Space.key
am.collapsed / am.spacesOpen / am.agentsOpen   boolean
```
🔴 **token 不写 localStorage**：走 Rust 侧 `tauri-plugin-store`，落 `$APP_DATA/devices.json`（文件权限 0600）。前端只读回 `{id,name,url,online}`，token 由 Rust 在建连时注入；UI 里 token 输入框恒为 `type="password"`，任何日志/toast/错误文案都不得回显 token。

启动恢复：`am.panes` 里指向已不存在的 Agent.key 在首个 listing 到达后静默剔除。

---

## 8. Provider 图标

### 8.1 vendor（不走 CDN）

```bash
npm i -D @lobehub/icons-static-svg
```
构建期把用到的 8 个 svg 复制进 `src/assets/provider/`（或直接 `import url from '@lobehub/icons-static-svg/icons/claude-color.svg'` 让 Vite 打包）。已验证存在的 slug：`claude-color`、`claude`、`codex`、`grok`、`opencode`、`cursor`、`zai`、`kimi`。
⛔ 不要照抄设计稿里 `fetch('https://unpkg.com/...')` + blob URL 的做法——桌面端离线必须能用。

### 8.2 slug 映射（`lib/providerIcons.js`）

| provider key | 运行态 slug | 空闲态 slug | 显示名 |
|---|---|---|---|
| `claude-code` | `claude-color` | `claude` | Claude Code |
| `claude` | `claude-color` | `claude` | Claude |
| `codex` | `codex` | `codex` | Codex |
| `grok` | `grok` | `grok` | Grok |
| `opencode` | `opencode` | `opencode` | OpenCode |
| `cursor` | `cursor` | `cursor` | Cursor |
| `zai` | `zai` | `zai` | Z Code |
| `kimi` | `kimi` | `kimi` | Kimi Code |

### 8.3 `components/ProviderIcon.jsx`

```js
/**
 * @param {string|null} provider
 * @param {number} [size=18]
 * @param {boolean} [active=false]     运行态（state 为 working/blocked）
 */
```
- 命中映射 → `<img src={slug} width={size} height={size} alt={provider}
  style={{display:'block', flex:'none', opacity: active ? 1 : 0.4, transition:'opacity var(--d-icon)'}}/>`
- **未命中兜底**（首字母圆圈）：
  `display:inline-flex; align-items:center; justify-content:center; flex:none; width/height:size; border-radius:50%; border:1.5px solid {tint}; color:{tint}; font-size:{size*0.5}px; font-weight:700; font-family:var(--font-mono)`，内容 = `provider?.[0]?.toUpperCase() ?? '?'`。
  `tint` = `active ? (TINT[provider] ?? var(--tint-default)) : var(--icon-idle)`。

### 8.4 `lib/provider.js`

```js
inferProvider(sessionName)  // 小写后按顺序子串匹配：
// claude→'claude-code' | codex→'codex' | cursor→'cursor' | grok→'grok'
// opencode→'opencode' | kimi→'kimi' | (zai|glm|zcode|z-code)→'zai' | 其余 → null
PROVIDER_LABEL  // §8.2 最后一列
```

---

## 9. 内联 SVG 清单（`lib/icons.jsx`）

统一 `viewBox="0 0 24 24" fill="none" stroke="currentColor"`，`style={{flex:'none'}}`；`size`/`strokeWidth` 由调用方给。

| 名字 | 内容 | 默认 stroke-width |
|---|---|---|
| `SidebarIcon` | `<rect x=3 y=4 width=18 height=16 rx=3/><line x1=9 y1=4 x2=9 y2=20/>` | 1.8 |
| `SearchIcon` | `<circle cx=11 cy=11 r=7/><line x1=21 y1=21 x2=16.5 y2=16.5/>` | 1.8 |
| `ChevronDown` | `<polyline points="6 9 12 15 18 9"/>` | 2.2 |
| `FolderIcon` | `<path d="M4 20h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7l-2-2H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2Z"/>` | 1.8 |
| `GridIcon` | 4×`<rect width=7 height=7 rx=1.5/>`，坐标 (3,3) (14,3) (3,14) (14,14) | 1.8 |
| `StarIcon` | `<polygon points="12 2 15 8.5 22 9.3 17 14 18.2 21 12 17.5 5.8 21 7 14 2 9.3 9 8.5"/>`，`fill` 传入、`stroke:none` | — |
| `StarOutline` | 同上 polygon，`fill:none` + stroke | 1.9 |
| `LayersIcon` | `<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/>` | 1.8 |
| `MonitorIcon` | `<rect x=2 y=4 width=20 height=13 rx=2/><line x1=8 y1=21 x2=16 y2=21/><line x1=12 y1=17 x2=12 y2=21/>` | 1.8 |
| `GearIcon` | `<circle cx=12 cy=12 r=3/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h0a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h0a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v0a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z"/>` | 1.8 |
| `CheckIcon` | `<polyline points="20 6 9 17 4 12"/>` | 2.2 |
| `XIcon` | `<line x1=18 y1=6 x2=6 y2=18/><line x1=6 y1=6 x2=18 y2=18/>` | 2 |
| `PlusIcon` | `<line x1=12 y1=5 x2=12 y2=19/><line x1=5 y1=12 x2=19 y2=12/>` | 1.8 |
| `SplitIcon` | `<rect x=3 y=4 width=18 height=16 rx=2/><line x1=12 y1=4 x2=12 y2=20/>` | 1.9 |
| `CloseLeftIcon` | `<line x1=5 y1=4 x2=5 y2=20/><path d="M19 12H9m0 0 4-4m-4 4 4 4"/>` | 1.9 |
| `CloseRightIcon` | `<line x1=19 y1=4 x2=19 y2=20/><path d="M5 12h10m0 0-4-4m4 4-4 4"/>` | 1.9 |
| `TerminalIcon` | `<polyline points="4 17 10 11 4 5"/><line x1=12 y1=19 x2=20 y2=19/>` | 1.8 |
| `ArrowUpIcon` | `<path d="M12 19V5m0 0-6 6m6-6 6 6"/>` | 2 |

菜单里的图标统一 `size=14, strokeWidth=1.9, stroke="currentColor"`（跟随菜单项 `color`）。

---

## 10. 明确「不做」清单

| 设计稿里有 / 常见联想 | 处理 | 原因 |
|---|---|---|
| 平台切换按钮（`macOS · 同一套代码` 胶囊） | **删除** | 只发 macOS |
| Windows caption 三键（46×40）、`isWin` 分支、`winRadius`、`Segoe UI` 字体切换 | **删除** | 同上 |
| 底部「图标 · 运行 / 空闲」画廊条（`iconGallery`） | **删除** | 设计稿演示用 |
| 「新建文件夹」按钮 + 内联文件夹输入行（`folderEditing` 全套） | **删除** | Space = 服务端发现的 workspace，客户端不可创建 |
| 暗色主题 | **不做** | 设计稿只有亮色；xterm 主题也固定亮色 |
| 侧栏 Search 功能 | 只保留占位行（无 hover、无点击） | 未在本期范围 |
| 侧栏宽度可调（原型 prop 240–340） | 固定 280 | 无需求 |
| 分裂列拖拽调宽 | 不做，flex 均分 | 无需求 |
| 外层 1400px 卡片圆角 + 四层投影 + body 径向渐变 | **删除** | 画布演示，真实窗口交给 macOS |
| 「新建 Agent」真正创建远程会话 | 按钮只弹 toast | 协议 v1 无此能力 |
| 「关闭 Agent」杀掉远端 tmux 会话 | 只关本地列 | 协议 v1 无 kill |
| 终端列 Cmd/Ctrl-V 粘贴文本或图片上传 | **不做**（#33 已回退，2026-08-22） | 上传路径 CORS 失败；理由被推翻的改动整条退 |

---

## 11. 与设计稿的偏差决策（汇总，供评审）

1. 品牌名 `Motrix Agent` → **AgentMirror**（产品已定名）。
2. 假 traffic lights → 2026-08-22 再裁定：隐藏系统灯、hover 运动场胶囊（四钮），保留 Cmd+W/Q。
3. 状态从布尔 `running` 扩到**协议五值**；新增 `blocked` 琥珀脉冲、`done` 绿色对勾、`unknown` 浅灰空心点。
4. Space 行**新增**设备徽章与聚合状态点（仅多设备 / 非 idle 时渲染），设计稿的 Space 行没有这两样。
5. **补出 pane 列头**：设计稿算出了 `title/iconEl/statusEl` 却没渲染；分裂多列必须能分辨归属。
6. `Add Device…` 从「插一条『等待配对』假设备」改成 **AddDeviceDialog（ws URL + token）**。
7. **终端输入**（设计稿主区是「不在设计范围」占位）；快捷键闭集严格对齐协议 `esc/ctrl_c/tab/up/down/left/right`，`text` 与 `keys` 互斥、`keys` 不补回车。主区不额外挂载底部图片条；Ctrl+V 图片上传路径仍保留。
8. 「关闭」语义改为**关闭分裂列**并在无列时置灰；190ms 关闭动画改挂到「服务端删除会话」路径。
9. 分裂列 `:first-child` 去掉 `border-left`（原型与侧栏 border-right 会并出双线）。
10. `max-height:clamp(96px, 100dvh - 464px, 288px)` 的 `100dvh` → `100vh`（桌面端窗口无动态视口）。
11. 新增 `prefers-reduced-motion` 降级（脉冲/过渡关闭）与输入框可见 focus ring —— 无障碍基础不省。
12. token 不写 localStorage，落 Rust 侧 store 文件（安全红线，见协议 §9）。
13. **2026-08-24**：Cmd/Ctrl 粘贴分键：Cmd+V 只发文本，Ctrl+V 图片经原生上传包装为无 ack 的 `attach_preview`；后续真实回车才提交，底部图片加号和说明已删除，CSP 不放宽。
14. **2026-08-22**：终端列回车等待 `input_ack` 必须有界；重连清场孤儿 waiter。多客户端重排后回车死锁的根因。
15. **2026-08-22**：全屏/折叠悬浮胶囊 chrome（用户确认 mockup）：藏系统灯、四钮运动场形、hover 才出、全屏热区 top 62px、红钮真关闭、Cmd+B/W/Q 兜底。
16. **2026-08-23**：xterm OSC/DA/CPR/DSR/DCS 应答不上行（被动镜像；远端超时回落默认主题可接受）。
17. **2026-08-23**：切列/改宽时本地 `term.resize` 与上报同一拍（120ms 落定）；未落定不 reflow 旧快照。
18. **2026-08-23**：捕获宽度 == 渲染网格宽度为不变量；落定后 subscribe、改宽重订、错宽帧不画。
19. **2026-08-23**：snapshot 重放对裸 LF 采用隐含 CR 语义；仅作用于 snapshot，delta 保持原始字节。
