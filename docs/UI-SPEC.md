# AgentMirror macOS 桌面端 · UI 实现规格书

本文件是**唯一 UI 事实来源**。实现者不需要再打开 `design-handoff/` 里的设计稿——所有像素、颜色、动画、SVG 路径、交互分支都在这里。

- 设计稿出处：`design-handoff/cross-platform-desktop-ui-mockups/project/Agent App Prototype.dc.html`（主）+ `Desktop Mockups.dc.html` 的 `#1c 窗口 chrome 规格`。
- 技术栈：Tauri v2 + Vite + React（JSX，**无 TypeScript**）+ `@xterm/xterm` 6。包管理 npm。
- 跨平台（macOS / Windows），支持三态主题（浅色 / 深色 / 跟随系统，Issue #255 / #296），界面文案中文。
- 协议：`/Volumes/nvme/Projects/远程Agent安卓/docs/protocol.md`（v1，只读参考）。

---

## 0. 术语与数据形状（所有组件共用）

协议 → 产品映射（已裁定，不要重新设计）：

| 产品概念 | 协议对应 | 说明 |
|---|---|---|
| Device | 一个 `agentmirrord` 连接（ws URL + token；本机 loopback 可为空，配置 token 时按标准 auth 认证） | 多设备 = 多个 Client 实例并行 |
| Space | `workspace`（按 cwd 聚合） | 行名 = cwd basename |
| Agent | `session` | `ref` / `name` / `state` |

```js
/** @typedef {'working'|'blocked'|'done'|'idle'|'unknown'} AgentState */

/** @typedef {Object} Device
 *  @property {string}  id        本地生成的稳定 id（uid()）
 *  @property {string}  name      用户填的显示名，如 "Mac Studio @ Home"
 *  @property {string}  url       ws:// 或 wss:// 地址
 *  @property {string}  token     配对 token（本机 loopback 可为空；有 token 时按标准 auth 认证；⛔ 永不明文上屏、永不进日志）
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
 *  @property {string}     title      = session.name 原样（服务端权威提取的会话展示名，如 "桌面端leader"；底层 OSC 窗口标题 session.title 仅做兜底，严禁以 OSC 污染界面，2026-09-17 裁定）
 *  @property {string} provider  daemon 的 canonical DTO provider；缺失/非法统一为 unknown
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

### 1.10 深色模式主题系统与审美规范（2026-09-24 裁定，Issue #255 / #296）

依据 Astra 审美指导书，深色模式定位为“低饱和石墨蓝灰、层级克制、文字清晰的专业终端桌面主题”：
- **表面层级（Surface Ramps）**：
  - 画布底色：`--bg-solid` / `--terminal-bg` 为 `#0F1115`，终端与分屏缝隙保持一致，无发白槽沟；
  - Surface-0：`#171B22`（侧栏、顶栏 Header、底部工具条基底）；
  - Surface-1：`#1E242D`（设置弹框外壳、占位图标框）；
  - Surface-2：`#272F3A`（卡片表面、右键浮层、活跃 Tab 胶囊）；
  - Surface-3：`#323D4B`（hover / pressed 浅层高光，分段选中高光）。
- **文字与反差（WCAG 2.1 AA 标准）**：
  - Text-primary：`#E5E7EB`（正文、当前会话标题）；
  - Text-secondary：`#B7C0CD`（次级说明、非活跃标签）；
  - Text-muted：`#9DAABB`（正常空态说明、组标题、辅助元数据，对比度 ≥ 4.6:1）；
  - Text-disabled：`#667181`（真正不可操作的禁用项）；
  - 彻底消灭完成按钮反相白字白底 Bug：通过成对动作变量 `--action-primary-bg: #8FAADC` 对 `--action-primary-fg: #111722`，反差达到 8.55:1；
- **分屏与高光**：
  - 活跃窗格边框：`--pane-active-border: #5C79A3`（单一 1px 细线，不加 0.25alpha 泛光）；
  - 分屏手柄高光：收敛至中心 2px 细线（`--accent: #8FAADC`），不填满 6px 间隙；
- **Provider 图标**：
  - 纯黑单色资产（Codex、Cursor、Pi 等）在深色模式下应用 `filter: invert(0.88) brightness(1.1)`，反差达到 5:1 以上；彩色品牌资产（Claude Code、Copilot、Grok 等）严格保持原色不反相；
  - 非活动态图标透明度自适应提升至 `0.65`，避免在深底上丢失轮廓。

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

## 2. 窗口 chrome（macOS，来自 Desktop Mockups `#1c` 与 2026-09-16 用户最新裁定）

- 标题栏高 **38px**。（2026-08-22 用户裁定：顶部去界化，标题条收窄。原 46px 作废。）
- **分列式架构与视觉对齐**（2026-09-16 用户最新裁定）：废除贯穿整个窗口顶部的全宽 Header，左侧菜单栏与右侧会话区由垂直分隔线彻底分离：
  - **左侧列（侧边栏区域）**：
    - 顶部工具栏（TitleBar，高 38px）预留 **80px** 原生红绿灯安全留白，并在垂直方向上与折叠按钮严格共线对齐（`trafficLightPosition: { "x": 18, "y": 20 }`）；
    - 菜单缩进按钮（SidebarToggle，`28×26px`，`<SidebarIcon size={16} strokeWidth={1.8}/>`）位于左侧栏最右侧、紧靠垂直分割线左侧，垂直绝对居中；
    - 中间区域为可拖动窗口区域（`.tb-drag`），由顶层 `data-tauri-drag-region="deep"` 原生接管窗口移动；
    - 侧栏会话支持即时拖动：按下鼠标位移 `dx/dy > 4px` 瞬间进入 dragging 状态（无 180ms 延迟），彻底消灭 HTML5 拖拽冲突（`-webkit-user-drag: none`）与蓝底选中文本；
    - 下方排布工作区与会话列表（SpacesList、AgentsList），彻底删除右键“分裂展示”废弃菜单；
    - 右侧拥有贯穿整个视口全高的垂直分隔线（`border-right: 1px solid var(--border-strong)`）。
  - **右侧列（会话主舞台）**：
    - 顶部放置会话选项卡栏（`tb-session-header` 内挂载 TabBar，高 38px，位于垂直分隔线右侧，仅覆盖右侧会话区，绝不在左侧菜单栏上方！）；
    - 顶栏空白处同样由顶层 `data-tauri-drag-region="deep"` 配合 Tab 与按钮 `data-tauri-drag-region="false"` 原生接管窗口移动；
    - 下方是同父平铺常驻终端舞台（TerminalStage），全域无死角分屏（多竖列连续分屏 1:1:1 绝对均等均分，彻底消灭 211 / 112 畸形比例；单会话中线左右 50/50 划分；分屏窗口点击左侧会话坚决不生效，杜绝挤占替换）；
  - **侧栏折叠**：`.app-left` 宽 **0**，无常驻窄列。展开/折叠通过快捷键 Cmd+B 或顶栏侧栏切换按钮唤出；折叠时右侧会话顶栏自动适配红绿灯留白与展开按钮。
- `tauri.conf.json` 保持 Overlay 模式：
  ```json
  { "titleBarStyle": "Overlay", "hiddenTitle": true, "trafficLightPosition": { "x": 18, "y": 20 } }
  ```
- **Cmd+B**：本地切换侧栏折叠/展开（任何窗口状态）。⛔ 不发给远端 CLI。
- 侧栏是独立一列 `height:100%; display:flex; flex-direction:column`；Agent 列表 `flex:1; min-height:0; overflow:auto`；All Devices 条是列的最后一个子元素，钉在窗口底部（不要 absolute）。
- 关闭 = 销毁窗口并退出进程（原生红钮 / Cmd+W 走 `close()`）。⛔ 不许 hide 后 Dock 残留。Quit = Cmd+Q。

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
    chrome/PairingDialog.jsx    §4.2 mobile pairing
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
    provider.js                 provider canonicalization + PROVIDER_LABEL
    providerIcons.js            （保留目录规划；当前资源直接由 ProviderIcon 导入）
    icons.jsx                   §9 全部内联 SVG 组件
    store.js                    localStorage 读写（见 §7.4）
    aggregate.js                多设备 listing → Space[]/Agent[] 聚合与去重
  assets/provider/              （不再复制；资源固定来自 deps/corral-core）
```

组件签名一律 JSDoc 注释 + 解构 props，无 TypeScript。

---

## 4. chrome 组件

### 4.1 `chrome/TitleBar.jsx`

```js
/**
 * @param {boolean} [sidebarCollapsed]
 * @param {() => void} [onToggleSidebar]
 * @param {boolean} [fullscreen]
 * @param {React.ReactNode} [children]  为后续 TabBar 预留
 */
