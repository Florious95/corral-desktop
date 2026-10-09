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
  ['kiro', 'kiro_cli'],
  ['aider', 'aider'],
  ['goose', 'goose'],
  ['kimi', 'kimi'],
  ['zcode', 'zai'],
  ['z-code', 'zai'],
  ['glm', 'zai'],
  ['zai', 'zai'],
  ['pi', 'pi'],
]);

/** Canonical provider IDs emitted by the daemon (plus the fail-closed sentinel). */
export const CANONICAL_PROVIDERS = Object.freeze([
  'claude_code', 'codex', 'copilot', 'grok', 'cursor', 'pi',
  'kiro_cli', 'aider', 'goose', 'opencode', 'unknown',
]);

/**
 * 标准全量 Provider 启动配置清单（兜底选型大厅）。
 * 当服务端未广告或下发空 agent_launchers 时自动呈现，确保 5 大主流 Provider 均可正常选型创建。
 */
export const DEFAULT_LAUNCHERS = Object.freeze([
  { provider: 'claude_code', display_name: 'Claude Code', supports_bypass: true },
  { provider: 'codex', display_name: 'Codex', supports_bypass: true },
  { provider: 'cursor', display_name: 'Cursor', supports_bypass: false },
  { provider: 'grok', display_name: 'Grok', supports_bypass: false },
  { provider: 'pi', display_name: 'Pi', supports_bypass: true },
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
  'cursor-agent': 'cursor',
  pi: 'pi',
  kiro_cli: 'kiro_cli',
  kiro: 'kiro_cli',
  'kiro-cli': 'kiro_cli',
  'kiro-cli-chat': 'kiro_cli',
  aider: 'aider',
  goose: 'goose',
  opencode: 'opencode',
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
  kiro_cli: 'Kiro CLI',
  aider: 'Aider',
  goose: 'Goose',
  opencode: 'OpenCode',
  // Legacy UI-only aliases remain readable in the sealed new-agent dialog.
  'claude-code': 'Claude Code',
  claude: 'Claude Code',
  zai: 'Z Code',
  kimi: 'Kimi Code',
});

/** Canonical icon/badge keys; ProviderIcon uses a letter badge when no asset exists. */
export const PROVIDER_ICON_SLUG = Object.freeze({
  claude_code: { active: 'claude_code', idle: 'claude_code' },
  codex: { active: 'codex', idle: 'codex' },
  copilot: { active: 'copilot', idle: 'copilot' },
  grok: { active: 'grok', idle: 'grok' },
  cursor: { active: 'cursor', idle: 'cursor' },
  pi: { active: 'pi', idle: 'pi' },
  kiro_cli: { active: 'kiro_cli', idle: 'kiro_cli' },
  aider: { active: 'aider', idle: 'aider' },
  goose: { active: 'goose', idle: 'goose' },
  opencode: { active: 'opencode', idle: 'opencode' },
  // Compatibility aliases, not additional canonical providers.
  'claude-code': { active: 'claude_code', idle: 'claude_code' },
  claude: { active: 'claude_code', idle: 'claude_code' },
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
    if (['pi', 'kiro', 'aider', 'goose'].includes(needle)) {
      if (new RegExp(`(?:^|[^a-z0-9])${needle}(?:[^a-z0-9]|$)`).test(n)) return key;
      continue;
    }
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
