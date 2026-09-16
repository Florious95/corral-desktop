import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
import { isNativeDesktop, loadDevicesSecure } from './core/store.js';
import './styles/tokens.css';
import './styles/app.css';

async function boot() {
  let seedDevices;
  if (isNativeDesktop()) {
    try {
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
