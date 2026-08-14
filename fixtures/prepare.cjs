const fs = require('fs');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const { datasetIdsFromHrefs } = require('../lib/dataset-links.cjs');
const { fixturesFor } = require('../lib/i18n.cjs');

const {
  DEFAULT_OS_TEMPLATE,
  goto,
  preparePage,
  selectFirstOption,
  selectRadioByRowText,
  submitLast,
} = require('../lib/webui.cjs');

const DOCUMENTATION_HOST_PUBLIC_KEY =
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC docs-host@example.test';
const DOCUMENTATION_HOST_KEY_FINGERPRINT =
  'SHA256:baqJQcVDEweKmw1OiZxGooCG2MGxYtwsQQzzOstxmiA';

function idFromUrl(raw, name) {
  const value = new URL(raw).searchParams.get(name);
  return value ? Number(value) : null;
}

async function findOwnedVps(page, hostname) {
  await goto(page, '/?page=adminvps&action=list');
  const hrefs = await page.locator('#content-in tr').evaluateAll((rows, expected) =>
    rows.flatMap((row) => {
      const cells = Array.from(row.cells).map((cell) => cell.textContent.trim());
      if (!cells.includes(expected)) return [];
      return Array.from(row.querySelectorAll(
        'a[href*="page=adminvps"][href*="action=info"][href*="veid="]',
      )).map((link) => link.href);
    }), hostname);
  const ids = [...new Set(hrefs.map((href) => idFromUrl(href, 'veid')).filter(Boolean))];
  if (ids.length > 1) {
    throw new Error(`Fixture hostname ${hostname} belongs to multiple VPSes: ${ids.join(', ')}`);
  }
  return ids[0] || null;
}

async function findUserId(page, login) {
  await goto(
    page,
    `/?page=adminm&section=members&action=list&login=${encodeURIComponent(login)}`,
  );
  const ids = await page.locator('#content-in tr').evaluateAll((rows, expected) =>
    rows.flatMap((row) => {
      const cells = Array.from(row.cells).map((cell) => cell.textContent.trim());
      if (cells[1] !== expected || !/^\d+$/.test(cells[0] || '')) return [];
      return [Number(cells[0])];
    }), login);
  const uniqueIds = [...new Set(ids)];
  if (uniqueIds.length !== 1) {
    throw new Error(
      `Expected one fixture user ${login}, found IDs: ${uniqueIds.join(', ') || 'none'}`,
    );
  }
  return uniqueIds[0];
}

async function createVpsIn(
  page,
  userId,
  hostname,
  boot,
  environmentLabel,
  locationLabel,
) {
  await goto(page, `/?page=adminvps&action=new-step-1&user=${userId}`);
  const environmentForm = page.locator('form[name="newvps-step1"]');
  if ((await environmentForm.count()) > 0) {
    const row = environmentForm.locator('tr', { hasText: environmentLabel }).first();
    await row.locator('input[type="radio"][name="environment"]').check({ force: true });
    await submitLast(environmentForm);
    await page.waitForLoadState('domcontentloaded');
    await preparePage(page);
  }

  let form = page.locator('form[name="newvps-step2"]');
  const locationRow = form.locator('tr', { hasText: locationLabel }).first();
  await locationRow.locator('input[type="radio"][name="location"]').check({ force: true });
  await submitLast(form);
  await page.waitForLoadState('domcontentloaded');
  await preparePage(page);

  form = page.locator('form[name="newvps-step2"]');
  await selectRadioByRowText(form, 'os_template', DEFAULT_OS_TEMPLATE);
  await submitLast(form);
  await page.waitForLoadState('domcontentloaded');
  await preparePage(page);

  form = page.locator('form[name="newvps-step3"]');
  await submitLast(form);
  await page.waitForLoadState('domcontentloaded');
  await preparePage(page);

  form = page.locator('form[action*="action=new-submit"]');
  await form.locator('input[name="hostname"]').fill(hostname);
  const userNamespace = form.locator('select[name="user_namespace_map"]');
  if ((await userNamespace.count()) > 0) await selectFirstOption(userNamespace);
  const noUserData = form.locator('input[name="user_data_type"][value="none"]');
  if ((await noUserData.count()) > 0) await noUserData.check({ force: true });
  const bootInput = form.locator('input[name="boot_after_create"]');
  if ((await bootInput.count()) > 0 && (await bootInput.isChecked()) !== boot) {
    await bootInput.setChecked(boot);
  }
  await submitLast(form);
  await page.waitForLoadState('domcontentloaded');
  const id = idFromUrl(page.url(), 'veid');
  if (!id) {
    const content = (await page.locator('body').innerText()).replace(/\s+/g, ' ').trim();
    throw new Error(`Unable to identify newly created VPS at ${page.url()}: ${content}`);
  }
  return id;
}

