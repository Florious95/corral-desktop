import fs from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(process.env.CORRAL_WEB_PACKAGE);
const { WebSocket, WebSocketServer } = require('ws');
const directory = process.env.CORRAL_ACCEPTANCE_RUN;
const port = Number(process.env.CORRAL_ACCEPTANCE_DAEMON_PORT);
if (!Number.isInteger(port) || port === 9900 || port < 1024) throw Error('unsafe upstream');
const trace = fs.createWriteStream(`${directory}/wire.jsonl`, { flags: 'wx', mode: 0o600 });
const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
server.on('listening', () => fs.writeFileSync(`${directory}/proxy-port`, String(server.address().port), { mode: 0o600 }));
server.on('connection', downstream => {
  const upstream = new WebSocket(`ws://127.0.0.1:${port}/ws`);
  const queued = [];
  upstream.on('open', () => queued.splice(0).forEach(([data, binary]) => upstream.send(data, { binary })));
  function record(direction, data, binary) {
    let entry = { at: Date.now(), direction, binary };
    if (binary) {
      const n = data[4];
      entry = { ...entry, kind: data[3], ref: data.subarray(5, 5 + n).toString(), payload: data.subarray(5 + n).toString('base64') };
    } else {
      const frame = JSON.parse(data.toString());
      entry.type = frame.type;
      entry.payload = frame.type === 'auth' ? '[redacted]' : frame.payload;
    }
    trace.write(JSON.stringify(entry) + '\n');
  }
  downstream.on('message', (data, binary) => {
    record('client-to-daemon', data, binary);
    if (upstream.readyState === WebSocket.OPEN) upstream.send(data, { binary });
    else queued.push([data, binary]);
  });
  upstream.on('message', (data, binary) => {
    record('daemon-to-client', data, binary);
    if (downstream.readyState === WebSocket.OPEN) downstream.send(data, { binary });
  });
  downstream.on('close', () => upstream.close());
  upstream.on('close', () => downstream.close());
  upstream.on('error', error => { trace.write(JSON.stringify({ upstreamError: error.message }) + '\n'); downstream.close(); });
});
