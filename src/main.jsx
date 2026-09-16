import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
import { isNativeDesktop, loadDevicesSecure } from './core/store.js';
import './styles/tokens.css';
import './styles/app.css';

async function boot() {
  const seedDevices = isNativeDesktop() ? await loadDevicesSecure() : undefined;
  createRoot(document.getElementById('root')).render(
    <StrictMode>
      <App seedDevices={seedDevices} />
    </StrictMode>,
  );
}

boot();
