const { expect } = require('@playwright/test');
const { renderTerminal, runTrafficMonitor } = require('../lib/terminal.cjs');
const { goto } = require('../lib/webui.cjs');
const { label } = require('../lib/i18n.cjs');
const { assertInventoryMember } = require('../fixtures/prepare.cjs');

async function run({ cluster, fixtures, language, page, proxyUrl, sourceRoot, invocationRoot, session }) {
  const vps = fixtures.vpsId;

  if (['traffic/vps-monthly-transfers', 'networking/routed-addresses', 'networking/interface-addresses']
    .some((checkpoint) => session.wants(checkpoint))) {
    await goto(page, `/?page=adminvps&action=info&veid=${vps}`);
    await session.locator(
      page,
      'traffic/vps-monthly-transfers',
      page.locator('form', { hasText: label(language, 'transfersIn') }).first(),
    );
    const routedAddressForm = page.locator(
      'form[action*="action=iproute_select"]',
    );
    await expect(routedAddressForm.locator('option[value="ipv6"]')).toHaveCount(1);
    await session.locator(page, 'networking/routed-addresses', routedAddressForm);

    const interfaceAddressForm = page.locator(
      'form[action*="action=hostaddr_add"]',
    );
    await expect(
      interfaceAddressForm.locator('select[name="hostaddr_public_v6"]'),
    ).toHaveCount(1);
    await session.locator(page, 'networking/interface-addresses', interfaceAddressForm);
  }
  if (session.wants('reverse-dns/configure-reverse-record')) {
    await goto(page, fixtures.reverseRecordRoute);
    await session.locator(
      page,
      'reverse-dns/configure-reverse-record',
      page.locator('#content-in'),
    );
  }

  if (session.wants('networking/ip-address-list')) {
    await goto(page, '/?page=networking&action=ip_addresses&list=1&limit=100');
    await assertInventoryMember(page, fixtures.inventoryMember);
    const table = page.locator('#content-in table').last();
    const detached = table.locator('tr', { hasText: `${fixtures.inventoryAddress}/32` });
    await expect(detached).toHaveCount(1);
    await expect(detached).toBeVisible();
    await expect(detached.locator('a[href*="action=route_edit"]')).toHaveCount(1);
    await expect(detached.locator('a[href*="action=assignments"]')).toHaveCount(1);
    await expect(detached.locator('a[href*="action=route_assign"]')).toHaveCount(1);
    const assigned = table.locator(`a[href*="action=info"][href*="veid=${fixtures.inventoryVpsId}"]`).first();
    await expect(assigned).toBeVisible();
    await session.locator(page, 'networking/ip-address-list', page.locator('#content-in'));
  }

  if (session.wants('traffic/monthly-traffic')) {
    await goto(page, '/?page=networking&action=traffic');
    await session.locator(page, 'traffic/monthly-traffic', page.locator('#content-in'));
  }

  if (session.wants('traffic/live-monitor-web')) {
    await goto(page, '/?page=networking&action=live');
    await session.locator(page, 'traffic/live-monitor-web', page.locator('#content-in'));
  }

  if (session.wants('traffic/live-monitor-cli')) {
    const output = await runTrafficMonitor({ cluster, fixtures, proxyUrl, sourceRoot, invocationRoot });
    const terminal = await page.context().newPage();
    try {
      await renderTerminal(
        terminal,
        cluster.consoleBaseUrl,
        'vpsfreectl network top',
        output,
      );
      await session.locator(
        terminal,
        'traffic/live-monitor-cli',
        terminal.locator('#terminal'),
        { padding: 12 },
      );
    } finally {
      await terminal.close();
    }
  }
}

module.exports = { run };
