import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  createInitialWorkspace,
  openSession,
  focusTab,
  splitSession,
  closePane,
  closeTab,
  pinTab,
  reorderTabs,
  getLeaves,
  removeNode,
  dropNode,
  project,
} from '../src/lib/workspaceLayout.js';
import {
  edgeAt,
  computePreviewRect,
  hitTestLeafPanes,
  hitTestTabBar,
  HOLD_DELAY_MS,
  TOLERANCE_PX,
  HYSTERESIS_PX,
} from '../src/lib/tabDrag.js';

const ROOT = new URL('../src/', import.meta.url);
const source = async (path) => readFile(new URL(path, ROOT), 'utf8');

function equalTabWidths(count, available, min = 44, max = 160) {
  const width = Math.max(min, Math.min(max, available / count));
  return Array.from({ length: count }, () => width);
}

function assertNoOverlapAndCovered(layout, rect, gap = 1) {
  const leaves = Object.values(layout);
  for (let i = 0; i < leaves.length; i += 1) {
    const a = leaves[i];
    assert.ok(a.w > 0 && a.h > 0);
    assert.ok(a.x >= rect.x && a.y >= rect.y);
    assert.ok(a.x + a.w <= rect.x + rect.w);
    assert.ok(a.y + a.h <= rect.y + rect.h);
    for (let j = i + 1; j < leaves.length; j += 1) {
      const b = leaves[j];
      const separated = a.x + a.w + gap <= b.x || b.x + b.w + gap <= a.x
        || a.y + a.h + gap <= b.y || b.y + b.h + gap <= a.y;
      assert.equal(separated, true, `overlap: ${JSON.stringify(a)} ${JSON.stringify(b)}`);
    }
  }
}

