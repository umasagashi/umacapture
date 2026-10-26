// An HTTPS_PROXY relay for one app process, so a round trip can cut that process off the network and
// let it back on without restarting it.
//
//   node relay.mjs <proxy-port> <control-port> [pass|refuse|drop]
//
// The app tunnels every HTTPS request through CONNECT on <proxy-port>. GET http://127.0.0.1:<control-port>/<mode>
// switches the mode and answers it; GET /state answers it unchanged.
//
// * pass   -- tunnels are opened to the requested host.
// * refuse -- open tunnels are destroyed and every new CONNECT is reset at once: the app sees the
//             connection fail immediately, as it does when the network is down.
// * drop   -- open tunnels are destroyed and every new CONNECT is held without an answer: the app sees
//             nothing until its own timeout, as it does when packets are lost.
import http from 'node:http';
import net from 'node:net';

const [port, controlPort] = [Number(process.argv[2] || 18080), Number(process.argv[3] || 18081)];
const modes = new Set(['pass', 'refuse', 'drop']);
let mode = modes.has(process.argv[4]) ? process.argv[4] : 'pass';
const tunnels = new Set();
const held = new Set();
const log = (...parts) => console.log(new Date().toISOString(), ...parts);

function closeAll() {
  for (const tunnel of tunnels) {
    tunnel.client.destroy();
    tunnel.upstream.destroy();
  }
  tunnels.clear();
  for (const socket of held) socket.destroy();
  held.clear();
}

const proxy = http.createServer((request, response) => {
  response.writeHead(405);
  response.end();
});
proxy.on('connect', (request, client, head) => {
  if (mode === 'refuse') {
    log('refuse', request.url);
    client.destroy();
    return;
  }
  if (mode === 'drop') {
    log('drop', request.url);
    held.add(client);
    client.on('close', () => held.delete(client));
    client.on('error', () => held.delete(client));
    return;
  }
  const [host, upstreamPort] = request.url.split(':');
  const upstream = net.connect(Number(upstreamPort || 443), host, () => {
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    upstream.write(head);
    upstream.pipe(client);
    client.pipe(upstream);
  });
  const tunnel = { client, upstream };
  tunnels.add(tunnel);
  const end = () => {
    tunnels.delete(tunnel);
    client.destroy();
    upstream.destroy();
  };
  upstream.on('error', end);
  client.on('error', end);
  upstream.on('close', end);
  client.on('close', end);
  log('pass', request.url);
});
proxy.listen(port, '127.0.0.1', () => log('proxy', port, mode));

http
  .createServer((request, response) => {
    const asked = request.url.slice(1);
    if (modes.has(asked) && asked !== mode) {
      mode = asked;
      if (mode !== 'pass') closeAll();
      log('mode', mode);
    }
    response.end(`${mode}\n`);
  })
  .listen(controlPort, '127.0.0.1', () => log('control', controlPort));
