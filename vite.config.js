import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  // Production loads from the tauri://localhost custom protocol, not an HTTP origin.
  // Default base '/' emits src="/assets/…"; WKWebView then resolves those as
  // host-less URLs that never hit the protocol handler, so the module never
  // runs and the SPA stays a blank #root. Relative base keeps asset URLs on
  // tauri://localhost/assets/….
  base: './',
  clearScreen: false,
  server: { port: 1430, strictPort: true },
});
