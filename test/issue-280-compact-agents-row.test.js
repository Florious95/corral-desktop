import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';

import {
  AGENT_OVERSCAN,
  AGENT_ROW_HEIGHT,
  sortAgents,
  visibleWindow,
} from '../src/components/sidebar/agentWindow.js';

test('Issue #280: AGENT_ROW_HEIGHT is compact 34px matching single-line streamlined session item', () => {
  assert.equal(AGENT_ROW_HEIGHT, 34, 'AGENT_ROW_HEIGHT must be 34px for compact single-line sessions');
  assert.equal(AGENT_OVERSCAN, 4);

  // Virtual window arithmetic scales cleanly with 34px
  const total = 500;
  const viewportHeight = 34 * 10; // 340px
  const win = visibleWindow(total, 0, viewportHeight);
  assert.equal(win.start, 0);
  assert.equal(win.end, 10 + AGENT_OVERSCAN);

  // Scrolled down by 50 rows
  const winScrolled = visibleWindow(total, 34 * 50, viewportHeight);
  assert.equal(winScrolled.start, 46);
  assert.equal(winScrolled.end, 64);
});

test('Issue #280: sidebar.css tightens vertical padding and height for .agents-row and .agents-item', async () => {
  const sidebarCss = await readFile(
    new URL('../src/components/sidebar/sidebar.css', import.meta.url),
    'utf8'
  );

  // 1. Height is tightened from 54px to 34px on .agents-row
  assert.match(
    sidebarCss,
    /\.agents-row\s*\{[^}]*height:\s*34px;/,
    'sidebar.css must define height: 34px on .agents-row'
  );

  // 2. Vertical padding is tightened to 6px (5px ~ 6px range)
  assert.match(
    sidebarCss,
    /\.agents-row\s*\{[^}]*padding:\s*6px 12px;/,
    'sidebar.css must define padding: 6px 12px on .agents-row'
  );

  // 3. Border radius is var(--r-8)
  assert.match(
    sidebarCss,
    /\.agents-row\s*\{[^}]*border-radius:\s*var\(--r-8\);/,
    'sidebar.css must define border-radius: var(--r-8) on .agents-row'
  );

  // 4. .agents-item alias also has 34px height and 6px padding
  assert.match(
    sidebarCss,
    /\.agents-item\s*\{[^}]*height:\s*34px;[^}]*padding:\s*6px 12px;/,
    'sidebar.css must define height and padding on .agents-item'
  );
});

test('Issue #280: AgentsList.jsx declares MIN_H = ROW * 2 and renders .agents-item class', async () => {
  const agentsListJsx = await readFile(
    new URL('../src/components/sidebar/AgentsList.jsx', import.meta.url),
    'utf8'
  );

  // 1. MIN_H derives dynamically from ROW * 2 (68px)
  assert.match(agentsListJsx, /const MIN_H = ROW \* 2;/);

  // 2. AgentRow markup renders both agents-row and agents-item
  assert.match(agentsListJsx, /className=\{`agents-row agents-item/);

  // 3. Viewport measurement quantizes to ROW (34px)
  assert.match(agentsListJsx, /Math\.floor\(el\.clientHeight \/ ROW\) \* ROW/);
});

test('Issue #280: AgentsList SSR renders compact tops incrementing by 34px', async () => {
  const server = await createServer({
    server: { middlewareMode: true },
    appType: 'custom',
  });

  try {
    const { default: AgentsList } = await server.ssrLoadModule('/src/components/sidebar/AgentsList.jsx');

    const mockAgents = [
      {
        key: 'local::%0',
        title: 'leader-agent',
        provider: 'pi',
        state: 'working',
        fav: false,
        spaceName: 'repo',
        deviceName: 'Local',
        deviceLocal: true,
      },
      {
        key: 'local::%1',
        title: 'worker-agent',
        provider: 'codex',
        state: 'idle',
        fav: true,
        spaceName: 'repo',
        deviceName: 'Local',
        deviceLocal: true,
      },
    ];

    const html = renderToStaticMarkup(
      createElement(AgentsList, {
        agents: mockAgents,
        openKeys: ['local::%0'],
        activeUid: 'local::%0',
        onOpen: () => {},
        onContextMenu: () => {},
        multiDevice: false,
      })
    );

    // Verify presence of agents-item
    assert.match(html, /class="[^"]*agents-item[^"]*"/);

    // Favourites sort first: worker-agent (fav: true) gets top: 0, leader-agent (fav: false) gets top: 34px
    assert.match(html, /data-agent-key="local::%1"[^>]*style="[^"]*top:(?:0px|0)\b/);
    assert.match(html, /data-agent-key="local::%0"[^>]*style="[^"]*top:34px\b/);

    // Total track height for 2 items is 68px (2 * 34px)
    assert.match(html, /class="agents-track"[^>]*style="[^"]*height:68px/);
  } finally {
    await server.close();
  }
});

test('Issue #280: UI-SPEC.md §5.3 documentation reflects 34px row height and 6px padding', async () => {
  const spec = await readFile(
    new URL('../docs/UI-SPEC.md', import.meta.url),
    'utf8'
  );

  assert.match(spec, /行高 34px/);
  assert.match(spec, /height:34px;/);
  assert.match(spec, /padding:6px 12px;/);
  assert.match(spec, /border-radius:var\(--r-8\);/);
  assert.match(spec, /Math\.floor\(el\.clientHeight \/ 34\) \* 34/);
});
