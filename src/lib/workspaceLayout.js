/**
 * 工作区与分屏布局核心引擎（UI-SPEC §4.1.1 & §6.1，2026-09-15 裁定）
 *
 * 采用全局单 Tab 会话池 + 一棵二叉分屏树 + 同父平铺常驻舞台。
 * 纯函数计算几何坐标，增删节点时兄弟节点自动吸收提升。
 */

const STORAGE_KEY = 'am.workspace.v1';
const MAX_READ_BYTES = 256 * 1024; // 256 KiB
const MAX_NODES = 512;
const MAX_DEPTH = 128;

/**
 * 创建初始空白工作区状态
 * @returns {WorkspaceState}
 */
export function createInitialWorkspace({ tabs = [], activeUid = null, root = null } = {}) {
  return {
    version: 1,
    tabs: Array.isArray(tabs) ? tabs.map((t) => ({ uid: t.uid, pinned: !!t.pinned })) : [],
    activeUid: typeof activeUid === 'string' ? activeUid : null,
    root: root || null,
  };
}

/**
 * 遍历获取树中的所有叶子 uid（按先序/中序遍历）
 * @param {Object|null} node
 * @returns {string[]}
 */
export function getLeaves(node) {
  if (!node) return [];
  if (node.kind === 'leaf') return node.uid ? [node.uid] : [];
  if (node.kind === 'split') {
    return [...getLeaves(node.first), ...getLeaves(node.second)];
  }
  return [];
}

/**
 * 检查某 uid 是否是树中的可见叶子
 * @param {Object|null} node
 * @param {string} uid
 * @returns {boolean}
 */
export function findLeaf(node, uid) {
  if (!node || !uid) return false;
  if (node.kind === 'leaf') return node.uid === uid;
  if (node.kind === 'split') {
    return findLeaf(node.first, uid) || findLeaf(node.second, uid);
  }
  return false;
}

/**
 * 从二叉树中删除指定叶子节点。
 * 兄弟节点自动吸收提升占满原矩形，保留兄弟内部 ratio，递归自然消除空祖先。
 *
 * @param {Object|null} node
 * @param {string} uid
 * @returns {Object|null}
 */
export function removeNode(node, uid) {
  if (!node) return null;
  if (node.kind === 'leaf') return node.uid === uid ? null : node;
  if (node.kind === 'split') {
    const first = removeNode(node.first, uid);
    const second = removeNode(node.second, uid);
    if (!first) return second;
    if (!second) return first;
    return first === node.first && second === node.second
      ? node
      : { ...node, first, second };
  }
  return node;
}

/**
 * 替换指定叶子节点
 * @param {Object|null} node
 * @param {string} targetUid
 * @param {string} newUid
 * @returns {Object|null}
 */
export function replaceLeaf(node, targetUid, newUid) {
  if (!node) return null;
  if (node.kind === 'leaf') {
    return node.uid === targetUid ? { kind: 'leaf', uid: newUid } : node;
  }
  if (node.kind === 'split') {
    const first = replaceLeaf(node.first, targetUid, newUid);
    const second = replaceLeaf(node.second, targetUid, newUid);
    return first === node.first && second === node.second
      ? node
      : { ...node, first, second };
  }
  return node;
}

/**
 * 切分指定叶子节点为分裂节点
 *
 * @param {Object|null} node
 * @param {string} targetUid
 * @param {string} newUid
 * @param {Object} [options]
 * @param {'x'|'y'} [options.axis='x'] 'x'=左右切分, 'y'=上下切分
 * @param {number} [options.ratio=0.5]
 * @param {boolean} [options.insertAfter=true] true: newUid 在后（右/下）；false: newUid 在前（左/上）
 * @returns {Object}
 */
export function splitLeaf(node, targetUid, newUid, { axis = 'x', ratio = 0.5, insertAfter = true } = {}) {
  if (!node) return { kind: 'leaf', uid: newUid };
  if (node.kind === 'leaf') {
    if (node.uid === targetUid) {
      const first = insertAfter ? { kind: 'leaf', uid: targetUid } : { kind: 'leaf', uid: newUid };
      const second = insertAfter ? { kind: 'leaf', uid: newUid } : { kind: 'leaf', uid: targetUid };
      return { kind: 'split', axis, ratio, first, second };
    }
    return node;
  }
  if (node.kind === 'split') {
    const first = splitLeaf(node.first, targetUid, newUid, { axis, ratio, insertAfter });
    const second = splitLeaf(node.second, targetUid, newUid, { axis, ratio, insertAfter });
    return first === node.first && second === node.second
      ? node
      : { ...node, first, second };
  }
  return node;
}

