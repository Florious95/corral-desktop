/*
 * Provider identity helpers.
 *
 * A provider value supplied by the daemon is authoritative and is normalised
 * against the closed canonical DTO set. Name inference remains only the
 * compatibility fallback for old listing frames that omit provider entirely.
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

/** Canonical provider IDs emitted by the daemon (plus the fail-closed sentinel). */
export const CANONICAL_PROVIDERS = Object.freeze([
  'claude_code', 'codex', 'copilot', 'grok', 'cursor', 'pi', 'unknown',
]);

/** Exact DTO values accepted by the desktop; aliases are compatibility-only. */
const PROVIDER_ALIASES = Object.freeze({
  claude_code: 'claude_code',
  'claude-code': 'claude_code',
  claude: 'claude_code',
  codex: 'codex',
  copilot: 'copilot',
  grok: 'grok',
  cursor: 'cursor',
  pi: 'pi',
  unknown: 'unknown',
});

/** Normalise a provider DTO without fuzzy matching or title fallback. */
export function normalizeProvider(value) {
  if (typeof value !== 'string') return 'unknown';
  return PROVIDER_ALIASES[value.trim().toLowerCase()] ?? 'unknown';
}

/** Fallback for old listing frames whose provider field is completely absent. */
export function inferCanonicalProvider(sessionName) {
  return normalizeProvider(inferProvider(sessionName));
}

/** Display name per canonical provider key (UI-SPEC §8.2, last column). */
export const PROVIDER_LABEL = Object.freeze({
  claude_code: 'Claude Code',
  codex: 'Codex',
  copilot: 'Copilot',
  grok: 'Grok',
  cursor: 'Cursor',
  pi: 'Pi',
  // Legacy UI-only aliases remain readable in the sealed new-agent dialog.
  'claude-code': 'Claude Code',
  claude: 'Claude Code',
  opencode: 'OpenCode',
  zai: 'Z Code',
  kimi: 'Kimi Code',
});

/** Canonical icon slug metadata; actual assets are imported by ProviderIcon. */
export const PROVIDER_ICON_SLUG = Object.freeze({
  claude_code: { active: 'claude_code', idle: 'claude_code' },
  codex: { active: 'codex', idle: 'codex' },
  copilot: { active: 'copilot', idle: 'copilot' },
  grok: { active: 'grok', idle: 'grok' },
  cursor: { active: 'cursor', idle: 'cursor' },
  pi: { active: 'pi', idle: 'pi' },
  // Compatibility aliases, not additional canonical providers.
  'claude-code': { active: 'claude_code', idle: 'claude_code' },
  claude: { active: 'claude_code', idle: 'claude_code' },
  opencode: { active: 'unknown', idle: 'unknown' },
  zai: { active: 'unknown', idle: 'unknown' },
  kimi: { active: 'unknown', idle: 'unknown' },
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
