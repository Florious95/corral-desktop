/**
 * 工作区与分屏布局核心引擎（UI-SPEC §4.1.1 & §6.1，2026-09-15 裁定）
 *
 * 采用全局单 Tab 会话池 + 一棵二叉分屏树 + 同父平铺常驻舞台。
 * 纯函数计算几何坐标，增删节点时兄弟节点自动吸收提升。
 */

export const STORAGE_KEY = 'am.workspace.v1';
export const MULTI_WORKSPACE_STORAGE_KEY = 'am.workspace.v2';
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
 * 判断标签页是否为空白标签页
 * 空白标签页：尚未绑定会话、没有 root 终端树的占位工作台
 * @param {Object|null} tab
 * @returns {boolean}
 */
export function isBlankTab(tab) {
  if (!tab) return false;
  if (tab.isBlank === true) return true;
  if (tab.isBlank === false) return false;
  return !tab.root && (!tab.activeUid || String(tab.activeUid).startsWith('tab-'));
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
 * 获取顶层竖列（水平排列的所有列）
 * 若节点为 split 且 axis === 'x'，展开为列列表；非 x 轴切分的子树作为复合列
 */
export function getTopLevelColumns(node) {
  if (!node) return [];
  if (node.kind === 'leaf') return [node];
  if (node.kind === 'split' && node.axis === 'x') {
    return [...getTopLevelColumns(node.first), ...getTopLevelColumns(node.second)];
  }
  return [node];
}

/**
 * 递归构建 1:1:1... 均等比例的竖列分屏二叉树
 * @param {Array<Object>} columns
 * @returns {Object|null}
 */
export function buildEqualRatioColumnsTree(columns) {
  if (!columns || columns.length === 0) return null;
  if (columns.length === 1) return columns[0];
  const ratio = 1 / columns.length;
  return {
    kind: 'split',
    axis: 'x',
    ratio,
    first: columns[0],
    second: buildEqualRatioColumnsTree(columns.slice(1)),
  };
}

/**
 * 拖放原子重排候选树（Drop 算子）
 * 校验 source != target → 移除 source → 按 target 再定位目标 → 插入新 split
 *
 * 竖列均分引擎升级（2026-09-16 用户最新指示）：
 * 当在顶层横向分列（edge 为 'left' 或 'right'）追加新竖列时，
 * 自动对所有并排竖列执行均分平衡（1:1:1 绝对等宽），彻底消灭 211 或 112 畸形比例！
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

  // 1. 横向分列（left / right）：执行均等分列平衡
  if (edge === 'left' || edge === 'right') {
    const columns = getTopLevelColumns(clean);
    const targetColIdx = columns.findIndex((col) => findLeaf(col, targetUid));

    if (targetColIdx !== -1) {
      const targetCol = columns[targetColIdx];
      // 目标列若为单叶子，直接作为独立竖列并排均分插入
      if (targetCol.kind === 'leaf') {
        const newLeaf = { kind: 'leaf', uid: sourceUid };
        const insertIdx = edge === 'right' ? targetColIdx + 1 : targetColIdx;
        const nextCols = [...columns];
        nextCols.splice(insertIdx, 0, newLeaf);
        return buildEqualRatioColumnsTree(nextCols);
      }
    }
  }

  // 2. 纵向分屏（top / bottom）或局部复合窗格内部切分：按原 splitLeaf 切分
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
  if (!uid || !state) return state;

  // v2 多工作台模式下：绝对不许直接往 tabs 追加扁平对象，统一走 smartOpenSession 安全流转
  if (state.version === 2 || state.activeTabId) {
    return smartOpenSession(state, uid);
  }

  let newTabs = state.tabs || [];
  const existingTab = newTabs.find((t) => (t.id || t.uid) === uid || t.activeUid === uid);
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
 * 聚焦当前激活工作台内部的某个分屏窗格（绝不增删或修改任何 Tab 结构，彻底杜绝幽灵 Tab 与重复 Tab）
 */
export function focusWorkspacePane(state, uid) {
  if (!uid || !state) return state;

  // 多工作台模式 (v2 / activeTabId)
  if (state.tabs && (state.version === 2 || state.activeTabId)) {
    const tabs = state.tabs || [];
    const currentTab = tabs.find((t) => (t.id || t.uid) === state.activeTabId) || tabs[0];
    if (!currentTab) return state;

    // 真实成员守卫：被点击的 uid 必须真正属于当前激活工作台
    // 1. 若当前处于预览模式且被点击的是预览窗格 (uid === state.previewUid)，绝对不污染持久 Tab
    if (state.previewUid && state.previewUid === uid) {
      return state;
    }

    // 2. 检查 uid 是否为当前工作台的合法成员
    const isMember = currentTab.root
      ? !!findLeaf(currentTab.root, uid)
      : (currentTab.activeUid === uid || (!currentTab.isBlank && (currentTab.id || currentTab.uid) === uid));

    if (!isMember) {
      return state;
    }

    // 若已经就是当前聚焦的会话，严格 0 操作直接返回原引用
    if (currentTab.activeUid === uid && state.activeUid === uid) {
      return state;
    }

    // 更新当前工作台的 activeUid，保持其 root 和 pinned 属性绝对不变，严禁对 tabs 产生增删！
    const updatedTab = { ...currentTab, activeUid: uid };
    const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));
    return syncActiveTabFields({
      ...state,
      tabs: updatedTabs,
    });
  }

  // 单工作台模式 (v1)
  if (state.root && findLeaf(state.root, uid)) {
    return { ...state, activeUid: uid };
  }
  return openSession(state, uid);
}

