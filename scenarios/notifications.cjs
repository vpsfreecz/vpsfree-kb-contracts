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

function matcherTables(page, documentationId) {
  if (documentationId !== 'notifications.matcher-form') {
    throw new Error(`Unexpected matcher form documentation ID: ${documentationId}`);
  }
  const matcher = documentationTable(page, documentationId);
  return [matcher, matcher.locator('xpath=following::table[1]')];
}

function documentedEventType(page, documentationId, selector) {
  return page.locator(`[data-vpsadmin-doc-id="${documentationId}"]`).locator(selector);
}

async function keepBasicRoutes(page, documentationId) {
  if (documentationId !== 'notifications.routes') {
    throw new Error(`Unexpected route list documentation ID: ${documentationId}`);
  }
  const table = documentationTable(page, documentationId);
  await table.locator('tr').evaluateAll((rows) => {
    const labels = ['Documentation alerts', 'Default route', 'Default admin route'];
    rows.slice(1).forEach((row) => {
      if (!labels.some((label) => row.textContent.includes(label))) {
        row.style.display = 'none';
      }
    });
  });
  return table;
}

async function routeTables(page, documentationId, matcherField) {
  const heading = page.locator(
    `[data-vpsadmin-doc-id="${documentationId}"]`,
  ).first();
  const route = heading.locator('xpath=following-sibling::form[1]');
  const matcherForm = page.locator(
    'form[action*="page=notifications"][action*="action=matcher_save"]',
  )
    .filter({ has: page.locator('code', { hasText: matcherField }) })
    .first();
  const matchers = matcherForm.locator('table')
    .filter({ has: page.locator('code', { hasText: matcherField }) })
    .first();
  const matcherHeading = matcherForm.locator('xpath=preceding-sibling::*[1]');

  await route.evaluate((routeForm, field) => {
    const finalForm = Array.from(document.querySelectorAll(
      'form[action*="page=notifications"][action*="action=matcher_save"]',
    )).find((form) => Array.from(form.querySelectorAll('code'))
      .some((code) => code.textContent.trim() === field));
    const finalHeading = finalForm?.previousElementSibling;

    for (
      let sibling = routeForm.nextElementSibling;
      sibling && sibling !== finalHeading;
      sibling = sibling.nextElementSibling
    ) {
      sibling.style.display = 'none';
    }
  }, matcherField);

  // The matcher table can overflow its form when translated column labels need
  // more space. Include the table explicitly so the crop follows its rendered
  // width instead of clipping controls that extend beyond the form.
  return [heading, route, matcherHeading, matcherForm, matchers];
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

function muteComposer(page, documentationId) {
  if (documentationId !== 'notifications.mute-similar-form') {
    throw new Error(`Unexpected mute composer documentation ID: ${documentationId}`);
  }
  return routeForm(page, documentationId);
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

async function assertRouteListLayout(page) {
  const table = documentationTable(page, 'notifications.routes');
  const result = await table.evaluate((element) => {
    const headers = Array.from(element.querySelectorAll('th'));
    const row = Array.from(element.querySelectorAll('tr'))
      .find((candidate) => candidate.querySelector('a[href*="action=route_delete"]'));
    const cells = row ? Array.from(row.children) : [];
    const content = document.querySelector('#content-in');
    const tableRect = element.getBoundingClientRect();
    const contentRect = content?.getBoundingClientRect();

    return {
      headerCount: headers.length,
      actionHeaders: headers.slice(-3).map((header) => header.textContent.trim()),
      cellCount: cells.length,
      editCell: cells.at(-3)?.querySelector('a[href*="action=route_edit"]') !== null,
      addCell: cells.at(-2)?.querySelector('a[href*="action=route_new"]') !== null,
      deleteCell: cells.at(-1)?.querySelector('a[href*="action=route_delete"]') !== null,
      actionWidths: cells.slice(-3).map((cell) => cell.getBoundingClientRect().width),
      overflowsContent: contentRect ? tableRect.right > contentRect.right + 1 : true,
    };
  });

  if (
    result.headerCount !== 7
    || result.actionHeaders.some(Boolean)
    || result.cellCount !== 7
    || !result.editCell
    || !result.addCell
    || !result.deleteCell
    || result.overflowsContent
    || result.actionWidths.some((width) => width > 64)
  ) {
    throw new Error(`Unexpected notification route table layout: ${JSON.stringify(result)}`);
  }
}

async function run({ fixtures, page, session }) {
  await goto(page, '/?page=notifications&action=routes');
  await assertRouteListLayout(page);
  await session.locator(
    page,
    'notifications/routes',
    await keepBasicRoutes(page, 'notifications.routes'),
  );

  await goto(page, '/?page=notifications&action=event_types');
  await session.locator(
    page,
    'notifications/event-types',
    page.locator('[data-vpsadmin-doc-id="notifications.event-types"]'),
  );

  await goto(page, '/?page=notifications&action=event_types#event-type-vps-oom_report');
  const oomEventType = page.locator('#event-type-vps-oom_report');
  await oomEventType.locator('xpath=ancestor::details[1]').evaluate((details) => {
    details.open = true;
  });
  await session.locator(
    page,
    'notifications/event-type-vps-oom-report',
    documentedEventType(page, 'notifications.event-types', '#event-type-vps-oom_report'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Mute selected OOM reports', 'route_edit'));
  await page.locator('a[href*="action=matcher_new"]').first().click();
  const matcherForm = page.locator(
    'form[action*="page=notifications"][action*="action=matcher_new"]',
  );
  await matcherForm.locator('select[name="field"]').selectOption('cgroup');
  await matcherForm.locator('select[name="operator"]').selectOption('=*');
  await matcherForm.locator('input[name="value"]').fill('/user.slice/**/*.scope');
  await session.shot(
    page,
    'notifications/matcher-form',
    matcherTables(page, 'notifications.matcher-form'),
  );

  await goto(page, '/?page=notifications&action=targets');
  await session.locator(
    page,
    'notifications/targets',
    documentationTable(page, 'notifications.targets'),
  );

  await goto(page, '/?page=notifications&action=receivers');
  await goto(page, await editUrlForRow(page, 'Documentation e-mail', 'receiver_edit'));
  await session.shot(
    page,
    'notifications/receiver',
    receiverTables(page, 'notifications.receiver-form'),
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

  await goto(page, '/?page=notifications&action=events&limit=100');
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

  await goto(page, `/?page=oom_reports&action=show&id=${fixtures.reports.oomReportId}`);
  await page.locator('[data-vpsadmin-doc-id="oom-reports.mute-similar"]').click();
  await session.shot(
    page,
    'notifications/mute-oom-composer',
    muteComposer(page, 'notifications.mute-similar-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Grouped OOM notifications', 'route_edit'));
  await session.shot(
    page,
    'notifications/grouping-route',
    routeForm(page, 'notifications.route-grouping-form'),
  );

  await goto(page, '/?page=notifications&action=routes');
  await goto(page, await editUrlForRow(page, 'Mute incident feed for VPS', 'route_edit'));
  await session.shot(
    page,
    'notifications/example-mute-incident-route',
    await routeTables(page, 'notifications.route-form', 'codename'),
  );

  await goto(
    page,
    `/?page=incidents&action=show&id=${fixtures.reports.incidentReportId}`,
  );
  await page.locator('[data-vpsadmin-doc-id="incidents.mute-similar"]').click();
  await session.shot(
    page,
    'notifications/mute-incident-composer',
    muteComposer(page, 'notifications.mute-similar-form'),
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

  await goto(page, '/?page=notifications&action=events&limit=100');
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
    'Suspension telephone verification',
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

  await goto(page, '/?page=notifications&action=events&limit=100');
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

  await goto(page, '/?page=notifications&action=events&limit=100');
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