/**
 * 拖放原子重排候选树（Drop 算子）
 * 校验 source != target → 移除 source → 按 target 再定位目标 → 插入新 split
 *
 * @param {Object|null} root
 * @param {string} sourceUid
 * @param {string} targetUid
 * @param {'left'|'right'|'top'|'bottom'} [edge='right']
 * @returns {Object|null}
 */
export function dropNode(root, sourceUid, targetUid, edge = 'right') {
  if (!root || !sourceUid || !targetUid || sourceUid === targetUid) return root;
  const clean = removeNode(root, sourceUid);
  if (!clean || !findLeaf(clean, targetUid)) return root;
  const axis = (edge === 'left' || edge === 'right') ? 'x' : 'y';
  const insertAfter = (edge === 'right' || edge === 'bottom');
  return splitLeaf(clean, targetUid, sourceUid, { axis, ratio: 0.5, insertAfter });
}

/**
 * 纯数学几何投影：将二叉分屏树投影为屏幕绝对像素矩形 Map
 *
 * 切分规则（UI-SPEC §4 & 顾问报告 §4）：
 * usable = size - gap;
 * first = Math.floor(usable * ratio);
 * second = usable - first;
 * 第二块起点 = x + first + gap;
 * 余数全部归第二块，零裂缝、零重叠。
 *
 * @param {Object|null} node
 * @param {{ x: number, y: number, w: number, h: number }} rect
 * @param {number} [gap=1]
 * @returns {Record<string, { x: number, y: number, w: number, h: number }>}
 */
export function project(node, rect, gap = 1) {
  const result = {};
  if (!node || !rect || rect.w <= 0 || rect.h <= 0) return result;

  function recurse(n, r) {
    if (!n || r.w <= 0 || r.h <= 0) return;
    if (n.kind === 'leaf') {
      result[n.uid] = { x: r.x, y: r.y, w: r.w, h: r.h };
      return;
    }
    if (n.kind === 'split') {
      const isX = n.axis === 'x';
      const size = isX ? r.w : r.h;
      const usable = Math.max(0, size - gap);
      const ratio = (Number.isFinite(n.ratio) && n.ratio > 0 && n.ratio < 1) ? n.ratio : 0.5;
      const firstSize = Math.floor(usable * ratio);
      const secondSize = usable - firstSize;

      if (isX) {
        recurse(n.first, { x: r.x, y: r.y, w: firstSize, h: r.h });
        recurse(n.second, { x: r.x + firstSize + gap, y: r.y, w: secondSize, h: r.h });
      } else {
        recurse(n.first, { x: r.x, y: r.y, w: r.w, h: firstSize });
        recurse(n.second, { x: r.x, y: r.y + firstSize + gap, w: r.w, h: secondSize });
      }
    }
  }

  recurse(node, rect);
  return result;
}

/* ——— 状态转换 Actions ——— */

/**
 * 打开会话（侧栏点击或激活）
 * 1. 若未在 tabs 中，追加到非固定区末尾（或 pinned 区末尾）
 * 2. 若已是可见叶子，仅聚焦
 * 3. 若树为空，创建根叶子并聚焦
 * 4. 若未在树中显示，替换当前 activeUid 所在叶子（若 activeUid 不在树中，替换第一个叶子）
 */
export function openSession(state, uid, { pin = false } = {}) {
  if (!uid) return state;

  let newTabs = state.tabs || [];
  const existingTab = newTabs.find((t) => t.uid === uid);
  if (!existingTab) {
    if (pin) {
      const pinnedIdx = newTabs.filter((t) => t.pinned).length;
      newTabs = [
        ...newTabs.slice(0, pinnedIdx),
        { uid, pinned: true },
        ...newTabs.slice(pinnedIdx),
      ];
    } else {
      newTabs = [...newTabs, { uid, pinned: false }];
    }
  }

  // 检查是否已经在树中
  if (findLeaf(state.root, uid)) {
    return {
      ...state,
      tabs: newTabs,
      activeUid: uid,
    };
  }

  // 树为空
  if (!state.root) {
    return {
      ...state,
      tabs: newTabs,
      activeUid: uid,
      root: { kind: 'leaf', uid },
    };
  }

  // 替换当前焦点叶子
  const targetUid = state.activeUid && findLeaf(state.root, state.activeUid)
    ? state.activeUid
    : getLeaves(state.root)[0];

  const newRoot = targetUid
    ? replaceLeaf(state.root, targetUid, uid)
    : { kind: 'leaf', uid };

  return {
    ...state,
    tabs: newTabs,
    activeUid: uid,
    root: newRoot,
  };
}

