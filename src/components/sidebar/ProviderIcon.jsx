// Canonical provider assets are consumed directly from the pinned core
// submodule. Vite emits them into the bundle; no CDN or runtime fetch.
import claudeCodeUrl from '../../../deps/corral-core/app/app/src/main/res/raw/provider_icon_claude_code.svg';
import codexUrl from '../../../deps/corral-core/app/app/src/main/res/raw/provider_icon_codex.svg';
import copilotUrl from '../../../deps/corral-core/app/app/src/main/res/drawable-nodpi/provider_copilot_color.png';
import grokUrl from '../../../deps/corral-core/app/app/src/main/res/drawable-nodpi/provider_grok.png';
import cursorUrl from '../../../deps/corral-core/app/app/src/main/res/raw/provider_icon_cursor.svg';
import piUrl from '../../../deps/corral-core/app/app/src/main/res/drawable-nodpi/provider_pi.png';

/** Canonical provider → [active, idle] asset. State only changes opacity. */
const ICONS = {
  claude_code: [claudeCodeUrl, claudeCodeUrl],
  codex: [codexUrl, codexUrl],
  copilot: [copilotUrl, copilotUrl],
  grok: [grokUrl, grokUrl],
  cursor: [cursorUrl, cursorUrl],
  pi: [piUrl, piUrl],
  // Sealed new-agent dialog compatibility aliases; DTOs use canonical IDs.
  'claude-code': [claudeCodeUrl, claudeCodeUrl],
  claude: [claudeCodeUrl, claudeCodeUrl],
};

/** 兜底首字母圆圈的色调 */
const TINT = {
  claude_code: 'var(--tint-claude)',
  codex: 'var(--tint-codex)',
  copilot: 'var(--tint-default)',
  grok: 'var(--tint-grok)',
  cursor: 'var(--tint-cursor)',
  pi: 'var(--tint-default)',
  'claude-code': 'var(--tint-claude)',
  claude: 'var(--tint-claude)',
};

/**
 * @param {Object} props
 * @param {string|null} [props.provider]
 * @param {number} [props.size=18]
 * @param {boolean} [props.active=false]  运行态（state 为 working/blocked）
 */
export default function ProviderIcon({ provider = null, size = 18, active = false }) {
  const pair = provider ? ICONS[provider] : null;
  if (pair) {
    return (
      <img
        src={active ? pair[0] : pair[1]}
        width={size}
        height={size}
        alt={provider}
        style={{
          display: 'block',
          flex: 'none',
          opacity: active ? 1 : 0.4,
          transition: 'opacity var(--d-icon)',
        }}
      />
    );
  }
  const tint = active ? (TINT[provider] ?? 'var(--tint-default)') : 'var(--icon-idle)';
  return (
    <span
      aria-hidden="true"
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        flex: 'none',
        boxSizing: 'border-box',
        width: size,
        height: size,
        borderRadius: '50%',
        border: `1.5px solid ${tint}`,
        color: tint,
        fontSize: `${size * 0.5}px`,
        fontWeight: 700,
        fontFamily: 'var(--font-mono)',
      }}
    >
      {provider?.[0]?.toUpperCase() ?? '?'}
    </span>
  );
}
