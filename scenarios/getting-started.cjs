const { goto } = require('../lib/webui.cjs');
const { fixturesFor, label } = require('../lib/i18n.cjs');

async function run({ fixtures, language, page, session }) {
  const vps = fixtures.vpsId;

  await goto(page, '/?page=adminm');
  await session.navigationTitleAndFirstTable(page, 'getting-started/members-list');

  await goto(page, '/?page=adminvps&action=list');
  await session.navigationTitleAndFirstTable(page, 'getting-started/vps-list');

  await goto(page, `/?page=adminvps&action=info&veid=${vps}`);
  await session.titleAndFirstTable(page, 'getting-started/vps-details');
  await session.section(page, 'getting-started/ssh-connection', label(language, 'sshConnection'));
  await session.section(page, 'ssh-keys/host-key-fingerprints', label(language, 'sshHostKeys'));
  await session.section(
    page,
    'getting-started/deploy-public-key',
    label(language, 'deployPublicKey'),
  );
  await goto(page, '/?page=adminm&action=pubkey_add&id=2');
  await session.locator(
    page,
    'ssh-keys/add-public-key',
    page.locator('#content-in').first(),
  );

  await goto(page, `/?page=adminvps&action=info&veid=${vps}`);
  await session.locator(
    page,
    'ssh-keys/deploy-public-key',
    page.locator('form', { hasText: fixturesFor(language).publicKey }).first(),
  );
}

module.exports = { run };