/**
 * 点击已存在的 Tab 标签
 */
export function focusTab(state, uid) {
  return openSession(state, uid);
}

/**
 * 分裂展示会话（二分分屏）
 */
export function splitSession(state, targetUid, newUid, { axis = 'x', ratio = 0.5, insertAfter = true } = {}) {
  if (!newUid) return state;

  let newTabs = state.tabs || [];
  if (!newTabs.some((t) => t.uid === newUid)) {
    newTabs = [...newTabs, { uid: newUid, pinned: false }];
  }

  // 保证同一会话在树中唯一：如果 newUid 已在树中，先移除
  let cleanRoot = removeNode(state.root, newUid);

  let newRoot;
  if (!cleanRoot) {
    newRoot = { kind: 'leaf', uid: newUid };
  } else {
    const splitTarget = targetUid && findLeaf(cleanRoot, targetUid)
      ? targetUid
      : (state.activeUid && findLeaf(cleanRoot, state.activeUid) ? state.activeUid : getLeaves(cleanRoot)[0]);

    newRoot = splitLeaf(cleanRoot, splitTarget, newUid, { axis, ratio, insertAfter });
  }

  return {
    ...state,
    tabs: newTabs,
    activeUid: newUid,
    root: newRoot,
  };
}

/**
 * 关闭标签页（关闭并移除 Tab 及树中的该叶子）
 */
export function closeTab(state, uid) {
  if (!uid) return state;

  const oldTabs = state.tabs || [];
  const tabIdx = oldTabs.findIndex((t) => t.uid === uid);
  const newTabs = oldTabs.filter((t) => t.uid !== uid);

  const newRoot = removeNode(state.root, uid);
  const remainingLeaves = getLeaves(newRoot);

  let newActiveUid = state.activeUid;
  if (state.activeUid === uid || !remainingLeaves.includes(state.activeUid)) {
    if (remainingLeaves.length > 0) {
      newActiveUid = remainingLeaves[0];
    } else if (newTabs.length > 0) {
      // 树空了但还有其他 Tab：激活临近 Tab 并作为单叶子重建舞台
      const fallbackIdx = Math.min(tabIdx >= 0 ? tabIdx : 0, newTabs.length - 1);
      newActiveUid = newTabs[fallbackIdx].uid;
      return {
        ...state,
        tabs: newTabs,
        activeUid: newActiveUid,
        root: { kind: 'leaf', uid: newActiveUid },
      };
    } else {
      newActiveUid = null;
    }
  }

  return {
    ...state,
    tabs: newTabs,
    activeUid: newActiveUid,
    root: newRoot,
  };
}

/**
 * 仅关闭当前分屏（保留在 Tab 列表中）
 */
export function closePane(state, uid) {
  if (!uid || !findLeaf(state.root, uid)) return state;

  const newRoot = removeNode(state.root, uid);
  const remainingLeaves = getLeaves(newRoot);

  let newActiveUid = state.activeUid;
  if (state.activeUid === uid) {
    newActiveUid = remainingLeaves[0] || null;
  }

  return {
    ...state,
    activeUid: newActiveUid,
    root: newRoot,
  };
}

/**
 * 钉选/取消钉选 Tab
 * 保持 pinned 是 tabs 数组的连续前缀
 */
export function pinTab(state, uid, pinned = true) {
  const tabs = state.tabs || [];
  const tab = tabs.find((t) => t.uid === uid);
  if (!tab || tab.pinned === pinned) return state;

  const pinnedTabs = tabs.filter((t) => t.pinned && t.uid !== uid);
  const unpinnedTabs = tabs.filter((t) => !t.pinned && t.uid !== uid);

  let newTabs;
  if (pinned) {
    newTabs = [...pinnedTabs, { uid, pinned: true }, ...unpinnedTabs];
  } else {
    newTabs = [...pinnedTabs, { uid, pinned: false }, ...unpinnedTabs];
  }

  return {
    ...state,
    tabs: newTabs,
  };
}

/**
 * 关闭其他未钉选的 Tab
 */