```
内部状态：无（纯展示）。全宽一体化常驻 Header（2026-09-15 裁定：全宽通栏，常驻顶端，独立于侧栏）。

| 部件 | 规格 |
|---|---|
| 根 | `height:38px; flex:none; display:flex; align-items:center; gap:8px; padding:0 10px 0 0; background:var(--titlebar-grad); border-bottom:1px solid var(--border-strong); box-shadow:var(--titlebar-inset); box-sizing:border-box; user-select:none; position:relative; z-index:10`。横贯窗口全宽。 |
| 原生灯留白 | 排在最左端（仅 macOS）。`<div class="tb-traffic-lights" aria-hidden="true"/>`，宽 `80px`（78~86px 原生红绿灯安全保护区），不渲染任何可交互按钮。Windows 下收敛为 0 且隐藏。 |
| 侧栏开关 | 紧接原生灯留白。`<button class="tb-btn tb-sidebar-toggle" ...>`，`28×26px; border-radius:var(--r-6); display:flex; align-items:center; justify-content:center; align-self:center; cursor:pointer; color:var(--icon-titlebar)`；在顶栏（高 38px）内垂直绝对居中，中心线严格在 y=19px，与相邻 TabBar 标签胶囊项（高 26px，中心线 y=19px）严格共线平齐对齐，展开与折叠态切换平滑不跳变（2026-09-23 裁定，Issue #270）；hover `background:var(--hover-4); color:var(--icon-strong)`；`title="折叠/展开侧栏"`；图标 `<SidebarIcon size={16}/>` stroke 1.8 |
| 品牌名 | **不渲染**（不要展示产品名）。 |
| 分裂徽章 | **不渲染**（去界化后不再占用标题条）。 |
| 拖动区 | 剩余宽度 `<div class="tb-drag" data-tauri-drag-region/>`。支持窗口移动，不铺到交互控件上。 |
| Windows 窗口控制 | （仅 Windows，2026-09-19 裁定）。左侧 TitleBar 不挂载控制按钮（防止侧栏折叠向左移位）；三联按钮 `<WindowsWindowControls />` 挂载在应用视口最右上角（`.tb-session-header` 最右侧，`position: absolute; right: 0; top: 0; width: 138px; z-index: 50`），`.tb-session-header.is-windows` 严格预留 `padding-right: 138px` 避让空间；三键各宽 46px，严格声明 `data-tauri-drag-region="false"`，关闭按钮 hover 红色高亮。 **2026-09-23（Issue #242）**：Windows 发布 EXE 为 GUI 子系统；WSL 后台进程统一使用 `CREATE_NO_WINDOW`，不混用 `DETACHED_PROCESS`。正常启动不得附带控制台窗口；调试构建可保留诊断控制台。 |

### 4.1.1 `chrome/TabBar.jsx`（2026-09-16 用户多工作台最新裁定）

```js
/**
 * @param {Array<{ id: string, uid: string, name?: string, root: Object|null, activeUid: string|null, pinned: boolean }>} tabs
 * @param {string|null} activeTabId
 * @param {string|null} activeUid
 * @param {string[]} [visibleUids]
 * @param {Map<string, Object>} agentsByUid
 * @param {(tabId: string) => void} onSelectTab
 * @param {(tabId: string) => void} onCloseTab
 * @param {() => void} onCreateTab
 * @param {(e: React.MouseEvent, tab: Object) => void} onContextMenu
 */
```
内部状态：无。挂载在右侧会话顶栏（`tb-session-header`）内部，位于垂直分隔线右侧。

- **布局**：`<nav class="tb-tabbar">`，`height:28px; display:flex; align-items:center; gap:6px; min-width:0; user-select:none`。
- **核心模型变革（Tab = 独立工作台 Workspace，而非单个零散会话）**：
  - **单工作台默认**：选项卡栏默认只有一个初始标签页（展示当前活跃会话名称或“工作区 1”），杜绝在侧栏点击会话产生大量零碎 Tab 的膨胀问题；
  - **新建加号按钮**（`.tb-tab-add`）：TabBar 标签列表最右侧常驻一个精致的【+】加号新建按钮，支持快捷键 `Cmd+T` 快速新建；
  - **当前工作台内部切换与分屏**：当用户选中当前工作台时，在左侧栏点击任何会话，**只在当前激活工作台内部打开/替换聚焦窗格**，绝对不会在 TabBar 新增 Tab；拖拽分屏也只在当前工作台内组装网格；
  - **【+】号独立工作台隔离**：点击【+】号时新建一个独立的空白工作台标签页并切换聚焦；在该工作台内的点击与分屏完全不影响其他工作台已有的会话和多分屏状态；在不同 Tab 间切换即在多个独立分屏工作台之间秒级无缝切换；
- **钉选标签区**（`.tb-tabs-pinned`）：紧凑锚定最左侧，每个 pinned tab 固定宽 `28px`，居中渲染 Provider 图标或首字母 + 状态灯，带 title 悬浮说明与完整无障碍属性。右键支持取消固定或关闭。
- **普通标签区**（`.tb-tabs-scroll`）：横向自适应滚动，支持鼠标滚轮左右滑动。
  - **等长布局与自适应缩短裁定（2026-09-19 裁定）**：所有普通未钉选工作台标签页（`.tb-tab:not(.tb-tab-pinned)`）采用弹性等分布局（`flex: 1 1 0px; width: 160px; max-width: 160px; min-width: 44px;`），宽度严格等长，彻底消除字数长短参差不齐现象；当标签页增多时等比自适应缩短变窄（160px → 120px → 90px → 最小安全宽度 44px），内部会话名通过 `text-overflow: ellipsis; overflow: hidden; white-space: nowrap;` 优雅截断省略；钉选标签（`.tb-tab-pinned`）保持固定 32px 紧凑图标宽度不参与压缩；新建加号按钮（`+`）与标签拖拽吸附系统完全兼容。
  - **TabBar 胶囊边框细腻度与底边防截断（2026-09-21 裁定）**：
    - 消除 `.tb-tabs-scroll` 滚动容器因固定高度/内边距导致的 1px 截断；滚动容器高度显式设为 `height: 28px; box-sizing: border-box; padding: 0 1px`，胶囊定位在 `top: 1px; height: 26px`，确保上下均有充足空间，底边绝不被截断；
    - 胶囊采用精确测量宽度赋值与等比 1px 细边框，禁止非等比拉伸边框导致粗糙模糊，确保胶囊在任何时刻均为等比清晰细腻的 1px 边框；
  - 动态展示当前活跃会话名称（多窗格时标出窗格数如 `Session (2)`）+ 状态灯（`.tb-tab-lamp`）。
  - **状态灯规格（2026-09-24 裁定，macOS GPU 降载与消除无限合成）**：Working 状态为绿灯高质感静态发光（`box-shadow: 0 0 6px var(--green-ring)`，彻底移除 `animation: ... infinite`，杜绝 WebKit `CADisplayLink` 锁定 120Hz 与持续 GPU 合成）；Idle 状态为温和中性灰小点；Unknown 状态为灰色空心圆圈。
  - Hover / Active 时显露右侧快速关闭按钮（`.tb-tab-close`，`<XIcon size={11} strokeWidth={2.2}/>`）。
- **生命周期交互**：
  - 点击已可见 Tab 切换工作台并展示该工作台专属分屏树；
  - 右键菜单支持「固定/取消固定」、「关闭工作台」、「关闭其他工作台」、「关闭右侧所有工作台」。
- **顶栏拖窗与幽灵标签/工作状态根除裁定（2026-09-16 顾问终极架构裁定）**：
  - **顶部长按拖窗原生唯一通路**：彻底废除无效的 `-webkit-app-region` 与前端 JS 手动 `triggerWindowDrag` 派发逻辑，全面收敛至 Tauri 官方唯一原生通路：两侧 Header 声明 `data-tauri-drag-region="deep"`，所有交互控件（按钮、Tab 标签等）显式声明 `data-tauri-drag-region="false"`；`src-tauri/capabilities/default.json` 授权 `"core:window:allow-start-dragging"`，由 Tauri 内置特权脚本与 AppKit 原生接管窗口移动，无死角、零延迟、防误触；
  - **侧栏文件夹/工作区双列数字徽标展示（2026-09-17 裁定）**：侧边栏文件夹行（SpacesList）行内状态灯彻底退役，统一收敛为最右侧并列双列数字徽标（左列为工作中会话数，有工作会话时为绿色数字，无工作会话时为灰色数字；右列为总会话数）；全域状态直接源于服务端 listing / list_delta 直通模型，不受侧栏文件夹选中与否影响；TabBar 顶部状态呼吸灯（`tb-lamp-pulse`）绝对完好保留；断线或重连新代首帧到达前严格执行新鲜度判定，不报虚假 working；
  - **幽灵标签与重复标签彻底根除**：点击右侧终端窗格走纯粹的 `focusWorkspacePane`，仅更新当前激活工作台内部的 `activeUid`，绝不修改 `tabs` 结构；单会话全顶栏查重与 `openSession` 安全防穿透委派，彻底杜绝生成没有 root、没有内容、仅有标题的空壳幽灵 Tab！
- **UI 与视觉审美精进裁定（2026-09-16 顾问审查收口）**：
  - **激活 Tab 与未定义变量清除**：彻底消除未定义 CSS 变量（`--surface-2`、`--border-soft`、`--hover-6`）；激活 Tab 采用 `background: var(--bg); border-color: var(--border-input); color: var(--text); box-shadow: 0 1px 2px rgba(0,0,0,.06);`；
  - **信息层级与对比度**：未激活 Tab 默认文字提升为 `var(--ink-700)`，行高 `16px`；Agent 列表第二行 meta 小字提升为 `var(--ink-700)`，字号 `var(--fs-115)`，行高 `15px`；
  - **侧栏 open 与 active 状态解耦**：已打开（open）项背景降为 `var(--fill-subtle)`，仅当前激活（active）项高亮使用 `var(--sel-bg)`，未选中项 hover 使用 `var(--hover-1)`；
  - **分屏多窗格焦点覆盖环**：多窗格分屏时（`[data-multi-pane="true"]`），当前活跃窗格覆盖 1px `var(--input-focus)` 精准焦点轮廓环（`::after`）；
  - **状态灯与微交互精修**：统一使用 `--green: #34c759`，2.4s ease-in-out 呼吸动效；TabBar idle 灯采用 `var(--icon-idle)` 实心灰；Pinned Tab 调整为 32px 舒适边距；关闭按钮热区扩大为 18×18px，新建按钮 26×26px，支持 `:focus-visible`；
  - **克制通透毛玻璃**：拖拽预览候选框 `backdrop-filter: blur(4px); background: rgba(59,130,246,.08);`，让终端文字隐约可见。

### 4.2 `chrome/DevicesPopover.jsx`

```js
/**
 * @param {Device[]} devices
 * @param {(id:string, next:boolean) => void} onToggle       单设备勾选
 * @param {(next:boolean) => void} onToggleAll               All Devices 全选/全不选
 * @param {() => void} onAddDevice                           打开 AddDeviceDialog
 * @param {() => void} onPairMobile                          打开移动端配对二维码
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
- **配对移动端行**：在 Add Device… 之前渲染，`display:flex; gap:10px; padding:8px 12px; font-size:var(--fs-13); color:var(--text-secondary); cursor:pointer; border-radius:var(--r-8)`；点击打开 PairingDialog；`<QrIcon size={14}/>`。
- **Add Device… 行**：`border-top:1px solid var(--border); margin-top:4px; padding:8px 12px; display:flex; gap:10px; font-size:var(--fs-13); color:var(--text-secondary); cursor:pointer; border-radius:0 0 var(--r-8) var(--r-8)`；hover `var(--hover-2)`；`<PlusIcon size={14}/>`。

### 4.2.1 `chrome/PairingDialog.jsx`

```js
/**
 * @param {boolean} open
 * @param {{v:number,url:string,token:string,ts_authkey:string,candidates:string[],host_id?:string,port?:number,name?:string}|null} payload
 * @param {() => void} onCancel
 * @param {(message:string) => void} [onCopied]
 * @param {(token:string) => void} [onSaveToken]
 */
