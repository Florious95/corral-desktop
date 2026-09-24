import { isLocalUrl } from './local.js';
import { nativeCapabilities } from './nativeCapabilities.js';

/*
 * localStorage persistence (CLIENT-CONTRACT §4).
 *
 * One JSON document per key, all under the `corral.desktop.v1.` prefix. The
 * legacy AgentMirror prefix is read once and copied forward for upgrades.
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

export function isNativeDesktop() {
  return nativeCapabilities.environment === 'swift' || isTauri();
}

export const PREFIX = 'corral.desktop.v1.';
export const LEGACY_PREFIX = 'agentmirror.desktop.v1.';

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

export function backupUiSnapshot(storage) {
  if (isNativeDesktop() && storage && typeof storage.length === 'number') {
    try {
      const snapshot = {};
      for (let i = 0; i < storage.length; i++) {
        const k = storage.key(i);
        if (k && (k.startsWith(PREFIX) || k.startsWith(LEGACY_PREFIX) || k.startsWith('am.'))) {
          const v = storage.getItem(k);
          if (typeof v === 'string') snapshot[k] = v;
        }
      }
      if (Object.keys(snapshot).length > 0) {
        nativeCapabilities.migration.saveUI(snapshot).catch(() => {});
      }
    } catch (_) {}
  }
}

function legacyKey(key) {
  return key.startsWith(PREFIX) ? `${LEGACY_PREFIX}${key.slice(PREFIX.length)}` : key;
}

function readJsonWithLegacy(storage, key) {
  const current = readJson(storage, key);
  if (current !== undefined) return current;
  const legacy = readJson(storage, legacyKey(key));
  if (legacy !== undefined) writeJson(storage, key, legacy);
  return legacy;
}

function writeJson(storage, key, value) {
  const serialized = JSON.stringify(value);
  try {
    if (storage?.getItem(key) === serialized) return true;
  } catch {
    // Read failures should not prevent a best-effort write below.
  }
  try {
    storage?.setItem(key, serialized);
    backupUiSnapshot(storage);
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
    .filter((d) => d
      && ['id', 'name', 'url', 'token'].every((k) => typeof d[k] === 'string')
      && d.id.length > 0 && d.name.length > 0 && d.url.length > 0
      && (d.token.length > 0 || isLocalUrl(d.url)))
    .map((d) => ({ id: d.id, name: d.name, url: d.url, token: d.token }));
}

/** @returns {{id:string,name:string,url:string,token:string}[]} tokens included — internal use only. */
export function loadDevices(storage) {
  // Desktop shell: never read pairing material from localStorage (UI-SPEC §7.4).
  if (isNativeDesktop()) return [];
  return normalizeDevices(readJsonWithLegacy(storage, KEYS.devices));
}

export function saveDevices(devices, storage) {
  const payload = devices.map((d) => ({ id: d.id, name: d.name, url: d.url, token: d.token }));
  if (isNativeDesktop()) {
    queueSecureSave(payload);
    return true;
  }
  return writeJson(storage, KEYS.devices, payload);
}

/**
 * Serialize async writes as one in-flight operation and retain only the latest
 * requested value. Equal serialized values are ignored before they can enter
 * the queue. The returned idle() hook is intentionally small and deterministic
 * so persistence behavior can be tested without a Tauri runtime.
 */
export function createLatestWinsQueue(write) {
  let lastSerialized;
  let desiredSerialized;
  let pending = null;
  let inFlight = null;
  let draining = null;

  const drain = async () => {
    while (pending) {
      const next = pending;
      pending = null;
      inFlight = next;
      if (next.serialized !== lastSerialized) {
        try {
          await write(next.value);
          lastSerialized = next.serialized;
        } catch {
          // Keep the UI state in memory; a later changed save may retry.
          if (desiredSerialized === next.serialized) desiredSerialized = lastSerialized;
        }
      }
      inFlight = null;
    }
  };

  const start = () => {
    if (draining) return;
    const run = drain();
    draining = run;
    run.then(() => {
      if (draining !== run) return;
      draining = null;
      if (pending) start();
    }, () => {
      if (draining !== run) return;
      draining = null;
      if (pending) start();
    });
  };

  return {
    enqueue(value) {
      const serialized = JSON.stringify(value);
      if (serialized === desiredSerialized) return false;
      desiredSerialized = serialized;
      if (serialized === inFlight?.serialized) {
        pending = null;
        return false;
      }
      if (serialized === lastSerialized && !inFlight) {
        pending = null;
        return false;
      }
      pending = { value, serialized };
      start();
      return true;
    },
    prime(value) {
      const serialized = JSON.stringify(value);
      if (draining || pending) return false;
      lastSerialized = serialized;
      desiredSerialized = serialized;
      return true;
    },
    async idle() {
      for (;;) {
        if (draining) {
          await draining;
        } else if (pending) {
          start();
        } else {
          return;
        }
      }
    },
  };
}

