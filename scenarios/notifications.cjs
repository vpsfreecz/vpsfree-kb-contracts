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

function routeForm(page, documentationId) {
  const heading = page.locator(
    `[data-vpsadmin-doc-id="${documentationId}"]`,
  ).first();
  return [
    heading,
    heading.locator('xpath=following-sibling::form[1]'),
  ];
}

function targetForms(page, documentationId) {
  if (documentationId !== 'notifications.target-form') {
    throw new Error(`Unexpected target form documentation ID: ${documentationId}`);
  }
  return page.locator(
    'form[action*="page=notifications"][action*="action=target_edit"]',
  ).first();
}

async function openRouteMatchDetails(page) {
  const details = documentationTable(
    page,
    'notifications.event-route-matches',
  ).locator('details');
  for (let i = 0; i < await details.count(); i += 1) {
    await details.nth(i).evaluate((element) => { element.open = true; });
  }
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

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Account contact', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/example-role-receiver',
    receiverTables(page, 'notifications.receiver-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Account-role notifications', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-role-routing',
    await routeTables(page, 'notifications.route-form', 'roles'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Admin-role notifications', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-role-admin-route',
    await routeTables(page, 'notifications.route-form', 'roles'),
  );

  await goto(page, '/?page=notifications&action=events');
  await goto(page, await editUrlForRow(
    page,
    'Role-routing documentation event',
    'event_show',
  ));
  await openRouteMatchDetails(page);
  await session.shot(
    page,
    'notifications/example-role-result',
    documentationTable(page, 'notifications.event-route-matches'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Mute selected OOM reports', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-mute-oom',
    await routeTables(page, 'notifications.route-form', 'cgroup'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Mute incident feed for VPS', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-mute-incident-route',
    await routeTables(page, 'notifications.route-form', 'codename'),
  );

  await goto(page, '/?page=notifications&action=events');
  await goto(page, await editUrlForRow(
    page,
    'Muted incident documentation event',
    'event_show',
  ));
  await openRouteMatchDetails(page);
  await session.shot(
    page,
    'notifications/example-mute-result',
    documentationTable(page, 'notifications.event-route-matches'),
  );

  await goto(page, '/?page=notifications&action=targets');
  await goto(page, await editUrlForRow(page, 'Operations Telegram', 'target_edit'));
  await session.shot(
    page,
    'notifications/example-telegram-target',
    targetForms(page, 'notifications.target-form'),
  );

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Operations Telegram', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/example-telegram',
    receiverTables(page, 'notifications.receiver-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Monitoring to Telegram', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-telegram-monitoring-route',
    routeForm(page, 'notifications.route-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Incident reports to Telegram', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-telegram-incident-route',
    routeForm(page, 'notifications.route-form'),
  );

  await goto(page, '/?page=notifications&action=events');
  await goto(page, await editUrlForRow(
    page,
    'Telegram delivery documentation event',
    'event_show',
  ));
  await openRouteMatchDetails(page);
  await session.shot(
    page,
    'notifications/example-telegram-result',
    documentationTable(page, 'notifications.event-route-matches'),
  );

  await goto(page, '/?page=notifications&action=targets');
  await goto(page, await editUrlForRow(
    page,
    'Suspension telephone',
    'target_edit',
  ));
  const smsVerificationForm = page.locator('form').filter({
    has: page.locator('input[name="code"]'),
  }).first();
  await session.shot(
    page,
    'notifications/example-sms-verification',
    [
      targetForms(page, 'notifications.target-form'),
      smsVerificationForm,
    ],
  );
  await smsVerificationForm.locator('input[name="code"]').fill('123456');
  await smsVerificationForm.locator(
    'input[type="submit"], button[type="submit"]',
  ).click();

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Suspension SMS', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/example-sms',
    receiverTables(page, 'notifications.receiver-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Account suspension SMS', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-sms-account-route',
    routeForm(page, 'notifications.route-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'VPS suspension SMS', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-sms-vps-route',
    routeForm(page, 'notifications.route-form'),
  );

  await goto(page, '/?page=notifications&action=events');
  await goto(page, await editUrlForRow(
    page,
    'SMS suspension documentation event',
    'event_show',
  ));
  await openRouteMatchDetails(page);
  await session.shot(
    page,
    'notifications/example-sms-result',
    documentationTable(page, 'notifications.event-route-matches'),
  );

  await goto(page, '/?page=notifications&action=targets');
  await goto(page, await editUrlForRow(page, 'Resource-change endpoint', 'target_edit'));
  await session.shot(
    page,
    'notifications/example-webhook-target',
    targetForms(page, 'notifications.target-form'),
  );

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Resource-change webhook', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/example-webhook',
    receiverTables(page, 'notifications.receiver-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'VPS resource-change webhook', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-webhook-route',
    routeForm(page, 'notifications.route-form'),
  );

  await goto(page, '/?page=notifications&action=events');
  await goto(page, await editUrlForRow(
    page,
    'Webhook delivery documentation event',
    'event_show',
  ));
  await openRouteMatchDetails(page);
  await session.shot(
    page,
    'notifications/example-webhook-result',
    documentationTable(page, 'notifications.event-route-matches'),
  );
}

module.exports = { run };
