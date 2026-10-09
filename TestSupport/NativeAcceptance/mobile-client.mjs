// A phone on the same private daemon: subscribes with its own grid as client_type "mobile".
import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(process.env.CORRAL_WEB_PACKAGE);
const { WebSocket } = require('ws');
const [port, ref, cols, rows, log] = process.argv.slice(2);
if (Number(port) === 9900) throw Error('unsafe upstream');
const trace = fs.createWriteStream(log, { flags: 'wx', mode: 0o600 });
const socket = new WebSocket(`ws://127.0.0.1:${port}/ws`);
const send = (type, payload) => {
  const recordedPayload = type === 'auth' ? { token: '<redacted>' } : payload;
  trace.write(JSON.stringify({ at: Date.now(), direction: 'client-to-daemon', type, payload: recordedPayload }) + '\n');
  socket.send(JSON.stringify({ v: 1, type, payload }));
};
socket.on('open', () => send('auth', { token: process.env.AGENTMIRROR_TOKEN }));
socket.on('message', (data, binary) => {
  if (binary) return trace.write(JSON.stringify({ at: Date.now(), binary: true, kind: data[3], bytes: data.length }) + '\n');
  const frame = JSON.parse(data.toString());
  trace.write(JSON.stringify({ at: Date.now(), type: frame.type, payload: frame.payload }) + '\n');
  if (frame.type === 'auth_ack') send('subscribe', { ref, rows: Number(rows), cols: Number(cols), client_type: 'mobile' });
});
socket.on('close', (code, reason) => {
  trace.write(JSON.stringify({ at: Date.now(), type: 'close', code, reason: reason.toString() }) + '\n');
});
process.on('SIGTERM', () => { socket.close(); setTimeout(() => process.exit(0), 200); });