/**
 * 聚焦已存在的会话 / 标签页
 */
export function focusTab(state, uid) {
  if (!uid || !state) return state;
  if (state.version === 2 || state.activeTabId) {
    return focusWorkspacePane(state, uid);
  }
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
  if (state && state.version === 2) {
    return closeWorkspacePane(state, uid);
  }
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
 * 检查节点是否为纯横向列排布二叉树
 */
export function isPureColumnsTree(node) {
  if (!node) return false;
  if (node.kind === 'leaf') return true;
  if (node.kind === 'split') {
    if (node.axis !== 'x') return false;
    return isPureColumnsTree(node.first) && isPureColumnsTree(node.second);
  }
  return false;
}

/**
 * 在当前激活工作台内部关闭指定分屏窗格（同步持久化到 tabs[activeTab].root）
 */
export function closeWorkspacePane(state, uid) {
  if (!uid || !state) return state;

  const tabs = state.tabs || [];
  const currentTab = tabs.find((t) => (t.id || t.uid) === state.activeTabId) || tabs[0];
  if (!currentTab || !findLeaf(currentTab.root, uid)) return state;

  // 1. 从当前 Tab 的 root 树中移除该 leaf
  const newRoot = removeNode(currentTab.root, uid);
  const remainingLeaves = getLeaves(newRoot);

  // 2. 更新当前 Tab 的焦点
  let newActiveUid = currentTab.activeUid;
  if (currentTab.activeUid === uid || !remainingLeaves.includes(currentTab.activeUid)) {
    newActiveUid = remainingLeaves[0] || null;
  }

  // 3. 若剩余窗格依然为全横向并排竖列，自动执行 1:1:1 均等平衡
  let finalRoot = newRoot;
  if (newRoot && isPureColumnsTree(newRoot) && remainingLeaves.length >= 2) {
    finalRoot = buildEqualRatioColumnsTree(remainingLeaves.map((k) => ({ kind: 'leaf', uid: k })));
  }

  const isNowBlank = !finalRoot && !newActiveUid;
  const updatedTab = {
    ...currentTab,
    root: finalRoot,
    activeUid: newActiveUid,
    isBlank: isNowBlank,
  };

  const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));

  return syncActiveTabFields({
    ...state,
    tabs: updatedTabs,
  });
}

/**
 * 从所有工作台移除已由服务端关闭的会话；不发送任何协议帧。
 */