```

弹窗复用 `.chr-dialog` 外壳，宽 380px，包含 260px 高清 SVG 二维码（四模块 quiet zone、`shape-rendering:crispEdges`）、主机地址/主机唯一标识与扫码说明：`打开 AgentMirror 移动端，选择扫码连接并对准此二维码`。`Esc`、遮罩、关闭按钮均关闭。

**移动端配对 Host ID 体系（2026-09-22 裁定，Issue #207）**：
- 移动端配对彻底解耦 IP，核心绑定【主机唯一标识 Host ID + Token】。
- 当载荷包含 `host_id` 时，弹窗直接呈现主机身份信息（如主机名、8 位短 ID 与端口），无需且不展示「本机可达地址」手动输入框，免除手动配置局域网/Tailscale IP 的繁琐与易错性。移动端扫码后由局域网广播自动对齐主机并填入 Token。
- 兼容旧版：当载荷缺少 `host_id` 且为 loopback 端点时，回落保留可达地址输入框。
- 本机免密直连没有 Token 时显示密文输入框和 `移动端远程连接需要安全 Token` 提示，粘贴后立即动态生成二维码；`保存并复制配对信息` 同时安全保存 Token 并复制协议载荷。`复制配对链接 / Token` 把协议单行 JSON 写入系统剪贴板，不在页面或 toast 回显 token。二维码字段支持 `{v:1,token,host_id,port,name,url,candidates,ts_authkey}`。

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
 * @param {{provider:string,display_name:string,supports_bypass:boolean,naming:string}[]} launchers
 * @param {boolean} loading
 * @param {(v:{name:string,provider:string,bypass:boolean}) => void} onCreate
 * @param {() => void} onCancel
 */
```
内部状态：`name:''`、`provider:''`、`bypass:false`（仅首次打开时重置）；厂家只来自当前设备 `auth_ack.agent_launchers`。弹窗保持打开时，即使能力 DTO 或 `launchers` 数组引用刷新，只要当前 provider 仍在有效列表中就保留用户选择；provider 失效时才回落到列表首项。

- **scrim**：`position:fixed; inset:0; z-index:50; background:var(--scrim); backdrop-filter:var(--scrim-blur); animation:menuIn var(--d-hover) ease-out`；点击 = `onCancel`。
- **卡片**：`position:fixed; left:50%; top:50%; transform:translate(-50%,-50%); z-index:51; width:420px; background:var(--glass-dialog); backdrop-filter:var(--blur-dialog); border-radius:var(--r-14); box-shadow:var(--shadow-dialog); padding:20px; animation:menuIn var(--d-dialog) var(--ease)`。
- 标题 `新建 Agent`（`--fs-15`/700/`margin-bottom:2px`）；副标题 `在「{spaceName}」中创建`（`--fs-12`/`--text-muted`/`margin-bottom:14px`）。
- 名称输入框：placeholder `任务名称`，`autoFocus`，样式同 §4.3 输入框；必须非空、≤64 Unicode 字符且不得含控制字符，否则禁用创建并给出错误提示。
- 小标题 `选择 Agent`：`font-size:var(--fs-115); font-weight:600; color:var(--text-muted); margin-bottom:8px`。
- **厂家网格**：`launchers.map(...)` 动态渲染当前设备广告的 provider/display_name；不得维护静态厂家数组。
  格子：`display:flex; flex-direction:column; align-items:center; gap:6px; padding:10px 4px 8px; border-radius:var(--r-9); cursor:pointer; transition:background var(--d-hover),box-shadow var(--d-hover)`；未选 `background:transparent; box-shadow:var(--ring-tile)`；选中 `background:var(--hover-4); box-shadow:var(--ring-tile-sel)`；hover `background:var(--hover-2)`。图标 `<ProviderIcon size={20} active/>`，名字 `font-size:var(--fs-105); color:var(--icon-strong); white-space:nowrap`。
- **Bypass 行**：`display:flex; align-items:center; gap:10px; padding:10px 12px; border-radius:var(--r-9); background:var(--fill-subtle); margin-bottom:16px`。
  - 左文：`Bypass permissions`（`--fs-125`/600/`var(--warn-text)`）+ `允许 Agent 不经确认执行 shell 命令`（`--fs-11`/`--text-muted`/`margin-top:1px`）。
  - 开关：`38×23px; border-radius:var(--r-pill); position:relative; cursor:pointer; flex:none; transition:background var(--d-toggle)`；关 `background:var(--toggle-off)`，开 `background:var(--brand)`。旋钮 `position:absolute; top:2px; left:2px→17px; width:19px; height:19px; border-radius:50%; background:#fff; box-shadow:var(--shadow-knob); transition:left var(--d-toggle) var(--ease)`。
- **按钮行**：`display:flex; justify-content:flex-end; gap:8px`。
  - 次要按钮：`padding:7px 14px; border-radius:var(--r-8); font-size:var(--fs-13); font-weight:600; color:var(--icon-strong); cursor:pointer`；hover `background:var(--hover-4)`。
  - 主按钮：`padding:7px 16px; border-radius:var(--r-8); font-size:var(--fs-13); font-weight:600; color:#fff; background:var(--ink-800); cursor:pointer`；hover `background:var(--ink-900)`；active `background:#000`。
- **Bypass 行**：始终渲染并占位，保证切换 provider 时弹窗高度恒定；当前 launcher 的 `supports_bypass=false` 或未选中时，卡片与开关置灰禁用且强制传 `bypass:false`。支持时恢复正常交互。
- **创建中**：提交后按钮显示 `创建中…`、保留对话框并禁止重复提交/取消；加载状态也保留固定占位，避免弹窗高度跳变；收到成功 result 后仍须等待 authoritative listing/list_delta 包含新 ref，再关闭对话框并聚焦新 Agent。
- **「创建」行为（协议裁定 2026-09-17）**：App 通过已认证 WebSocket 发送 `create_agent`；失败 toast 保留表单；错误帧/断连不假结算，受控超时解除 loading。

### 4.4.1 `chrome/CloseAgentDialog.jsx`

受控二次确认弹层，props 为 `open`、`agent`、`loading`、`onConfirm`、`onCancel`。复用 §4.4 的 scrim/card/button token；展示「关闭 Agent」及终止风险提示。取消、Esc、scrim 点击只调用 `onCancel`，确认才调用 `onConfirm`；不得调用原生 `window.confirm`。发送请求后按钮禁用并显示 `关闭中…`，服务端权威删除前不改变 Agent 行与工作区。

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
- **菜单类别与动作（2026-09-23 裁定，Issue #261；2026-09-24 裁定，Issue #295）**：
  - Space 菜单（`space`）：`新建 Agent`；
  - Agent 菜单（`agent`）：`收藏 / 取消收藏`、`关闭`（带二次确认）；
  - Tab 菜单（`tab`）：`适应当前窗口`、`恢复自动标题`（若自定义）、`固定到最左 / 取消固定`、`关闭工作台`、`关闭其他工作台`、`关闭右侧所有工作台`；
  - 窗格菜单（`pane`）：`适应当前窗口`、`收藏 / 取消收藏`、`关闭此分屏`。**彻底删除「向右分屏」（Issue #295）与历史「向上分屏」/「向下分屏」（Issue #261），保持右键菜单简洁并与现有分屏交互逻辑一致**。

### 4.6 `chrome/Toast.jsx`

```js
/** @param {string|null} message  非空即显示；@param {() => void} onDone */
```
内部状态：定时器。`message` 变化 → 重置 2600ms 定时器 → `onDone()`。**单条，不排队**（新消息覆盖旧的）。

`position:fixed; left:50%; bottom:22px; transform:translateX(-50%); z-index:60; max-width:420px; padding:9px 14px; border-radius:var(--r-10); background:rgba(58,56,53,.92); backdrop-filter:blur(12px); color:#fff; font-size:var(--fs-125); box-shadow:var(--shadow-menu); pointer-events:none; animation:rowIn var(--d-toggle) ease-out`。

---

### 4.10 `chrome/SettingsDialog.jsx`（2026-09-21 设置界面重构裁定）

