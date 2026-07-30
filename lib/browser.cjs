const fs = require('fs');
const http = require('http');
const net = require('net');
const path = require('path');
const { chromium } = require('playwright');

const serverSockets = new WeakMap();

function chromiumExecutable() {
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE) {
    return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
  }

  const browsersPath = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!browsersPath) {
    throw new Error('PLAYWRIGHT_BROWSERS_PATH is not set; enter nix develop');
  }
  const chromiumDir = fs
    .readdirSync(browsersPath)
    .find((name) => name.startsWith('chromium-'));
  if (!chromiumDir) {
    throw new Error(`No Chromium directory found in ${browsersPath}`);
  }
  const candidates = [
    path.join(browsersPath, chromiumDir, 'chrome-linux64', 'chrome'),
    path.join(browsersPath, chromiumDir, 'chrome-linux', 'chrome'),
  ];
  const executable = candidates.find((candidate) => fs.existsSync(candidate));
  if (!executable) {
    throw new Error(`No Chromium executable found in ${browsersPath}`);
  }
  return executable;
}

async function startProxy(cluster) {
  const suffix = '.aitherdev.int.vpsfree.cz';
  const proxy = http.createServer();
  const sockets = new Set();
  serverSockets.set(proxy, sockets);

  proxy.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });

  proxy.on('connect', (request, clientSocket, head) => {
    const target = new URL(`http://${request.url}`);
    const isCluster = target.hostname.endsWith(suffix);
    const isLocalCluster = isCluster && cluster.network === 'local';
    const hostname = isCluster && !isLocalCluster
      ? cluster.servicesIp
      : target.hostname;
    const serverSocket = net.connect(
      isLocalCluster ? 10443 : Number(target.port || 443),
      isLocalCluster ? '127.0.0.1' : hostname,
      () => {
        clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        if (head.length > 0) {
          serverSocket.write(head);
        }
        serverSocket.pipe(clientSocket);
        clientSocket.pipe(serverSocket);
      },
    );
    serverSocket.on('error', () => clientSocket.destroy());
    clientSocket.on('error', () => serverSocket.destroy());
  });

  await new Promise((resolve) => proxy.listen(0, '127.0.0.1', resolve));
  return proxy;
}

async function closeServer(server) {
  const sockets = serverSockets.get(server);
  if (!sockets) throw new Error('Server was not created by startProxy');

  const closed = new Promise((resolve, reject) => server.close((error) => {
    if (error) reject(error);
    else resolve();
  }));
  for (const socket of sockets) socket.destroy();
  await closed;
  serverSockets.delete(server);
}

async function launchBrowser(cluster, viewport, language = 'cs') {
  const proxy = await startProxy(cluster);
  const address = proxy.address();
  const browser = await chromium.launch({
    executablePath: chromiumExecutable(),
    headless: true,
    args: ['--no-sandbox'],
    proxy: { server: `http://127.0.0.1:${address.port}` },
  });
  const context = await browser.newContext({
    baseURL: cluster.webuiBaseUrl,
    ignoreHTTPSErrors: true,
    locale: language === 'cs' ? 'cs-CZ' : 'en-US',
    timezoneId: 'Europe/Prague',
    viewport,
  });

  return {
    browser,
    context,
    proxyUrl: `http://127.0.0.1:${address.port}`,
    async close() {
      await browser.close();
      await closeServer(proxy);
    },
  };
}

async function login(page, cluster, language) {
  const account = cluster.account();
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  const logout = page.locator(
    '#logout a[href*="action=logout"], form[action*="action=logout"]',
  ).first();

  if ((await logout.count()) === 0) {
    await page
      .locator('form[action="?page=login&action=login"] input[type="submit"]')
      .click();
    await page.waitForLoadState('domcontentloaded');
    await page.locator('input[name="user"]').fill(account.login);
    await page.locator('input[name="password"]').fill(account.password);
    await page.locator('input[name="login_credentials"]').click({ noWaitAfter: true });
    await logout.waitFor({ state: 'attached', timeout: 60_000 });
  }

  const locale = language === 'cs' ? 'cs_CZ.utf8' : 'en_US.utf8';
  const htmlLanguage = language === 'cs' ? 'cs' : 'en';
  if ((await page.locator('html').getAttribute('lang')) !== htmlLanguage) {
    const flag = page.locator(
      `#langbox a[href*="newlang=${locale}"]`,
    );
    await Promise.all([
      page.waitForNavigation({ waitUntil: 'domcontentloaded' }),
      flag.click(),
    ]);
  }
  await page.locator(`html[lang="${htmlLanguage}"]`).waitFor();
}

module.exports = { chromiumExecutable, closeServer, launchBrowser, login, startProxy };
