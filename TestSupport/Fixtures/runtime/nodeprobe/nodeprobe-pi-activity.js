// Pi 0.84.4 extension: publish one atomic, per-process lifecycle record.
// Load with: pi --extension /path/to/nodeprobe-pi-activity.js
// Set NODEPROBE_PI_ACTIVITY_DIR to a private local directory shared with nodeprobe.

import { createServer } from "node:net";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { join } from "node:path";

const dir = process.env.NODEPROBE_PI_ACTIVITY_DIR ||
  (process.env.HOME ? join(process.env.HOME, ".local", "state", "nodeprobe", "pi-activity") : undefined);
const pid = process.pid;
const seat = process.env.NODEPROBE_PI_SEAT || String(pid);
const path = dir ? join(dir, `${pid}.json`) : undefined;
const socketPath = dir ? join(dir, `${pid}.sock`) : undefined;
const schemaVersion = 2;

// Pi can discover the same extension more than once in one process. Module
// scope is not a singleton in that case (for example, a query-string import
// or a duplicate auto-discovery path evaluates this file twice). Keep channel
// ownership in the process-global registry so one PID can have one listener.
const registryKey = Symbol.for("agentmirror.nodeprobe.pi.activity.channels");
const registry = globalThis[registryKey] || (globalThis[registryKey] = new Map());
const stateKey = `${pid}\0${dir || ""}`;
let state = registry.get(stateKey);
if (!state) {
  state = {
    instanceId: dir ? randomUUID() : undefined,
    activity: "idle",
    sessionName: undefined,
    heartbeat: undefined,
    server: undefined,
    startPromise: undefined,
    stopPromise: undefined,
  };
  registry.set(stateKey, state);
}

function currentRecord() {
  return {
    schema_version: schemaVersion,
    provider: "pi",
    pid,
    seat,
    activity: state.activity,
    session_name: state.sessionName ?? null,
    updated_at_ms: Date.now(),
    socket_path: socketPath,
    instance_id: state.instanceId,
  };
}

function ownsRecord() {
  if (!path || !state.instanceId) return false;
  try {
    const record = JSON.parse(readFileSync(path, "utf8"));
    return record.pid === pid && record.instance_id === state.instanceId;
  } catch {
    return false;
  }
}

function unlinkOwnedSocket() {
  if (!socketPath || !existsSync(socketPath) || !ownsRecord()) return;
  try {
    unlinkSync(socketPath);
  } catch {}
}

function unlinkOwnedRecord() {
  if (!path || !ownsRecord()) return;
  try {
    unlinkSync(path);
  } catch {}
}

function publish() {
  if (!path) return;
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  const tmp = `${path}.tmp-${pid}`;
  writeFileSync(tmp, JSON.stringify(currentRecord()) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
}

async function startChannel() {
  if (!socketPath) return;
  if (state.startPromise) return state.startPromise;
  // A restart must finish the old listener before rebinding. Never unlink a
  // pathname owned by another instance: the JSON record is the ownership
  // fence, and EADDRINUSE is safer than stealing a live channel.
  if (state.stopPromise) await state.stopPromise;
  if (state.server) return;
  if (state.startPromise) return state.startPromise;
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  if (existsSync(socketPath)) unlinkOwnedSocket();

  state.startPromise = (async () => {
    const candidate = createServer((socket) => {
      socket.on("error", () => {});
      let input = "";
      socket.on("data", (chunk) => {
        input += chunk.toString();
        const newline = input.indexOf("\n");
        if (newline === -1) return;
        try {
          const request = JSON.parse(input.slice(0, newline));
          if (typeof request.challenge !== "string") return socket.destroy();
          socket.end(JSON.stringify({ challenge: request.challenge, ...currentRecord() }) + "\n");
        } catch {
          socket.destroy();
        }
      });
    });
    state.server = candidate;
    await new Promise((resolve, reject) => {
      let ready = false;
      candidate.on("error", (error) => {
        if (!ready) {
          state.server = undefined;
          reject(error);
        }
      });
      candidate.listen(socketPath, () => {
        try {
          // The pathname can disappear while the kernel listener remains
          // alive. Let the heartbeat own recovery instead of failing startup
          // on a transient ENOENT between listen and chmod.
          if (existsSync(socketPath)) chmodSync(socketPath, 0o600);
          ready = true;
          resolve();
        } catch (error) {
          state.server = undefined;
          candidate.close(() => reject(error));
        }
      });
    });
  })().finally(() => {
    state.startPromise = undefined;
  });
  return state.startPromise;
}

async function stopChannel() {
  if (state.stopPromise) return state.stopPromise;
  state.stopPromise = (async () => {
    if (state.startPromise) {
      try {
        await state.startPromise;
      } catch {}
    }
    const active = state.server;
    if (!active) {
      unlinkOwnedSocket();
      return;
    }
    await new Promise((resolve) => active.close(resolve));
    if (state.server === active) state.server = undefined;
    unlinkOwnedSocket();
  })().finally(() => {
    state.stopPromise = undefined;
  });
  return state.stopPromise;
}

async function ensureChannel() {
  if (!socketPath) return;
  if (state.server && existsSync(socketPath)) return;
  if (state.server) {
    await stopChannel();
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  await startChannel();
}

async function heartbeat() {
  try {
    await ensureChannel();
  } catch {}
  publish();
}

export default function (pi) {
  pi.on("session_start", async (_event, ctx) => {
    await startChannel();
    state.sessionName = ctx.sessionManager.getSessionName();
    state.activity = "idle";
    publish();
    if (!state.heartbeat) state.heartbeat = setInterval(() => { void heartbeat(); }, 1000).unref();
  });

  pi.on("session_info_changed", async (event) => {
    state.sessionName = event.name;
    publish();
  });

  pi.on("agent_start", async () => {
    state.activity = "working";
    publish();
  });

  // Pi documents agent_end as non-settled; do not mark idle here.
  pi.on("agent_end", async () => {
    publish();
  });

  pi.on("tool_execution_start", async () => {
    state.activity = "working";
    publish();
  });

  pi.on("tool_execution_end", async () => {
    publish();
  });

  pi.on("agent_settled", async () => {
    state.activity = "idle";
    publish();
  });

  pi.on("session_shutdown", async () => {
    if (state.heartbeat) clearInterval(state.heartbeat);
    state.heartbeat = undefined;
    state.activity = "idle";
    publish();
    await stopChannel();
    unlinkOwnedRecord();
  });
}
