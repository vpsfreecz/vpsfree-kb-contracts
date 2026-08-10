const { goto } = require('../lib/webui.cjs');
const { label } = require('../lib/i18n.cjs');

async function run({ fixtures, language, page, session }) {
  await goto(page, `/?page=adminvps&action=info&veid=${fixtures.kvmVpsId}`);
  const datasets = page.locator('#content-in h2', {
    hasText: new RegExp(`^\\s*${label(language, 'datasets')}\\s*$`),
  }).first();
  const mounts = page.locator('#content-in h2', {
    hasText: new RegExp(`^\\s*${label(language, 'mounts')}\\s*$`),
  }).first();
  await session.shot(page, 'vps-details/datasets', [
    datasets,
    datasets.locator('xpath=following-sibling::*[1]'),
    mounts,
    mounts.locator('xpath=following-sibling::*[1]'),
  ]);
}

module.exports = { run };
