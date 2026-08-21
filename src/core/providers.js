/*
 * session.name → provider inference.
 *
 * The daemon never tells us which CLI runs in a pane (listing carries no
 * provider field, see CLIENT-CONTRACT §0.1; level2_frame carries one only for
 * subscribed workspaces). The tmux session name is the only always-available
 * hint, so the sidebar infers from it. Unrecognised → null, rendered as the
 * first-letter fallback circle (UI-SPEC §8.3).
 */

/**
 * Ordered needle → provider key. Order matters: the first substring hit wins.
 * Lowercased substring match (not prefix): real session names look like
 * "claude-code-2", "my codex run", "opencode".
 */
const RULES = Object.freeze([
  ['claude', 'claude-code'],
  ['codex', 'codex'],
  ['openai', 'codex'],
  ['cursor', 'cursor'],
  ['grok', 'grok'],
  ['opencode', 'opencode'],
  ['kimi', 'kimi'],
  ['zcode', 'zai'],
  ['z-code', 'zai'],
  ['glm', 'zai'],
  ['zai', 'zai'],
]);

/** Display name per provider key (UI-SPEC §8.2, last column). */
export const PROVIDER_LABEL = Object.freeze({
  'claude-code': 'Claude Code',
  claude: 'Claude',
  codex: 'Codex',
  grok: 'Grok',
  opencode: 'OpenCode',
  cursor: 'Cursor',
  zai: 'Z Code',
  kimi: 'Kimi Code',
});

/**
 * Icon slug per provider key (UI-SPEC §8.2). Values are @lobehub/icons-static-svg
 * file stems — the UI layer maps them to bundled asset URLs; this module stays
 * bundler-free so it runs under plain `node --test`.
 */
export const PROVIDER_ICON_SLUG = Object.freeze({
  'claude-code': { active: 'claude-color', idle: 'claude' },
  claude: { active: 'claude-color', idle: 'claude' },
  codex: { active: 'codex', idle: 'codex' },
  grok: { active: 'grok', idle: 'grok' },
  opencode: { active: 'opencode', idle: 'opencode' },
  cursor: { active: 'cursor', idle: 'cursor' },
  zai: { active: 'zai', idle: 'zai' },
  kimi: { active: 'kimi', idle: 'kimi' },
});

/**
 * Infer the provider key from a tmux session name.
 * @param {string} sessionName
 * @returns {string|null} provider key, or null when unrecognised
 */
export function inferProvider(sessionName) {
  if (typeof sessionName !== 'string' || sessionName.length === 0) return null;
  const n = sessionName.toLowerCase();
  for (const [needle, key] of RULES) {
    if (n.includes(needle)) return key;
  }
  return null;
}

/**
 * Display label for a session: provider label when recognised, else the raw name.
 * @param {string|null} provider
 * @param {string} [fallback]
 */
export function providerLabel(provider, fallback = '') {
  return PROVIDER_LABEL[provider] ?? fallback;
}