async function waitForRunning(page, vpsId) {
  const deadline = Date.now() + 10 * 60_000;
  let lastStartRequest = 0;
  while (Date.now() < deadline) {
    await goto(page, `/?page=adminvps&action=info&veid=${vpsId}`);
    const text = await page.locator('#content-in').innerText();
    if (/Běží|Running/i.test(text)) return;
    if (/Vypnuto|Stopped/i.test(text) && Date.now() - lastStartRequest >= 15_000) {
      const start = page.locator(`a[href*="run=start"][href*="veid=${vpsId}"]`).first();
      if ((await start.count()) > 0) {
        await start.click();
        lastStartRequest = Date.now();
      }
    }
    await page.waitForTimeout(3_000);
  }
  throw new Error(`VPS #${vpsId} did not reach the running state`);
}

async function rootDatasetId(page, vpsId) {
  await goto(page, `/?page=adminvps&action=info&veid=${vpsId}`);
  const href = await page
    .locator('a[href*="page=dataset"][href*="dataset="]')
    .first()
    .getAttribute('href');
  if (!href) throw new Error(`Fixture VPS #${vpsId} has no root dataset link`);
  const id = idFromUrl(new URL(href, page.url()).href, 'dataset');
  if (!id) throw new Error(`Fixture VPS #${vpsId} has an invalid root dataset link: ${href}`);
  return id;
}

async function datasetIdsByName(page, name) {
  const hrefs = await page.locator('#content-in tr').evaluateAll((rows, expected) => {
    const escaped = expected.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const pattern = new RegExp(`(?:^|/)${escaped}(?:\\s|$)`);
    return [...new Set(rows.flatMap((row) => {
      if (!pattern.test(row.textContent.trim())) return [];
      return Array.from(row.querySelectorAll('a[href*="page=dataset"]'))
        .map((link) => link.href);
    }))];
  }, name);
  return datasetIdsFromHrefs(hrefs);
}

async function waitForDataset(page, route, name) {
  const deadline = Date.now() + 5 * 60_000;
  while (Date.now() < deadline) {
    await goto(page, route);
    const ids = await datasetIdsByName(page, name);
    if (ids.length > 1) throw new Error(`Multiple fixture datasets match ${name}: ${ids.join(', ')}`);
    if (ids.length === 1) return ids[0];
    await page.waitForTimeout(3_000);
  }
  throw new Error(`Dataset ${name} did not become visible at ${route}`);
}

async function setDatasetQuota(form, field, value) {
  await form.locator(`input[name="${field}"]`).fill(value);
  await form.locator('select[name="quota_unit"]').selectOption('g');
}

async function ensureChildDataset(
  page,
  vpsId,
  parentId,
  { name = 'data', refquotaGiB = '1' } = {},
) {
  const route = `/?page=adminvps&action=info&veid=${vpsId}`;
  await goto(page, route);
  const existing = await datasetIdsByName(page, name);
  if (existing.length > 1) {
    throw new Error(`Multiple fixture datasets match ${name}: ${existing.join(', ')}`);
  }
  if (existing.length === 1) return existing[0];

  await goto(page, `/?page=dataset&action=new&role=hypervisor&parent=${parentId}`);
  const form = page.locator('form[action*="page=dataset"][action*="action=new"]');
  await form.locator('input[name="name"]').fill(name);
  const automount = form.locator('input[name="automount"]');
  if ((await automount.count()) > 0 && await automount.isChecked()) {
    await automount.uncheck();
  }
  await setDatasetQuota(form, 'refquota', refquotaGiB);
  await submitLast(form);
  return waitForDataset(page, route, name);
}