test('web interaction matrix: 1..8 regular tabs stay equal, bounded and ellipsis-ready', async () => {
  const css = await source('components/chrome/chrome.css');
  assert.match(css, /\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[\s\S]*?flex:\s*1 1 0px/);
  assert.match(css, /\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[\s\S]*?width:\s*160px/);
  assert.match(css, /\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[\s\S]*?min-width:\s*44px/);
  assert.match(css, /\.tb-tab-name\s*\{[\s\S]*?overflow:\s*hidden[\s\S]*?text-overflow:\s*ellipsis/);
  for (let count = 1; count <= 8; count += 1) {
    const widths = equalTabWidths(count, 960);
    assert.equal(new Set(widths).size, 1);
    assert.ok(widths[0] >= 44 && widths[0] <= 160);
  }
});

test('web interaction matrix: tab activation and close transfer focus deterministically', () => {
  let ws = createInitialWorkspace();
  for (let i = 1; i <= 4; i += 1) ws = openSession(ws, `session-${i}`);
  ws = focusTab(ws, 'session-2');
  assert.equal(ws.activeUid, 'session-2');
  ws = closeTab(ws, 'session-2');
  assert.equal(ws.tabs.some((tab) => tab.uid === 'session-2'), false);
  assert.notEqual(ws.activeUid, 'session-2');
  assert.equal(ws.tabs.length, 3);
});

test('web interaction matrix: pinned and regular tabs are isolated groups', () => {
  let ws = createInitialWorkspace();
  for (let i = 1; i <= 4; i += 1) ws = openSession(ws, `session-${i}`);
  ws = pinTab(ws, 'session-1', true);
  ws = reorderTabs(ws, 0, 3);
  const pinned = ws.tabs.filter((tab) => tab.pinned).map((tab) => tab.uid);
  const regular = ws.tabs.filter((tab) => !tab.pinned).map((tab) => tab.uid);
  assert.deepEqual(pinned, ['session-1']);
  assert.deepEqual(new Set(regular), new Set(['session-2', 'session-3', 'session-4']));
  assert.equal(ws.tabs.findIndex((tab) => !tab.pinned), 1);
});

test('web interaction matrix: horizontal and vertical two-pane geometry is gap-exact', () => {
  let horizontal = openSession(createInitialWorkspace(), 'a');
  horizontal = splitSession(horizontal, 'a', 'b', { axis: 'x', ratio: 0.5 });
  const hLayout = project(horizontal.root, { x: 0, y: 0, w: 1000, h: 600 }, 1);
  assertNoOverlapAndCovered(hLayout, { x: 0, y: 0, w: 1000, h: 600 });
  assert.equal(hLayout.a.x, 0);
  assert.equal(hLayout.b.x, hLayout.a.w + 1);

  let vertical = openSession(createInitialWorkspace(), 'a');
  vertical = splitSession(vertical, 'a', 'b', { axis: 'y', ratio: 0.5 });
  const vLayout = project(vertical.root, { x: 0, y: 0, w: 1000, h: 600 }, 1);
  assertNoOverlapAndCovered(vLayout, { x: 0, y: 0, w: 1000, h: 600 });
  assert.equal(vLayout.a.y, 0);
  assert.equal(vLayout.b.y, vLayout.a.h + 1);
  assert.equal(vLayout.a.x, vLayout.b.x, 'vertical split panes must share the same left edge');
  assert.equal(vLayout.a.w, vLayout.b.w, 'vertical split panes must share the same width');
  assert.equal(vLayout.b.y + vLayout.b.h, 600, 'lower pane must reach the stage bottom without truncation');
});

test('web interaction matrix: three-pane nested binary tree has unique leaves and no cracks', () => {
  let ws = openSession(createInitialWorkspace(), 'a');
  ws = splitSession(ws, 'a', 'b', { axis: 'x', ratio: 0.5 });
  ws = splitSession(ws, 'b', 'c', { axis: 'y', ratio: 0.5 });
  assert.deepEqual(getLeaves(ws.root), ['a', 'b', 'c']);
  const layout = project(ws.root, { x: 0, y: 0, w: 1200, h: 800 }, 1);
  assertNoOverlapAndCovered(layout, { x: 0, y: 0, w: 1200, h: 800 });
  assert.equal(new Set(Object.keys(layout)).size, 3);
});

test('web interaction matrix: closing a pane promotes sibling and reflows the tree', () => {
  let ws = openSession(createInitialWorkspace(), 'a');
  ws = splitSession(ws, 'a', 'b', { axis: 'x', ratio: 0.5 });
  ws = splitSession(ws, 'b', 'c', { axis: 'y', ratio: 0.5 });
  ws = closePane(ws, 'b');
  assert.deepEqual(getLeaves(ws.root), ['a', 'c']);
  ws = closePane(ws, 'a');
  assert.deepEqual(ws.root, { kind: 'leaf', uid: 'c' });
  const layout = project(ws.root, { x: 0, y: 0, w: 600, h: 400 }, 1);
  assert.deepEqual(layout.c, { x: 0, y: 0, w: 600, h: 400 });
});

test('web interaction matrix: edge hit testing covers all four drop zones and hysteresis', () => {
  const rect = { x: 100, y: 50, w: 800, h: 500 };
  assert.equal(edgeAt(rect, 110, 250), 'left');
  assert.equal(edgeAt(rect, 890, 250), 'right');
  assert.equal(edgeAt(rect, 500, 60), 'top');
  assert.equal(edgeAt(rect, 500, 540), 'bottom');
  assert.equal(edgeAt(rect, 500, 250), 'top');
  assert.equal(edgeAt(rect, 500, 300, 'left'), 'left');
  assert.equal(edgeAt(rect, 500, 300, 'left', HYSTERESIS_PX), 'left');
  assert.ok(TOLERANCE_PX > 0 && HYSTERESIS_PX > 0 && HOLD_DELAY_MS >= 150);
});

test('web interaction matrix: preview rectangles are physically attached to the edge', () => {
  const rect = { x: 10, y: 20, w: 800, h: 600 };
  assert.deepEqual(computePreviewRect(rect, 'left'), { x: 10, y: 20, w: 400, h: 600 });
  assert.deepEqual(computePreviewRect(rect, 'right'), { x: 410, y: 20, w: 400, h: 600 });
  assert.deepEqual(computePreviewRect(rect, 'top'), { x: 10, y: 20, w: 800, h: 300 });
  assert.deepEqual(computePreviewRect(rect, 'bottom'), { x: 10, y: 320, w: 800, h: 300 });
});

test('web interaction matrix: pane hit testing rejects outside/self/min-size drops and accepts valid edge drop', () => {
  const stageRect = { x: 0, y: 0, w: 1000, h: 600 };
  const root = { kind: 'split', axis: 'x', ratio: 0.5, first: { kind: 'leaf', uid: 'a' }, second: { kind: 'leaf', uid: 'b' } };
  const leafRects = [
    { uid: 'a', rect: { x: 0, y: 0, w: 499, h: 600 } },
    { uid: 'b', rect: { x: 500, y: 0, w: 500, h: 600 } },
  ];
  assert.equal(hitTestLeafPanes({ x: -1, y: 30, sourceUid: 'a', stageRect, leafRects, root }), null);
  assert.equal(hitTestLeafPanes({ x: 250, y: 300, sourceUid: 'a', stageRect, leafRects, root })?.type, 'center');
  const right = hitTestLeafPanes({ x: 980, y: 300, sourceUid: 'a', stageRect, leafRects, root });
  assert.equal(right?.edge, 'right');
  assert.equal(right?.targetUid, 'b');
  assert.ok(right.previewRect.w > 0 && right.previewRect.h > 0);
});

test('web interaction matrix: tab-bar hit test reorders regular tabs but never crosses pinned boundary', () => {
  const tabBarRect = { x: 0, y: 0, w: 600, h: 38 };
  const tabRects = [
    { uid: 'pinned', index: 0, rect: { x: 0, y: 0, w: 38, h: 38 }, pinned: true },
    { uid: 'a', index: 1, rect: { x: 38, y: 0, w: 140, h: 38 }, pinned: false },
    { uid: 'b', index: 2, rect: { x: 178, y: 0, w: 140, h: 38 }, pinned: false },
    { uid: 'c', index: 3, rect: { x: 318, y: 0, w: 140, h: 38 }, pinned: false },
  ];
  assert.deepEqual(hitTestTabBar({ x: 350, y: 20, sourceUid: 'a', tabBarRect, tabRects }), { type: 'tabbar', fromIndex: 1, toIndex: 3 });
  assert.deepEqual(hitTestTabBar({ x: 15, y: 20, sourceUid: 'a', tabBarRect, tabRects }), { type: 'tabbar', fromIndex: 1, toIndex: 1 });
  assert.deepEqual(hitTestTabBar({ x: 350, y: 20, sourceUid: 'pinned', tabBarRect, tabRects }), { type: 'tabbar', fromIndex: 0, toIndex: 0 });
});

test('web interaction matrix: dropNode preserves a single binary workspace tree', () => {
  const root = { kind: 'split', axis: 'x', ratio: 0.5, first: { kind: 'leaf', uid: 'a' }, second: { kind: 'leaf', uid: 'b' } };
  const right = dropNode(root, 'a', 'b', 'right');
  assert.deepEqual(getLeaves(right), ['b', 'a']);
  const below = dropNode(root, 'a', 'b', 'bottom');
  assert.deepEqual(getLeaves(below), ['b', 'a']);
  assert.equal(dropNode(root, 'a', 'a', 'left'), root);
  assert.deepEqual(getLeaves(removeNode(right, 'a')), ['b']);
});

test('web interaction matrix: split-pane and terminal host contracts preserve full stage geometry', async () => {
  const split = await source('components/terminal/SplitPanes.jsx');
  const paneCss = await source('components/terminal/terminal.css');
  const pane = await source('components/terminal/TerminalPane.jsx');
  assert.match(split, /className="splitpanes terminal-stage"/);
  assert.match(split, /project\(effectiveRoot, effectiveRect, 1\)/);
  assert.match(split, /data-pane-uid/);
  assert.match(paneCss, /\.terminalpane-body\s*\{[\s\S]*?flex:\s*1;[\s\S]*?min-height:\s*0;[\s\S]*?padding:\s*8px 10px 0/);
  assert.match(paneCss, /\.terminalpane-host\s*\{[\s\S]*?flex:\s*1;[\s\S]*?min-height:\s*0;[\s\S]*?position:\s*relative[\s\S]*?overflow:\s*hidden/);
  assert.match(paneCss, /\.terminalpane-host > \.xterm\s*\{[\s\S]*?position:\s*absolute[\s\S]*?bottom:\s*0/);
  assert.match(pane, /data-alignment=\"bottom-left\"/);
  assert.match(pane, /new ResizeObserver/);
  assert.match(pane, /view\.fit\(/);
  const view = await source('term/TerminalView.js');
  assert.match(view, /clientWidth/);
  assert.match(view, /clientHeight/);
  assert.match(view, /Math\.floor\s*\(\s*w\s*\/\s*cell\.w\)/);
  assert.match(view, /Math\.floor\s*\(\s*h\s*\/\s*cell\.h\)/);
});

test('web interaction matrix: fullscreen CSS removes outer inset and fills viewport', async () => {
  const css = await source('styles/app.css');
  assert.match(css, /\.app-root\.is-fullscreen\s*\{[\s\S]*?width:\s*100vw/);
  assert.match(css, /\.app-root\.is-fullscreen\s*\{[\s\S]*?height:\s*100vh/);
  assert.match(css, /\.app-root\.is-fullscreen\s*\{[\s\S]*?border-radius:\s*0/);
  assert.match(css, /\.app-root\.is-fullscreen\s*\{[\s\S]*?margin:\s*0/);
});

test('Issue #202 scrim animation is opacity-only and never transforms the full-screen backdrop', async () => {
  const css = await source('components/chrome/chrome.css');
  const tokens = await source('styles/tokens.css');
  const scrimRule = css.match(/\.chr-scrim\s*\{([^}]*)\}/)?.[1] || '';
  assert.doesNotMatch(scrimRule, /transform\s*:/, 'scrim must not transform or resize the full-screen backdrop');
  const animationName = scrimRule.match(/animation\s*:\s*([a-zA-Z_-][a-zA-Z0-9_-]*)/)?.[1] || '';
  assert.equal(animationName, 'scrimFadeIn', 'scrim must use the dedicated opacity-only fade animation');
  const keyframes = tokens.match(new RegExp(`@keyframes\\s+${animationName}\\s*\\{([\\s\\S]*?)\\n\\s*\\}`))?.[1] || '';
  assert.match(keyframes, /opacity\s*:/, 'scrim animation must animate opacity');
  assert.doesNotMatch(keyframes, /transform\s*:|scale\s*\(|translate(?:X|Y|3d)?\s*\(/, 'scrim keyframes must not scale or translate');
});

test('web interaction matrix: drop controller implementation is pointer-event based and schedules one rAF', async () => {
  const drag = await source('lib/tabDrag.js');
  assert.match(drag, /setPointerCapture/);
  assert.match(drag, /requestAnimationFrame/);
  assert.match(drag, /pointermove/);
  assert.match(drag, /pointerup/);
  assert.match(drag, /cancel\('container-resize'\)/);
});
