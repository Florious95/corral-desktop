import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { DeviceManager } from './core/devices.js';
import { inferProvider } from './core/providers.js';
import {
  CloseLeftIcon, CloseRightIcon, PlusIcon, SplitIcon, StarIcon, StarOutline, TerminalIcon, XIcon,
} from './lib/icons.jsx';

import TitleBar from './components/chrome/TitleBar.jsx';
import DevicesPopover from './components/chrome/DevicesPopover.jsx';
import AddDeviceDialog from './components/chrome/AddDeviceDialog.jsx';
import NewAgentDialog from './components/chrome/NewAgentDialog.jsx';
import ContextMenu from './components/chrome/ContextMenu.jsx';
import Toast from './components/chrome/Toast.jsx';
import Sidebar from './components/sidebar/Sidebar.jsx';
import SplitPanes from './components/terminal/SplitPanes.jsx';
import TerminalPane from './components/terminal/TerminalPane.jsx';

/** 关闭动画时长（token --d-close），行消失后延迟卸载 */
const CLOSE_MS = 190;
/** 右键菜单夹取尺寸（UI-SPEC §4.5） */
const MENU_W = 180, MENU_H = 130;

/* ——— localStorage（前缀 am.，UI-SPEC §7.4）。设备与 token 归 DeviceManager 管，这里不碰。 ———
   ponytail: 只读写 UI 本地态，坏数据一律回落缺省值，不做迁移。 */
const LS = {
  read(key, fallback) {
    try {
      const raw = localStorage.getItem(key);
      return raw == null ? fallback : JSON.parse(raw);
    } catch { return fallback }
  },
  write(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)) } catch { /* 隐私模式/配额满：忽略 */ }
  },
};

/** ws://10.10.10.87:9900/ws → "10.10.10.87:9900 · WebSocket" */
function deviceSub(url) {
  try { return `${new URL(url).host} · WebSocket` } catch { return 'WebSocket' }
}

function isLocalUrl(url) {
  try {
    const h = new URL(url).hostname;
    return h === 'localhost' || h === '127.0.0.1' || h === '::1' || h === '[::1]';
  } catch { return false }
}

