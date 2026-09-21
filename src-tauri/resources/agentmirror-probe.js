// AgentMirror Pi activity probe.
// Installed by the desktop lifecycle into ~/.pi/agent/plugins/ and the
// standard ~/.pi/agent/extensions/ discovery path.

import { createServer } from "node:net";
import { chmodSync, mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { join } from "node:path";

const dir = process.env.NODEPROBE_PI_ACTIVITY_DIR ||
  (process.env.HOME ? join(process.env.HOME, ".local", "state", "nodeprobe", "pi-activity") : undefined);
const pid = process.pid;
const seat = process.env.NODEPROBE_PI_SEAT || String(pid);
const path = dir ? join(dir, `${pid}.json`) : undefined;
const socketPath = dir ? join(dir, `${pid}.sock`) : undefined;
const schemaVersion = 2;
let instanceId = dir ? randomUUID() : undefined;
let activity = "idle";
let sessionName;
let heartbeat;
let server;

function currentRecord() {
  return {
    schema_version: schemaVersion,
    provider: "pi",
    pid,
    seat,
    activity,
    session_name: sessionName ?? null,
    updated_at_ms: Date.now(),
    socket_path: socketPath,
    instance_id: instanceId,
  };
}

function publish() {
  if (!path) return;
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  chmodSync(dir, 0o700);
  const tmp = `${path}.tmp-${pid}`;
  writeFileSync(tmp, JSON.stringify(currentRecord()) + "\n", { mode: 0o600 });
  renameSync(tmp, path);
}

function startChannel() {
  if (!socketPath || server) return;
  instanceId = randomUUID();
  try {
    unlinkSync(socketPath);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  server = createServer((socket) => {
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
  server.on("error", () => {});
  server.listen(socketPath, () => chmodSync(socketPath, 0o600));
}

async function stopChannel() {
  if (!server) return;
  await new Promise((resolve) => server.close(resolve));
  server = undefined;
  try {
    if (socketPath) unlinkSync(socketPath);
  } catch {}
}

export default function (pi) {
  pi.on("session_start", async (_event, ctx) => {
    startChannel();
    sessionName = ctx.sessionManager.getSessionName();
    activity = "idle";
    publish();
    if (!heartbeat) heartbeat = setInterval(publish, 1000).unref();
  });

  pi.on("session_info_changed", async (event) => {
    sessionName = event.name;
    publish();
  });

  pi.on("agent_start", async () => {
    activity = "working";
    publish();
  });

  // Pi documents agent_end as non-settled; do not mark idle here.
  pi.on("agent_end", async () => {
    publish();
  });

  pi.on("tool_execution_start", async () => {
    activity = "working";
    publish();
  });

  pi.on("tool_execution_end", async () => {
    publish();
  });

  pi.on("agent_settled", async () => {
    activity = "idle";
    publish();
  });

  pi.on("session_shutdown", async () => {
    if (heartbeat) clearInterval(heartbeat);
    heartbeat = undefined;
    activity = "idle";
    publish();
    await stopChannel();
    try {
      if (path) unlinkSync(path);
    } catch {}
  });
}