export function removeSessionFromWorkspace(state, uid) {
  if (!uid || !state) return state;
  let changed = state.previewUid === uid;
  const tabs = (state.tabs || []).map((tab) => {
    const hasRoot = !!(tab.root && findLeaf(tab.root, uid));
    const hasFlat = !tab.root && tab.activeUid === uid;
    if (!hasRoot && !hasFlat) return tab;
    changed = true;
    const root = hasRoot ? removeNode(tab.root, uid) : null;
    const leaves = getLeaves(root);
    const activeUid = tab.activeUid === uid || !leaves.includes(tab.activeUid)
      ? (leaves[0] || null) : tab.activeUid;
    let finalRoot = root;
    if (root && isPureColumnsTree(root) && leaves.length >= 2) {
      finalRoot = buildEqualRatioColumnsTree(leaves.map((key) => ({ kind: 'leaf', uid: key })));
    }
    return {
      ...tab,
      root: finalRoot,
      activeUid,
      isBlank: !finalRoot && !activeUid,
    };
  });
  if (!changed) return state;
  return syncActiveTabFields({
    ...state,
    previewUid: state.previewUid === uid ? null : state.previewUid,
    tabs,
  });
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
  if (state.version === 2) {
    return reorderWorkspaceTabs(state, fromIndex, toIndex);
  }
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

  // v2 多工作台模式校验
  if (raw.version === 2) {
    if (!Array.isArray(raw.tabs) || raw.tabs.length === 0) return false;
    const tabIds = new Set();
    for (const t of raw.tabs) {
      const id = t.id || t.uid;
      if (typeof id !== 'string' || !id || tabIds.has(id)) return false;
      tabIds.add(id);
      if (t.root !== null && t.root !== undefined) {
        const nodeCount = { count: 0 };
        if (!validateNode(t.root, 0, nodeCount)) return false;
      }
    }
    if (raw.activeTabId && !tabIds.has(raw.activeTabId)) return false;
    return true;
  }

  // v1 单工作区模式校验
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

  if (state.version === 2) {
    const whitelist = {
      version: 2,
      activeTabId: String(state.activeTabId || (state.tabs && state.tabs[0]?.id) || 'tab-1'),
      tabs: (state.tabs || []).map((t, idx) => ({
        id: String(t.id || t.uid || `tab-${idx + 1}`),
        uid: String(t.uid || t.id || `tab-${idx + 1}`),
        name: String(t.name || ''),
        isCustomTitle: !!t.isCustomTitle,
        pinned: !!t.pinned,
        isBlank: isBlankTab(t),
        activeUid: t.activeUid ? String(t.activeUid) : null,
        root: sanitizeNode(t.root),
      })),
    };
    return JSON.stringify(whitelist);
  }

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
    if (parsed.version === 2) {
      return createMultiWorkspace({
        tabs: parsed.tabs,
        activeTabId: parsed.activeTabId,
      });
    }
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
 * 从 Storage 恢复工作区（优先读 am.workspace.v2，无新键时平滑迁移旧键）
 */
export function loadWorkspaceFromStorage(storage = (typeof localStorage !== 'undefined' ? localStorage : null)) {
  if (!storage) return createMultiWorkspace();

  try {
    const rawV2 = storage.getItem(MULTI_WORKSPACE_STORAGE_KEY);
    if (rawV2) {
      const state = deserializeWorkspace(rawV2);
      if (state) return state;
    }
  } catch {
    // 降级
  }

  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (raw) {
      const state = deserializeWorkspace(raw);
      if (state) {
        if (state.version === 1) {
          return createMultiWorkspace({
            tabs: [{ id: 'tab-1', uid: 'tab-1', name: '', root: state.root, activeUid: state.activeUid, pinned: false }],
            activeTabId: 'tab-1',
          });
        }
        return state;
      }
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
        const multi = createMultiWorkspace({
          tabs: [{ id: 'tab-1', uid: 'tab-1', name: '', root: migrated.root, activeUid: migrated.activeUid, pinned: false }],
          activeTabId: 'tab-1',
        });
        saveWorkspaceToStorage(multi, storage);
        return multi;
      }
    }
  } catch {
    // 忽略
  }

  return createMultiWorkspace();
}

import { backupUiSnapshot } from '../core/store.js';

/**
 * 持久化到 Storage
 */
