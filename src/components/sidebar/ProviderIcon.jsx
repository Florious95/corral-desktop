// provider 图标（UI-SPEC §8）。svg 由 Vite 打包进产物，⛔ 不走 CDN，离线可用。
import claudeColorUrl from '@lobehub/icons-static-svg/icons/claude-color.svg';
import claudeUrl from '@lobehub/icons-static-svg/icons/claude.svg';
import codexUrl from '@lobehub/icons-static-svg/icons/codex.svg';
import grokUrl from '@lobehub/icons-static-svg/icons/grok.svg';
import opencodeUrl from '@lobehub/icons-static-svg/icons/opencode.svg';
import cursorUrl from '@lobehub/icons-static-svg/icons/cursor.svg';
import zaiUrl from '@lobehub/icons-static-svg/icons/zai.svg';
import kimiUrl from '@lobehub/icons-static-svg/icons/kimi.svg';

/** provider → [运行态 slug, 空闲态 slug]（UI-SPEC §8.2） */
const ICONS = {
  'claude-code': [claudeColorUrl, claudeUrl],
  claude: [claudeColorUrl, claudeUrl],
  codex: [codexUrl, codexUrl],
  grok: [grokUrl, grokUrl],
  opencode: [opencodeUrl, opencodeUrl],
  cursor: [cursorUrl, cursorUrl],
  zai: [zaiUrl, zaiUrl],
  kimi: [kimiUrl, kimiUrl],
};

/** 兜底首字母圆圈的色调 */
const TINT = {
  'claude-code': 'var(--tint-claude)',
  claude: 'var(--tint-claude)',
  codex: 'var(--tint-codex)',
  grok: 'var(--tint-grok)',
  opencode: 'var(--tint-opencode)',
  cursor: 'var(--tint-cursor)',
  zai: 'var(--tint-zai)',
  kimi: 'var(--tint-kimi)',
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