async function ensureDatasetQuota(page, datasetId, refquotaGiB) {
  const route = `/?page=dataset&action=edit&role=hypervisor&id=${datasetId}`;
  await goto(page, route);
  let form = page.locator('form[action*="page=dataset"][action*="action=edit"]');
  const quota = form.locator('input[name="refquota"]');
  const unit = form.locator('select[name="quota_unit"]');
  if (await quota.inputValue() === refquotaGiB && await unit.inputValue() === 'g') return;

  await quota.fill(refquotaGiB);
  await unit.selectOption('g');
  await submitLast(form);

  const deadline = Date.now() + 5 * 60_000;
  while (Date.now() < deadline) {
    await goto(page, route);
    form = page.locator('form[action*="page=dataset"][action*="action=edit"]');
    if (
      await form.locator('input[name="refquota"]').inputValue() === refquotaGiB
      && await form.locator('select[name="quota_unit"]').inputValue() === 'g'
    ) return;
    await page.waitForTimeout(3_000);
  }
  throw new Error(`Dataset #${datasetId} did not reach a ${refquotaGiB} GiB refquota`);
}

async function ensureMount(page, vpsId, datasetId, mountpoint = '/srv/data') {
  const route = `/?page=adminvps&action=info&veid=${vpsId}`;
  await goto(page, route);
  const existing = await page.locator('#content-in tr', { hasText: mountpoint }).count();
  if (existing > 1) throw new Error(`Multiple fixture mounts use ${mountpoint}`);
  if (existing === 1) return;
  await goto(page, `/?page=dataset&action=mount&dataset=${datasetId}&vps=${vpsId}`);
  const form = page.locator('form[action*="action=mount"]');
  await form.locator('input[name="mountpoint"]').fill(mountpoint);
  await submitLast(form);
  const deadline = Date.now() + 5 * 60_000;
  while (Date.now() < deadline) {
    await goto(page, route);
    if ((await page.locator('#content-in tr', { hasText: mountpoint }).count()) > 0) return;
    await page.waitForTimeout(3_000);
  }
  throw new Error(`Fixture mount ${mountpoint} did not become visible`);
}

async function ensureInterfaceAddress(page, vpsId) {
  const route = `/?page=adminvps&action=info&veid=${vpsId}`;
  const deadline = Date.now() + 5 * 60_000;
  let assignmentRequested = false;

  while (Date.now() < deadline) {
    await goto(page, route);
    const form = page.locator('form[action*="action=hostaddr_add"]');
    const reverse = form.locator(
      'a[href*="page=networking"][href*="action=hostaddr_ptr"]',
    );
    if ((await reverse.count()) > 0) {
      const href = new URL(await reverse.first().getAttribute('href'), page.url());
      return `${href.pathname}${href.search}`;
    }

    if (!assignmentRequested) {
      await selectFirstOption(form.locator('select[name="hostaddr_public_v4"]'));
      await Promise.all([
        page.waitForNavigation({ waitUntil: 'domcontentloaded' }),
        form.evaluate((element) => element.requestSubmit()),
      ]);
      const resultText = (await page.locator('#perex').innerText()).replace(/\s+/g, ' ').trim();
      if (!/Plánováno přidání IP adresy|Addition of IP address planned/i.test(resultText)) {
        throw new Error(`Interface address assignment did not succeed: ${resultText}`);
      }
      assignmentRequested = true;
    }
    await page.waitForTimeout(3_000);
  }

  throw new Error('Fixture public IPv4 address did not become an interface address');
}