export function saveWorkspaceToStorage(state, storage = (typeof localStorage !== 'undefined' ? localStorage : null)) {
  if (!storage || !state) return;
  try {
    const serialized = serializeWorkspace(state);
    if (serialized) {
      if (state.version === 2) {
        storage.setItem(MULTI_WORKSPACE_STORAGE_KEY, serialized);
      }
      storage.setItem(STORAGE_KEY, serialized);
      try { backupUiSnapshot(storage); } catch (_) {}
    }
  } catch {
    // 隐私模式或配额满时静默忽略
  }
}

/* ——— 多工作台标签页核心引擎（UI-SPEC §4.1.3，2026-09-16 用户最新最高指示） ——— */

/**
 * 辅助同步当前选中的 Tab 专属的 root 与 activeUid
 */
function syncActiveTabFields(state) {
  const tabs = state.tabs || [];
  const currentTab = tabs.find((t) => (t.id || t.uid) === state.activeTabId) || tabs[0];

  // 若处于虚空接纳槽（previewUid 存在），右侧即时映射该预览会话，上方的 tabs 稳如泰山
  if (state.previewUid) {
    return {
      ...state,
      activeTabId: currentTab ? (currentTab.id || currentTab.uid) : null,
      activeUid: state.previewUid,
      root: { kind: 'leaf', uid: state.previewUid },
    };
  }

  return {
    ...state,
    previewUid: null,
    activeTabId: currentTab ? (currentTab.id || currentTab.uid) : null,
    activeUid: currentTab ? currentTab.activeUid : null,
    root: currentTab ? currentTab.root : null,
  };
}

/**
 * 创建多工作台初始状态
 */
export function createMultiWorkspace({ tabs = null, activeTabId = null } = {}) {
  const initialTab = {
    id: 'tab-1',
    uid: 'tab-1',
    name: '',
    root: null,
    activeUid: null,
    pinned: false,
    isBlank: true,
  };

  const tabList = Array.isArray(tabs) && tabs.length > 0
    ? tabs
        .filter((t) => t && (t.id || t.uid))
        .map((t, idx) => {
          const tabId = String(t.id || t.uid || `tab-${idx + 1}`);
          const effectiveUid = t.activeUid || (t.uid && !t.uid.startsWith('tab-') ? t.uid : null);
          const sanitizedRoot = t.root ? sanitizeNode(t.root) : (effectiveUid ? { kind: 'leaf', uid: effectiveUid } : null);
          const activeUid = effectiveUid || (sanitizedRoot ? getLeaves(sanitizedRoot)[0] : null);
          const hasSession = !!(sanitizedRoot || activeUid);
          const isBlank = t.isBlank !== undefined ? !!t.isBlank : !hasSession;
          return {
            id: tabId,
            uid: tabId,
            name: String(t.name || ''),
            isCustomTitle: !!t.isCustomTitle,
            root: sanitizedRoot,
            activeUid: activeUid ? String(activeUid) : null,
            pinned: !!t.pinned,
            isBlank,
          };
        })
    : [initialTab];

  const currentTabId = activeTabId && tabList.some((t) => (t.id || t.uid) === activeTabId)
    ? activeTabId
    : (tabList[0].id || tabList[0].uid);

  return syncActiveTabFields({
    version: 2,
    previewUid: null,
    activeTabId: currentTabId,
    tabs: tabList,
  });
}

/**
 * 点击【+】新建空白工作台标签页
 */