- **视觉**：支持浅色/深色主题外观（Issue #255 / #296）；深色模式采用专业低饱和石墨蓝灰。弹窗宽 560px、18px 圆角，窄窗口保留左右各 16px；高度不超过视口减 32px。标题 / 内容 / 页脚三段，内容独立滚动，关闭与完成始终可见。
- **分组**：「终端外观」「工作区行为」两节；12px 圆角浅色卡片、细边框与内高光。只用现有语义 token，不再引用不存在的 `--text-strong` / `--text-subtle`。
- **字体**：六个本地常用字体胶囊按各自字体栈展示，主字体匹配时以墨底浅字与 `aria-pressed` 标记（包括默认回退栈）；自定义 CSS 字体栈输入仍保留。未安装字体使用 CSS 回退，不宣称已检测 / 安装字体、不联网加载字体。
- **字号**：原生 range（10–24，步长 1）+ 减号 / 数字文本输入 / px / 加号组成联动控件，边界步进按钮禁用；输入合法数值即时生效；空值 / 单个 `1` 等中间态不提前夹逼，失焦或 Enter 使用现有 `clampFontSize` 收口。保留数字清洗与上下方向键步进，禁止回退到会中断输入的 number 自动夹逼。
- **预览**：卡片内墨色终端字样预览同时应用当前字体栈与字号，包含拉丁字母、数字与中文；纯本地示例，不连接 / 写入真实 Agent。
- **目录跟踪**：以原生 button + `role="switch"` / `aria-checked` 实现现代 Switch，38×23px 轨道、19px 滑块、200ms transform 动画。仍即时持久化 `directoryTracking`，默认关闭；不改变 #204 仅随当前 Agent 标量变化的目录跟踪逻辑。
- **交互**：右上关闭、右下完成、Escape、遮罩均可关闭；文案明确「修改即时保存」，不新增取消 / 提交事务。弹窗打开时接管焦点、Tab/Shift+Tab 环绕、关闭后归还焦点；控件键盘可操作并有可见焦点环，reduced-motion 禁用设置内部动画。
- **边界**：不新增设置键、依赖、主题切换、字体下载、后台连接或桌面权限；浏览器验证与独立 `.app` 验收分开记录。

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
 * @param {(spaceKey:string) => void} [onNewAgent]
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
- **Search 占位行彻底删除（Issue #253）**：侧栏顶部原无功能 Search 占位行已彻底拔除，释放纵向视觉空间，Spaces 列表自适应上移顶格。
- **Spaces 分组头**：`display:flex; align-items:center; justify-content:space-between; padding:14px 20px 4px`。左侧可点 span：`display:inline-flex; align-items:center; gap:4px; font-size:var(--fs-12); font-weight:600; color:var(--text-muted); cursor:pointer; border-radius:var(--r-5); padding:2px 6px; margin-left:-6px`；hover `background:var(--hover-2); color:var(--icon-strong)`。chevron：`<ChevronDown size={11} strokeWidth={2.2}/>`，`transform:rotate({spacesOpen?0:-90}deg); transition:transform var(--d-chevron) var(--ease)`。**右侧「新建文件夹」按钮删除**（见 §10）。
- `spacesOpen` 为真时渲染 `<SpacesList/>`。
- **Agents 分组头**：`padding:14px 20px 4px; display:flex; align-items:center; min-width:0`。文案：`selected==='all'` → `Agents`；`'fav'` → `收藏的 Agents`；否则 `` `${spaceName} 的 Agents` ``。文字 span 需 `white-space:nowrap;overflow:hidden;text-overflow:ellipsis`，chevron `flex:none`，其余同 Spaces 头。
- `agentsOpen` 为真时渲染 `<AgentsList/>`。
- **弹性占位**：`<div style={{flex: agentsOpen ? '0 1 0px' : '1 1 0px'}}/>` —— Agents 收起时把底部 Devices 条推到底。
- **底部 Devices 与设置控制栏（Issue #252 重构）**：`sidebar-footer` 容器 `height:44px; display:flex; align-items:center; justify-content:space-between; gap:4px; padding:4px 8px 4px 12px; border-top:1px solid var(--border-strong)`。
  - 左侧设备区（`.sidebar-devices`）：`flex:1; min-width:0; height:34px; padding:0 8px; border-radius:var(--r-6); display:flex; align-items:center; gap:8px; cursor:pointer`。包含 `<LayersIcon size={15}/>` + `label`（省略号）+ 状态点 `7px` 圆（`anyDeviceOnline` → `var(--green)`，否则 `border:1.5px solid var(--dot-hollow);background:transparent`）。
  - 右侧设置按钮（`.sidebar-settings-btn`）：**独立热区 34×34px（>=32px）**，`<GearIcon size={16}/>`，hover 态提供平滑旋转微动效（`transform:rotate(18deg)`）。**与设备区为兄弟元素，彻底消除点击设置误触发设备列表弹窗**。

### 5.2 `sidebar/SpacesList.jsx`

```js
/**
 * @param {Space[]} spaces
 * @param {number} allCount @param {number} favCount
 * @param {string} selected
 * @param {(key:string) => void} onSelect
 * @param {(e:MouseEvent, key:string) => void} onContextMenu
 * @param {(spaceKey:string) => void} [onNewAgent]
 * @param {boolean} multiDevice
 */
```
内部状态：无。

- 容器：`padding:0 10px; display:flex; flex-direction:column; overflow-y:auto; flex:none; max-height:clamp(96px, 100vh - 464px, 288px)`。
- **两个虚拟行置顶**（不可右键，`onContextMenu` 只 `preventDefault`）：
  1. `all` / `All Spaces` / `<GridIcon size={15} stroke="var(--icon-strong)"/>` / count = 可见 Agent 总数
  2. `fav` / `收藏` / `<StarIcon size={15} fill="var(--amber)"/>` / count = 收藏数
- **真实 Space 行**：图标 `<FolderIcon size={15} stroke="var(--icon)"/>`；hover 时显示 `<PlusIcon/>`，点击只打开动态能力的新建 Agent 对话框。
- 行样式：`display:flex; align-items:center; gap:10px; height:32px; flex:none; box-sizing:border-box; padding:0 10px; border-radius:var(--r-7); font-size:var(--fs-135); cursor:pointer; transition:background var(--d-hover); animation:rowIn var(--d-toggle) ease-out`；选中 `background:var(--sel-bg); font-weight:600`，未选 `background:transparent; font-weight:400`；hover `background:var(--hover-5)`。
- 名字 span：`overflow:hidden; text-overflow:ellipsis; white-space:nowrap`。
- 右侧（从右往左）：双列数字徽标（`.spaces-row-counts`），包含右侧总数（`count`，`font-size:var(--fs-12); color:var(--text-muted); font-weight:400; flex:none`）与左侧工作中数（`workingCount`，有会话工作时呈现为亮绿色数字 `.is-working.is-active`，无工作会话时呈现为灰色数字 `.is-idle.is-zero`）。行内原有聚合状态绿灯彻底退役（2026-09-17 裁定）。其左侧是：
  - **设备徽章**（仅 `multiDevice` 时渲染）：pill，`font-size:var(--fs-10); font-weight:500; padding:1px 6px; border-radius:var(--r-pill); margin-right:6px; box-shadow:var(--ring-hairline)`；本机 `background:var(--badge-local-bg); color:var(--badge-local-fg)`，远端 `background:var(--badge-remote-bg); color:var(--badge-remote-fg)`。
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
内部状态：`vpH`（可视高度，初值 68）。

**行高 34px，绝对定位 + top 过渡，是这套列表的灵魂，不要改成普通流式布局。**

- **外层**（挂 `ref`，被 `ResizeObserver` 观测）：`padding:0 10px; flex:1; min-height:68px; overflow:hidden; box-sizing:border-box`。
- **量化视口**：
  ```js
  const h = Math.max(68, Math.floor(el.clientHeight / 34) * 34);
  ```
  只在变化时 `setVpH(h)`。中层 `<div style={{height:vpH, overflowY:'auto'}}>` —— 保证永远只露出整数行，不出现半行。
- **轨道**：`position:relative; height:{agents.length * 34}px`。
- **排序**：`sorted = [...agents].sort((a,b)=>(b.fav?1:0)-(a.fav?1:0))`（稳定排序，收藏置顶）。**DOM 顺序仍用 `agents` 原序**，只把 `top = sorted.indexOf(ag) * 34` 写进样式 —— 这样 React key 不动，重排走 `top` 过渡。
- **行样式（会话行纯净精简与垂直收紧，Issue #254 / #280）**：
  ```
  position:absolute; left:0; right:0; top:{top}px; height:34px; box-sizing:border-box;
  border:2px solid transparent; background-clip:padding-box;
  display:flex; align-items:center; padding:6px 12px;
  border-radius:var(--r-8); cursor:pointer;
  background-color:{openKeys.includes(key) ? var(--sel-bg) : transparent};
  opacity:{closing?0:1}; transform:scale({closing?0.94:1});
  transition:background-color var(--d-hover),opacity var(--d-row),transform var(--d-row),top var(--d-reorder) var(--ease);
  animation:rowIn var(--d-chevron) ease-out;
  ```
  hover `background-color:var(--hover-5)`。单行卡片上下留白收紧至 6px 比例（卡片可视高 30px），与 18px Provider 图标紧密贴合。
- **三大核心视觉要素（彻底剔除重复 Provider 文本与工程/目录名）**：
  - **核心 1：工作状态指示点**（`.agents-dot`），`8px` 圆，`border-radius:var(--r-pill); flex:none`：
    | state | 样式 | title |
    |---|---|---|
    | working | `background:var(--green); box-shadow: 0 0 6px var(--green-ring);`（静态发光，无动画） | 运行中 |
    | blocked | `background:var(--amber); box-shadow: 0 0 6px var(--amber-ring);`（静态发光，无动画） | 等待确认 |
    | done | `background:var(--green-deep)`（实心，无动画） | 已完成 |
    | idle | `background:transparent; border:1.5px solid var(--dot-hollow)` | 空闲 |
    | unknown | `background:transparent; border:1.5px solid var(--ink-060)` | 状态未知 |
  - **核心 2：Provider 图标**：`<ProviderIcon provider={provider} size={18} active={state==='working'||state==='blocked'}/>`
  - **核心 3：会话名称**：`span.agents-row-title`（`flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap`）
  - **尾部标记**：`margin-left:auto; display:inline-flex; align-items:center; gap:5px; flex:none`：`state==='done'` → `<CheckIcon size={12}/>`；`fav` → `<StarIcon size={12} fill="var(--amber)"/>`；多设备徽章（`.agents-badge`，仅 `multiDevice` 时显示）。
  - **精简成效**：垂直单行居中排布，紧凑清晰，彻底消灭旧版第二行冗余重叠的文字，信噪比极大提升。
- **空态**（`agents.length === 0`，渲染在轨道之后）：`padding:18px 10px; font-size:var(--fs-12); color:var(--text-faint); text-align:center`，两行：`这个空间还没有 Agent` / `{emptyHint}`（默认 `在 Space 上右键 → 新建 Agent`）。

---

## 6. 主区（同父平铺终端舞台）

### 6.1 `terminal/SplitPanes.jsx`（TerminalStage，2026-09-15 裁定）

```js
/**
 * @param {Object|null} root                     二叉分屏树 root（LeafNode | SplitNode）
 * @param {Array<{uid: string, pinned: boolean}>} tabs 全局 Tab 列表
 * @param {string|null} activeUid                当前焦点会话 uid
 * @param {string|null} previewUid               虚空预览槽会话 uid（未固化到 tabs 时仍须挂载）
 * @param {Map<string, Object>} agentByKey       会话数据映射表
 * @param {(agent:Agent) => JSX.Element} renderPane 渲染终端内容
 * @param {(uid:string) => void} onFocusPane     聚焦窗格
 * @param {(e:MouseEvent, uid:string) => void} onPaneMenu 右键菜单
 * @param {(uid:string) => void} onClosePane     关闭此分屏
 */
```
内部状态：DOM 视口尺寸监听（ResizeObserver）、常驻宿主列表 `residentUids`、最新几何记录 `lastRects`。

