// Agents 列表（UI-SPEC §5.3）。行高 54px、绝对定位 + top 过渡，收藏置顶靠 top 重排而非 DOM 重排。
import { useEffect, useRef, useState } from 'react';
import ProviderIcon from './ProviderIcon.jsx';
import { PROVIDER_LABEL } from '../../core/providers.js';
import { StarIcon, CheckIcon } from '../../lib/icons.jsx';

const ROW = 54;
const MIN_H = 108;

const STATE_TITLE = {
  working: '运行中',
  blocked: '等待确认',
  done: '已完成',
  idle: '空闲',
  unknown: '状态未知',
};

/** 状态收敛到闭集，未知值一律当 unknown 渲染成灰空心点 */
const stateOf = (s) => (STATE_TITLE[s] ? s : 'unknown');

/** meta 文本：`${显示名} · ${space}`；显示名与标题重复时只留 space */
function metaText(ag) {
  const label = PROVIDER_LABEL[ag.provider];
  if (label === ag.title) return ag.spaceName;
  return `${label ?? ag.title} · ${ag.spaceName}`;
}

/**
 * @param {Object} props
 * @param {Array}  props.agents                        可见集合，顺序 = 稳定的原始顺序（勿排序）
 * @param {string[]} props.openKeys
 * @param {Object<string,boolean>} [props.closing]     key → 正在播关闭动画
 * @param {(key:string) => void} props.onOpen
 * @param {(e:MouseEvent, key:string) => void} props.onContextMenu
 * @param {boolean} props.multiDevice
 * @param {string} [props.emptyHint]                   空态第二行文案
 * @param {string} [props.emptyTitle]                  空态第一行文案（搜索无结果时替换）
 */
export default function AgentsList({
  agents,
  openKeys,
  closing = {},
  onOpen,
  onContextMenu,
  multiDevice,
  emptyHint = '会话由主机发现后会出现在这里',
  emptyTitle = '这个空间还没有 Agent',
}) {
  const hostRef = useRef(null);
  const [vpH, setVpH] = useState(MIN_H);

  // 视口高度量化到 54 的整数倍：永远只露出整数行，不出现半行
  useEffect(() => {
    const el = hostRef.current;
    if (!el) return undefined;
    const measure = () => {
      const h = Math.max(MIN_H, Math.floor(el.clientHeight / ROW) * ROW);
      setVpH((prev) => (prev === h ? prev : h));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // 收藏置顶：只算 top，DOM 顺序不动，重排走 top 过渡
  const sorted = [...agents].sort((a, b) => (b.fav ? 1 : 0) - (a.fav ? 1 : 0));
  const tops = new Map(sorted.map((ag, i) => [ag.key, i * ROW]));

  return (
    <div className="agents-host" ref={hostRef}>
      <div className="agents-viewport" style={{ height: vpH }}>
        <div className="agents-track" style={{ height: agents.length * ROW }}>
          {agents.map((ag) => (
            <div
              key={ag.key}
              className={`agents-row${openKeys.includes(ag.key) ? ' is-open' : ''}`}
              data-ref={ag.ref || ''}
              data-fav={ag.fav ? '1' : '0'}
              data-host-cols={ag.hostCols != null ? String(ag.hostCols) : ''}
              data-host-rows={ag.hostRows != null ? String(ag.hostRows) : ''}
              style={{
                top: tops.get(ag.key),
                opacity: closing[ag.key] ? 0 : 1,
                transform: `scale(${closing[ag.key] ? 0.94 : 1})`,
              }}
              onClick={() => onOpen(ag.key)}
              onContextMenu={(e) => onContextMenu(e, ag.key)}
            >
              <div className="agents-row-main">
                <ProviderIcon
                  provider={ag.provider}
                  size={18}
                  active={ag.state === 'working' || ag.state === 'blocked'}
                />
                <span className="agents-row-title">{ag.title}</span>
                <span className="agents-row-marks">
                  {ag.state === 'done' ? (
                    <CheckIcon size={12} stroke="var(--green-deep)" strokeWidth={2.4} />
                  ) : null}
                  {ag.fav ? <StarIcon size={12} fill="var(--amber)" /> : null}
                </span>
              </div>
              <div className="agents-row-meta">
                <span
                  className={`agents-dot is-${stateOf(ag.state)}`}
                  title={STATE_TITLE[stateOf(ag.state)]}
                />
                <span className="agents-row-metatext">{metaText(ag)}</span>
                {multiDevice ? (
                  <span className={`agents-badge${ag.deviceLocal ? ' is-local' : ''}`}>
                    {ag.deviceName}
                  </span>
                ) : null}
              </div>
            </div>
          ))}
        </div>
        {agents.length === 0 ? (
          <div className="agents-empty">
            <div>{emptyTitle}</div>
            <div>{emptyHint}</div>
          </div>
        ) : null}
      </div>
    </div>
  );
}