export function closeOtherTabs(state, keepUid) {
  const tabs = state.tabs || [];
  const keepTab = tabs.find((t) => t.uid === keepUid);
  if (!keepTab) return state;

  // 保留所有 pinned tab 以及当前 keepUid
  const newTabs = tabs.filter((t) => t.pinned || t.uid === keepUid);
  const removedUids = tabs.filter((t) => !t.pinned && t.uid !== keepUid).map((t) => t.uid);

  let newRoot = state.root;
  for (const uid of removedUids) {
    newRoot = removeNode(newRoot, uid);
  }

  if (!newRoot) {
    newRoot = { kind: 'leaf', uid: keepUid };
  }

  return {
    ...state,
    tabs: newTabs,
    activeUid: keepUid,
    root: newRoot,
  };
}

/**
 * 关闭右侧未钉选的 Tab
 */
export function closeRightTabs(state, uid) {
  const tabs = state.tabs || [];
  const idx = tabs.findIndex((t) => t.uid === uid);
  if (idx === -1 || idx >= tabs.length - 1) return state;

  // 仅关闭该 Tab 右侧的未钉选 Tab
  const toRemove = [];
  const newTabs = [];

  for (let i = 0; i < tabs.length; i++) {
    const t = tabs[i];
    if (i > idx && !t.pinned) {
      toRemove.push(t.uid);
    } else {
      newTabs.push(t);
    }
  }

  let newRoot = state.root;
  for (const rUid of toRemove) {
    newRoot = removeNode(newRoot, rUid);
  }

  const leaves = getLeaves(newRoot);
  let newActive = state.activeUid;
  if (!leaves.includes(newActive)) {
    newActive = leaves[0] || uid;
  }

  if (!newRoot) {
    newRoot = { kind: 'leaf', uid: newActive };
  }

  return {
    ...state,
    tabs: newTabs,
    activeUid: newActive,
    root: newRoot,
  };
}

/**
 * 拖拽重排 Tab 顺序
 */
export function reorderTabs(state, fromIndex, toIndex) {
  const tabs = [...(state.tabs || [])];
  if (fromIndex < 0 || fromIndex >= tabs.length || toIndex < 0 || toIndex >= tabs.length || fromIndex === toIndex) {
    return state;
  }

  const [moved] = tabs.splice(fromIndex, 1);
  tabs.splice(toIndex, 0, moved);

  // 保证 pinned 连续前缀性质
  const pinnedTabs = tabs.filter((t) => t.pinned);
  const unpinnedTabs = tabs.filter((t) => !t.pinned);

  return {
    ...state,
    tabs: [...pinnedTabs, ...unpinnedTabs],
  };
}

/* ——— 校验、持久化与向后迁移 ——— */

/**
 * 验证树结构合法性（防递归爆栈、未知版本或非法节点）
 */
function validateNode(node, depth = 0, nodeCount = { count: 0 }) {
  if (!node || typeof node !== 'object') return false;
  nodeCount.count += 1;
  if (nodeCount.count > MAX_NODES || depth > MAX_DEPTH) return false;

  if (node.kind === 'leaf') {
    return typeof node.uid === 'string' && node.uid.length > 0;
  }
  if (node.kind === 'split') {
    if (node.axis !== 'x' && node.axis !== 'y') return false;
    if (!Number.isFinite(node.ratio) || node.ratio <= 0 || node.ratio >= 1) return false;
    return validateNode(node.first, depth + 1, nodeCount) && validateNode(node.second, depth + 1, nodeCount);
  }
  return false;
}

/**
 * 验证 WorkspaceState 对象
 * @returns {boolean}
 */
export function validateWorkspaceState(raw) {
  if (!raw || typeof raw !== 'object') return false;
  if (raw.version !== 1) return false;
  if (!Array.isArray(raw.tabs)) return false;

  const uids = new Set();
  for (const t of raw.tabs) {
    if (!t || typeof t.uid !== 'string' || !t.uid) return false;
    if (uids.has(t.uid)) return false; // uid 必须唯一
    uids.add(t.uid);
  }

  if (raw.root !== null) {
    const nodeCount = { count: 0 };
    if (!validateNode(raw.root, 0, nodeCount)) return false;
    const leaves = getLeaves(raw.root);
    // 检查叶子 uid 唯一且均在 tabs 中
    const leafSet = new Set();
    for (const l of leaves) {
      if (leafSet.has(l) || !uids.has(l)) return false;
      leafSet.add(l);
    }
  }

  if (raw.activeUid !== null) {
    if (typeof raw.activeUid !== 'string') return false;
    if (raw.root && !findLeaf(raw.root, raw.activeUid)) return false;
  }

  return true;
}