- **同父平铺常驻体系**：
  - 容器：`<div class="splitpanes terminal-stage">`，`position:relative; flex:1; min-height:0; min-width:0; overflow:hidden`。
  - **核心保障**：所有的 `TerminalPane` 作为同一 DOM 父容器下的直接子组件，通过 `absolute` 定位投影（纯函数 `projectLayout(root, rect, gap=6)` 计算 `{x, y, w, h}`）；
  - 无论分屏怎么切分、重排或前后台切换，React `key={uid}` 与组件在 DOM 树中的层级永远保持不变，**彻底杜绝组件 Unmount、零 xterm 重建、零闪屏**。
  - **分屏物理间隙与调节手柄（2026-09-23 裁定，Issue #271 / #272）**：
    - 多分屏各窗格之间统一保留 **6px**（`SPLIT_GAP_PX = 6`）物理间隙，透出底层高质感背景；
    - 6px 间隙直接作为同父可交互拖拽手柄（`.split-resizer`），左右分界处显示 `col-resize`（宽 6px），上下分界处显示 `row-resize`（高 6px），拥有微动效 Hover 高光；
    - 拖拽过程基于 `setPointerCapture` 与单 rAF 进行 60fps 纯 DOM 视觉预览，零存储风暴；在鼠标松开时原子提交新比例并持久化至 `am.workspace.v2`（活动 Tab `root`）；
    - 严格遵循叶级最小安全尺寸约束（宽度 ≥ 120px，高度 ≥ 60px），杜绝窗格无限压瘪；窗口伸缩时按用户手调比例等比放缩，绝不被窗口 Resize 冲毁覆盖。
- **后台常驻机制**：
  - 合法宿主 UID 是已固化 Tab 的全部叶子加上当前 root 叶子（含 `previewUid`）；预览尚未写入 `tabs` 时也必须挂载 TerminalPane；
  - 已打开且未关闭的会话宿主常驻于 DOM 中，切换到后台时保留最后的非零尺寸矩形，施加 `visibility:hidden; pointer-events:none; inert; aria-hidden:true`；
  - 重新切回可见时直接恢复 `visibility:visible`，仅在几何发生真实改变时触发 120ms 防抖的 xterm `fit()`。
  - **单屏 ↔ 已初始化分屏切换（2026-09-26，Issue #301）**：按同一舞台矩形预投影所有 Tab 的叶子几何，并在隐藏宿主上保留该矩形与 xterm 网格；激活已驻留分屏时不得触发 `fit`、`subscribe` 或 `resize`，12 帧几何采样保持恒定。只有真实容器/字体度量改变才允许重排。
  - 仅在 Tab 明确关闭或服务端确认删除时，才真正卸载该组件并完整清理 xterm / 监听器 / 资源。
- **窗格结构与关闭钮**：
  - `.pane-host`：`position:absolute; box-sizing:border-box; display:flex; flex-direction:column; overflow:hidden`；单窗格全屏无外边框，多分屏状态（`[data-multi-pane="true"]`）带有 `1px solid var(--border)` 及 `border-radius:var(--r-8)` 卡片外框。
  - 处于多窗格分屏状态时（`visibleUids.length > 1`），窗格右上角悬浮显露关闭此分屏按钮（`.pane-close-btn`，`<XIcon size={12} strokeWidth={2.2}/>`）。
- **空态**（`visibleUids.length === 0`）：
  - 绝对定位覆盖层 `.splitpanes-empty`，居中提示：第一行 `从左侧选择一个 Agent`，第二行 `<span style="font-size:var(--fs-115)">点击打开、或右键在右侧分屏展示</span>`。

### 6.2 `terminal/TerminalPane.jsx`

```js
/**
 * @param {Agent} agent
 * @param {Object} client                        该设备的协议 Client 实例
 * @param {boolean} focused                      是否为键盘焦点列
 * @param {(rows:number, cols:number) => void} [onResize]
 *        通用本地几何通知；主 App 不连接它发送重复网络 resize。
 */
```
内部状态：xterm 实例、FitAddon、订阅生命周期、`ready`（是否收到首帧 snapshot）。

- **列头**（设计稿把 `title/iconEl/statusEl` 算了但没渲染，这里补上——分裂列不标名字没法用）：
  `height:34px; flex:none; display:flex; align-items:center; gap:8px; padding:0 40px 0 12px; border-bottom:1px solid var(--border-hairline)`；
  `<ProviderIcon size={17}/>` + title（`--fs-125`/600/`var(--text-secondary)`/省略号）+ 8px 状态点（规格同 §5.3）+ 设备徽章（仅 `multiDevice`）。
- **终端区**：`flex:1; min-height:0; box-sizing:border-box; background:var(--bg)`。**终端视口边距（2026-09-22 裁定，Issue #196 & #233）**：各平台 `.terminalpane` 统一保持 `padding: 0 5px;`（上下 0 消除单窗格与分屏底部空洞感，彻底回退 Windows 平台上下 5px 留白偏差；左右 5px 保留舒适文本安全距离，防止文字贴边）。全屏遮罩（`.chr-scrim`）采用纯净透明度渐变动画 `scrimFadeIn`，杜绝任何 scale / translate 几何缩放与平移抖动（2026-09-22 裁定，Issue #202）。
  **2026-09-23（Issue #239）**：Windows DOM 渲染器取消字符行之间的额外 leading，渲染与字体度量回退共用行高；外层 padding 不负责字符行内的制表符接缝。
  **2026-09-23（macOS 实测回归 & Issue #277 符号回退）**：macOS 同样取消额外行距。首屏投影与实际渲染共用行高；布局读取 xterm 渲染器已计算的精确字符格尺寸，不跨 DOM/WebGL 渲染器缓存，也不从整幅画布的整数宽度反推单格；切换后按最终渲染单元格重新计算列数，避免右侧空白随窗格宽度累积。终端保留用户正文选定字体，内嵌离线 `AgentMirror Symbols` 符号字体（覆盖 U+1F5AB 🖫 等杂项磁盘/存储符号），并追加平台符号字体（macOS Apple Symbols/Apple Color Emoji，Windows Segoe UI Symbol/Segoe UI Emoji）及 Symbols Nerd Font Mono/JetBrainsMono Nerd Font Mono 后备，彻底消除底栏符号与 Git Diff 状态的中空方块（tofu）；不替换 PTY 字符、不联网下载字体。
  xterm 选项：`fontFamily:'ui-monospace, SF Mono, Menlo, monospace'`、`fontSize:13`、`lineHeight: macOS/Windows 为 1.0，其余平台 1.25`、`cursorBlink:false`（严格关闭闪烁，彻底消除 WebGL 600ms 定时器空转重绘，2026-09-24 裁定）、`scrollback:0`（历史走协议 `scrollback` 帧）、`convertEol:false`。snapshot 重放在写入 xterm 前仅为每个裸 LF 补一个隐含 CR，使 capture-pane 的行间换行回到第 0 列；delta 仍按原始字节追加，不做该转换、不裁行、不改宽度计算。
  **2026-09-24（运行期光标协议硬锁策略）**：除构造默认 `cursorBlink:false` 外，前端在终端协议层实施运行期硬锁：彻底防御底层程序通过转义序列（`DECSCUSR`、`DECSET ?12h`）重新激活光标闪烁，避免 WebGL 渲染管线内部被动拉起 600ms `CursorBlinkStateManager` 定时重绘；同时完整保留合法光标形状（bar / block / underline）、`0` 参数重置恢复应用配置默认形状及其他 DEC 私有模式。本项属于协议层内部硬锁适配，系统级实际能耗与 GPU 占用需经由真实交付面与独立量具消融检验。
  **2026-09-26（WebGL 字符图集所有权收敛与退役 AtlasPage 显存主动回收，MVP Phase M1）**：在严格保持常驻平铺架构「WebGL Canvas 常驻不拆装、数据流常驻不断开、切 Tab 零重排」不变量的前提下，根治字符图集显存单调泄漏：① 在 `WebglAddon` 构造与激活阶段静默 `LinkRenderLayer`（`BaseRenderLayer._refreshCharAtlas`）对 2048 图集的无用申请（保留其下划线绘制画布与交互），彻底消除同一 `Terminal` 在 `CharAtlasCache` 中因 2048 与设备最大纹理尺寸（如 16384）不一致引发的互踢颠簸，确保相同字体/主题的多窗格 100% 共享单一 `TextureAtlas`；② 监听 `onRemoveTextureAtlasCanvas` 并挂钩 `TextureAtlas.dispose`，当图集发生 `_mergePages` 扩页合并、`_evictAllPages` 淘汰或最终 `dispose` 时，显式将退役 `AtlasPage` 画布及 `_tmpCanvas` 的 `width/height` 置为 `0`，同时阻断已退役图集的异步 `_doWarmUp` 暖机绘制，强制 WebKit 立即回收底层 2D Canvas Backing Store 与 `IOSurface` 显存。
  **2026-09-26（后台窗格渲染休眠与写流零拷贝，MVP Phase M2）**：彻底消除基线后台隐藏窗格以 60fps 持续执行 WebGL GPU 绘制吃掉 35%~60% GPU 的问题，同时 100% 保持切 Tab 绝对零重排、零清屏、即时可交互：① WebGL Canvas 永久常驻 DOM 原几何位置，数据流常驻正常解析写入 `term.buffer`（保证历史文字与后台输出 100% 不丢、零断流零退订）；② 窗格切入后台隐藏态时挂起 GPU 绘制循环（`_renderService._isPaused = true`）并跳过游标锚点 DOM 扫描，后台 GPU 提交归零；③ 窗格切回前台时解除休眠，若后台期间产生新文本（`_needsFullRefresh`）则在已有常驻画布上触发一次原子增量 `refresh(0, rows - 1)` 呈现最新状态，若后台期间画面静止则零额外重绘零提交；④ 写流路径消除 `withHiddenCursor` 逐帧数组重新分配与内存拷贝，采用引用直写并在尾部追加常量 `HIDE_CURSOR`，保全游标语义同时零分配零拷贝。
  `theme:{ background:'#fbfaf8', foreground:'#3a3835', cursor:'#3a3835', selectionBackground:'rgba(0,0,0,.12)' }`。
  首次几何就绪后立即完成首订；后续窗口拖拽的 `fit()` 目标 cols/rows 仍 **120ms 落定后再** `term.resize`（裁定 2026-09-17）。首帧立刻落到格子。
  **首帧几何前置纯数学投影与零延迟 Resize 体系（2026-09-22 裁定）**：
  - 彻底拔除 500ms 盲等与 46x44 盲建：由 `SplitPanes` 预先投影物理像素，结合全局离屏常驻字体度量缓存（`fontMetrics.js`）纯数学直接得出目标 `initialCols / initialRows` 并注入构造函数，发起的首帧网络 `subscribe` 直接携带最终尺寸一步到位拉起远端目标几何，彻底消灭二次 resize 导致的 CLI 输入框弹跳；
  - 拖拽 Resize 视觉 60fps 跟随与网络 PTY 120ms 节流解耦：本地容器与视口 60fps 实时跟随鼠标刷新，网络 PTY `resize` 维持单一 120ms 尾随防抖；
  - macOS 原生窗口在尺寸/屏幕变化时立即失效拖拽命中图；最新窗口几何静止至少 120ms 后合并通知 WKWebView，最多一条在途通知。前端每次重新 arm 前仅发送一次 disarm；原生同尺寸 generation/DPR 变化也必须重新 arm，禁止退回旧命中图。拒绝旧报告只清空命中图，不虚增原生 generation（2026-09-23，Issue #251）。
  - 首帧快照单微任务原子上屏：首帧快照到达时，在同一个微任务中同步完成快照写入与 `setReady(true)` 状态更新，保证内容上屏与加载占位卸载严格在同一帧呈现，零白屏闪烁。
  **同宽不变量（裁定 2026-08-23）**：每一帧画进 xterm 的 snapshot，其捕获宽度必须等于当时网格宽度。①几何落定之后才 `subscribe`（点开瞬间的过渡宽度不下订）②本地网格变了就用最新几何重发 `subscribe`（不再紧跟同尺寸网络 `resize`）③旧快照在改宽前 `reset`，捕获宽度 ≠ 网格宽度的 snapshot/delta 不下笔。⛔ 不裁行、不改宽度计算。频繁切列时过渡宽度 ⛔ 不把旧 snapshot 本地 reflow。