async function ensureNasDataset(page) {
  const route = '/?page=nas';
  const deadline = Date.now() + 5 * 60_000;
  while (Date.now() < deadline) {
    await goto(page, route);
    const ids = await datasetIdsByName(page, 'nas');
    if (ids.length > 1) {
      throw new Error(`Multiple fixture datasets match nas: ${ids.join(', ')}`);
    }
    if (ids.length === 1) {
      const [id] = ids;
      const row = page.locator(
        '#content-in tr',
        { has: page.locator(`a[href*="page=export"][href*="dataset=${id}"]`) },
      ).first();
      const exportHref = await row.locator(
        'a[href*="page=export"][href*="action=create"][href*="dataset="]',
      ).first().getAttribute('href');
      if (exportHref) {
        const url = new URL(exportHref, page.url());
        return { id, exportCreateRoute: `${url.pathname}${url.search}` };
      }
    }
    await page.waitForTimeout(3_000);
  }
  throw new Error('Preseeded NAS fixture dataset did not become exportable');
}

async function vpsNodeMachine(page, vpsId) {
  await goto(page, `/?page=adminvps&action=info&veid=${vpsId}`);
  const rows = await page.locator('#content-in table').first().locator('tr').evaluateAll(
    (elements) => elements.map((row) =>
      Array.from(row.cells).map((cell) => cell.textContent.trim())),
  );
  const node = rows.find((row) => row[0]?.replace(/:$/, '') === 'Node');
  const match = node?.slice(1).join(' ').match(/node(\d+)/i);
  return match ? `node${match[1]}` : 'node1';
}

async function ensurePublicKey(page, publicKeyLabel) {
  await goto(page, '/?page=adminm&action=pubkeys&id=2');
  const matches = await page.getByText(publicKeyLabel, { exact: true }).count();
  if (matches > 1) throw new Error(`Multiple public keys use the fixture label ${publicKeyLabel}`);
  if (matches === 1) return;
  await goto(page, '/?page=adminm&action=pubkey_add&id=2');
  const form = page.locator('form').filter({ has: page.locator('textarea[name="key"]') }).first();
  const label = form.locator('input[name="label"], input[name="name"]');
  if ((await label.count()) > 0) await label.fill(publicKeyLabel);
  const keyType = Buffer.from('ssh-ed25519');
  const length = (value) => {
    const result = Buffer.alloc(4);
    result.writeUInt32BE(value);
    return result;
  };
  const blob = Buffer.concat([
    length(keyType.length),
    keyType,
    length(32),
    Buffer.alloc(32, 1),
  ]).toString('base64');
  await form.locator('textarea[name="key"]').fill(
    `ssh-ed25519 ${blob} docs@example.test`,
  );
  await submitLast(form);
  await page.waitForLoadState('domcontentloaded');
}

async function ensureSshHostKey(cluster, page, node, vpsId) {
  const script = [
    'set -eu',
    'root=$(osctl ct show -H -o rootfs "$1")',
    'test -n "$root"',
    'find "$root/etc/ssh" -maxdepth 1 -type f -name "ssh_host_*.pub" -delete',
    'key=$(printf "%s" "$2" | base64 -d)',
    'printf "%s\\n" "$key" > "$root/etc/ssh/ssh_host_ed25519_key.pub"',
  ].join('\n');
  const encodedPublicKey = Buffer.from(DOCUMENTATION_HOST_PUBLIC_KEY).toString('base64');
  execFileSync(
    cluster.commandPath,
    cluster.sshArgs(node, [
      'bash', '-s', '--', String(vpsId), encodedPublicKey,
    ]),
    { input: `${script}\n`, stdio: ['pipe', 'pipe', 'pipe'] },
  );
  execFileSync(
    cluster.commandPath,
    cluster.sshArgs(node, [
      'nodectl', 'update', 'ssh-host-keys', String(vpsId),
    ]),
    { stdio: ['ignore', 'pipe', 'pipe'] },
  );

  const route = `/?page=adminvps&action=info&veid=${vpsId}`;
  const deadline = Date.now() + 2 * 60_000;
  while (Date.now() < deadline) {
    await goto(page, route);
    const matches = await page.getByText(
      DOCUMENTATION_HOST_KEY_FINGERPRINT,
      { exact: true },
    ).count();
    if (matches === 1) return;
    if (matches > 1) {
      throw new Error('Documentation SSH host-key fingerprint is not unique');
    }
    await page.waitForTimeout(2_000);
  }
  throw new Error(
    `VPS #${vpsId} did not publish the documentation SSH host-key fingerprint`,
  );
}

