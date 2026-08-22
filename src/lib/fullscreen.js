/**
 * Native macOS fullscreen (Tauri Overlay) is not document.fullscreenElement.
 * Also treat "inner size fills the display" as fullscreen — some zoom-fill
 * states leave isFullscreen() false while still covering the screen.
 */
export function fillsDisplay() {
  if (typeof window === 'undefined') return false;
  const sw = window.screen.availWidth || window.screen.width;
  const sh = window.screen.availHeight || window.screen.height;
  return window.innerWidth >= sw - 24 && window.innerHeight >= sh - 80;
}

export async function watchFullscreen(onChange) {
  if (typeof window === 'undefined') return () => {};
  const emit = (fs) => onChange(!!(fs || fillsDisplay()));
  try {
    const { getCurrentWindow } = await import('@tauri-apps/api/window');
    const w = getCurrentWindow();
    const apply = async () => {
      let fs = false;
      try { fs = await w.isFullscreen(); } catch { fs = false; }
      emit(fs);
    };
    await apply();
    const un = await w.onResized(apply);
    const onWin = () => { apply(); };
    window.addEventListener('resize', onWin);
    return () => {
      try { un(); } catch { /* */ }
      window.removeEventListener('resize', onWin);
    };
  } catch {
    const apply = () => emit(!!document.fullscreenElement);
    apply();
    document.addEventListener('fullscreenchange', apply);
    window.addEventListener('resize', apply);
    return () => {
      document.removeEventListener('fullscreenchange', apply);
      window.removeEventListener('resize', apply);
    };
  }
}