- **未就绪占位**（`!ready`）：居中，`44×44px; border-radius:var(--r-12); background:var(--surface-sunken); border:1px solid var(--border-hairline); display:flex;center; margin:0 auto 12px` + `<TerminalIcon size={20} stroke="var(--icon-placeholder)"/>`；下方 `正在连接会话…`（`--fs-13`/600/`var(--text-muted)`）+ `订阅 {ref} · 等待首帧快照`（`--fs-115`/`var(--text-faint)`/`margin-top:3px`）。
- 挂载：网格落定后 `subscribe(ref, rows, cols)`；改宽重订；卸载 `unsubscribe(ref)`。断线重连由 Client 侧 `replaySubscriptions()` 负责。

**终端列回车与 `input_ack`（裁定 2026-08-22）**：xterm 把可打印段先 `input.text`，再发空 `input`（裸 Enter）。等上一段的 ack **必须有界**（5s，与本地发送 `pending` 超时一致）。超时返回 `{ok:false, reason:'ack_timeout'}`，toast「上一条未确认，回车未发出，再按一次强制发送」，**清掉 pending**，下一次回车立刻发出。设备状态变化（重连 / READY 迁移）清 `inputWaiters` / 早到 ack / `lastTextByUid`，在等的 waiter 以 `ack_cleared` 结掉。⛔ 不许无超时 `await` 把回车永久扣押。`ok:false` 仍不把失败旧缓冲再提交一次。

**xterm 应答不上行（裁定 2026-08-23）**：我方是被动镜像，⛔ 不许替远端终端回答 OSC/CSI 查询。xterm 自动生成的 OSC（含 4/10/11/12）、DA（`CSI … c`）、CPR（`CSI … R`）、DSR（`CSI … n`）、DCS 在 `NativeInputPump` 中 **丢掉，不发 `input.text` / `input.keys` / `input.bytes`**。方向键是 `CSI A/B/C/D`（终字节大写），与 CPR 的 `R`、DA 的 `c` 分开。远端拿不到颜色应答会回落到默认主题，可接受。⛔ 修前 OSC 11 应答会变成输入行垃圾并可能打出 `esc`。