async function ensureSnapshot(page, datasetId, snapshotLabel) {
  await goto(page, '/?page=backup&action=vps');
  let rows = page.locator('#content-in tr', { hasText: snapshotLabel });
  let count = await rows.count();
  if (count > 1) throw new Error('Multiple snapshots use the fixture label Dokumentační snapshot');
  if (count === 0) {
    await goto(page, `/?page=backup&action=snapshot&dataset=${datasetId}`);
    const form = page.locator('form[action*="action=snapshot_create"]');
    await form.locator('input[name="label"]').fill(snapshotLabel);
    await submitLast(form);
    const deadline = Date.now() + 5 * 60_000;
    while (Date.now() < deadline) {
      await goto(page, '/?page=backup&action=vps');
      rows = page.locator('#content-in tr', { hasText: snapshotLabel });
      count = await rows.count();
      if (count > 0) break;
      await page.waitForTimeout(3_000);
    }
  }
  if (count > 1) throw new Error('Multiple snapshots use the fixture label Dokumentační snapshot');
  const exportLink = rows.first().locator('a[href*="page=export"][href*="snapshot="]').first();
  if ((await exportLink.count()) === 0) throw new Error('Documentation snapshot was not created');
  const href = new URL(await exportLink.getAttribute('href'), page.url());
  return {
    id: idFromUrl(href.href, 'snapshot'),
    exportCreateRoute: `${href.pathname}${href.search}`,
  };
}

function ensureNixosGenerations(cluster, node, vpsId) {
  const script = [
    'set -eu',
    'root=$(osctl ct show -H -o rootfs "$1")',
    'mkdir -p "$root/nix/var/nix/profiles" "$root/nix/store/kb-docs-system-1" "$root/nix/store/kb-docs-system-2" /nix/store/kb-docs-system-1 /nix/store/kb-docs-system-2',
    "printf '%s\\n' '24.11 (Vicuña)' | tee \"$root/nix/store/kb-docs-system-1/nixos-version\" /nix/store/kb-docs-system-1/nixos-version >/dev/null",
    "printf '%s\\n' '25.05 (Warbler)' | tee \"$root/nix/store/kb-docs-system-2/nixos-version\" /nix/store/kb-docs-system-2/nixos-version >/dev/null",
    'touch "$root/nix/store/kb-docs-system-1/init" "$root/nix/store/kb-docs-system-2/init" /nix/store/kb-docs-system-1/init /nix/store/kb-docs-system-2/init',
    'ln -sfn /nix/store/kb-docs-system-1 "$root/nix/var/nix/profiles/system-1-link"',
    'ln -sfn /nix/store/kb-docs-system-2 "$root/nix/var/nix/profiles/system-2-link"',
    'touch -h -t 202501011000.00 "$root/nix/var/nix/profiles/system-1-link" || true',
    'touch -h -t 202506011000.00 "$root/nix/var/nix/profiles/system-2-link" || true',
  ].join('; ');
  execFileSync(
    cluster.commandPath,
    cluster.sshArgs(node, ['bash', '-s', '--', String(vpsId)]),
    { input: `${script}\n`, stdio: ['pipe', 'pipe', 'pipe'] },
  );
}

function generateTrafficSamples(cluster, node, vpsId) {
  const result = spawnSync(cluster.commandPath, cluster.sshArgs(node, [
    'osctl', 'ct', 'exec', String(vpsId),
    '/bin/ping', '-c', '200', '-i', '0.02', '-W', '1', '198.51.100.1',
  ]), { encoding: 'utf8', timeout: 15_000 });
  if (result.error || ![0, 1].includes(result.status) || !result.stdout.includes('PING')) {
    throw new Error(
      `Unable to generate traffic for VPS #${vpsId}: ${result.error || result.stderr}`,
    );
  }
}

