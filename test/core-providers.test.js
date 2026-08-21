/*
 * provider inference table (UI-SPEC §8.2/§8.4). The tmux session name is the
 * only provider hint available before a level2 subscription exists, so this
 * table decides which icon the sidebar shows for most rows.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  inferProvider, providerLabel, PROVIDER_LABEL, PROVIDER_ICON_SLUG,
} from '../src/core/providers.js';

const CASES = [
  ['claude', 'claude-code'],
  ['Claude-Code-2', 'claude-code'],
  ['CLAUDE', 'claude-code'],
  ['my claude run', 'claude-code'],
  ['codex', 'codex'],
  ['Codex-review', 'codex'],
  ['openai-cli', 'codex'],
  ['cursor', 'cursor'],
  ['grok-bot', 'grok'],
  ['opencode', 'opencode'],
  ['kimi', 'kimi'],
  ['Kimi-Code', 'kimi'],
  ['zai', 'zai'],
  ['zcode', 'zai'],
  ['z-code', 'zai'],
  ['glm-4', 'zai'],
  ['bash', null],
  ['', null],
  ['  ', null],
  [undefined, null],
  [null, null],
  [42, null],
];

test('inferProvider: case-insensitive substring table', () => {
  for (const [name, expected] of CASES) {
    assert.equal(inferProvider(name), expected, `inferProvider(${JSON.stringify(name)})`);
  }
});

test('inferProvider: opencode is not misread as codex', () => {
  assert.equal(inferProvider('opencode'), 'opencode');
  assert.equal(inferProvider('OpenCode-main'), 'opencode');
});

test('every inferred key has a label and an icon slug pair', () => {
  const keys = new Set(CASES.map(([, k]) => k).filter(Boolean));
  for (const k of keys) {
    assert.equal(typeof PROVIDER_LABEL[k], 'string', `label for ${k}`);
    const slug = PROVIDER_ICON_SLUG[k];
    assert.ok(slug && typeof slug.active === 'string' && typeof slug.idle === 'string', `slug for ${k}`);
  }
  // Both maps cover the same key set (UI-SPEC §8.2 table).
  assert.deepEqual(Object.keys(PROVIDER_LABEL).sort(), Object.keys(PROVIDER_ICON_SLUG).sort());
});

test('providerLabel falls back to the raw session name', () => {
  assert.equal(providerLabel('claude-code'), 'Claude Code');
  assert.equal(providerLabel(null, 'bash'), 'bash');
  assert.equal(providerLabel(undefined), '');
});