**终端暗色模式高对比度可读性与键盘映射（2026-09-21 裁定）**：
- 适配暗色模式终端配色方案（Tokyo Night / VS Code Dark+ 高对比度方案），在 WSL `#0f1115` 暗色底色下，主要前景色、光标以及 ANSI 16 色所有可读前景色严格满足 WCAG 2.1 AA 标准（对比度严格 >= 4.5:1），消除暗灰文字不可读问题。
- **终端点击物理聚焦与输入所有权（2026-09-21 裁定）**：
  - `.terminalpane-placeholder` 声明 `pointer-events: none`，消除未就绪占位层对用户点击的屏障阻断；
  - 窗格容器（`.terminalpane`）注册点击物理聚焦唤醒入口，无论点击的是新窗格还是已激活窗格（甚至从窗口外部切回），以及 46x44 避让模式下的留白区域，均能瞬时聚焦底层的真实 xterm `textarea`，彻底消灭终端焦点死锁（Focus Starvation）；
  - 彻底拔除 `TerminalPane` 捕获阶段 `onKeyDown` 拦截器，键盘输入与控制键统一由 xterm 编码并交由 `NativeInputPump`；应用终端快捷键统一收口于 `TerminalView` 的 `term.attachCustomKeyEventHandler`；
  - 统一建立单一干净的 `textarea` 原生 DOM `paste` 接缝：普通 paste 优先级严格为 **非空 text/plain ➔ image/* ➔ empty/unsupported**；
  - 文本粘贴复用 `handlePaneText` 发送，一次手势一次发送，保留多行文本且绝不自动追加 Enter；
  - 图片粘贴提取有效 bytes 后触发 `uploadAndPreview` 原生 HTTP 上传预览；图片-only 快捷键（macOS Ctrl+V）与纯文本快捷键（Windows Ctrl+Shift+V）各自职责明确、失败可见。
- **终端快捷键与鼠标映射**：
  - TUI 开启鼠标跟踪时，左键按下、连续拖动、释放按 xterm 生成的 SGR/X10 字节直达 PTY；无按键移动、右/中键与滚轮不走此通道。Windows 按 Shift、macOS 按 Option 强制本地选区（沿用 xterm 平台原生语义），无鼠标模式时正常框选（2026-09-23，Issue #258）。
  - 支持快捷键 `Ctrl+Shift+C` 复制终端选中文本；
  - 支持快捷键 `Ctrl+Shift+V` 强制纯文本粘贴；
  - 终端区域右键点击保持标准上下文冒泡（UI-SPEC §4.5 窗格菜单），坚决禁止捕获阶段暴力拦截阻断右键菜单或静默向 PTY 灌入剪贴板文本（2026-09-21 裁定）。
- **WSL 路径映射与会话更名随动更新**：
  - 统一通过 `normalizeCwd` 与 `isSameSpaceKey` 标准化工作区标识，解决 Linux POSIX 路径（`/mnt/c/...`）与 Windows 盘符路径（`C:\...`）等价判定；
  - `list_delta` 增量推送到达时，通过唯一 `ref` 精确匹配会话并原地更新会话名称，确保侧边栏会话名称随动刷新。

**粘贴（裁定 2026-08-24，B 预贴修订；2026-09-21 输入回炉重写裁定）**：DOM `paste` 事件优先处理文本；当文本为空且剪贴板携带图片数据（`image/*`）时，直接解析图片并触发 `uploadAndPreview` 原生 HTTP 上传预览，杜绝“图片请用 Ctrl+V”阻断提示；Ctrl+V 在 Windows 下放行原生 paste 事件以保持标准文字优先流转，在 macOS 下保留图片专用上传通道；图片字节经原生 `upload_http`
上传后只发 `attach_preview {ref,path}`，不发 `input.attachment_path`、`input.text` 或空 `input`，也不自动 Enter；图片留在远端 CLI 输入框，用户后续真实回车才提交。主区不再挂载底部图片条、图片加号或键位说明。原生 HTTP 不经过 WebView，故不放宽 loopback `connect-src`。

### 6.3 终端输入

终端列直接承接 xterm 的键盘输入和粘贴事件；可识别的命名键走 `input.keys`，其他有意输入序列由桌面薄 adapter 以非空 RFC 4648 base64 `input.bytes` 直达 PTY；主区不挂载额外的底部图片条。

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

**「关闭」的语义（协议裁定 2026-09-17）**：关闭 Agent 仅从 Agent 行右键上下文菜单进入，必须二次确认，然后通过已认证 WebSocket 发送 `close_session` 终止远端会话；收到 `close_session_result(ok:true)` 后仍保留行与工作区引用，直到权威 `listing/list_delta(removed)` 到达，再清理本地工作区、Tab、分裂列与订阅。请求失败或超时只反馈错误，不伪造删除；一次只允许一个关闭请求。
设计稿的 190ms 关闭动画**保留**，用在**行因服务端 `list_delta` 消失**时：先 `closing[key]=true`（opacity→0、scale→.94，`.18s`），`setTimeout(190)` 后再从数组里移除，并同步剔除 `panes` 里的该 key。关闭确认使用受控对话框，不调用原生 `window.confirm`。

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
newAgentSpace:string|null, newAgentLaunchers:Launcher[], createPending:Request|null,
closeConfirmAgent:Agent|null, closePending:Request|null, addDeviceOpen:boolean,
toast:string|null, closing:{}

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
生命周期 pending 不落盘；断线、错误或超时解除 loading，不自动重试。关闭请求在权威删除前保留行与工作区，权威删除后沿既有 190ms 退场路径清理。

---

## 8. Provider 图标

### 8.1 固定 core 资源（不走 CDN）

Provider 资源直接从固定 `deps/corral-core` submodule 导入，Vite 在构建期打包，离线可用：

| canonical provider | 固定资源 |
|---|---|
| `claude_code` | `app/app/src/main/res/raw/provider_icon_claude_code.svg` |
| `codex` | `app/app/src/main/res/raw/provider_icon_codex.svg` |
| `copilot` | `app/app/src/main/res/drawable-nodpi/provider_copilot_color.png` |
| `grok` | `app/app/src/main/res/drawable-nodpi/provider_grok.png` |
| `cursor` | `app/app/src/main/res/raw/provider_icon_cursor.svg` |
| `pi` | `app/app/src/main/res/drawable-nodpi/provider_pi.png` |

⛔ 不要引入 CDN、运行时 fetch、第二份复制资源或新的图标依赖。

### 8.2 canonical 映射（`components/sidebar/ProviderIcon.jsx`）

| provider key | working/blocked | idle/unknown | 显示名 |
|---|---|---|---|
| `claude_code` | `provider_icon_claude_code.svg` | 同一资源，opacity=.4 | Claude Code |
| `codex` | `provider_icon_codex.svg` | 同一资源，opacity=.4 | Codex |
| `copilot` | `provider_copilot_color.png` | 同一资源，opacity=.4 | Copilot |
| `grok` | `provider_grok.png` | 同一资源，opacity=.4 | Grok |
| `cursor` | `provider_icon_cursor.svg` | 同一资源，opacity=.4 | Cursor |
| `pi` | `provider_pi.png` | 同一资源，opacity=.4 | Pi |
| `unknown` | 中性首字母圆圈 | 中性首字母圆圈 | Unknown |

`claude` / `claude-code` 只作为封存 UI 的显示兼容别名映射到 `claude_code` 资源，不属于服务 canonical 集合。

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
normalizeProvider(value)  // 仅 canonical DTO 精确匹配；非法/显式 unknown → 'unknown'
inferCanonicalProvider(sessionName)  // 仅旧 listing 缺 provider 时的兼容回退
// claude / claude-code / claude_code → 'claude_code'
// codex | copilot | cursor | grok | pi → 原 canonical 值；其余 → 'unknown'
PROVIDER_LABEL  // §8.2 最后一列（旧封存 UI 别名仍可读）
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
| `PinIcon` | `<line x1=12 y1=17 x2=12 y2=22/><path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.89A2 2 0 0 1 15 10.77V5h1a1 1 0 0 0 0-2H8a1 1 0 0 0 0 2h1v5.77a2 2 0 0 1-1.11 1.79l-1.78.89A2 2 0 0 0 5 15.24Z"/>` | 1.9 |

菜单里的图标统一 `size=14, strokeWidth=1.9, stroke="currentColor"`（跟随菜单项 `color`）。

---

## 10. 明确「不做」清单

| 设计稿里有 / 常见联想 | 处理 | 原因 |
|---|---|---|
| 平台切换按钮（`macOS · 同一套代码` 胶囊） | **删除** | 只发 macOS |
| Windows caption 三键（原型 46×40 废弃方案） | **已按 2026-09-19 裁定重写** | 依据多端支持规划，采用 Tauri v2 标准集成方案：引入 `<WindowsWindowControls />`（46×38px，严格 `data-tauri-drag-region="false"`），并自适应 `TitleBar.jsx`，替代了原型的历史废案 |
| 底部「图标 · 运行 / 空闲」画廊条（`iconGallery`） | **删除** | 设计稿演示用 |
| 「新建文件夹」按钮 + 内联文件夹输入行（`folderEditing` 全套） | **删除** | Space = 服务端发现的 workspace，客户端不可创建 |
| 暗色主题 | **已支持** | 依据 Issue #255 / #296 规范完整实现深色模式及三态主题切换（浅色/深色/跟随系统），并依据 Astra 审美指导书完成低饱和石墨蓝灰与成对语义 Token 重构 |
| 侧栏 Search 功能 | 只保留占位行（无 hover、无点击） | 未在本期范围 |
| 侧栏宽度可调（原型 prop 240–340） | 固定 280 | 无需求 |
| 分裂列拖拽调宽 | 不做，flex 均分 | 无需求 |
| 外层 1400px 卡片圆角 + 四层投影 + body 径向渐变 | **删除** | 画布演示，真实窗口交给 macOS |
| 「新建 Agent」真正创建远程会话 | **已支持** | 依据当前设备 `auth_ack.agent_launchers` 能力广告发送 `create_agent` |
| 「关闭 Agent」杀掉远端 tmux 会话 | **已支持** | 二次确认后发送 `close_session`，以权威 listing/list_delta 驱动本地清理 |
| 终端列 Cmd/Ctrl-V 粘贴 | **已恢复**（PR93/94；2026-09-12 核对） | Cmd+V 文本；Ctrl+V 原生图片上传后预贴，不自动 Enter；见 §6.2 |

---

## 11. 与设计稿的偏差决策（汇总，供评审）

1. 品牌名 `Motrix Agent` → **AgentMirror**（产品已定名）。
2. 假 traffic lights → 2026-08-22 再裁定：隐藏系统灯、hover 运动场胶囊（四钮），保留 Cmd+W/Q。
3. 状态从布尔 `running` 扩到**协议五值**；新增 `blocked` 琥珀脉冲、`done` 绿色对勾、`unknown` 浅灰空心点。
4. Space 行**新增**设备徽章与双列数字徽标（侧栏文件夹行状态灯已正式退役，收敛为双列数字徽标；顶部 TabBar 呼吸灯保留，2026-09-17 裁定），设计稿的 Space 行没有这两样。
5. **补出 pane 列头**：设计稿算出了 `title/iconEl/statusEl` 却没渲染；分裂多列必须能分辨归属。
6. `Add Device…` 从「插一条『等待配对』假设备」改成 **AddDeviceDialog（ws URL + token）**。
7. **终端输入**（设计稿主区是「不在设计范围」占位）；命名快捷键保留协议闭集 `esc/ctrl_c/tab/up/down/left/right/backspace`，xterm 编好的其他有意序列走非空 `input.bytes`（标准 base64）；`keys`、`bytes`、`text`/`attachment_path` 三类载荷互斥且均不补回车。主区不额外挂载底部图片条；Ctrl+V 图片上传路径仍保留。
8. 「关闭 Agent」仅保留在 Agent 行右键菜单；二次确认后终止远端会话，190ms 关闭动画仍挂到「服务端删除会话」路径。
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
20. **2026-09-15**：恢复 macOS 原生红绿灯，彻底废除浮动胶囊（ChromePill）；实现全宽一体化常驻 Header（TitleBar），预留 80px 原生灯留白区，侧栏开关迁入顶栏，独立于侧栏折叠。
21. **2026-09-15 (PR B)**：全局 Tab 会话生命周期与同父平铺常驻分屏舞台（TerminalStage）。顶栏接入 TabBar（会话名 + 状态指示灯，Working 绿灯微动、Idle 静止、Unknown 灰空心；支持 Pin 紧凑锚定与关闭）；主区采用纯函数二叉分屏树（workspaceLayout.js）计算绝对几何，所有 TerminalPane 作为同一 DOM 父容器直接子节点投影定位，切分重排零 React Unmount、零 xterm 重建、零闪屏；采用 am.workspace.v1 本地白名单持久化。
22. **2026-09-15 (PR C)**：Tab 长按平滑调序与四向边缘吸附分屏引擎（tabDrag.js）。采用 Pointer Events（pointerdown/move/up + setPointerCapture），长按阈值 180ms、容差 6px；Zero Forced Reflow：pointerdown 预缓存视口与几何坐标，pointermove 仅记录点位并由单 rAF 调度，热路径绝对严禁读取 DOM 布局；主区触发 25% 四向边缘吸附（带 3px 切换滞回防抖与中心 50%×50% no-drop 区域）；GPU 硬件加速预览（translate3d + scale + opacity，悬浮期间绝不触碰真实 DOM/树）；pointerup 瞬间原子提交树变更，保持终端同父平铺保活，零 Unmount，120ms 防抖收敛。
23. **2026-09-17**：新建 Agent 仅展示当前 `auth_ack.agent_launchers` 广告的 provider；名称限制为非空、≤64 Unicode 字符且无控制字符，Bypass 由 `supports_bypass` 控制。`create_agent` 成功后等待权威 listing/list_delta 入驻再打开；`close_session` 成功后等待权威移除再清理本地状态，关闭确认采用受控对话框。
24. **2026-09-17**：Agent 行不渲染常驻或 hover 关闭 X；终止会话唯一入口是 Agent 行右键上下文菜单，避免会话点击误触危险操作。
25. **2026-09-17**：NewAgentDialog 的 provider 选择仅在首次打开或当前 provider 不再被能力广告支持时重置；能力列表引用刷新不得覆盖用户主动选择。
26. **2026-09-17**：Cursor Agent 的 follow-up 输入由 TUI 绘制软件游标；客户端隐藏底部停靠硬件游标，并将本地 IME helper/composition 视图锚定到可视 `Add a follow-up` 行，持续拦截 xterm 的内部样式冲刷，禁止在底部停靠行合成或闪烁。该适配不改变服务端帧。
27. **2026-09-18（多端协同契约与物理底锚裁定）**：
    - **2026-09-23，Issue #266（本轮仅 macOS）**：桌面 takeover 同样使用固有网格高度的 root bottom-left 底锚，撤销 macOS 路径的 `position:relative; height:100%` 覆盖。不能整除行高的余量留在顶部；同一终端字号/行高下，所有触及舞台底边的网格最后一行共享物理底边，无论初次打开、连续 Resize、2/3/4 列或嵌套上下分屏。CSS 随宿主底边即时移动，行列提交仍保持原有 120ms 同宽契约，不用负边距、逐窗格补偿或远端内容重写。Windows 本轮样式行为保持既有值。
    - **视口物理底锚**：彻底废除 flex-end 与 max-height 钳制，实施完整的 root bottom-left 物理底锚（`.terminalpane-host` 声明 `position: relative; display: block; overflow: hidden;`；`.terminalpane-host > .xterm` 声明 `position: absolute; left: 0; bottom: 0; width: max-content; max-width: none; max-height: none;`）。手机端 46×44 坚屏网格（792px）在桌面视口（~600px）中物理底锚对齐，顶端自然上伸裁切，最底部的输入框 `[ █ ]` 与状态行 100% 完整可见可交互；
    - **多端协同动静双模**：subscribe 携带 `client_type: "desktop"` 与 `retain_pane_size: true`，开启服务端尺寸驻留；未明确 presence 时以 46×44 保守初订，绝不提前挤掉手机；手机在线（`has_mobile: true`）避让模式保持 46×44 不发桌面 resize；手机离开（`has_mobile: false`）接管模式平滑铺满桌面视口；右键【适应当前窗口】走原子单一受控通道（单次发送）。
28. **2026-09-19**：标签页实施等长布局与自适应缩短；所有普通工作台标签页采用弹性等分布局（`flex: 1 1 0px; width: 160px; max-width: 160px; min-width: 44px;`），宽度严格等长；标签增多时等比自适应收缩变窄，文字优雅省略截断；钉选标签保持 32px 紧凑固定宽。
29. **2026-09-19（Windows 端 UI 自适应与 WSL 路径映射裁定）**：
    - **窗口控制按钮与视口右上角物理固定**：Windows 平台顶部 `TitleBar` 移除 macOS 80px 交通灯留白（收敛为 0 且折叠态亦不渲染）；三联按钮 `<WindowsWindowControls />`（最小化、最大化/还原、关闭）脱离左侧 TitleBar，挂载在整个应用窗口最右上角（`.tb-session-header` 最右端，`position: absolute; right: 0; top: 0; width: 138px; z-index: 50;`），且 `.tb-session-header.is-windows` 声明 `padding-right: 138px;` 保证 TabBar 绝不延伸遮挡；按钮各宽 46px，严格声明 `data-tauri-drag-region="false"`，关闭按钮 hover 红色高亮；无论侧栏处于展开态还是折叠态，物理坐标均严格恒定在 `{ right: 0, top: 0, width: 138, height: 38 }`；
    - **终端智能粘贴体验**：终端 Ctrl+V 快捷键实现智能识别，Windows 平台下若非图片内容直接作为文本/文件粘贴，消除“请按 Cmd+V”阻断提示；
    - **WSL 跨系统路径转换**：剪贴板文件路径通过 `wslPath` 双向转换为 WSL 2 POSIX 路径，并严格实施 fail-closed 白名单，绝对拒止非 WSL UNC 网络共享路径（如 `\\evil\share`）。

## core 依赖边界（裁定 2026-09-12）

客户端直接引用固定 corral-core submodule 的未修改 web/js，桌面只保留协议扩展和几何追踪适配。
目录/Agent 列表、分列镜像、断线恢复、历史翻页、滚轮及现有输入保持原行为。
PR93/94 的无底栏、图片一次上传后 attach_preview 预贴、不自动 Enter 继续生效；
不新增 Finder 路径、provider 图标或快捷键策略；xterm 有意输入的原始 bytes 已按 §6.3 接入。初始化与离线构建约束见 CLIENT-CONTRACT §1。
本次 Node/构建证据与真实测试 `.app` 证据分开，不能相互替代。

## Window (Swift Shell)

裁定日期：2026-09-16。方案 A 的 N1 提供 AppKit 窗口、WKWebView 本地静态资源容器与原生同步拖窗接缝；本段记录研发候选，不表示 Swift 壳已交付或玻璃验收通过。

- Native 仅根据预报告的 chrome 空白矩形，在自身窗口的当前 `mouseDown` 同步调用 AppKit `performDrag(with:)`；按钮、Tab、关闭区、输入、终端与弹层优先排除。Swift 禁止 `window.startDragging` 异步 RPC。
- macOS 自定义顶栏空白区双击由原生 `mouseDown` 显式切换窗口内 Zoom：目标严格为当前 `NSScreen.visibleFrame`，再次双击恢复进入 Zoom 前的 frame；不得调用原生 Fullscreen 或挤占 Dock/菜单栏（Issue #297，2026-09-24）。
- resize、跨屏、全屏、reload/dispose 时清空可拖矩形。正式接缝使用单调 Native `geometryGeneration` 与布局前 `disarm`/`arm` 屏障；同尺寸 DOM 动画仍须由前端在布局提交前 disarm，不得在未握手或几何失效时默认整页可拖。
- React 保留 Tab 和业务交互。N1 的系统标题栏是装配起点，最终标题栏/安全留白须在 F2/I1 与既有布局同候选验收，不擅自改变 header 几何。
- `GlassChrome` 在 macOS 26+ 挂载公共 `NSGlassEffectView`/`NSGlassEffectContainerView`，旧系统、减少透明度或提高对比度时降级为实底并保留清晰边界；终端/canvas 保持实底。WK 背景实际穿透未通过交付面验证前，不声明玻璃合成验收完成。
- **原生不透明承载面与主题契约（2026-09-24，PR #307 收口）**：C1 实验/交付候选固定 `NSWindow.isOpaque = true`、`WKWebView.drawsBackground = true`；Swift 窗口底色与 `WKWebView.underPageBackgroundColor` 必须由同一有效主题同步，浅色为 `#FBFAF8`，深色为 `#0F1115`，禁止只硬编码暗色。React 三态主题（light / dark / system）生效后经 `window.setTheme` 原生 bridge 更新两者。
- **材质与层级**：root 下 `GlassChrome` 只占顶部 38px `headerFrame`，位于覆盖全 root 的 WKWebView 之下；drag surface / 原生标题栏控件位于最上层。system glass、legacy visual effect、opaque accessibility fallback 严格互斥；终端舞台不进入 `behindWindow` 材质采样区。以上是不透明承载面与层级契约，不等同于 GPU/WindowServer 根治证明，真实 `.app` 仍需独立消融验收。
- bundle 页面限定 `agentmirror://app/index.html`，只对可信主 frame 暴露 `native` handler；服务由 I1 注入，未配置返回不可用。页面重载换代并取消 pending。资源响应使用 `HTTPURLResponse` 的白名单 MIME、200/206/416 状态与单范围流式传输；实际候选 `.app` 仍须按交付面验收。

### Windows Local 监听（2026-09-23，Issue #240）

客户端管理的 WSL daemon 显式绑定 `127.0.0.1:9900`；启动、readiness 与客户端 Local 连接统一使用 IPv4 loopback。WSL localhost forwarding 的 Windows IPv4 可达性仍须在实际安装包上验收。

### Windows 本地模式图片上传速度与 IPv4 地址归一（2026-09-24，Issue #289）

Windows 本地模式下剪贴板图片上传卡顿的直接根因为：URL 使用 `localhost:9900` 导致 Windows 优先尝试 IPv6 (`[::1]:9900`)，因 WSL 管理的 daemon 仅监听 IPv4 `127.0.0.1:9900` 从而引发 1~3 秒 TCP SYN 超时重试。
1. `DEFAULT_LOCAL_URL` 严格收敛为 IPv4 loopback `ws://127.0.0.1:9900/ws`；
2. `wsToHttpOrigin` 与 Rust 侧 `upload_http` 双端强制将环回 `localhost` 归一化为 `127.0.0.1`，杜绝任何 IPv6 SYN 超时回退；
3. `nativeCapabilities.upload.uploadHttp` 缓存 Tauri `invoke` 实例，消灭高频重复动态 import；
4. `extractPasteEventSnapshot` 保持对 `ClipboardEvent` 的同步原子数据捕获与瞬时二进制流转换，上传前发送与发送完成到 `attach_preview` 保持零延时直通。

### Windows 窗口最大化与还原状态解耦（2026-09-24，Issue #298）

Windows 右上角放大按钮（`.tb-win-max`）执行标准 Windows「最大化 / 还原」语义，与 document / native 全屏彻底解耦：
1. 窗口控制能力：`nativeCapabilities.window` 规范实现 `isMaximized`、`maximize`、`unmaximize` 与 `toggleMaximize` 原生接口，并在 `src-tauri/capabilities/default.json` 授予对应权限；
2. 状态与事件响应：组件挂载及窗口每次触发 `resize` / `onResized` 时均通过 `isMaximized()` 校验真实状态；在最大化与还原之间可靠双向切换，`aria-label` 与 `title` 随动展示「最大化」与「还原」，失败路径静默防御不抛出未处理异常；
3. 全屏与最大化状态解耦：Windows 下普通最大化窗口仅铺满工作区，`fillsDisplay()` 在 Windows 下恒返回 `false`，确保 `isFullscreen` 与 `isMaximized` 状态互不混淆；最大化路径仅调用 `maximize()` / `unmaximize()`，绝不触发 `setFullscreen()`。

### Windows WSL 启动响应（2026-09-23，Issue #243）

检查、安装、启动和读取 token 的原生 IPC 均异步分派到阻塞线程池，不占用窗口消息循环。每次 WSL 查询最多等待 30 秒并仅终止本次 launcher；启动 readiness 最多 10 秒，launcher 提前退出立即报错。仍需真实 HTTP readiness 和 token 就绪才进入连接流程，等待期间窗口保持响应。

### Windows 探针资源一致性（2026-09-23，Issue #241）

桌面分发的 daemon、nodeprobe、Pi 扩展与两份 corpus 必须符合 daemon 实际内嵌的同一份 accepted manifest；构建门禁拒绝任一哈希或大小漂移。同步更新 WSL bundle revision，使同版本重装也会替换旧能力清单的 daemon，禁止靠兼容多个插件 hash 掩盖资源错配。

Provider 分类由已验真的 nodeprobe 与 canonical corpus 负责。删除旧 Go provider table 的桌面注入补丁和字符串标识断言；它们对应的上游模块已移除，不作为新 daemon 的交付要求。

### Windows 终端选区复制（2026-09-23，Issue #257）

终端有非空选区时，Ctrl+C 与 Ctrl+Shift+C 同步触发 xterm 的系统 copy 事件，复制原始选区文本并阻止 PTY 输入。无选区的 Ctrl+C 保持中断语义；无选区的 Ctrl+Shift+C 不改剪贴板、不向终端输入。复制失败显示提示，选区保留供重试。macOS 快捷键语义保持不变。
