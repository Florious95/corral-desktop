import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

import {
  normalizeProvider,
  providerLabel,
  PROVIDER_ICON_SLUG,
} from '../src/core/providers.js';

const CASES = [
  { wire: 'pi', key: 'pi', label: 'Pi' },
  { wire: 'claude_code', key: 'claude_code', label: 'Claude Code' },
  { wire: 'codex', key: 'codex', label: 'Codex' },
  { wire: 'cursor', key: 'cursor', label: 'Cursor' },
  { wire: 'aider', key: 'aider', label: 'Aider' },
  { wire: 'goose', key: 'goose', label: 'Goose' },
  { wire: 'opencode', key: 'opencode', label: 'OpenCode' },
  { wire: 'kiro-cli', key: 'kiro_cli', label: 'Kiro CLI' },
];

// Load the actual production JSX through Vite's SSR pipeline so the test
// exercises the same ProviderIcon asset imports used by the sidebar.
const server = await createServer({
  configFile: false,
  root: fileURLToPath(new URL('..', import.meta.url)),
  plugins: [react()],
  server: { middlewareMode: true, watch: null, hmr: false },
  logLevel: 'silent',
});
after(() => server.close());

const { default: ProviderIcon } = await server.ssrLoadModule('/src/components/sidebar/ProviderIcon.jsx');

test('all eight mainstream Agent CLIs keep a canonical provider identity', () => {
  const actual = CASES.map(({ wire }) => normalizeProvider(wire));
  assert.deepEqual(actual, CASES.map(({ key }) => key),
    'listing provider values must not collapse kiro-cli/aider/goose/opencode to unknown');

  for (const { key, label } of CASES) {
    assert.equal(providerLabel(key), label, `${key} needs its canonical display name`);
    const icon = PROVIDER_ICON_SLUG[key];
    assert.ok(icon && icon.active !== 'unknown' && icon.idle !== 'unknown',
      `${key} needs a dedicated or classified icon slug`);
  }
});

test('sidebar ProviderIcon renders a real mapped image and accessible CLI name for every provider', () => {
  for (const { key, label } of CASES) {
    const html = renderToStaticMarkup(createElement(ProviderIcon, { provider: key, active: true, size: 18 }));
    assert.match(html, /<img\b/, `${key} must render an image, not the unknown-provider circle`);
    assert.match(html, new RegExp(`alt="${label}"`), `${key} icon must expose ${label} to the sidebar/AX surface`);
  }
});
