import { useEffect, useRef, useState } from 'react';
import { SidebarIcon } from '../../lib/icons.jsx';
import {
  createPillReveal, pillHotTop, PILL_HOT, runWindowChrome, desktopWindowApi,
} from '../../lib/windowChrome.js';
import './chrome.css';

/**
 * Hover-only stadium: close / min / zoom / sidebar. Matches pill mockup.
 */
export default function ChromePill({ fullscreen = false, sidebarCollapsed, onToggleSidebar }) {
  const [open, setOpen] = useState(false);
  const ctl = useRef(null);
  if (ctl.current === null) {
    ctl.current = createPillReveal({ onChange: setOpen });
  }
  useEffect(() => () => ctl.current.dispose(), []);

  const onChrome = async (kind) => {
    if (kind === 'toggle') {
      onToggleSidebar?.();
      return;
    }
    try {
      await runWindowChrome(kind, await desktopWindowApi());
    } catch { /* non-tauri / missing permission: Cmd+W still closes */ }
  };

  const top = pillHotTop(fullscreen);

  return (
    <div className={`chrome-pill-root${fullscreen ? ' is-fullscreen' : ''}`}>
      <div
        className="chrome-pill-hot"
        style={{ top, left: PILL_HOT.left, width: PILL_HOT.width, height: PILL_HOT.height }}
        onMouseEnter={() => ctl.current.enter()}
        onMouseLeave={() => ctl.current.leave()}
      />
      <div
        className={`chrome-pill${open ? ' is-reveal' : ''}`}
        style={{ top: fullscreen ? top + 10 : 10 }}
        onMouseEnter={() => ctl.current.enter()}
        onMouseLeave={() => ctl.current.leave()}
      >
        <button type="button" className="chrome-lamp r" aria-label="关闭窗口" title="关闭窗口" onClick={() => onChrome('close')}>
          <span>✕</span>
        </button>
        <button type="button" className="chrome-lamp y" aria-label="最小化" title="最小化" onClick={() => onChrome('min')}>
          <span>–</span>
        </button>
        <button type="button" className="chrome-lamp g" aria-label="全屏" title="全屏" onClick={() => onChrome('zoom')}>
          <span>⤢</span>
        </button>
        <div className="chrome-pill-sep" aria-hidden="true" />
        <button
          type="button"
          className="chrome-pill-exp"
          title="折叠/展开侧栏"
          aria-label="折叠/展开侧栏"
          aria-pressed={!!sidebarCollapsed}
          onClick={() => onChrome('toggle')}
        >
          <SidebarIcon size={15} strokeWidth={1.4} />
        </button>
      </div>
    </div>
  );
}