/**
 * 递归白名单节点清洗（S1 继承加固：彻底剔除节点上的非法非白名单属性）
 */
export function sanitizeNode(node) {
  if (!node || typeof node !== 'object') return null;
  if (node.kind === 'leaf') {
    return {
      kind: 'leaf',
      uid: String(node.uid),
    };
  }
  if (node.kind === 'split') {
    const first = sanitizeNode(node.first);
    const second = sanitizeNode(node.second);
    if (!first || !second) return null;
    return {
      kind: 'split',
      axis: node.axis === 'y' ? 'y' : 'x',
      ratio: Number(node.ratio) || 0.5,
      first,
      second,
    };
  }
  return null;
}

/**
 * 白名单序列化（不保存大对象、终端快照或 token，递归白名单清洗）
 */
export function serializeWorkspace(state) {
  if (!state || typeof state !== 'object') return null;
  const whitelist = {
    version: 1,
    tabs: (state.tabs || []).map((t) => ({ uid: String(t.uid), pinned: !!t.pinned })),
    activeUid: state.activeUid ? String(state.activeUid) : null,
    root: sanitizeNode(state.root),
  };
  return JSON.stringify(whitelist);
}

/**
 * 反序列化并校验
 */
export function deserializeWorkspace(jsonStr) {
  if (!jsonStr || typeof jsonStr !== 'string') return null;
  if (jsonStr.length > MAX_READ_BYTES) return null;
  try {
    const parsed = JSON.parse(jsonStr);
    if (!validateWorkspaceState(parsed)) return null;
    return {
      ...parsed,
      root: sanitizeNode(parsed.root),
    };
  } catch {
    return null;
  }
}

/**
 * 从旧版 am.panes / am.activePane 迁移为左到右等宽 x 树
 * 首叶 ratio = 1/n，余 n-1 递归，使得所有列绝对等宽
 */
export function migrateLegacyPanes(paneKeys, activeKey) {
  const keys = Array.isArray(paneKeys) ? paneKeys.filter((k) => typeof k === 'string' && k) : [];
  if (keys.length === 0) {
    return createInitialWorkspace();
  }

  const tabs = keys.map((uid) => ({ uid, pinned: false }));

  function buildEqualXTree(list) {
    if (list.length === 0) return null;
    if (list.length === 1) return { kind: 'leaf', uid: list[0] };
    const ratio = 1 / list.length;
    return {
      kind: 'split',
      axis: 'x',
      ratio,
      first: { kind: 'leaf', uid: list[0] },
      second: buildEqualXTree(list.slice(1)),
    };
  }

  const root = buildEqualXTree(keys);
  const activeUid = keys.includes(activeKey) ? activeKey : keys[0];

  return {
    version: 1,
    tabs,
    activeUid,
    root,
  };
}

/**
 * 从 Storage 恢复工作区（优先读 am.workspace.v1，无新键时平滑迁移旧键）
 */
export function loadWorkspaceFromStorage(storage = (typeof localStorage !== 'undefined' ? localStorage : null)) {
  if (!storage) return createInitialWorkspace();

  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (raw) {
      const state = deserializeWorkspace(raw);
      if (state) return state;
    }
  } catch {
    // 忽略异常，降级到迁移或默认
  }

  // 尝试读取旧键迁移
  try {
    const oldPanesRaw = storage.getItem('am.panes');
    const oldActiveRaw = storage.getItem('am.activePane');
    if (oldPanesRaw) {
      const oldPanes = JSON.parse(oldPanesRaw);
      const oldActive = oldActiveRaw ? JSON.parse(oldActiveRaw) : null;
      const migrated = migrateLegacyPanes(oldPanes, oldActive);
      if (validateWorkspaceState(migrated)) {
        saveWorkspaceToStorage(migrated, storage);
        return migrated;
      }
    }
  } catch {
    // 忽略
  }

  return createInitialWorkspace();
}

/**
 * 持久化到 Storage
 */
export function saveWorkspaceToStorage(state, storage = (typeof localStorage !== 'undefined' ? localStorage : null)) {
  if (!storage || !state) return;
  try {
    const serialized = serializeWorkspace(state);
    if (serialized) {
      storage.setItem(STORAGE_KEY, serialized);
    }
  } catch {
    // 隐私模式或配额满时静默忽略
  }
}
