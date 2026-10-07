const {
  debianConsoleBanner,
  openRemoteConsole,
  normalizeGuestConsole,
  restartFromConsole,
  send,
  setStartMenuTimeout,
  waitForConsoleText,
} = require('../lib/console.cjs');
const { goto } = require('../lib/webui.cjs');
const { label } = require('../lib/i18n.cjs');

async function captureConsole(session, page, frame, checkpoint) {
  await session.locator(
    page,
    checkpoint,
    frame.locator('#terminal .xterm-screen').first(),
    { padding: 4 },
  );
}

async function captureWebConsole(session, page, checkpoint, language, includeSidebar = false) {
  await page.locator('#perex').scrollIntoViewIfNeeded();
  const targets = [
    page.locator('#perex h1', { hasText: label(language, 'remoteConsoleForVps') }).first(),
    page.locator('#vpsadmin-console-frame'),
  ];
  if (includeSidebar) {
    await page.locator('#vps-action-status').evaluate((element) => {
      element.textContent = '';
    });
    await page.locator('#aside .webui-tip, #aside #transactions').evaluateAll((elements) => {
      for (const element of elements) element.style.display = 'none';
    });
    await page.evaluate(() => new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(resolve));
    }));
    targets.push(
      page.locator('#aside > h3').first(),
      page.locator('#aside #boot-button').locator('xpath=ancestor::table[1]'),
    );
  }
  await session.shot(page, checkpoint, targets);
}

async function run({ cluster, fixtures, language, page, session }) {
  const vps = fixtures.vpsId;
  const guestBoot = /(?:[\w.-]+ login:)|Debian GNU\/Linux/i;
  let normalBootVerified = false;
  try {
    await goto(page, `/?page=adminvps&action=info&veid=${vps}`);
    await session.titleAndFirstTable(page, 'console/open-web-console');
    await session.section(page, 'start-menu/vps-action', label(language, 'startMenu'));
    await session.documentationSection(
      page,
      'rescue-mode/boot-form',
      'vps.boot-rescue',
    );

    await setStartMenuTimeout(page, vps, 60);
    let remote = await openRemoteConsole(page, vps);
    await send(remote.frame, '\r');
    let initial = await waitForConsoleText(
      remote.frame,
      /Start Menu|emergency shell|\/ #|(?:[\w.-]+ login:)|Debian GNU\/Linux/i,
    );
    if (/emergency shell|\/ #/i.test(initial)) {
      await send(remote.frame, 'exit\r');
      initial = await waitForConsoleText(remote.frame, /Start Menu/);
    }
    if (/Start Menu/.test(initial)) await send(remote.frame, 'i');
    await waitForConsoleText(remote.frame, guestBoot);
    const banner = await debianConsoleBanner(
      cluster,
      fixtures.node,
      fixtures.vpsId,
      fixtures.hostname,
    );
    await normalizeGuestConsole(
      remote.frame,
      banner,
      { includeRemoteWelcome: true },
    );
    await captureWebConsole(session, page, 'console/web-console', language);

    await restartFromConsole(page);
    await waitForConsoleText(remote.frame, /Start Menu/);
    await captureConsole(session, page, remote.frame, 'start-menu/main-menu');

    await send(remote.frame, '\u001b[B');
    await waitForConsoleText(remote.frame, /Select NixOS generation/);
    await captureConsole(session, page, remote.frame, 'start-menu/nixos-generation-action');

    await send(remote.frame, '\r');
    await waitForConsoleText(remote.frame, /Configuration 2/);
    await captureConsole(session, page, remote.frame, 'start-menu/generation-list');

    await send(remote.frame, '\u001b');
    await send(remote.frame, 'i');
    await waitForConsoleText(remote.frame, /vps login:/i);
    normalBootVerified = true;
    await normalizeGuestConsole(remote.frame, banner);

    await captureWebConsole(
      session,
      page,
      'rescue-mode/vps-console-boot',
      language,
      true,
    );
  } finally {
    await setStartMenuTimeout(page, vps, 5);
    if (normalBootVerified) {
      const deadline = Date.now() + 5 * 60_000;
      let running = false;
      while (Date.now() < deadline) {
        await goto(page, `/?page=adminvps&action=info&veid=${vps}`);
        const details = await page.locator('#content-in').innerText();
        if (/Status:\s*(?:běží|running)/i.test(details)) {
          running = true;
          break;
        }
        await page.waitForTimeout(2_000);
      }
      if (!running) {
        throw new Error(`VPS #${vps} did not remain in normal boot`);
      }
    } else {
      const deadline = Date.now() + 5 * 60_000;
      let restart;
      while (Date.now() < deadline) {
        await goto(page, `/?page=adminvps&action=info&veid=${vps}`);
        restart = page.locator(`a[href*="run=restart"][href*="veid=${vps}"]`).first();
        if ((await restart.count()) > 0) break;
        await page.waitForTimeout(2_000);
      }
      if (!restart || (await restart.count()) === 0) {
        throw new Error(`Unable to restore normal boot for VPS #${vps}`);
      }
      await restart.click();
      await page.waitForLoadState('domcontentloaded');
      await page.waitForTimeout(12_000);
    }
  }
}

module.exports = { run };
