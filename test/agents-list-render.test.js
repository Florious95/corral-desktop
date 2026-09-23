import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';
import react from '@vitejs/plugin-react';

// Use production Vite SSR pipeline to load and render the real JSX component
const server = await createServer({
  configFile: false,
  root: fileURLToPath(new URL('..', import.meta.url)),
  plugins: [react()],
  server: { middlewareMode: true, watch: null, hmr: false },
  logLevel: 'silent',
});
after(() => server.close());

const { default: AgentsList } = await server.ssrLoadModule('/src/components/sidebar/AgentsList.jsx');

test('Issue #268: AgentsList imports all required React hooks (useEffect, useCallback, useMemo, useRef, useState)', async () => {
  const code = await readFile(new URL('../src/components/sidebar/AgentsList.jsx', import.meta.url), 'utf8');

  // Verify import declaration explicitly includes useEffect and useCallback
  assert.match(
    code,
    /import\s*\{[^}]*\buseEffect\b[^}]*\}\s*from\s*['"]react['"]/,
    'AgentsList must import useEffect from react to avoid ReferenceError on mount',
  );
  assert.match(
    code,
    /import\s*\{[^}]*\buseCallback\b[^}]*\}\s*from\s*['"]react['"]/,
    'AgentsList must import useCallback from react to avoid ReferenceError on mount',
  );
});

test('Issue #268: AgentsList mounts and renders cleanly without throwing ReferenceError', () => {
  const mockAgents = [
    {
      key: 'local::%0',
      title: 'agent-1',
      provider: 'pi',
      state: 'working',
      fav: false,
      spaceName: 'repo',
      deviceName: 'Local',
      deviceLocal: true,
    },
    {
      key: 'local::%1',
      title: 'agent-2',
      provider: 'codex',
      state: 'idle',
      fav: true,
      spaceName: 'repo',
      deviceName: 'Local',
      deviceLocal: true,
    },
  ];

  // Must render without throwing ReferenceError
  let html = '';
  assert.doesNotThrow(() => {
    html = renderToStaticMarkup(
      createElement(AgentsList, {
        agents: mockAgents,
        openKeys: ['local::%0'],
        activeUid: 'local::%0',
        closing: {},
        onOpen: () => {},
        onContextMenu: () => {},
        multiDevice: false,
      }),
    );
  }, 'Rendering AgentsList must not throw ReferenceError: useEffect/useCallback is not defined');

  assert.ok(html.length > 0, 'AgentsList must produce non-empty markup');
  assert.match(html, /class="agents-host"/);
  assert.match(html, /class="agents-track"/);
  assert.match(html, /agent-1/);
  assert.match(html, /agent-2/);
  assert.match(html, /agents-dot is-working/);
  assert.match(html, /agents-dot is-idle/);
});

test('Issue #268: AgentsList renders empty state cleanly when agents array is empty', () => {
  let html = '';
  assert.doesNotThrow(() => {
    html = renderToStaticMarkup(
      createElement(AgentsList, {
        agents: [],
        openKeys: [],
        activeUid: null,
        closing: {},
        onOpen: () => {},
        onContextMenu: () => {},
        multiDevice: false,
      }),
    );
  });

  assert.match(html, /class="agents-empty"/);
  assert.match(html, /这个空间还没有 Agent/);
  assert.match(html, /会话由主机发现后会出现在这里/);
});