let storePromise;

async function pluginStore() {
  // Browser `npm run dev` never sets __TAURI_INTERNALS__; skip before Vite even
  // follows the specifier (vite.config.js also strips these modules from the
  // browser graph). Desktop shell still loads the real plugin.
  if (!isTauri()) throw new Error('plugin-store is desktop-only');
  const { load } = await import('@tauri-apps/plugin-store');
  // The queue below owns the only save boundary; plugin autoSave would race
  // with the explicit set → save → lock transaction.
  if (!storePromise) storePromise = load(SECURE_STORE_FILE, { autoSave: false });
  return storePromise;
}

let secureStoreLoader = pluginStore;
async function lockSecureStore() {
  const { invoke } = await import('@tauri-apps/api/core');
  await invoke('lock_devices_file');
}
let secureStoreLocker = lockSecureStore;

/** Desktop hydrate. Tests inject a fake backend through setSecureStoreForTests. */
export async function loadDevicesSecure() {
  if (!isNativeDesktop()) return [];
  let devicesRaw;
  if (secureStoreLoader !== pluginStore) {
    const s = await secureStoreLoader();
    devicesRaw = await s.get('devices');
  } else {
    devicesRaw = await nativeCapabilities.secureStore.get('devices');
  }
  const devices = normalizeDevices(devicesRaw);
  secureSaveQueue.prime(devices);
  return devices;
}

async function writeSecureDevices(payload) {
  if (secureStoreLoader !== pluginStore) {
    const s = await secureStoreLoader();
    await s.set('devices', payload);
    await s.save();
    await secureStoreLocker();
  } else {
    await nativeCapabilities.secureStore.set('devices', payload);
  }
}

let secureSaveQueue = createLatestWinsQueue(writeSecureDevices);

/**
 * Replace the secure backend in isolated tests without loading Tauri modules.
 * Runtime code always uses the default plugin-store loader above.
 */
export function setSecureStoreForTests(backend) {
  secureStoreLoader = backend?.load || pluginStore;
  secureStoreLocker = backend?.lock || lockSecureStore;
  secureSaveQueue = createLatestWinsQueue(writeSecureDevices);
}

function queueSecureSave(devices) {
  if (isNativeDesktop()) secureSaveQueue.enqueue(devices);
}

/** Await all queued secure-store work; useful for deterministic shell tests. */
export function flushSecureSaves() {
  return secureSaveQueue.idle();
}

/** @returns {string[]} device ids that participate in the aggregated model. */
export function loadCheckedDevices(storage) {
  return stringArray(readJsonWithLegacy(storage, KEYS.checkedDevices));
}

/** Distinguishes "user unchecked everything" ([]) from "never written" (default: all checked). */
export function hasCheckedDevices(storage) {
  return Array.isArray(readJsonWithLegacy(storage, KEYS.checkedDevices));
}

export function saveCheckedDevices(ids, storage) {
  return writeJson(storage, KEYS.checkedDevices, stringArray(ids));
}

/** @returns {string[]} favKey() values. */
export function loadFavorites(storage) {
  return stringArray(readJsonWithLegacy(storage, KEYS.favorites));
}

export function saveFavorites(keys, storage) {
  return writeJson(storage, KEYS.favorites, stringArray(keys));
}

/** @returns {{sidebarCollapsed:boolean,panes:string[],activePane:string|null,lastSpace:string|null}} */
export function loadUi(storage) {
  const raw = readJsonWithLegacy(storage, KEYS.ui);
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
export function forgetDevice(deviceId, storage, checkedIds) {
  const owned = (s) => !s.startsWith(`${deviceId}::`);
  saveFavorites(loadFavorites(storage).filter(owned), storage);
  const checked = checkedIds === undefined
    ? loadCheckedDevices(storage).filter((id) => id !== deviceId)
    : checkedIds.filter((id) => id !== deviceId);
  saveCheckedDevices(checked, storage);
  const ui = loadUi(storage);
  saveUi({
    ...ui,
    panes: ui.panes.filter(owned),
    activePane: ui.activePane && !owned(ui.activePane) ? null : ui.activePane,
    lastSpace: ui.lastSpace && !owned(ui.lastSpace) ? null : ui.lastSpace,
  }, storage);
}
