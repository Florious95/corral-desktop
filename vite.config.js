import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

/** `tauri dev` / `tauri build` set these; bare `npm run dev` does not. */
function isTauriBundling() {
  return Boolean(
    process.env.TAURI_ENV_PLATFORM
    || process.env.TAURI_PLATFORM
    || process.env.TAURI_ENV_DEBUG
    || process.env.TAURI_DEBUG,
  );
}

/**
 * Browser graph must not resolve @tauri-apps/* (Vite import-analysis 500s the
 * page). Desktop bundling keeps the real modules so tokens stay in plugin-store.
 */
function skipTauriPluginsInBrowser() {
  const empty = '\0agentmirror-tauri-browser-empty';
  const ids = new Set(['@tauri-apps/plugin-store', '@tauri-apps/api/core']);
  return {
    name: 'skip-tauri-plugins-in-browser',
    enforce: 'pre',
    resolveId(id) {
      if (ids.has(id)) return empty;
    },
    load(id) {
      if (id !== empty) return undefined;
      return [
        'export async function load() { throw new Error("plugin-store is desktop-only"); }',
        'export async function invoke() { throw new Error("tauri invoke is desktop-only"); }',
      ].join('\n');
    },
  };
}

export default defineConfig({
  plugins: isTauriBundling() ? [react()] : [skipTauriPluginsInBrowser(), react()],
  clearScreen: false,
  server: { port: 1430, strictPort: true },
});