export default function App({ seedDevices } = {}) {
  /* ——— 协议层：DeviceManager 是 UI 与 Client 之间的唯一边界 ——— */
  const binaryListeners = useRef(new Set());
  const inputWaiters = useRef(new Map()); // `${deviceId}:${reqId}` → resolve（reqId 只在单设备内唯一）
  const inputAcks = useRef(new Map());    // ack 早于 waiter 登记时暂存
  const dmRef = useRef(null);

  const [devices, setDevices] = useState([]);
  const [workspaces, setWorkspaces] = useState([]);
  const [toastMsg, setToastMsg] = useState(null);

  const toastInputFail = (reason) => {
    setToastMsg(reason === 'timeout' ? '未收到回执' : `发送失败：${reason || '未知原因'}`);
  };

  if (dmRef.current === null) {
    dmRef.current = new DeviceManager({
      seedDevices,
      onModelChange: (ws) => setWorkspaces(ws),
      onDeviceChange: (ds) => setDevices(ds),
      onBinary: (evt) => { for (const fn of binaryListeners.current) fn(evt) },
      onInputResult: (r) => {
        const k = `${r.deviceId}:${r.reqId}`;
        const resolve = inputWaiters.current.get(k);
        if (resolve) { inputWaiters.current.delete(k); resolve(r) }
        else inputAcks.current.set(k, r);
        // ack 一到就要让用户看见失败（C-077 / R-54）
        if (!r.ok) toastInputFail(r.reason);
      },
      // ⛔ message 由 DeviceManager 保证不含 token
      onError: ({ code, message }) => setToastMsg(code === 'auth' ? message : `${code}：${message}`),
    });
  }
  const dm = dmRef.current;

  /* ——— UI 本地态 ——— */
  const [favs, setFavs] = useState(() => LS.read('am.fav', []));
  const [paneKeys, setPaneKeys] = useState(() => LS.read('am.panes', []));
  const [activeKey, setActiveKey] = useState(() => LS.read('am.activePane', null));
  const [selected, setSelected] = useState(() => LS.read('am.selected', 'all'));
  const [collapsed, setCollapsed] = useState(() => LS.read('am.collapsed', false));
  const [spacesOpen, setSpacesOpen] = useState(() => LS.read('am.spacesOpen', true));
  const [agentsOpen, setAgentsOpen] = useState(() => LS.read('am.agentsOpen', true));

  const [devicesOpen, setDevicesOpen] = useState(false);
  const [addDeviceOpen, setAddDeviceOpen] = useState(false);
  const [newAgentSpace, setNewAgentSpace] = useState(null);
  const [menu, setMenu] = useState(null); // { kind:'space'|'agent'|'pane', id, x, y }

  // 服务端删掉会话时的 190ms 退场动画：行先留着播动画，再卸载
  const [ghosts, setGhosts] = useState([]);
  const [closing, setClosing] = useState({});

  const started = useRef(false);
  useEffect(() => {
    if (started.current) return; // StrictMode 双挂载不重连
    started.current = true;
    dm.connectAll();
    setDevices(dm.devices);
    setWorkspaces(dm.workspaces);
  }, [dm]);

  useEffect(() => { LS.write('am.fav', favs) }, [favs]);
  useEffect(() => { LS.write('am.panes', paneKeys) }, [paneKeys]);
  useEffect(() => { LS.write('am.activePane', activeKey) }, [activeKey]);
  useEffect(() => { LS.write('am.selected', selected) }, [selected]);
  useEffect(() => { LS.write('am.collapsed', collapsed) }, [collapsed]);
  useEffect(() => { LS.write('am.spacesOpen', spacesOpen) }, [spacesOpen]);
  useEffect(() => { LS.write('am.agentsOpen', agentsOpen) }, [agentsOpen]);

  /* ——— 派生模型：AggregatedWorkspace[] → Space[] / Agent[] ——— */
  const localById = useMemo(() => {
    const m = new Map();
    for (const d of devices) m.set(d.id, isLocalUrl(d.url));
    return m;
  }, [devices]);

  const checkedCount = devices.filter((d) => d.checked).length;
  const multiDevice = checkedCount > 1;

  const spaces = useMemo(() => workspaces.map((w) => ({
    key: w.spaceKey,
    deviceId: w.deviceId,
    deviceName: w.deviceName,
    deviceLocal: !!localById.get(w.deviceId),
    cwd: w.cwd,
    name: w.label,
    count: w.sessionCount,
    state: w.aggregateState || 'unknown',
  })), [workspaces, localById]);

  const favSet = useMemo(() => new Set(favs), [favs]);

  const allAgents = useMemo(() => {
    const out = [];
    for (const w of workspaces) {
      for (const s of w.sessions || []) {
        const title = s.name || '';
        out.push({
          key: s.uid,
          ref: s.ref,
          deviceId: w.deviceId,
          deviceName: w.deviceName,
          deviceLocal: !!localById.get(w.deviceId),
          spaceKey: w.spaceKey,
          spaceName: w.label,
          title,
          provider: inferProvider(title),
          state: s.status || 'unknown',
          fav: favSet.has(`${w.spaceKey}::${title}`), // daemon 重启后 ref 会变，收藏 key 用 cwd+name
        });
      }
    }
    return out;
  }, [workspaces, localById, favSet]);

  const agentByKey = useMemo(() => new Map(allAgents.map((a) => [a.key, a])), [allAgents]);

  // 服务端删会话 → 标记 closing → CLOSE_MS 后真正卸载并剔出分裂列
  const prevAgents = useRef([]);
  const ghostTimers = useRef(new Map());
  useEffect(() => {
    const live = new Set(allAgents.map((a) => a.key));
    const vanished = prevAgents.current.filter((a) => !live.has(a.key) && !ghostTimers.current.has(a.key));
    prevAgents.current = allAgents;
    if (vanished.length === 0) return;
    setGhosts((g) => [...g, ...vanished]);
    setClosing((c) => {
      const next = { ...c };
      for (const a of vanished) next[a.key] = true;
      return next;
    });
    for (const a of vanished) {
      ghostTimers.current.set(a.key, setTimeout(() => {
        ghostTimers.current.delete(a.key);
        setGhosts((g) => g.filter((x) => x.key !== a.key));
        setClosing((c) => { const next = { ...c }; delete next[a.key]; return next });
        setPaneKeys((p) => p.filter((k) => k !== a.key));
      }, CLOSE_MS));
    }
  }, [allAgents]);

  const matchSelected = useCallback(
    (a) => (selected === 'all' ? true : selected === 'fav' ? a.fav : a.spaceKey === selected),
    [selected],
  );

  const visibleAgents = useMemo(() => [
    ...allAgents.filter(matchSelected),
    ...ghosts.filter((g) => !agentByKey.has(g.key) && matchSelected(g)),
  ], [allAgents, ghosts, agentByKey, matchSelected]);

  const panes = useMemo(
    () => paneKeys.map((k) => agentByKey.get(k)).filter(Boolean),
    [paneKeys, agentByKey],
  );

  const activeAgent = (activeKey && agentByKey.get(activeKey)) || panes[0] || null;

  /* ——— 设备派生 ——— */
  const popoverDevices = useMemo(() => devices.map((d) => ({
    id: d.id,
    name: d.name,
    url: d.url,
    checked: d.checked,
    sub: deviceSub(d.url),
    online: d.state === 'ready',
    lastError: d.lastError || null,
  })), [devices]);

  const deviceLabel = useMemo(() => {
    if (devices.length === 0) return '未添加设备';
    const on = devices.filter((d) => d.checked);
    if (on.length === devices.length) return 'All Devices';
    if (on.length === 0) return '未勾选设备';
    return on.map((d) => d.name).join(' · ');
  }, [devices]);

  const anyDeviceOnline = devices.some((d) => d.state === 'ready');

  /* ——— level2：选中某个 Space 才订二级状态流（一台设备同时只能订一个 cwd） ——— */
  useEffect(() => {
    if (selected === 'all' || selected === 'fav') return;
    dm.subscribeLevel2(selected);
  }, [dm, selected]);

  /* ——— 会话动作 ——— */
  const openAgent = useCallback((key) => {
    // 已在列里：只聚焦（U-06）。未打开：单列替换（C-053，左键不是追加）。
    setPaneKeys((p) => (p.includes(key) ? p : [key]));
    setActiveKey(key);
  }, []);

  const splitAgent = useCallback((key) => {
    setPaneKeys((p) => (p.includes(key) ? p : [...p, key]));
    setActiveKey(key);
  }, []);

  const toggleFav = useCallback((agent) => {
    const favKey = `${agent.spaceKey}::${agent.title}`;
    setFavs((f) => (f.includes(favKey) ? f.filter((k) => k !== favKey) : [...f, favKey]));
  }, []);

  const closeAgent = useCallback((key) => {
    setPaneKeys((p) => p.filter((k) => k !== key)); // 协议 v1 无 kill session：只关本地列
  }, []);

  /* ——— 每个分裂列拿一个 Client 形状的薄 shim（按 uid 路由到 DeviceManager） ——— */
  const shims = useRef(new Map());
  const clientFor = useCallback((agent) => {
    let shim = shims.current.get(agent.key);
    if (!shim) {
      const uid = agent.key;
      shim = {
        get isReady() { return dm.isReady(agent.deviceId) },
        subscribe: (_ref, rows, cols) => dm.subscribe(uid, rows, cols),
        unsubscribe: () => dm.unsubscribe(uid),
        resize: (_ref, rows, cols) => dm.resize(uid, rows, cols),
        scrollback: (_ref, fromLine, count) => dm.scrollback(uid, fromLine, count)?.reqId ?? null,
        /** 只投递本列的二进制帧；返回退订函数 */
        onBinary: (fn) => {
          const handler = (evt) => { if (evt.uid === uid) fn(evt.frame) };
          binaryListeners.current.add(handler);
          return () => binaryListeners.current.delete(handler);
        },
      };
      shims.current.set(agent.key, shim);
    }
    return shim;
  }, [dm]);

  /* ——— 原生输入：xterm onData → 该列 uid，不经底部 InputBar ——— */
  const waitAck = useCallback(
    (sent) => new Promise((resolve) => {
      const k = `${sent.deviceId}:${sent.reqId}`;
      const ready = inputAcks.current.get(k);
      if (ready) { inputAcks.current.delete(k); resolve(ready); return }
      inputWaiters.current.set(k, resolve);
    }),
    [],
  );
  const lastTextByUid = useRef(new Map());

  const uidReady = useCallback((uid) => {
    const i = String(uid).indexOf('::');
    const deviceId = i === -1 ? uid : uid.slice(0, i);
    return dm.isReady(deviceId);
  }, [dm]);

  const handlePaneText = useCallback((uid, text) => {
    if (!uidReady(uid)) { setToastMsg('未连接，未发送'); return }
    const sent = dm.input(uid, text);
    if (!sent) { setToastMsg('未发送'); return }
    lastTextByUid.current.set(uid, sent);
  }, [dm, uidReady]);

  const handlePaneKey = useCallback((uid, key) => {
    if (!uidReady(uid)) { setToastMsg('未连接，未发送'); return }
    lastTextByUid.current.delete(uid);
    if (!dm.keys(uid, key)) setToastMsg('未发送');
  }, [dm, uidReady]);

  const handlePaneEnter = useCallback(async (uid) => {
    if (!uidReady(uid)) { setToastMsg('未连接，未发送'); return }
    const pending = lastTextByUid.current.get(uid);
    lastTextByUid.current.delete(uid);
    if (pending) {
      const res = await waitAck(pending);
      if (!res.ok) return; // toast 已由 onInputResult 发出；⛔ 不把失败 enter 提交到旧缓冲
    }
    if (!dm.input(uid, '')) setToastMsg('未发送');
  }, [dm, waitAck, uidReady]);

  const renderPane = useCallback((agent) => (
    <TerminalPane
      agent={agent}
      client={clientFor(agent)}
      focused={activeAgent ? agent.key === activeAgent.key : false}
      multiDevice={multiDevice}
      onResize={(rows, cols) => dm.resize(agent.key, rows, cols)}
      onText={(text) => handlePaneText(agent.key, text)}
      onKey={(key) => handlePaneKey(agent.key, key)}
      onEnter={() => handlePaneEnter(agent.key)}
    />
  ), [clientFor, activeAgent, multiDevice, dm, handlePaneText, handlePaneKey, handlePaneEnter]);

  /* ——— 设备 ——— */
  const handleAddDevice = useCallback(({ name, url, token }) => {
    const label = name || deviceSub(url).split(' · ')[0];
    // 本期只有 Local：再走一遍 Add Device 覆盖已有的那台本机，不必做编辑对话框（C-007 / R-05）。
    const locals = dm.devices.filter((d) => isLocalUrl(d.url));
    if (isLocalUrl(url) && locals.length === 1) {
      dm.updateDevice(locals[0].id, { name: label, url, token });
    } else {
      dm.addDevice({ name: label, url, token });
    }
    dm.connectAll();
    setAddDeviceOpen(false);
    setDevices(dm.devices);
  }, [dm]);

  const handleToggleDevice = useCallback((id, next) => {
    dm.setChecked(id, next);
    setDevices(dm.devices);
  }, [dm]);

  const handleToggleAllDevices = useCallback((next) => {
    for (const d of dm.devices) dm.setChecked(d.id, next);
    setDevices(dm.devices);
  }, [dm]);

  /* ——— 右键菜单 ——— */
  const closeMenu = useCallback(() => setMenu(null), []);

  const openMenu = useCallback((e, kind, id) => {
    e.preventDefault();
    e.stopPropagation();
    setMenu({
      kind,
      id,
      x: Math.min(e.clientX, window.innerWidth - MENU_W - 8),
      y: Math.min(e.clientY, window.innerHeight - MENU_H - 8),
    });
  }, []);

  const menuItems = useMemo(() => {
    if (!menu) return [];
    const icon = (El, extra) => <El size={14} strokeWidth={1.9} {...extra} />;

    if (menu.kind === 'space') {
      const space = spaces.find((s) => s.key === menu.id);
      return [{
        key: 'new-agent',
        label: '新建 Agent',
        icon: icon(PlusIcon),
        color: 'var(--text)',
        onClick: () => { closeMenu(); setNewAgentSpace(space ? space.name : '') },
      }];
    }

    if (menu.kind === 'agent') {
      const agent = agentByKey.get(menu.id);
      if (!agent) return [];
      const inPanes = paneKeys.includes(agent.key);
      return [
        {
          key: 'split',
          label: '分裂展示',
          icon: icon(SplitIcon),
          color: 'var(--text)',
          onClick: () => { closeMenu(); splitAgent(agent.key) },
        },
        {
          key: 'fav',
          label: agent.fav ? '取消收藏' : '收藏',
          icon: agent.fav
            ? <StarIcon size={14} fill="currentColor" />
            : icon(StarOutline),
          color: agent.fav ? 'var(--amber-deep)' : 'var(--text)',
          onClick: () => { closeMenu(); toggleFav(agent) },
        },
        {
          key: 'close',
          label: '关闭',
          icon: icon(XIcon, { strokeWidth: 2 }),
          color: 'var(--danger)',
          separator: true,
          disabled: !inPanes,
          onClick: () => { closeMenu(); closeAgent(agent.key) },
        },
      ];
    }

    // pane
    const idx = paneKeys.indexOf(menu.id);
    return [
      {
        key: 'close-left',
        label: '关闭左侧所有',
        icon: icon(CloseLeftIcon),
        color: 'var(--text)',
        disabled: idx <= 0,
        onClick: () => { closeMenu(); if (idx > 0) setPaneKeys((p) => p.slice(idx)) },
      },
      {
        key: 'close-right',
        label: '关闭右侧所有',
        icon: icon(CloseRightIcon),
        color: 'var(--text)',
        disabled: idx < 0 || idx >= paneKeys.length - 1,
        onClick: () => { closeMenu(); if (idx >= 0) setPaneKeys((p) => p.slice(0, idx + 1)) },
      },
      {
        key: 'close-others',
        label: '关闭其他',
        icon: icon(XIcon, { strokeWidth: 2 }),
        color: 'var(--text)',
        disabled: paneKeys.length <= 1,
        onClick: () => { closeMenu(); setPaneKeys([menu.id]); setActiveKey(menu.id) },
      },
    ];
  }, [menu, spaces, agentByKey, paneKeys, closeMenu, splitAgent, toggleFav, closeAgent]);

  const noDevices = devices.length === 0;

  return (
    <div className="app-root">
      <TitleBar
        sidebarCollapsed={collapsed}
        onToggleSidebar={() => setCollapsed((v) => !v)}
        paneCount={panes.length}
      />

      <div className="app-body">
        <Sidebar
          collapsed={collapsed}
          spacesOpen={spacesOpen}
          onToggleSpaces={() => setSpacesOpen((v) => !v)}
          agentsOpen={agentsOpen}
          onToggleAgents={() => setAgentsOpen((v) => !v)}
          selected={selected}
          onSelect={setSelected}
          spaces={spaces}
          agents={visibleAgents}
          allCount={allAgents.length}
          favCount={allAgents.filter((a) => a.fav).length}
          closing={closing}
          openKeys={paneKeys}
          onSpaceMenu={(e, key) => {
            if (key === 'all' || key === 'fav') { e.preventDefault(); return } // 虚拟行不弹菜单
            openMenu(e, 'space', key);
          }}
          onAgentMenu={(e, key) => openMenu(e, 'agent', key)}
          onOpenAgent={openAgent}
          deviceLabel={deviceLabel}
          anyDeviceOnline={anyDeviceOnline}
          onToggleDevices={() => setDevicesOpen((v) => !v)}
          multiDevice={multiDevice}
        />

        <main className="app-main">
          {noDevices ? (
            <div className="app-empty">
              <div className="app-empty-icon"><TerminalIcon size={20} /></div>
              <div className="app-empty-title">还没有添加设备</div>
              <div className="app-empty-sub">连接一台运行 agentmirrord 的机器，开始镜像它的 Agent</div>
              <button type="button" className="app-empty-btn" onClick={() => setAddDeviceOpen(true)}>
                添加设备
              </button>
            </div>
          ) : (
            <>
              <SplitPanes
                panes={panes}
                focusedKey={activeAgent ? activeAgent.key : null}
                onFocusPane={setActiveKey}
                onClosePane={closeAgent}
                onPaneMenu={(e, key) => openMenu(e, 'pane', key)}
                renderPane={renderPane}
              />
            </>
          )}
        </main>
      </div>

      {devicesOpen && (
        <DevicesPopover
          devices={popoverDevices}
          onToggle={handleToggleDevice}
          onToggleAll={handleToggleAllDevices}
          onAddDevice={() => { setDevicesOpen(false); setAddDeviceOpen(true) }}
          onClose={() => setDevicesOpen(false)}
        />
      )}

      <ContextMenu
        open={menu !== null}
        x={menu ? menu.x : 0}
        y={menu ? menu.y : 0}
        items={menuItems}
        onClose={closeMenu}
      />

      <AddDeviceDialog
        open={addDeviceOpen}
        onSubmit={handleAddDevice}
        onCancel={() => setAddDeviceOpen(false)}
      />

      <NewAgentDialog
        open={newAgentSpace !== null}
        spaceName={newAgentSpace || ''}
        onCreate={() => {
          setNewAgentSpace(null);
          setToastMsg('当前 daemon 协议不支持远程创建 Agent'); // 协议 v1 无此帧，别去发明
        }}
        onCancel={() => setNewAgentSpace(null)}
      />

      <Toast message={toastMsg} onDone={() => setToastMsg(null)} />
    </div>
  );
}
