const { goto } = require('../lib/webui.cjs');

function documentationTable(page, documentationId) {
  return page.locator(
    `[data-vpsadmin-doc-id="${documentationId}"]:not(a)`,
  )
    .first()
    .locator('xpath=(ancestor::table[1] | following::table[1])[1]');
}

function receiverTables(page, documentationId) {
  const receiver = documentationTable(page, documentationId);
  return [
    receiver,
    receiver.locator('xpath=following::table[1]'),
  ];
}

async function routeTables(page, documentationId, matcherField) {
  const heading = page.locator(
    `[data-vpsadmin-doc-id="${documentationId}"]`,
  ).first();
  const route = heading.locator('xpath=following-sibling::form[1]');
  const matchers = page.locator('#content-in table')
    .filter({ has: page.locator('code', { hasText: matcherField }) })
    .first();
  const matcherForm = matchers.locator('xpath=ancestor::form[1]');
  const matcherHeading = matcherForm.locator('xpath=preceding-sibling::*[1]');

  await route.evaluate((routeForm, field) => {
    const matcherTable = Array.from(document.querySelectorAll('#content-in table'))
      .find((table) => Array.from(table.querySelectorAll('code'))
        .some((code) => code.textContent.trim() === field));
    const finalHeading = matcherTable?.closest('form')?.previousElementSibling;

    for (
      let sibling = routeForm.nextElementSibling;
      sibling && sibling !== finalHeading;
      sibling = sibling.nextElementSibling
    ) {
      sibling.style.display = 'none';
    }
  }, matcherField);

  return [heading, route, matcherHeading, matcherForm];
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

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Account-role notifications', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-role-routing',
    await routeTables(page, 'notifications.route-form', 'roles'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Mute selected OOM reports', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-mute-oom',
    await routeTables(page, 'notifications.route-form', 'cgroup'),
  );

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Operations Telegram', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/example-telegram',
    receiverTables(page, 'notifications.receiver-form'),
  );

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Suspension SMS', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/example-sms',
    receiverTables(page, 'notifications.receiver-form'),
  );

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Resource-change webhook', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/example-webhook',
    receiverTables(page, 'notifications.receiver-form'),
  );
}

module.exports = { run };
