// Agents 列表（UI-SPEC §5.3）。行高 54px、绝对定位 + top 过渡，收藏置顶靠 top 重排。
import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import ProviderIcon from './ProviderIcon.jsx';
import { PROVIDER_LABEL } from '../../core/providers.js';
import { StarIcon, CheckIcon } from '../../lib/icons.jsx';
import { AGENT_ROW_HEIGHT as ROW, sortAgents, visibleWindow } from './agentWindow.js';

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

const sameAgentRow = (prev, next) => {
  const a = prev.agent;
  const b = next.agent;
  return prev.top === next.top
    && prev.isOpen === next.isOpen
    && prev.isClosing === next.isClosing
    && prev.multiDevice === next.multiDevice
    && prev.onOpen === next.onOpen
    && prev.onContextMenu === next.onContextMenu
    && prev.onPointerDown === next.onPointerDown
    && a.key === b.key
    && a.title === b.title
    && a.provider === b.provider
    && a.state === b.state
    && a.fav === b.fav
    && a.spaceName === b.spaceName
    && a.deviceName === b.deviceName
    && a.deviceLocal === b.deviceLocal;
};

const AgentRow = memo(function AgentRow({
  agent: ag, top, isOpen, isClosing, onOpen, onContextMenu, multiDevice, onPointerDown,
}) {
  return (
    <div
      className={`agents-row${isOpen ? ' is-open' : ''}`}
      style={{
        top,
        opacity: isClosing ? 0 : 1,
        transform: `scale(${isClosing ? 0.94 : 1})`,
      }}
      onClick={() => onOpen(ag.key)}
      onContextMenu={(e) => onContextMenu(e, ag.key)}
      onPointerDown={(e) => onPointerDown && onPointerDown(e, ag)}
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
  );
}, sameAgentRow);

/**
 * @param {Object} props
 * @param {Array}  props.agents                        可见集合，收藏项会稳定置顶
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
  onPointerDown,
  emptyHint = '会话由主机发现后会出现在这里',
  emptyTitle = '这个空间还没有 Agent',
}) {
  const hostRef = useRef(null);
  const [vpH, setVpH] = useState(MIN_H);
  const [scrollTop, setScrollTop] = useState(0);

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

  const handleScroll = useCallback((event) => {
    setScrollTop(event.currentTarget.scrollTop);
  }, []);
  const sorted = useMemo(() => sortAgents(agents), [agents]);
  const tops = useMemo(() => new Map(sorted.map((ag, i) => [ag.key, i * ROW])), [sorted]);
  const openSet = useMemo(() => new Set(openKeys), [openKeys]);
  const totalHeight = sorted.length * ROW;
  const renderTop = Math.min(scrollTop, Math.max(0, totalHeight - vpH));
  const { start, end } = visibleWindow(sorted.length, renderTop, vpH);
  const windowed = sorted.slice(start, end);

  return (
    <div className="agents-host" ref={hostRef}>
      <div
        className="agents-viewport"
        style={{ height: vpH }}
        onScroll={handleScroll}
      >
        <div className="agents-track" style={{ height: totalHeight }}>
          {windowed.map((ag) => (
            <AgentRow
              key={ag.key}
              agent={ag}
              top={tops.get(ag.key)}
              isOpen={openSet.has(ag.key)}
              isClosing={!!closing[ag.key]}
              onOpen={onOpen}
              onContextMenu={onContextMenu}
              multiDevice={multiDevice}
              onPointerDown={onPointerDown}
            />
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
