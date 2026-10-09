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
  { wire: 'pi', key: 'pi', label: 'Pi', badgeCharacter: null },
  { wire: 'claude_code', key: 'claude_code', label: 'Claude Code', badgeCharacter: null },
  { wire: 'codex', key: 'codex', label: 'Codex', badgeCharacter: null },
  { wire: 'cursor', key: 'cursor', label: 'Cursor', badgeCharacter: null },
  { wire: 'aider', key: 'aider', label: 'Aider', badgeCharacter: 'A' },
  { wire: 'goose', key: 'goose', label: 'Goose', badgeCharacter: 'G' },
  { wire: 'opencode', key: 'opencode', label: 'OpenCode', badgeCharacter: 'O' },
  { wire: 'kiro_cli', key: 'kiro_cli', label: 'Kiro CLI', badgeCharacter: 'K' },
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
    'listing provider values must not collapse kiro_cli/aider/goose/opencode to unknown');

  for (const { key, label } of CASES) {
    assert.equal(providerLabel(key), label, `${key} needs its canonical display name`);
    const icon = PROVIDER_ICON_SLUG[key];
    assert.ok(icon && icon.active !== 'unknown' && icon.idle !== 'unknown',
      `${key} needs a dedicated or classified icon slug`);
  }
});

test('sidebar ProviderIcon renders a mapped asset or canonical letter badge for every provider', () => {
  for (const { key, label, badgeCharacter } of CASES) {
    const html = renderToStaticMarkup(createElement(ProviderIcon, { provider: key, active: true, size: 18 }));
    if (badgeCharacter) {
      assert.match(html, /<span\b/, `${key} must render a Letter Badge when no third-party asset is used`);
      assert.match(html, new RegExp(`>${badgeCharacter}</span>`), `${key} must render its ${badgeCharacter} classification badge`);
      assert.match(html, new RegExp(`aria-label="${label}"`), `${key} badge must expose ${label} to the sidebar/AX surface`);
      assert.doesNotMatch(html, /aria-hidden="true"/, `${key} badge must remain visible to the sidebar/AX surface`);
    } else {
      assert.match(html, /<img\b/, `${key} must render its mapped provider image`);
      assert.match(html, new RegExp(`alt="${label}"`), `${key} icon must expose ${label} to the sidebar/AX surface`);
    }
  }
});
