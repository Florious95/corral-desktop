/*
 * localStorage persistence (CLIENT-CONTRACT §4).
 *
 * One JSON document per key, all under the `agentmirror.desktop.v1.` prefix.
 * Every loader swallows parse/storage failures and returns a stable default —
 * corrupt data must never white-screen the app. Schema violations drop the
 * whole entry rather than patching it half-way.
 *
 * ⛔ Device tokens live here and in Client.token only; they must never reach a
 * log, a toast, or any UI projection (DeviceManager.devices strips them).
 */

/** Plugin-store filename under $APP_DATA. Desktop shell only; ⛔ not localStorage. */
export const SECURE_STORE_FILE = 'devices.json';

export function isTauri() {
  return typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
}

export const PREFIX = 'agentmirror.desktop.v1.';

export const KEYS = Object.freeze({
  devices: `${PREFIX}devices`,
  checkedDevices: `${PREFIX}checkedDevices`,
  favorites: `${PREFIX}favorites`,
  ui: `${PREFIX}ui`,
});

export const DEFAULT_UI = Object.freeze({
  sidebarCollapsed: false,
  panes: [],
  activePane: null,
  lastSpace: null,
});

function readJson(storage, key) {
  try {
    const raw = storage?.getItem(key);
    if (typeof raw !== 'string' || raw.length === 0) return undefined;
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

function writeJson(storage, key, value) {
  try {
    storage?.setItem(key, JSON.stringify(value));
    return true;
  } catch {
    return false; // quota / private mode / no storage: state stays in memory
  }
}

function stringArray(value) {
  return Array.isArray(value) ? value.filter((s) => typeof s === 'string' && s.length > 0) : [];
}

/**
 * Stable favourite key. Not ref-based: refs change when the daemon restarts,
 * (deviceId, cwd, session name) survives it (UI-SPEC §0).
 */
export function favKey(deviceId, cwd, sessionName) {
  return `${deviceId}::${cwd}::${sessionName}`;
}

function normalizeDevices(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((d) => d && ['id', 'name', 'url', 'token'].every((k) => typeof d[k] === 'string' && d[k].length > 0))
    .map((d) => ({ id: d.id, name: d.name, url: d.url, token: d.token }));
}

/** @returns {{id:string,name:string,url:string,token:string}[]} tokens included — internal use only. */
export function loadDevices(storage) {
  // Desktop shell: never read pairing material from localStorage (UI-SPEC §7.4).
  if (isTauri()) return [];
  return normalizeDevices(readJson(storage, KEYS.devices));
}

export function saveDevices(devices, storage) {
  if (isTauri()) {
    queueSecureSave(devices);
    return true;
  }
  return writeJson(storage, KEYS.devices, devices.map((d) => ({ id: d.id, name: d.name, url: d.url, token: d.token })));
}

let storePromise;

async function pluginStore() {
  // Browser `npm run dev` never sets __TAURI_INTERNALS__; skip before Vite even
  // follows the specifier (vite.config.js also strips these modules from the
  // browser graph). Desktop shell still loads the real plugin.
  if (!isTauri()) throw new Error('plugin-store is desktop-only');
  const { load } = await import('@tauri-apps/plugin-store');
  if (!storePromise) storePromise = load(SECURE_STORE_FILE, { autoSave: true });
  return storePromise;
}

/** Desktop hydrate. Tests never call this (no Tauri). */
export async function loadDevicesSecure() {
  if (!isTauri()) return [];
  try {
    const s = await pluginStore();
    return normalizeDevices(await s.get('devices'));
  } catch {
    return [];
  }
}

function queueSecureSave(devices) {
  if (!isTauri()) return;
  const payload = devices.map((d) => ({ id: d.id, name: d.name, url: d.url, token: d.token }));
  pluginStore()
    .then(async (s) => {
      await s.set('devices', payload);
      await s.save();
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('lock_devices_file');
    })
    .catch(() => { /* quota / plugin missing: keep in-memory only */ });
}

/** @returns {string[]} device ids that participate in the aggregated model. */
export function loadCheckedDevices(storage) {
  return stringArray(readJson(storage, KEYS.checkedDevices));
}

/** Distinguishes "user unchecked everything" ([]) from "never written" (default: all checked). */
export function hasCheckedDevices(storage) {
  return Array.isArray(readJson(storage, KEYS.checkedDevices));
}

export function saveCheckedDevices(ids, storage) {
  return writeJson(storage, KEYS.checkedDevices, stringArray(ids));
}

/** @returns {string[]} favKey() values. */
export function loadFavorites(storage) {
  return stringArray(readJson(storage, KEYS.favorites));
}

export function saveFavorites(keys, storage) {
  return writeJson(storage, KEYS.favorites, stringArray(keys));
}

/** @returns {{sidebarCollapsed:boolean,panes:string[],activePane:string|null,lastSpace:string|null}} */
export function loadUi(storage) {
  const raw = readJson(storage, KEYS.ui);
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return { ...DEFAULT_UI };
  return {
    sidebarCollapsed: raw.sidebarCollapsed === true,
    panes: stringArray(raw.panes),
    activePane: typeof raw.activePane === 'string' ? raw.activePane : null,
    lastSpace: typeof raw.lastSpace === 'string' ? raw.lastSpace : null,
  };
}

export function saveUi(ui, storage) {
  return writeJson(storage, KEYS.ui, { ...DEFAULT_UI, ...ui, panes: stringArray(ui?.panes) });
}

/** Drop every favourite / pane / checked entry belonging to one device. */
export function forgetDevice(deviceId, storage) {
  const owned = (s) => !s.startsWith(`${deviceId}::`);
  saveFavorites(loadFavorites(storage).filter(owned), storage);
  saveCheckedDevices(loadCheckedDevices(storage).filter((id) => id !== deviceId), storage);
  const ui = loadUi(storage);
  saveUi({
    ...ui,
    panes: ui.panes.filter(owned),
    activePane: ui.activePane && !owned(ui.activePane) ? null : ui.activePane,
    lastSpace: ui.lastSpace && !owned(ui.lastSpace) ? null : ui.lastSpace,
  }, storage);
}