function networkInterface(cluster, node, vpsId) {
  const output = execFileSync(
    cluster.commandPath,
    cluster.sshArgs(node, [
      'osctl', 'ct', 'exec', String(vpsId), '/bin/ls', '/sys/class/net',
    ]),
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] },
  );
  const excluded = new Set(['erspan0', 'gre0', 'gretap0', 'ip6tnl0', 'lo', 'tunl0']);
  const interfaces = output.trim().split(/\s+/).filter((name) => !excluded.has(name));
  if (interfaces.length !== 1) {
    throw new Error(`Expected one fixture network interface, found: ${interfaces.join(', ')}`);
  }
  return interfaces[0];
}

async function prepareFixtures({ cluster, language, page, required, repoRoot }) {
  const requiredSet = new Set(required);
  const fixtureLabels = fixturesFor(language);
  const userId = await findUserId(page, 'test-user1');
  const fixtures = {};
  let datasetId;
  let node;
  let vpsId;
  const needsBaseVps = [
    'base-vps',
    'nixos-generations',
    'second-vps',
    'snapshot',
    'ssh-host-key',
    'traffic-samples',
  ].some((name) => requiredSet.has(name));

  if (needsBaseVps) {
    vpsId = await findOwnedVps(page, 'vps')
      || await createVpsIn(page, userId, 'vps', true, 'Production', 'Praha');
    await waitForRunning(page, vpsId);
    datasetId = await rootDatasetId(page, vpsId);
    node = await vpsNodeMachine(page, vpsId);
    Object.assign(fixtures, { vpsId, datasetId, node, hostname: 'vps' });
    fixtures.networkInterface = networkInterface(cluster, node, vpsId);
    fixtures.reverseRecordRoute = await ensureInterfaceAddress(page, vpsId);
    fixtures.childDatasetId = await ensureChildDataset(page, vpsId, datasetId);
    await ensureMount(page, vpsId, fixtures.childDatasetId);
    fixtures.nas = await ensureNasDataset(page);
  }

  if (requiredSet.has('kvm-storage')) {
    fixtures.kvmVpsId = await findOwnedVps(page, 'kvm-host')
      || await createVpsIn(page, userId, 'kvm-host', true, 'Production', 'Praha');
    await waitForRunning(page, fixtures.kvmVpsId);
    fixtures.kvmRootDatasetId = await rootDatasetId(page, fixtures.kvmVpsId);
    await ensureDatasetQuota(page, fixtures.kvmRootDatasetId, '20');
    fixtures.kvmImagesDatasetId = await ensureChildDataset(
      page,
      fixtures.kvmVpsId,
      fixtures.kvmRootDatasetId,
      { name: 'vm-images', refquotaGiB: '100' },
    );
    await ensureDatasetQuota(page, fixtures.kvmImagesDatasetId, '100');
    await ensureMount(
      page,
      fixtures.kvmVpsId,
      fixtures.kvmImagesDatasetId,
      '/srv/libvirt/images',
    );
  }

  if (requiredSet.has('second-vps')) {
    fixtures.secondVpsId = await findOwnedVps(page, 'playground-vps') ||
      await createVpsIn(
        page,
        userId,
        'playground-vps',
        false,
        'Playground',
        'Playground',
      );
  }
  if (requiredSet.has('public-key')) await ensurePublicKey(page, fixtureLabels.publicKey);
  if (requiredSet.has('ssh-host-key')) {
    await ensureSshHostKey(cluster, page, node, vpsId);
  }
  if (requiredSet.has('snapshot')) {
    fixtures.snapshot = await ensureSnapshot(page, datasetId, fixtureLabels.snapshot);
  }
  if (requiredSet.has('nixos-generations')) {
    ensureNixosGenerations(cluster, node, vpsId);
  }
  if (requiredSet.has('traffic-samples')) {
    generateTrafficSamples(cluster, node, vpsId);
  }

  const target = path.join(repoRoot, 'tmp/fixtures.json');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `${JSON.stringify(fixtures, null, 2)}\n`);
  return fixtures;
}

module.exports = { generateTrafficSamples, prepareFixtures };