export function createWorkspaceTab(state, { id = null, name = '', root = null, activeUid = null, pinned = false, isBlank = undefined } = {}) {
  const tabId = id || `tab-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
  const hasSession = !!(root || (activeUid && !String(activeUid).startsWith('tab-')));
  const computedIsBlank = isBlank !== undefined ? !!isBlank : !hasSession;
  const newTab = {
    id: tabId,
    uid: tabId,
    name: name || '',
    isCustomTitle: false,
    root: root ? sanitizeNode(root) : null,
    activeUid: activeUid ? String(activeUid) : null,
    pinned: !!pinned,
    isBlank: computedIsBlank,
  };

  const newTabs = [...(state.tabs || []), newTab];
  return syncActiveTabFields({
    ...state,
    previewUid: null,
    activeTabId: newTab.id,
    tabs: newTabs,
  });
}

/**
 * 切换选中的工作台标签页
 */
export function switchWorkspaceTab(state, tabId) {
  if (!tabId) return state;
  const target = (state.tabs || []).find((t) => (t.id || t.uid) === tabId);
  if (!target) return state;
  return syncActiveTabFields({
    ...state,
    previewUid: null,
    activeTabId: target.id || target.uid,
  });
}

/**
 * 关闭指定工作台标签页
 */
export function closeWorkspaceTab(state, tabId) {
  if (!tabId) return state;
  const oldTabs = state.tabs || [];
  const tabIdx = oldTabs.findIndex((t) => (t.id || t.uid) === tabId);
  if (tabIdx === -1) return state;

  const newTabs = oldTabs.filter((t) => (t.id || t.uid) !== tabId);
  // 若全部关闭，自动重置为一个初始空白工作台
  if (newTabs.length === 0) {
    return createMultiWorkspace();
  }

  let nextActiveId = state.activeTabId;
  if (state.activeTabId === tabId) {
    const fallbackIdx = Math.min(tabIdx, newTabs.length - 1);
    nextActiveId = newTabs[fallbackIdx].id || newTabs[fallbackIdx].uid;
  }

  return syncActiveTabFields({
    ...state,
    previewUid: null,
    activeTabId: nextActiveId,
    tabs: newTabs,
  });
}

/**
 * 在当前激活的工作台内部打开会话（替换当前聚焦窗格，绝对不新增 Tab）
 */
export function openSessionInActiveTab(state, sessionUid) {
  if (!sessionUid) return state;

  const tabs = state.tabs || [];
  const currentTab = tabs.find((t) => (t.id || t.uid) === state.activeTabId) || tabs[0];
  if (!currentTab) return state;

  // 1. 若已经在当前工作台的树中：仅聚焦
  if (findLeaf(currentTab.root, sessionUid)) {
    const updatedTab = { ...currentTab, activeUid: sessionUid, isBlank: false };
    const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));
    return syncActiveTabFields({ ...state, previewUid: null, tabs: updatedTabs });
  }

  // 2. 若当前工作台为空：创建根叶子
  if (!currentTab.root) {
    const updatedTab = { ...currentTab, root: { kind: 'leaf', uid: sessionUid }, activeUid: sessionUid, isBlank: false };
    const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));
    return syncActiveTabFields({ ...state, previewUid: null, tabs: updatedTabs });
  }

  // 3. 替换当前焦点窗格（或第一个窗格）
  const targetLeaf = currentTab.activeUid && findLeaf(currentTab.root, currentTab.activeUid)
    ? currentTab.activeUid
    : getLeaves(currentTab.root)[0];

  const newRoot = targetLeaf
    ? replaceLeaf(currentTab.root, targetLeaf, sessionUid)
    : { kind: 'leaf', uid: sessionUid };

  const updatedTab = { ...currentTab, root: newRoot, activeUid: sessionUid, isBlank: false };
  const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));
  return syncActiveTabFields({ ...state, previewUid: null, tabs: updatedTabs });
}

/**
 * 智能会话切换与虚空接纳槽引擎（三大铁律权威实现）
 *
 * 1. 第一铁律：全局唯一性与自动导航跳转（单实例与去重）
 *    - 无论用户当前处于哪个 Tab（包括空白卡、普通卡、分屏卡），只要点击的会话已在某个 Tab 中打开：
 *      -> 立即跳转到该 Tab 并聚焦该窗格！绝不重复打开，绝不无反应。
 * 2. 第三铁律：显式空白卡是唯一的固化槽（Commit / Pin）
 *    - 只有用户主动点击 `+` 新增了空白选项卡（且当前处于该空白卡）时：
 *      -> 点击左侧未打开过的会话，该会话才正式【固化入驻】该选项卡，转为常驻 Tab。
 * 3. 第二铁律：虚空接纳槽与右侧即时预览（快速浏览、不改 TabBar）
 *    - 当前处于非空白 Tab，用户点击未打开过的会话：
 *      -> 绝不修改、替换当前已固化的 Tab，TabBar 也绝不增加新 Tab 挤占位置！
 *      -> 激活【虚空预览槽（previewUid）】：右侧工作区立刻呈现该会话供操作，上方 TabBar 纹丝不动！
 *
 * @param {Object} state 多工作台状态
 * @param {string} sessionUid
 * @returns {Object}
 */
export function smartOpenSession(state, sessionUid) {
  if (!sessionUid || !state) return state;

  const tabs = state.tabs || [];

  // -------------------------------------------------------------
  // 第一铁律：全局唯一性与自动导航跳转（单实例去重与定位）
  // -------------------------------------------------------------
  // 遍历所有 Tab，检查该 sessionUid 是否已经在某个 Tab（包括单会话或多分屏）中打开
  const targetTab = tabs.find((t) => {
    if (!t) return false;
    if (t.root && findLeaf(t.root, sessionUid)) return true;
    return !t.root && t.activeUid === sessionUid;
  });

  if (targetTab) {
    // 立即清空虚空槽，切换到该 Tab，并聚焦该窗格
    const switched = switchWorkspaceTab({ ...state, previewUid: null }, targetTab.id || targetTab.uid);
    return focusWorkspacePane(switched, sessionUid);
  }

  // -------------------------------------------------------------
  // 该 sessionUid 尚未在任何 Tab 中打开
  // -------------------------------------------------------------
  const currentTab = tabs.find((t) => (t.id || t.uid) === state.activeTabId) || tabs[0];

  // 第三铁律：显式空白卡是唯一的固化槽（Commit / Pin）
  // 只有当前激活的 Tab 是空白卡时，该会话才正式固化入驻成为常驻 Tab
  if (currentTab && isBlankTab(currentTab)) {
    const updatedTab = {
      ...currentTab,
      root: { kind: 'leaf', uid: sessionUid },
      activeUid: sessionUid,
      isBlank: false,
    };
    const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));
    return syncActiveTabFields({
      ...state,
      previewUid: null,
      tabs: updatedTabs,
    });
  }

  // 第二铁律：虚空接纳槽与右侧即时预览（快速浏览、不改 TabBar）
  // 当前处于非空白 Tab，点击未打开会话：右侧立刻展示终端供操作，顶栏 TabBar 纹丝不动！
  return syncActiveTabFields({
    ...state,
    previewUid: sessionUid,
  });
}

/**
 * 在当前激活的工作台内部进行分屏（绝对不新增 Tab）
 */
export function splitSessionInActiveTab(state, targetUid, sessionUid, edge = 'right') {
  if (!sessionUid) return state;

  const tabs = state.tabs || [];
  const currentTab = tabs.find((t) => (t.id || t.uid) === state.activeTabId) || tabs[0];
  if (!currentTab) return state;

  const baseRoot = currentTab.root || (state.previewUid ? { kind: 'leaf', uid: state.previewUid } : null);

  if (!baseRoot || edge === 'full') {
    const updatedTab = { ...currentTab, root: { kind: 'leaf', uid: sessionUid }, activeUid: sessionUid, isBlank: false };
    const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));
    return syncActiveTabFields({ ...state, previewUid: null, tabs: updatedTabs });
  }

  const effectiveTarget = targetUid && findLeaf(baseRoot, targetUid)
    ? targetUid
    : (currentTab.activeUid && findLeaf(baseRoot, currentTab.activeUid) ? currentTab.activeUid : getLeaves(baseRoot)[0]);

  if (!effectiveTarget) return state;

  const nextRoot = dropNode(baseRoot, sessionUid, effectiveTarget, edge);
  if (!nextRoot) return state;

  const updatedTab = { ...currentTab, root: nextRoot, activeUid: sessionUid, isBlank: false };
  const updatedTabs = tabs.map((t) => ((t.id || t.uid) === (currentTab.id || currentTab.uid) ? updatedTab : t));
  return syncActiveTabFields({ ...state, previewUid: null, tabs: updatedTabs });
}

/**
 * 固定 / 取消固定工作台标签页
 */
export function pinWorkspaceTab(state, tabId, pinned = true) {
  const tabs = state.tabs || [];
  const tab = tabs.find((t) => (t.id || t.uid) === tabId);
  if (!tab || !!tab.pinned === !!pinned) return state;

  const unpinned = tabs.filter((t) => (t.id || t.uid) !== tabId && !t.pinned);
  const pinnedList = tabs.filter((t) => (t.id || t.uid) !== tabId && t.pinned);

  let newTabs;
  if (pinned) {
    newTabs = [...pinnedList, { ...tab, pinned: true }, ...unpinned];
  } else {
    newTabs = [...pinnedList, { ...tab, pinned: false }, ...unpinned];
  }

  return syncActiveTabFields({ ...state, tabs: newTabs });
}

/**
 * 调序工作台标签页（遵守 pinned 前缀不变量）
 */
export function reorderWorkspaceTabs(state, fromIndex, toIndex) {
  const tabs = [...(state.tabs || [])];
  if (fromIndex < 0 || fromIndex >= tabs.length || toIndex < 0 || toIndex >= tabs.length) return state;

  const moving = tabs[fromIndex];
  const target = tabs[toIndex];
  if (moving.pinned !== target.pinned) return state;

  tabs.splice(fromIndex, 1);
  tabs.splice(toIndex, 0, moving);

  return syncActiveTabFields({ ...state, tabs });
}

/**
 * 关闭其他工作台标签页（保留固定标签页）
 */
export function closeOtherWorkspaceTabs(state, tabId) {
  const tabs = state.tabs || [];
  const keep = tabs.filter((t) => (t.id || t.uid) === tabId || t.pinned);
  return syncActiveTabFields({
    ...state,
    activeTabId: tabId,
    tabs: keep,
  });
}

/**
 * 关闭右侧工作台标签页（保留固定标签页）
 */
export function closeRightWorkspaceTabs(state, tabId) {
  const tabs = state.tabs || [];
  const idx = tabs.findIndex((t) => (t.id || t.uid) === tabId);
  if (idx === -1) return state;

  const keep = tabs.filter((t, i) => i <= idx || t.pinned);
  return syncActiveTabFields({
    ...state,
    tabs: keep,
  });
}

/**
 * 获取所有工作台中所有正在展示的会话集合（用于侧栏开态指示）
 */
export function getAllWorkspaceSessions(state) {
  const set = new Set();
  for (const tab of state.tabs || []) {
    if (tab.root) {
      for (const uid of getLeaves(tab.root)) {
        set.add(uid);
      }
    } else if (tab.activeUid) {
      set.add(tab.activeUid);
    }
  }
  if (state?.previewUid) {
    set.add(state.previewUid);
  }
  return Array.from(set);
}

/**
 * 重命名工作台 Tab 并锁定自定义标题防覆盖（Issue #194）。
 * 用户自定义改名后，标记 isCustomTitle: true。
 * 来自 tmux 的 list_delta 与 changed_sessions 窗口重命名 (window rename) 事件绝对不覆盖锁定的自定义标题。
 */
export function renameWorkspaceTab(state, tabIdOrUid, newName, isCustomTitle = true) {
  if (!state || !Array.isArray(state.tabs)) return state;
  const nameStr = String(newName || '').trim();
  const nextTabs = state.tabs.map((t) => {
    if ((t.id || t.uid) === tabIdOrUid || t.uid === tabIdOrUid) {
      return {
        ...t,
        name: nameStr,
        isCustomTitle: Boolean(isCustomTitle && nameStr),
      };
    }
    return t;
  });
  return syncActiveTabFields({
    ...state,
    tabs: nextTabs,
  });
}

/**
 * 恢复自动标题 (Reset Title)：清除 isCustomTitle 锁定标记并清空自定义名称，恢复跟踪 tmux 窗口名。
 */
export function resetWorkspaceTabTitle(state, tabIdOrUid) {
  if (!state || !Array.isArray(state.tabs)) return state;
  const nextTabs = state.tabs.map((t) => {
    if ((t.id || t.uid) === tabIdOrUid || t.uid === tabIdOrUid) {
      return {
        ...t,
        name: '',
        isCustomTitle: false,
      };
    }
    return t;
  });
  return syncActiveTabFields({
    ...state,
    tabs: nextTabs,
  });
}

