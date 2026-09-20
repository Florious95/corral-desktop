import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { DeviceManager } from './core/devices.js';
import { isLocalUrl } from './core/local.js';
import { geomTrace } from './term/geomTrace.js';
import {
  CloseLeftIcon, CloseRightIcon, PlusIcon, SplitIcon, StarIcon, StarOutline, TerminalIcon, XIcon, PinIcon, SidebarIcon, ReflowIcon,
} from './lib/icons.jsx';

import TitleBar from './components/chrome/TitleBar.jsx';
import TabBar from './components/chrome/TabBar.jsx';
import WindowsWindowControls from './components/chrome/WindowsWindowControls.jsx';
import WslBootstrapCard from './components/chrome/WslBootstrapCard.jsx';
import DevicesPopover from './components/chrome/DevicesPopover.jsx';
import AddDeviceDialog from './components/chrome/AddDeviceDialog.jsx';
import PairingDialog from './components/chrome/PairingDialog.jsx';
import NewAgentDialog from './components/chrome/NewAgentDialog.jsx';
import CloseAgentDialog from './components/chrome/CloseAgentDialog.jsx';
import ContextMenu from './components/chrome/ContextMenu.jsx';
import Toast from './components/chrome/Toast.jsx';
import { watchFullscreen } from './lib/fullscreen.js';
import { createSurfaceGeometryWatcher } from './lib/surfaceGeometry.js';
import { createInputAckGate, submitPaneEnter, ACK_TIMEOUT, ACK_CLEARED } from './term/inputAckGate.js';
import Sidebar from './components/sidebar/Sidebar.jsx';
import SplitPanes from './components/terminal/SplitPanes.jsx';
import TerminalPane from './components/terminal/TerminalPane.jsx';
import {
  loadWorkspaceFromStorage,
  saveWorkspaceToStorage,
  createMultiWorkspace,
  createWorkspaceTab,
  switchWorkspaceTab,
  closeWorkspaceTab,
  openSessionInActiveTab,
  splitSessionInActiveTab,
  pinWorkspaceTab,
  reorderWorkspaceTabs,
  closeOtherWorkspaceTabs,
  closeRightWorkspaceTabs,
  getAllWorkspaceSessions,
  smartOpenSession,
  closeWorkspacePane,
  removeSessionFromWorkspace,
  focusWorkspacePane,
  getLeaves,
  openSession,
  focusTab,
  splitSession,
  closePane,
  pinTab,
  closeOtherTabs,
  closeRightTabs,
  dropNode,
  reorderTabs,
  findLeaf,
  removeNode,
} from './lib/workspaceLayout.js';
import { TabDragController } from './lib/tabDrag.js';
import { getAgentFavKey, isAgentFav, toggleAgentFav } from './lib/favorites.js';
import { nativeCapabilities } from './core/nativeCapabilities.js';
import {
  readCtrlV, readClipboardFiles, formatClipboardFiles, textFromPasteEvent,
} from './term/clipboard.js';

/** 关闭动画时长（token --d-close），行消失后延迟卸载 */
const CLOSE_MS = 190;
const LIFECYCLE_TIMEOUT_MS = 10000;
/** 右键菜单夹取尺寸（UI-SPEC §4.5） */
const MENU_W = 180, MENU_H = 168;

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

