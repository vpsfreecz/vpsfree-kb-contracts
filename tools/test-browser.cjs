const assert = require('assert');
const net = require('net');
const { once } = require('events');

const { closeServer, startProxy } = require('../lib/browser.cjs');

async function main() {
  const teardownProxy = await startProxy({ network: 'local' });
  const openSocket = net.connect(teardownProxy.address().port, '127.0.0.1');
  await once(openSocket, 'connect');
  const socketClosed = once(openSocket, 'close');

  await Promise.race([
    closeServer(teardownProxy),
    new Promise((_, reject) => setTimeout(
      () => reject(new Error('proxy teardown timed out with an open tunnel')),
      1_000,
    )),
  ]);

  await socketClosed;
  assert.strictEqual(openSocket.destroyed, true);

  const upstream = net.createServer();
  upstream.listen(0, '127.0.0.1');
  await once(upstream, 'listening');
  const upstreamConnected = once(upstream, 'connection');
  const proxy = await startProxy({ network: 'bridge', servicesIp: '127.0.0.1' });
  const tunnel = net.connect(proxy.address().port, '127.0.0.1');
  await once(tunnel, 'connect');
  tunnel.write(
    `CONNECT webui.aitherdev.int.vpsfree.cz:${upstream.address().port} HTTP/1.1\r\n\r\n`,
  );
  const [response] = await once(tunnel, 'data');
  assert.match(response.toString(), /^HTTP\/1\.1 200 Connection Established/);
  const [upstreamSocket] = await upstreamConnected;

  tunnel.destroy();
  upstreamSocket.destroy();
  await closeServer(proxy);
  await new Promise((resolve, reject) => upstream.close((error) => {
    if (error) reject(error);
    else resolve();
  }));
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
