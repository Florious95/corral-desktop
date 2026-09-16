import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
import { isNativeDesktop, loadDevicesSecure } from './core/store.js';
import { nativeCapabilities } from './core/nativeCapabilities.js';
import './styles/tokens.css';
import './styles/app.css';

async function boot() {
  let seedDevices = [];
  if (isNativeDesktop()) {
    try {
      // OPEN-1: 启动时尝试从原生 migration 恢复 UI 快照至 localStorage（仅当尚未有工作区时）
      if (typeof localStorage !== 'undefined' && !localStorage.getItem('am.workspace.v2') && !localStorage.getItem('am.workspace.v1')) {
        try {
          const uiSnapshot = await Promise.race([
            nativeCapabilities.migration.loadUI(),
            new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 400)),
          ]);
          if (uiSnapshot && typeof uiSnapshot === 'object') {
            for (const [k, v] of Object.entries(uiSnapshot)) {
              if (k.startsWith('am.') && typeof v === 'string') {
                localStorage.setItem(k, v);
              }
            }
          }
        } catch (_) {
          // 容错忽略，降级到默认初始状态
        }
      }
      seedDevices = await Promise.race([
        loadDevicesSecure(),
        new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 600)),
      ]);
    } catch (err) {
      console.warn('Could not hydrate devices from secure store, falling back to stable default:', err);
      seedDevices = [];
    }
  }
  const rootEl = document.getElementById('root');
  if (rootEl) {
    createRoot(rootEl).render(
      <StrictMode>
        <App seedDevices={seedDevices} />
      </StrictMode>,
    );
  }
}

boot();