export default function App({ seedDevices } = {}) {
  /* ——— 协议层：DeviceManager 是 UI 与 Client 之间的唯一边界 ——— */
  const binaryListeners = useRef(new Set());
  const presenceListeners = useRef(new Set());
  const ackGate = useRef(null);
  if (ackGate.current === null) ackGate.current = createInputAckGate();
  const prevDevState = useRef(new Map());
  const dmRef = useRef(null);

  const [devices, setDevices] = useState([]);
  const [workspaces, setWorkspaces] = useState([]);
  const [toastMsg, setToastMsg] = useState(null);
  const [lifecycleEvent, setLifecycleEvent] = useState(null);
  const [createPending, setCreatePending] = useState(null);
  const [closePending, setClosePending] = useState(null);
  const closePendingRef = useRef(null);
  closePendingRef.current = closePending;
  const activeCloseRef = useRef(null);
  const [dismissedUids, setDismissedUids] = useState(new Set());
  const [closeConfirmAgent, setCloseConfirmAgent] = useState(null);
  const lifecycleTimerRef = useRef(new Map());
  const [capabilityRevision, setCapabilityRevision] = useState(0);

  const toastInputFail = (reason) => {
    setToastMsg(reason === 'timeout' ? '未收到回执' : `发送失败：${reason || '未知原因'}`);
  };

  const onErrorRef = useRef(null);

  if (dmRef.current === null) {
    dmRef.current = new DeviceManager({
      seedDevices,
      autoLocal: true,
      onModelChange: (ws) => setWorkspaces(ws),
      onDeviceChange: (ds) => {
        for (const d of ds) {
          const prev = prevDevState.current.get(d.id);
          prevDevState.current.set(d.id, d.state);
          if (prev && prev !== d.state) ackGate.current.flush();
        }
        setDevices(ds);
      },
      onBinary: (evt) => { for (const fn of binaryListeners.current) fn(evt) },
      onPresenceUpdate: (evt) => { for (const fn of presenceListeners.current) fn(evt); },
      onInputResult: (r) => {
        ackGate.current.onInputResult(r);
        // ack 一到就要让用户看见失败（C-077 / R-54）；超时/清场文案由 submitPaneEnter 发
        if (!r.ok && r.reason !== ACK_TIMEOUT && r.reason !== ACK_CLEARED) toastInputFail(r.reason);
      },
      onLifecycleResult: (r) => setLifecycleEvent({ ...r, nonce: `${Date.now()}-${Math.random()}` }),
      onCapabilityChange: () => setCapabilityRevision((v) => v + 1),
      // ⛔ message 由 DeviceManager 保证不含 token
      onError: (err) => onErrorRef.current?.(err),
    });
  }
  const dm = dmRef.current;

  /* ——— UI 本地态 ——— */
  const [favs, setFavs] = useState(() => LS.read('am.fav', []));
  const [workspace, setWorkspace] = useState(() => loadWorkspaceFromStorage());
  const workspaceRef = useRef(workspace);
  workspaceRef.current = workspace;

  const activeKey = workspace.activeUid;
  const visibleLeaves = useMemo(() => getLeaves(workspace.root), [workspace.root]);
  const visibleLeavesRef = useRef(visibleLeaves);
  visibleLeavesRef.current = visibleLeaves;

  const liveAgentKeysRef = useRef(new Set());
  const pendingPasteRef = useRef(new Map());
  const [selected, setSelected] = useState(() => LS.read('am.selected', 'all'));
  const [collapsed, setCollapsed] = useState(() => LS.read('am.collapsed', false));
  const [nativeFullscreen, setNativeFullscreen] = useState(false);
  const [spacesOpen, setSpacesOpen] = useState(() => LS.read('am.spacesOpen', true));
  const [agentsOpen, setAgentsOpen] = useState(() => LS.read('am.agentsOpen', true));

  const [devicesOpen, setDevicesOpen] = useState(false);
  const [addDeviceOpen, setAddDeviceOpen] = useState(false);
  const [pairingOpen, setPairingOpen] = useState(false);
  const [pairingPayload, setPairingPayload] = useState(null);
  const [newAgentSpace, setNewAgentSpace] = useState(null);
  const [menu, setMenu] = useState(null); // { kind:'space'|'agent'|'tab'|'pane', id, x, y }

  const stageRef = useRef(null);
  const overlayRef = useRef(null);
  const ghostRef = useRef(null);
  const [draggingUid, setDraggingUid] = useState(null);
  const workspaceRevisionRef = useRef(0);

  const dragCtrl = useRef(null);
  if (!dragCtrl.current) {
    dragCtrl.current = new TabDragController({
      getStageEl: () => stageRef.current,
      getTabBarEl: () => document.querySelector('.tb-tabbar'),
      getTabs: () => workspaceRef.current.tabs,
      getRoot: () => workspaceRef.current.root,
      getRevision: () => workspaceRevisionRef.current,
      onDropSplit: (sourceUid, targetUid, edge, startRevision, startRoot) => {
        setWorkspace((prev) => {
          const snapshot = (typeof startRevision === 'object' && startRevision !== null) ? startRevision : null;
          const revVal = snapshot ? snapshot.revision : startRevision;
          const expectedRoot = startRoot || snapshot?.root;

          // 原子校验（顾问 R2）：
          if (revVal !== undefined && workspaceRevisionRef.current !== revVal) {
            return prev;
          }
          if (expectedRoot && prev?.root !== expectedRoot) {
            return prev;
          }
          return splitSessionInActiveTab(prev, targetUid, sourceUid, edge);
        });
      },
      onReorderTabs: (fromIndex, toIndex, startRevision, sourceUid, startTabs) => {
        setWorkspace((prev) => {
          const snapshot = (typeof startRevision === 'object' && startRevision !== null) ? startRevision : null;
          const revVal = snapshot ? snapshot.revision : startRevision;
          const expectedUid = sourceUid || snapshot?.sourceUid;
          const expectedTabs = startTabs || snapshot?.tabs;

          // 1. 来源 Tab 校验：必须与当前 prev.tabs[fromIndex] 的 uid 吻合
          if (expectedUid && prev?.tabs && (prev.tabs[fromIndex]?.id !== expectedUid && prev.tabs[fromIndex]?.uid !== expectedUid)) {
            return prev;
          }
          // 2. tabs 完整快照校验：若排队更新导致 tabs 变动，安全取消
          if (expectedTabs && (!prev?.tabs || prev.tabs.length !== expectedTabs.length || prev.tabs.some((t, i) => (t.id || t.uid) !== (expectedTabs[i]?.id || expectedTabs[i]?.uid)))) {
            return prev;
          }
          // 3. 版本校验
          if (revVal !== undefined && workspaceRevisionRef.current !== revVal) {
            return prev;
          }
          // 4. 索引越界保护
          if (!prev?.tabs || fromIndex < 0 || fromIndex >= prev.tabs.length || toIndex < 0 || toIndex >= prev.tabs.length) {
            return prev;
          }
          if (typeof startRevision === 'number' && prev.tabs.length < startRevision) {
            return prev;
          }
          return reorderTabs(prev, fromIndex, toIndex);
        });
      },
      onStateChange: (state, info) => {
        setDraggingUid(state === 'dragging' ? info?.uid : null);
      },
      onOpenTab: (uid) => {
        setWorkspace((prev) => openSessionInActiveTab(prev, uid));
      },
    });
  }

  useEffect(() => {
    if (dragCtrl.current && overlayRef.current && ghostRef.current) {
      dragCtrl.current.mountOverlays(overlayRef.current, ghostRef.current);
    }
    return () => dragCtrl.current?.dispose();
  }, []);

  const handleTabPointerDown = useCallback((e, tab, title) => {
    dragCtrl.current?.start(e, tab, title);
  }, []);

  const handleAgentPointerDown = useCallback((e, ag) => {
    dragCtrl.current?.start(e, { uid: ag.key }, ag.title, { instant: true });
  }, []);

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

  useEffect(() => {
    let off;
    watchFullscreen(setNativeFullscreen).then((u) => { off = u; });
    return () => { if (typeof off === 'function') off(); };
  }, []);

  const surfaceWatcherRef = useRef(null);
  useEffect(() => {
    const watcher = createSurfaceGeometryWatcher();
    surfaceWatcherRef.current = watcher;
    return () => {
      watcher.dispose();
      surfaceWatcherRef.current = null;
    };
  }, []);

  useEffect(() => {
    surfaceWatcherRef.current?.disarm();
    surfaceWatcherRef.current?.schedule();
  }, [collapsed, workspace.tabs, nativeFullscreen]);

  useEffect(() => { LS.write('am.fav', favs) }, [favs]);
  useEffect(() => {
    workspaceRevisionRef.current += 1;
    saveWorkspaceToStorage(workspace);
  }, [workspace]);
  useEffect(() => { LS.write('am.selected', selected) }, [selected]);
  useEffect(() => {
    dragCtrl.current?.cancel('sidebar-toggle');
    LS.write('am.collapsed', collapsed);
  }, [collapsed]);
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

  const spaces = useMemo(() => workspaces.map((w) => {
    const rawSessions = w.sessions || [];
    const sessions = dismissedUids.size > 0
      ? rawSessions.filter((s) => !dismissedUids.has(s.uid))
      : rawSessions;
    const workingCount = sessions.filter((s) => s.state === 'working' || s.status === 'working').length;
    const hasWorking = workingCount > 0;
    const hasIdle = sessions.some((s) => s.state === 'idle' || s.status === 'idle');
    const state = hasWorking ? 'working' : (hasIdle ? 'idle' : (w.aggregateState || 'unknown'));

    return {
      key: w.spaceKey,
      deviceId: w.deviceId,
      deviceName: w.deviceName,
      deviceLocal: !!localById.get(w.deviceId),
      cwd: w.cwd,
      name: w.label,
      count: sessions.length,
      workingCount,
      state,
      sessions,
    };
  }), [workspaces, localById, dismissedUids]);

  const newAgentTarget = useMemo(
    () => workspaces.find((w) => w.spaceKey === newAgentSpace) || null,
    [workspaces, newAgentSpace],
  );
  const newAgentLaunchers = useMemo(
    () => newAgentTarget ? dm.getAgentLaunchers(newAgentTarget.deviceId) : [],
    [dm, newAgentTarget, capabilityRevision],
  );

  const favSet = useMemo(() => new Set(favs), [favs]);

  const allAgents = useMemo(() => {
    const out = [];
    for (const w of workspaces) {
      for (const s of w.sessions || []) {
        if (dismissedUids.has(s.uid)) continue;
        // 服务端协议中，s.name 是权威提取的准确会话展示名（如 "桌面端leader"）；
        // s.title 仅作为底层的 OSC 窗口外壳兜底。
        const sessionName = s.name || s.title || '';
        const curStatus = s.state || s.status || 'unknown';
        out.push({
          key: s.uid,
          ref: s.ref,
          uid: s.uid,
          deviceId: w.deviceId,
          deviceName: w.deviceName,
          deviceLocal: !!localById.get(w.deviceId),
          spaceKey: w.spaceKey,
          spaceName: w.label,
          title: sessionName,
          // DeviceManager already projects the authoritative DTO provider;
          // do not let the display title override it in the UI layer.
          provider: s.provider,
          state: curStatus,
          status: curStatus,
          fav: isAgentFav(w.spaceKey, s, favSet),
        });
      }
    }
    return out;
  }, [workspaces, localById, favSet, dismissedUids]);

  const agentByKey = useMemo(() => new Map(allAgents.map((a) => [a.key, a])), [allAgents]);
  const favCount = useMemo(() => allAgents.reduce((count, agent) => count + (agent.fav ? 1 : 0), 0), [allAgents]);
  const allWorkingCount = useMemo(() => (
    allAgents.filter((a) => a.state === 'working' || a.status === 'working').length
  ), [allAgents]);
  const favWorkingCount = useMemo(() => (
    allAgents.filter((a) => a.fav && (a.state === 'working' || a.status === 'working')).length
  ), [allAgents]);
  liveAgentKeysRef.current = new Set(allAgents.map((a) => a.key));

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
        setWorkspace((prev) => removeSessionFromWorkspace(prev, a.key));
        shims.current.delete(a.key);
        pendingPasteRef.current.delete(a.key);
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
    () => visibleLeaves.map((k) => agentByKey.get(k)).filter(Boolean),
    [visibleLeaves, agentByKey],
  );

  const activeAgent = (activeKey && agentByKey.get(activeKey)) || panes[0] || null;
  const openKeys = useMemo(() => getAllWorkspaceSessions(workspace), [workspace]);

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

  /* ——— Windows WSL 2 自动环境自检与连接自愈状态机 ——— */
  const [wslState, setWslState] = useState('idle'); // 'idle' | 'checking' | 'starting' | 'unready' | 'error'
  const [wslEnvStatus, setWslEnvStatus] = useState(null);
  const [wslError, setWslError] = useState('');
  const wslHealedRef = useRef(false);

  const checkAndHealWsl = useCallback(async () => {
    if (nativeCapabilities.platform !== 'windows') return;
    setWslState('checking');
    setWslError('');
    try {
      const status = await nativeCapabilities.wsl.checkEnvironment();
      setWslEnvStatus(status);
      if (!status.wsl_installed || !status.ubuntu_installed || !status.tmux_installed) {
        setWslState('unready');
        return;
      }
      if (!status.service_installed) {
        setWslState('unready');
        return;
      }
      if (!status.service_running) {
        setWslState('starting');
        try {
          await nativeCapabilities.wsl.startService('agentmirrord');
        } catch (err) {
          try {
            await nativeCapabilities.wsl.startService('corral-core');
          } catch (e2) {
            setWslState('error');
            setWslError(e2?.message || '无法启动会话服务');
            return;
          }
        }
      } else {
        setWslState('starting');
      }
      dm.connectAll();
    } catch (err) {
      setWslState('error');
      setWslError(err?.message || 'WSL 检测异常');
    }
  }, [dm]);

  useEffect(() => {
    const isWin = nativeCapabilities.platform === 'windows';
    if (!isWin) return;

    if (anyDeviceOnline) {
      setWslState('idle');
      wslHealedRef.current = false;
      return;
    }

    if (!wslHealedRef.current && wslState === 'idle') {
      wslHealedRef.current = true;
      checkAndHealWsl();
    }
  }, [anyDeviceOnline, checkAndHealWsl, wslState]);

  /* ——— WSL 2 启动期 1s 轮询自愈探测与 8s 超时看门狗保护 ——— */
  useEffect(() => {
    if (wslState !== 'starting') return;
    if (anyDeviceOnline) {
      setWslState('idle');
      return;
    }

    const pollTimer = setInterval(async () => {
      try {
        const status = await nativeCapabilities.wsl.checkEnvironment();
        setWslEnvStatus(status);
        if (status?.service_running) {
          dm.connectAll();
        }
      } catch (_) {
        // 轮询异常静默忽略，等待看门狗或下一次轮询
      }
    }, 1000);

    const watchdogTimer = setTimeout(() => {
      setWslState('error');
      setWslError('会话服务启动超时（8秒内未就绪），请检查 WSL 服务运行状态');
    }, 8000);

    return () => {
      clearInterval(pollTimer);
      clearTimeout(watchdogTimer);
    };
  }, [wslState, anyDeviceOnline, dm]);

  /* ——— level2：选中某个 Space 才订二级状态流（一台设备同时只能订一个 cwd） ——— */
  useEffect(() => {
    if (selected === 'all' || selected === 'fav') {
      dm.unsubscribeLevel2();
      return;
    }
    dm.subscribeLevel2(selected);
    return () => {
      const sep = String(selected).indexOf('::');
      if (sep >= 0) {
        dm.unsubscribeLevel2(selected.slice(0, sep));
      } else {
        dm.unsubscribeLevel2();
      }
    };
  }, [dm, selected]);

  /* ——— 会话动作 ——— */
  const openAgent = useCallback((key) => {
    if (dragCtrl.current?.suppressClickUntil && Date.now() < dragCtrl.current.suppressClickUntil) {
      return;
    }
    geomTrace('activate', { ref: key });
    setWorkspace((prev) => smartOpenSession(prev, key));
  }, []);

  const toggleFav = useCallback((agent) => {
    setFavs((prev) => toggleAgentFav(prev, agent.spaceKey, agent));
  }, []);

  const openNewAgentDialog = useCallback((spaceKey) => {
    const target = workspaces.find((w) => w.spaceKey === spaceKey);
    const anchor = target?.sessions?.find((session) => `${target.deviceId}::${session.ref}` === activeKey)
      || target?.sessions?.[0];
    if (!anchor?.ref) {
      setToastMsg('该目录没有可用的 Agent 锚点');
      return;
    }
    setNewAgentSpace(spaceKey);
  }, [workspaces, activeKey]);

  const handleCreateAgent = useCallback(({ name, provider, bypass }) => {
    const target = newAgentTarget;
    const anchor = target?.sessions?.find((session) => `${target.deviceId}::${session.ref}` === activeKey)
      || target?.sessions?.[0];
    const anchorRef = anchor?.ref;
    if (!target || !anchorRef) {
      setToastMsg('该目录没有可用的 Agent 锚点');
      return;
    }
    const result = dm.createAgent({
      deviceId: target.deviceId,
      workspace: target.cwd,
      anchorRef,
      provider,
      name,
      bypass,
    });
    if (!result) {
      setToastMsg('创建请求未发送：设备未连接');
      return;
    }
    const timerKey = `create:${result.deviceId}:${result.reqId}`;
    clearTimeout(lifecycleTimerRef.current.get(timerKey));
    lifecycleTimerRef.current.set(timerKey, setTimeout(() => {
      lifecycleTimerRef.current.delete(timerKey);
      setCreatePending((pending) => (
        pending?.deviceId === result.deviceId && pending.reqId === result.reqId ? null : pending
      ));
      setToastMsg('创建请求超时，等待会话列表确认');
    }, LIFECYCLE_TIMEOUT_MS));
    setCreatePending(result);
  }, [dm, newAgentTarget, activeKey]);

  const handleUnsupportedClose = useCallback((closingUid, deviceId, reqId) => {
    const targetUid = closingUid || activeCloseRef.current?.uid || closePendingRef.current?.uid;
    const targetDeviceId = deviceId || activeCloseRef.current?.deviceId || closePendingRef.current?.deviceId;
    const targetReqId = reqId || activeCloseRef.current?.reqId || closePendingRef.current?.reqId;

    if (targetDeviceId && targetReqId) {
      const timerKey = `close:${targetDeviceId}:${targetReqId}`;
      clearTimeout(lifecycleTimerRef.current.get(timerKey));
      lifecycleTimerRef.current.delete(timerKey);
    }
    activeCloseRef.current = null;
    closePendingRef.current = null;
    setClosePending(null);

    if (targetUid) {
      setDismissedUids((prev) => new Set([...prev, targetUid]));
      setWorkspace((prev) => removeSessionFromWorkspace(prev, targetUid));
      shims.current.delete(targetUid);
      pendingPasteRef.current.delete(targetUid);
    }
    setToastMsg('服务端当前不支持远端销毁会话，已从工作台移出');
  }, []);

  onErrorRef.current = ({ deviceId, code, message }) => {
    const isUnsupported = code === 'unsupported_type'
      || code === 'unknown frame type'
      || message?.includes('unsupported_type')
      || message?.includes('unknown frame type');

    if (isUnsupported && (activeCloseRef.current || closePendingRef.current)) {
      handleUnsupportedClose();
      return;
    }
    setToastMsg(code === 'auth' ? message : `${code}：${message}`);
  };

  const submitCloseAgent = useCallback((agent) => {
    setCloseConfirmAgent(null);
    if (!agent?.key) return;
    if (activeCloseRef.current || closePending) {
      setToastMsg('已有关闭请求处理中');
      return;
    }
    const result = dm.closeSession(agent.key);
    if (!result) {
      setToastMsg('关闭请求未发送：设备未连接');
      return;
    }
    const pendingObj = { ...result, uid: agent.key, agent };
    activeCloseRef.current = pendingObj;
    closePendingRef.current = pendingObj;
    setClosePending(pendingObj);

    const timerKey = `close:${result.deviceId}:${result.reqId}`;
    clearTimeout(lifecycleTimerRef.current.get(timerKey));
    lifecycleTimerRef.current.set(timerKey, setTimeout(() => {
      lifecycleTimerRef.current.delete(timerKey);
      if (activeCloseRef.current?.deviceId === result.deviceId && activeCloseRef.current?.reqId === result.reqId) {
        activeCloseRef.current = null;
        closePendingRef.current = null;
      }
      setClosePending((pending) => (
        pending?.deviceId === result.deviceId && pending.reqId === result.reqId ? null : pending
      ));
      setToastMsg('关闭请求超时，状态待核');
    }, LIFECYCLE_TIMEOUT_MS));
  }, [dm, closePending]);

  const closeAgent = useCallback((agent) => {
    if (!agent?.key) return;
    if (closePending) {
      setToastMsg('已有关闭请求处理中');
      return;
    }
    setCloseConfirmAgent(agent);
  }, [closePending]);

  useEffect(() => {
    if (!lifecycleEvent) return;
    const { kind, deviceId, reqId, payload } = lifecycleEvent;
    if (kind === 'create_agent_result' && createPending?.deviceId === deviceId && createPending.reqId === reqId && !createPending.ref) {
      const timerKey = `create:${deviceId}:${reqId}`;
      if (payload.ok === true && payload.ref) {
        // The result confirms tmux creation, not catalog publication. Keep the
        // dialog pending until listing/list_delta contains this exact ref.
        setCreatePending({ deviceId, reqId, ref: payload.ref });
      } else if (payload.ok === true) {
        clearTimeout(lifecycleTimerRef.current.get(timerKey));
        lifecycleTimerRef.current.delete(timerKey);
        setCreatePending(null);
        setToastMsg('Agent 创建结果缺少会话引用，状态待核');
      } else {
        const labels = {
          invalid_field: '名称或目标参数无效',
          target_not_found: '创建位置已失效，请刷新目录',
          provider_unavailable: '当前设备不支持该 Agent',
          unsupported_bypass: '该 Agent 不支持 Bypass',
          launch_failed: 'Agent 创建未确认，请刷新会话列表',
        };
        clearTimeout(lifecycleTimerRef.current.get(timerKey));
        lifecycleTimerRef.current.delete(timerKey);
        setToastMsg(labels[payload.reason] || `Agent 创建失败：${payload.reason || '未知原因'}`);
        setCreatePending(null);
      }
    }
    if (kind === 'close_session_result') {
      const isTarget = (activeCloseRef.current?.deviceId === deviceId && activeCloseRef.current?.reqId === reqId)
        || (closePending?.deviceId === deviceId && closePending.reqId === reqId);
      if (isTarget && !closePending?.awaitingListing) {
        const timerKey = `close:${deviceId}:${reqId}`;
        if (payload.ok === true) {
          // Keep the workspace reference until the authoritative listing removes
          // this ref; the existing disappearance effect then performs cleanup.
          setClosePending((prev) => (prev ? { ...prev, awaitingListing: true } : { deviceId, reqId, awaitingListing: true }));
        } else {
          clearTimeout(lifecycleTimerRef.current.get(timerKey));
          lifecycleTimerRef.current.delete(timerKey);
          const closingUid = activeCloseRef.current?.uid || closePending?.uid;
          const isUnsupported = payload.reason === 'unsupported_type'
            || payload.reason === 'unknown frame type'
            || payload.code === 'unsupported_type';

          if (isUnsupported) {
            handleUnsupportedClose(closingUid, deviceId, reqId);
          } else {
            activeCloseRef.current = null;
            closePendingRef.current = null;
            setClosePending(null);
            setToastMsg(`Agent 关闭失败：${payload.reason || '未知原因'}`);
          }
        }
      }
    }
  }, [lifecycleEvent, createPending, closePending]);

  useEffect(() => {
    if (!createPending?.ref) return;
    const uid = `${createPending.deviceId}::${createPending.ref}`;
    if (!agentByKey.has(uid)) return;
    const timerKey = `create:${createPending.deviceId}:${createPending.reqId}`;
    clearTimeout(lifecycleTimerRef.current.get(timerKey));
    lifecycleTimerRef.current.delete(timerKey);
    setWorkspace((prev) => smartOpenSession(prev, uid));
    setNewAgentSpace(null);
    setCreatePending(null);
    setToastMsg('Agent 已创建');
  }, [createPending, agentByKey]);

  useEffect(() => {
    if (!closePending?.awaitingListing || agentByKey.has(closePending.uid)) return;
    const timerKey = `close:${closePending.deviceId}:${closePending.reqId}`;
    clearTimeout(lifecycleTimerRef.current.get(timerKey));
    lifecycleTimerRef.current.delete(timerKey);
    // The listing disappearance effect owns the 190ms exit animation and
    // removes the pane/subscription after it settles. Only resolve the request
    // here, after the authoritative delta has arrived.
    setClosePending(null);
    setToastMsg('Agent 已关闭');
  }, [closePending, agentByKey]);

  useEffect(() => () => {
    for (const timer of lifecycleTimerRef.current.values()) clearTimeout(timer);
    lifecycleTimerRef.current.clear();
  }, []);

  const handleSelectTab = useCallback((uid) => {
    if (dragCtrl.current?.suppressClickUntil && Date.now() < dragCtrl.current.suppressClickUntil) {
      return;
    }
    setWorkspace((prev) => switchWorkspaceTab(prev, uid));
  }, []);

  const handleCloseTab = useCallback((uid) => {
    setWorkspace((prev) => closeWorkspaceTab(prev, uid));
    shims.current.delete(uid);
    pendingPasteRef.current.delete(uid);
  }, []);

  const handleCreateTab = useCallback(() => {
    setWorkspace((prev) => createWorkspaceTab(prev));
  }, []);

  const handlePinTab = useCallback((uid, pinned) => {
    setWorkspace((prev) => pinWorkspaceTab(prev, uid, pinned));
  }, []);

  const handleCloseOtherTabs = useCallback((uid) => {
    setWorkspace((prev) => closeOtherWorkspaceTabs(prev, uid));
  }, []);

  const handleCloseRightTabs = useCallback((uid) => {
    setWorkspace((prev) => closeRightWorkspaceTabs(prev, uid));
  }, []);

  // Cmd+T 全局新建工作台快捷键
  useEffect(() => {
    const handleGlobalKeyDown = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 't') {
        e.preventDefault();
        handleCreateTab();
      }
    };
    window.addEventListener('keydown', handleGlobalKeyDown);
    return () => window.removeEventListener('keydown', handleGlobalKeyDown);
  }, [handleCreateTab]);

  const handleClosePane = useCallback((uid) => {
    setWorkspace((prev) => closeWorkspacePane(prev, uid));
  }, []);

  const handleFocusPane = useCallback((uid) => {
    setWorkspace((prev) => {
      if (prev?.previewUid && prev.previewUid === uid) {
        return prev;
      }
      return focusWorkspacePane(prev, uid);
    });
  }, []);

  /* ——— 每个分裂列拿一个 Client 形状的薄 shim（按 uid 路由到 DeviceManager） ——— */
  const shims = useRef(new Map());
  const clientFor = useCallback((agent) => {
    let shim = shims.current.get(agent.key);
    if (!shim) {
      const uid = agent.key;
      shim = {
        get isReady() { return dm.isReady(agent.deviceId) },
        subscribe: (_ref, rows, cols, reason, opts) => dm.subscribe(uid, rows, cols, reason, opts),
        unsubscribe: () => dm.unsubscribe(uid),
        resize: (_ref, rows, cols, reason) => dm.resize(uid, rows, cols, reason),
        scrollWheel: (_ref, delta) => dm.scrollWheel(uid, delta),
        scrollback: (_ref, fromLine, count) => dm.scrollback(uid, fromLine, count)?.reqId ?? null,
        getPresence: () => dm.getPresence(uid),
        /** 监听本会话的 presence 变化（是否有手机在线等） */
        onPresence: (fn) => {
          const handler = (evt) => { if (evt.uid === uid) fn(evt); };
          presenceListeners.current.add(handler);
          return () => presenceListeners.current.delete(handler);
        },
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

  /* ——— 原生输入：xterm onData → 该列 uid ——— */
  const uidReady = useCallback((uid) => {
    const i = String(uid).indexOf('::');
    const deviceId = i === -1 ? uid : uid.slice(0, i);
    return dm.isReady(deviceId);
  }, [dm]);

  const handlePaneText = useCallback((uid, text) => {
    if (!uidReady(uid)) { setToastMsg('未连接，未发送'); return }
    const sent = dm.input(uid, text);
    if (!sent) { setToastMsg('未发送'); return }
    ackGate.current.noteText(uid, sent);
  }, [dm, uidReady]);

  const handlePaneKey = useCallback((uid, key) => {
    if (!uidReady(uid)) { setToastMsg('未连接，未发送'); return }
    ackGate.current.takePending(uid);
    if (!dm.keys(uid, key)) setToastMsg('未发送');
  }, [dm, uidReady]);

  const handlePaneBytes = useCallback((uid, bytes) => {
    if (!uidReady(uid)) { setToastMsg('未连接，未发送'); return }
    if (!dm.inputBytes(uid, bytes)) setToastMsg('未发送');
  }, [dm, uidReady]);

  const paneCanSend = useCallback((uid) => (
    visibleLeavesRef.current.includes(uid)
      && liveAgentKeysRef.current.has(uid)
      && uidReady(uid)
  ), [uidReady]);

  const handlePaneEnter = useCallback(async (uid) => {
    const pendingPaste = pendingPasteRef.current.get(uid);
    if (pendingPaste) await pendingPaste.catch(() => {});
    if (!paneCanSend(uid)) return;
    await submitPaneEnter({
      ready: true,
      pending: ackGate.current.takePending(uid),
      waitAck: (sent) => ackGate.current.waitAck(sent),
      sendBareEnter: () => dm.input(uid, ''),
      onToast: setToastMsg,
    });
  }, [dm, paneCanSend]);

  const handleAttachment = useCallback(async (uid, attachment) => {
    if (!uidReady(uid)) { setToastMsg('未连接，图片未发送'); return; }
    try {
      await dm.uploadAndPreview(uid, attachment);
    } catch (e) {
      setToastMsg(e?.message || '图片上传失败');
    }
  }, [dm, uidReady]);

  const handlePaneCtrlV = useCallback(async (uid) => {
    const isWindows = nativeCapabilities.platform === 'windows';
    const result = await readCtrlV();
    if (result.kind === 'image') {
      await handleAttachment(uid, result.attachment);
      return;
    }

    if (isWindows) {
      let files = null;
      try {
        files = await readClipboardFiles();
      } catch {}
      if (files?.length) {
        try {
          const paths = formatClipboardFiles(files);
          if (paths && paneCanSend(uid)) {
            handlePaneText(uid, paths);
            return;
          }
        } catch (e) {
          setToastMsg(e?.message || '文件路径无法粘贴');
          return;
        }
      }
      let text = '';
      try {
        text = await nativeCapabilities.clipboard.readText();
      } catch {}
      if (text && paneCanSend(uid)) {
        handlePaneText(uid, text);
        return;
      }
      return;
    }

    setToastMsg('Ctrl+V 仅支持图片，请使用 Cmd+V 粘贴文字');
  }, [handleAttachment, handlePaneText, paneCanSend]);

  const handlePanePaste = useCallback((uid, event) => {
    const text = textFromPasteEvent(event);
    const previous = pendingPasteRef.current.get(uid) || Promise.resolve();
    const pendingPaste = previous.catch(() => {}).then(async () => {
      let files = null;
      try {
        files = await readClipboardFiles();
      } catch {
        // A native reader error must not break ordinary browser text paste.
      }
      if (!paneCanSend(uid)) return;
      if (files?.length) {
        try {
          const paths = formatClipboardFiles(files);
          if (paths) handlePaneText(uid, paths);
        } catch (e) {
          setToastMsg(e?.message || '文件路径无法粘贴');
        }
        return;
      }
      if (text) handlePaneText(uid, text);
      else setToastMsg('图片请用 Ctrl+V');
    });
    pendingPasteRef.current.set(uid, pendingPaste);
    pendingPaste.then(
      () => { if (pendingPasteRef.current.get(uid) === pendingPaste) pendingPasteRef.current.delete(uid); },
      () => { if (pendingPasteRef.current.get(uid) === pendingPaste) pendingPasteRef.current.delete(uid); },
    );
    return pendingPaste;
  }, [handlePaneText, paneCanSend]);

  const renderPane = useCallback((agent) => (
    <TerminalPane
      agent={agent}
      client={clientFor(agent)}
      focused={activeAgent ? agent.key === activeAgent.key : false}
      onText={(text) => handlePaneText(agent.key, text)}
      onKey={(key) => handlePaneKey(agent.key, key)}
      onBytes={(bytes) => handlePaneBytes(agent.key, bytes)}
      onEnter={() => handlePaneEnter(agent.key)}
      onCtrlV={() => handlePaneCtrlV(agent.key)}
      onPaste={(event) => handlePanePaste(agent.key, event)}
    />
  ), [clientFor, activeAgent, dm, handlePaneText, handlePaneKey, handlePaneBytes, handlePaneEnter, handlePaneCtrlV, handlePanePaste]);

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

  const handlePairMobile = useCallback(() => {
    setDevicesOpen(false);
    setPairingPayload(dm.createPairingPayload() || dm.createPairingDraft());
    setPairingOpen(true);
  }, [dm]);

  const savePairingToken = useCallback((token) => {
    dm.savePairingToken(token);
  }, [dm]);

  const closePairing = useCallback(() => {
    setPairingOpen(false);
    setPairingPayload(null);
  }, []);

  /* ——— 右键菜单 ——— */
  const closeMenu = useCallback(() => setMenu(null), []);

  const triggerReflow = useCallback((uid) => {
    if (!uid) return;
    if (typeof window !== 'undefined') {
      window.dispatchEvent(new CustomEvent('terminal:reflow', { detail: { uid } }));
    }
  }, []);

  const handleReflowTab = useCallback((tabKey) => {
    const tab = workspace.tabs.find((t) => (t.id || t.uid) === tabKey);
    const uids = tab
      ? ((tab.root && typeof tab.root === 'object') ? getLeaves(tab.root) : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : [])))
      : [tabKey];
    for (const uid of uids) {
      triggerReflow(uid);
    }
  }, [workspace.tabs, triggerReflow]);

  const handleReflowPane = useCallback((uid) => {
    triggerReflow(uid);
  }, [triggerReflow]);

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

  const handleSpaceMenu = useCallback((e, key) => {
    if (key === 'all' || key === 'fav') { e.preventDefault(); return; }
    openMenu(e, 'space', key);
  }, [openMenu]);
  const handleAgentMenu = useCallback((e, key) => openMenu(e, 'agent', key), [openMenu]);

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
        onClick: () => { closeMenu(); openNewAgentDialog(space?.key); },
      }];
    }

    if (menu.kind === 'agent') {
      const agent = agentByKey.get(menu.id);
      if (!agent) return [];
      return [
        {
          key: 'fav',
          label: agent.fav ? '取消收藏' : '收藏',
          icon: agent.fav
            ? <StarIcon size={14} fill="currentColor" />
            : icon(StarOutline),
          color: agent.fav ? 'var(--amber-deep)' : 'var(--text)',
          onClick: () => { closeMenu(); toggleFav(agent); },
        },
        {
          key: 'close',
          label: '关闭',
          icon: icon(XIcon, { strokeWidth: 2 }),
          color: 'var(--danger)',
          separator: true,
          disabled: closePending?.uid === agent.key,
          onClick: () => { closeMenu(); closeAgent(agent); },
        },
      ];
    }

    if (menu.kind === 'tab') {
      const tab = workspace.tabs.find((t) => (t.id || t.uid) === menu.id);
      const isPinned = !!tab?.pinned;
      const tabIdx = workspace.tabs.findIndex((t) => (t.id || t.uid) === menu.id);
      const unpinnedCount = workspace.tabs.filter((t) => !t.pinned).length;

      return [
        {
          key: 'reflow',
          label: '适应当前窗口',
          icon: icon(ReflowIcon),
          color: 'var(--text)',
          onClick: () => { closeMenu(); handleReflowTab(menu.id); },
        },
        {
          key: 'pin',
          label: isPinned ? '取消固定' : '固定到最左',
          icon: icon(PinIcon),
          color: 'var(--text)',
          onClick: () => { closeMenu(); handlePinTab(menu.id, !isPinned); },
        },
        {
          key: 'close-tab',
          label: '关闭工作台',
          icon: icon(XIcon, { strokeWidth: 2 }),
          color: 'var(--danger)',
          separator: true,
          onClick: () => { closeMenu(); handleCloseTab(menu.id); },
        },
        {
          key: 'close-others',
          label: '关闭其他工作台',
          icon: icon(XIcon, { strokeWidth: 2 }),
          color: 'var(--text)',
          disabled: unpinnedCount <= 1 || isPinned,
          onClick: () => { closeMenu(); handleCloseOtherTabs(menu.id); },
        },
        {
          key: 'close-right',
          label: '关闭右侧所有工作台',
          icon: icon(CloseRightIcon),
          color: 'var(--text)',
          disabled: tabIdx < 0 || tabIdx >= workspace.tabs.length - 1,
          onClick: () => { closeMenu(); handleCloseRightTabs(menu.id); },
        },
      ];
    }

    // pane
    const agent = agentByKey.get(menu.id);
    const unvisibleTabs = workspace.tabs.filter((t) => !visibleLeaves.includes(t.uid));
    return [
      {
        key: 'reflow',
        label: '适应当前窗口',
        icon: icon(ReflowIcon),
        color: 'var(--text)',
        onClick: () => { closeMenu(); handleReflowPane(menu.id); },
      },
      {
        key: 'split-right',
        label: '向右分屏',
        icon: icon(SplitIcon),
        color: 'var(--text)',
        disabled: unvisibleTabs.length === 0,
        onClick: () => {
          closeMenu();
          if (unvisibleTabs.length > 0) {
            setWorkspace((prev) => splitSession(prev, menu.id, unvisibleTabs[0].uid, { axis: 'x', ratio: 0.5 }));
          }
        },
      },
      {
        key: 'split-down',
        label: '向下分屏',
        icon: icon(SplitIcon),
        color: 'var(--text)',
        disabled: unvisibleTabs.length === 0,
        onClick: () => {
          closeMenu();
          if (unvisibleTabs.length > 0) {
            setWorkspace((prev) => splitSession(prev, menu.id, unvisibleTabs[0].uid, { axis: 'y', ratio: 0.5 }));
          }
        },
      },
      {
        key: 'fav',
        label: agent?.fav ? '取消收藏' : '收藏',
        icon: agent?.fav
          ? <StarIcon size={14} fill="currentColor" />
          : icon(StarOutline),
        color: agent?.fav ? 'var(--amber-deep)' : 'var(--text)',
        onClick: () => { if (agent) { closeMenu(); toggleFav(agent); } },
      },
      {
        key: 'close-pane',
        label: '关闭此分屏',
        icon: icon(XIcon, { strokeWidth: 2 }),
        color: 'var(--danger)',
        separator: true,
        disabled: visibleLeaves.length <= 1,
        onClick: () => { closeMenu(); handleClosePane(menu.id); },
      },
    ];
  }, [
    menu,
    spaces,
    agentByKey,
    workspace,
    visibleLeaves,
    closeMenu,
    openNewAgentDialog,
    toggleFav,
    closeAgent,
    closePending,
    handlePinTab,
    handleReflowTab,
    handleReflowPane,
    handleCloseTab,
    handleCloseOtherTabs,
    handleCloseRightTabs,
    handleClosePane,
  ]);

  const noDevices = devices.length === 0;
  const isWindows = nativeCapabilities.platform === 'windows';

  return (
    <div className={`app-root${collapsed ? ' is-collapsed' : ''}${nativeFullscreen ? ' is-fullscreen' : ''}`}>
      <div className="app-body">
        <div className={`app-left${collapsed ? ' is-collapsed' : ''}`}>
          <TitleBar
            fullscreen={nativeFullscreen}
            sidebarCollapsed={collapsed}
            onToggleSidebar={() => setCollapsed((v) => !v)}
          />
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
            allWorkingCount={allWorkingCount}
            favCount={favCount}
            favWorkingCount={favWorkingCount}
            closing={closing}
            openKeys={openKeys}
            onSpaceMenu={handleSpaceMenu}
            onNewAgent={openNewAgentDialog}
            onAgentMenu={handleAgentMenu}
            onOpenAgent={openAgent}
            onAgentPointerDown={handleAgentPointerDown}
            activeUid={workspace.activeUid}
            deviceLabel={deviceLabel}
            anyDeviceOnline={anyDeviceOnline}
            onToggleDevices={() => setDevicesOpen((v) => !v)}
            multiDevice={multiDevice}
          />
        </div>

        <main className="app-main">
          <header className={`tb-session-header${collapsed ? ' is-sidebar-collapsed' : ''}${isWindows ? ' is-windows' : ''}`} data-tauri-drag-region="deep">
            {collapsed && (
              <>
                {!isWindows && <div className="tb-traffic-lights" aria-hidden="true" />}
                <button
                  type="button"
                  className="tb-btn tb-sidebar-toggle"
                  data-tauri-drag-region="false"
                  title="展开侧栏"
                  aria-label="展开侧栏"
                  onClick={() => setCollapsed(false)}
                >
                  <SidebarIcon size={16} strokeWidth={1.8} />
                </button>
              </>
            )}
            <TabBar
              tabs={workspace.tabs}
              activeTabId={workspace.activeTabId}
              activeUid={workspace.activeUid}
              visibleUids={visibleLeaves}
              draggingUid={draggingUid}
              agentsByUid={agentByKey}
              onSelectTab={handleSelectTab}
              onCloseTab={handleCloseTab}
              onCreateTab={handleCreateTab}
              onContextMenu={(e, tab) => openMenu(e, 'tab', tab.id || tab.uid)}
              onPointerDown={handleTabPointerDown}
            />
            {/* 顶部长按拖窗收敛至原生 data-tauri-drag-region="deep"，由 Tauri 官方 drag.js 原生触发 startDragging */}
            <div className="tb-drag" />
            {isWindows && <WindowsWindowControls fullscreen={nativeFullscreen} />}
          </header>

          <div className="main-stage-container">
            {isWindows && !anyDeviceOnline && wslState !== 'idle' ? (
              <WslBootstrapCard
                state={wslState}
                envStatus={wslEnvStatus}
                errorMsg={wslError}
                onRetry={checkAndHealWsl}
              />
            ) : noDevices ? (
              <div className="app-empty">
                <div className="app-empty-icon"><TerminalIcon size={20} /></div>
                <div className="app-empty-title">还没有添加设备</div>
                <div className="app-empty-sub">连接一台运行 agentmirrord 的机器，开始镜像它的 Agent</div>
                <button type="button" className="app-empty-btn" onClick={() => setAddDeviceOpen(true)}>
                  添加设备
                </button>
              </div>
            ) : (
              <SplitPanes
                stageRef={stageRef}
                root={workspace.root}
                tabs={workspace.tabs}
                activeUid={workspace.activeUid}
                previewUid={workspace.previewUid}
                agentByKey={agentByKey}
                onFocusPane={handleFocusPane}
                onClosePane={handleClosePane}
                onPaneMenu={(e, key) => openMenu(e, 'pane', key)}
                renderPane={renderPane}
              />
            )}
          </div>
        </main>
      </div>

      {devicesOpen && (
        <DevicesPopover
          devices={popoverDevices}
          onToggle={handleToggleDevice}
          onToggleAll={handleToggleAllDevices}
          onAddDevice={() => { setDevicesOpen(false); setAddDeviceOpen(true) }}
          onPairMobile={handlePairMobile}
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

      <PairingDialog
        open={pairingOpen}
        payload={pairingPayload}
        onCancel={closePairing}
        onCopied={setToastMsg}
        onSaveToken={savePairingToken}
      />

      <NewAgentDialog
        open={newAgentSpace !== null}
        spaceName={newAgentTarget?.label || newAgentTarget?.cwd || ''}
        launchers={newAgentLaunchers}
        loading={!!createPending}
        onCreate={handleCreateAgent}
        onCancel={() => { if (!createPending) setNewAgentSpace(null); }}
      />

      <CloseAgentDialog
        open={closeConfirmAgent !== null}
        agent={closeConfirmAgent}
        loading={!!closePending}
        onConfirm={() => submitCloseAgent(closeConfirmAgent)}
        onCancel={() => { if (!closePending) setCloseConfirmAgent(null); }}
      />

      {/* 拖拽 GPU 预览浮层与吸附高亮（全屏视口级） */}
      <div ref={overlayRef} className="dropzone-overlay" aria-hidden="true" />
      <div ref={ghostRef} className="tab-drag-ghost" aria-hidden="true" />

      <Toast message={toastMsg} onDone={() => setToastMsg(null)} />
    </div>
  );
}
