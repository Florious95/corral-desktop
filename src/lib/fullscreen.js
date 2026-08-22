/**
 * Native macOS fullscreen (Tauri Overlay) is not document.fullscreenElement.
 */
export async function watchFullscreen(onChange) {
  if (typeof window === 'undefined') return () => {};
  try {
    const { getCurrentWindow } = await import('@tauri-apps/api/window');
    const w = getCurrentWindow();
    const apply = async () => {
      try { onChange(await w.isFullscreen()); } catch { onChange(false); }
    };
    await apply();
    const un = await w.onResized(apply);
    return () => { try { un(); } catch { /* */ } };
  } catch {
    const apply = () => onChange(!!document.fullscreenElement);
    apply();
    document.addEventListener('fullscreenchange', apply);
    return () => document.removeEventListener('fullscreenchange', apply);
  }
}
