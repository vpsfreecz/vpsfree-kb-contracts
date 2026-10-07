const { goto, preparePage, submitLast } = require('./webui.cjs');

async function setStartMenuTimeout(page, vpsId, timeout) {
  await goto(page, `/?page=adminvps&action=info&veid=${vpsId}`);
  const form = page.locator(`form[action*="action=startmenu"][action*="veid=${vpsId}"]`);
  await form.locator('input[name="timeout"]').fill(String(timeout));
  await submitLast(form);
  await page.waitForLoadState('domcontentloaded');
  await preparePage(page);
  await page.waitForTimeout(4_000);
}

async function openRemoteConsole(page, vpsId) {
  await goto(page, `/?page=adminvps&action=info&veid=${vpsId}`);
  const link = page.locator(`a[href*="page=console"][href*="veid=${vpsId}"]`).first();
  const href = await link.getAttribute('href');
  if (!href) throw new Error(`No remote-console link found for VPS #${vpsId}`);
  await goto(page, new URL(href, page.url()).href);
  const iframe = page.locator('#vpsadmin-console-frame');
  await iframe.waitFor({ state: 'visible' });
  const handle = await iframe.elementHandle();
  const frame = await handle.contentFrame();
  await frame.locator('#terminal .xterm-screen').waitFor({ state: 'visible', timeout: 60_000 });
  return { frame, iframe };
}

async function consoleText(frame) {
  return frame.locator('#terminal .xterm-rows').innerText();
}

function canonicalGuestConsole(text, verifiedBanner = null) {
  const lines = text.split(/\r?\n/).map((line) => line.trimEnd());
  const findLast = (pattern, label) => {
    const line = lines.findLast((candidate) => pattern.test(candidate));
    if (!line) throw new Error(`Console is missing ${label}: ${text}`);
    return line.trimStart();
  };
  const banner = verifiedBanner || findLast(
    /^Debian GNU\/Linux\b/,
    'the Debian console banner',
  );
  if (!/^Debian GNU\/Linux\b/.test(banner)) {
    throw new Error(`Invalid Debian console banner: ${banner}`);
  }
  return [
    banner,
    '',
    findLast(/^vps login:/, 'the fixture login prompt'),
  ].join('\n');
}

async function debianConsoleBanner(cluster, node, vpsId, hostname) {
  const output = await cluster.ssh(node, [
    'osctl', 'ct', 'exec', String(vpsId), '/bin/cat', '/etc/os-release',
  ]);
  const id = output.match(/^ID=(?:"([^"]+)"|([^\n]+))$/m)?.slice(1).find(Boolean);
  const version = output.match(/^VERSION_ID=(?:"([^"]+)"|([^\n]+))$/m)
    ?.slice(1).find(Boolean);
  if (id !== 'debian' || !version) {
    throw new Error(`VPS #${vpsId} is not a versioned Debian guest: ${output}`);
  }
  return `Debian GNU/Linux ${version} ${hostname} console`;
}

async function normalizeGuestConsole(frame, banner, { includeRemoteWelcome = false } = {}) {
  const guest = canonicalGuestConsole(await consoleText(frame), banner);
  const output = includeRemoteWelcome
    ? `Welcome to vpsFree.cz Remote Console\n\n${guest}`
    : guest;
  await frame.evaluate((value) => new Promise((resolve) => {
    clearTimeout(window.remoteConsole.timeout);
    window.remoteConsole.term.reset();
    window.remoteConsole.term.write(
      `\u001b[2J\u001b[H${value.replaceAll('\n', '\r\n')}`,
      () => {
        window.remoteConsole.term.refresh(0, window.remoteConsole.term.rows - 1);
        requestAnimationFrame(() => requestAnimationFrame(resolve));
      },
    );
  }), output);
}

async function send(frame, data) {
  await frame.evaluate((value) => { window.remoteConsole.pendingData += value; }, data);
  await frame.waitForTimeout(350);
}

async function waitForConsoleText(frame, pattern, timeout = 90_000) {
  const deadline = Date.now() + timeout;
  let text = '';
  while (Date.now() < deadline) {
    text = await consoleText(frame);
    if (pattern.test(text)) return text;
    await frame.waitForTimeout(500);
  }
  throw new Error(`Console did not show ${pattern}: ${text}`);
}

async function restartFromConsole(page) {
  const iframe = page.locator('#vpsadmin-console-frame');
  const handle = await iframe.elementHandle();
  const frame = await handle.contentFrame();
  await frame.evaluate(() => {
    window.remoteConsole.term.clear();
    window.remoteConsole.term.reset();
  });
  await page.evaluate(() => window.vps_do('restart'));
  await page.waitForTimeout(1_500);
}

module.exports = {
  canonicalGuestConsole,
  consoleText,
  debianConsoleBanner,
  normalizeGuestConsole,
  openRemoteConsole,
  restartFromConsole,
  send,
  setStartMenuTimeout,
  waitForConsoleText,
};
