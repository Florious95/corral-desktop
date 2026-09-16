import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
import { isNativeDesktop, loadDevicesSecure } from './core/store.js';
import { nativeCapabilities } from './core/nativeCapabilities.js';
import './styles/tokens.css';
import './styles/app.css';

async function boot() {
  let seedDevices;
  if (isNativeDesktop()) {
    try {
      // OPEN-1: 启动时尝试从原生 migration 恢复 UI 快照至 localStorage（仅当尚未有工作区时）
      if (typeof localStorage !== 'undefined' && !localStorage.getItem('am.workspace.v2') && !localStorage.getItem('am.workspace.v1')) {
        try {
          const uiSnapshot = await nativeCapabilities.migration.loadUI();
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
      seedDevices = await loadDevicesSecure();
    } catch (err) {
      console.error('Fatal: failed to load secure devices from native store:', err);
      throw err;
    }
  }
  createRoot(document.getElementById('root')).render(
    <StrictMode>
      <App seedDevices={seedDevices} />
    </StrictMode>,
  );
}

boot();
