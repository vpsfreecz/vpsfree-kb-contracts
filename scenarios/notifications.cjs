const { goto } = require('../lib/webui.cjs');

function documentationTable(page, documentationId) {
  return page.locator(
    `[data-vpsadmin-doc-id="${documentationId}"]:not(a)`,
  )
    .first()
    .locator('xpath=(ancestor::table[1] | following::table[1])[1]');
}

async function editUrlForRow(page, text, action) {
  const link = page.locator('#content-in tr')
    .filter({ hasText: text })
    .filter({ has: page.locator(`a[href*="action=${action}"]`) })
    .first()
    .locator(`a[href*="action=${action}"]`)
    .first();
  await link.waitFor({ state: 'visible' });
  return link.getAttribute('href');
}

async function run({ page, session }) {
  await goto(page, '/?page=notifications&action=routes');
  await session.locator(
    page,
    'notifications/routes',
    documentationTable(page, 'notifications.routes'),
  );

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Documentation e-mail', 'receiver_edit'));
  await session.locator(
    page,
    'notifications/receiver',
    documentationTable(page, 'notifications.receiver-form'),
  );

  await goto(page, '/?page=notifications&action=time_intervals');
  await goto(page, await editUrlForRow(page, 'Office hours', 'time_interval_edit'));
  await session.locator(
    page,
    'notifications/time-interval',
    documentationTable(page, 'notifications.time-interval-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Documentation alerts', 'route_edit'));
  await session.locator(
    page,
    'notifications/route-time-intervals',
    documentationTable(page, 'notifications.route-time-intervals'),
  );

  await goto(page, '/?page=notifications&action=events');
  await goto(page, await editUrlForRow(
    page,
    'Scheduled-out documentation event',
    'event_show',
  ));
  const matches = documentationTable(page, 'notifications.event-route-matches');
  const details = matches.locator('details');
  if (await details.count()) {
    await details.first().evaluate((element) => { element.open = true; });
  }
  await session.locator(
    page,
    'notifications/event-suppressed',
    documentationTable(page, 'notifications.event-route-matches'),
  );
}

module.exports = { run };
