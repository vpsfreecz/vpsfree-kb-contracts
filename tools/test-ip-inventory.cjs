const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const https = require('node:https');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { spawn } = require('node:child_process');
const { createInterface } = require('node:readline');
const crypto = require('node:crypto');
const { Connection } = require('../lib/connection.cjs');
const { assertInventoryMember, ensureIpInventory,
  INVENTORY_POOL, INVENTORY_RESOURCES, prepareFixtures } = require('../fixtures/prepare.cjs');
const { heldController, observeLeaseState } = require('./verify-live-lease.cjs');

const recordedAccounts = () => [['test-admin', 99, 1], ['test-user1', 1, 9], ['test-user2', 1, 17]].map(([login, level, blockStart]) => ({
  login, level, password: `synthetic-${login}`, fullName: `Synthetic ${login}`,
  email: `${login}@example.test`, namespace: { blockStart, blockCount: 8 },
}));

async function withInventoryConnection(accounts, work) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-inventory-accounts-'));
  const filename = path.join(root, 'accounts.json');
  const ca = path.join(root, 'ca');
  fs.writeFileSync(filename, JSON.stringify({ users: accounts }), { mode: 0o600 });
  fs.writeFileSync(ca, 'synthetic CA', { mode: 0o600 });
  const abort = new AbortController();
  const cluster = new Connection({ accounts_file: filename, tls: { ca_file: ca },
    services: { api: { url: 'https://api.example.test/', connect_host: '127.0.0.1', connect_port: 16443 } },
  }, { signal: abort.signal, assertLive() { abort.signal.throwIfAborted(); } });
  try { await work(cluster, abort, root); }
  finally { fs.rmSync(root, { recursive: true }); }
}

function mockInventoryTransport(t, respond) {
  const calls = [];
  t.mock.method(https, 'request', (options, callback) => {
    const [login, password] = Buffer.from(options.headers.Authorization.slice(6), 'base64').toString().split(':');
    assert.equal(password, `synthetic-${login}`);
    assert.equal(options.hostname, '127.0.0.1');
    assert.equal(options.port, 16443);
    assert.equal(options.servername, 'api.example.test');
    assert.equal(options.headers.Host, 'api.example.test');
    assert.equal(options.ca.toString(), 'synthetic CA');
    assert.equal(options.headers.Cookie, undefined);
    assert(options.signal instanceof AbortSignal);
    const request = new EventEmitter();
    request.setTimeout = () => request;
    request.destroy = (error) => request.emit('error', error);
    request.end = (bytes) => {
      const call = { login, method: options.method, resource: options.path.replace(/^\/v1\//, ''), body: bytes ? JSON.parse(bytes) : undefined };
      calls.push(call);
      Promise.resolve().then(() => respond(call)).then((result) => {
        const response = new PassThrough();
        response.statusCode = result.statusCode || 200;
        callback(response);
        response.end(JSON.stringify(result.denied ? { status: false } : { status: true, response: result.response }));
      }).catch((error) => request.emit('error', error));
    };
    return request;
  });
  return calls;
}

function currentUser(login) {
  return { user: { login, id: login === 'test-admin' ? 1 : 2, level: login === 'test-admin' ? 99 : 1 } };
}

function memberPage({ id = 2, login = 'test-user1', admin = false, impersonated = false } = {}) {
  return {
    url: () => 'https://webui.example.test/?page=networking',
    locator(selector) {
      if (selector === '[data-vpsadmin-doc-id="member.edit-profile"]') return { count: async () => admin ? 0 : 1, getAttribute: async () => `?page=adminm&section=members&action=edit&id=${id}` };
      if (selector === '#logbox-submit') return { count: async () => 1, getAttribute: async () => `Log out (${login}) ⯆` };
      if (selector.includes('regain_admin')) return { count: async () => impersonated ? 1 : 0 };
      if (selector.includes('logout')) return { count: async () => 1 };
      throw new Error(`Unexpected member-identity selector ${selector}`);
    },
  };
}

test('actual inventory preparation proves both API identities and admin-only disabled rerun without admin browser navigation', async (t) => {
  const existing = fixture({ disabled: true });
  const calls = mockInventoryTransport(t, async (call) => {
    if (call.resource === 'users/current') return { response: currentUser(call.login) };
    assert.equal(call.login, 'test-admin', 'only the explicit administrator reads/provisions dedicated inventory');
    assert.equal(call.method, 'GET', 'disabled rerun cannot reenable, register or charge');
    return { response: await existing.api(call.method, call.resource, call.body) };
  });
  await withInventoryConnection(recordedAccounts(), async (cluster, _abort, root) => {
    const navigation = [];
    const page = memberPage();
    const identityLocator = page.locator.bind(page);
    page.goto = async (route) => {
      assert(!route.includes('page=adminm'), 'inventory cannot discover a user through administrator navigation');
      assert.equal(calls[0]?.resource, 'users/current');
      assert.equal(calls[1]?.resource, 'users/current');
      navigation.push(route);
    };
    page.addStyleTag = async () => {};
    page.evaluate = async () => {};
    page.locator = (selector) => {
      if (selector === '#content-in tr') return { evaluateAll: async () => ['https://webui.example.test/?page=adminvps&action=info&veid=10'] };
      if (selector === '#content-in') return { innerText: async () => 'Running' };
      return identityLocator(selector);
    };
    const invocationRoot = path.join(root, 'invocation');
    fs.mkdirSync(invocationRoot, { mode: 0o700 });
    const result = await prepareFixtures({ cluster, page, language: 'en', required: ['ip-inventory'], invocationRoot });
    assert.deepEqual(result.inventoryMember, { id: 2, login: 'test-user1' });
    assert.deepEqual(calls.slice(0, 2).map((call) => [call.login, call.resource]), [['test-user1', 'users/current'], ['test-admin', 'users/current']]);
    assert.equal(result.inventoryVpsId, 10);
    assert.equal(navigation.length, 2, 'only owned VPS discovery and running-state reads are needed');
    assert.equal(cluster.account().login, 'test-user1', 'default browser account remains the ordinary member');
    await assertInventoryMember(page, result.inventoryMember);
    const retained = fs.readFileSync(path.join(invocationRoot, 'fixtures.json'), 'utf8');
    assert(!retained.includes('password') && !retained.includes('test-admin'), 'fixture metadata contains only member identity, never admin credentials');
  });
});

for (const wrong of ['missing', 'duplicate', 'role', 'namespace', 'password']) {
  test(`recorded inventory account ${wrong} refuses before HTTP or browser mutation`, async (t) => {
    const accounts = recordedAccounts();
    const admin = accounts[0];
    if (wrong === 'missing') accounts.shift();
    if (wrong === 'duplicate') accounts.push({ ...admin });
    if (wrong === 'role') admin.level = 1;
    if (wrong === 'namespace') admin.namespace.blockStart = 9;
    if (wrong === 'password') delete admin.password;
    const calls = mockInventoryTransport(t, () => assert.fail('invalid accounts must precede HTTP'));
    await withInventoryConnection(accounts, async (cluster) => {
      const page = { locator() { assert.fail('invalid accounts must precede browser work'); } };
      await assert.rejects(prepareFixtures({ cluster, page, language: 'en', required: ['ip-inventory'] }), /account/);
    });
    assert.equal(calls.length, 0);
  });
}

for (const wrong of ['denied', 'login', 'role', 'same-id', 'lease-loss']) {
  test(`public current-user ${wrong} refuses before VPS or inventory mutation`, async (t) => {
    let abort;
    const calls = mockInventoryTransport(t, (call) => {
      assert.equal(call.method, 'GET'); assert.equal(call.resource, 'users/current');
      const response = currentUser(call.login);
      if (call.login === 'test-admin') {
        if (wrong === 'denied') return { statusCode: 403, denied: true };
        if (wrong === 'login') response.user.login = 'other';
        if (wrong === 'role') response.user.level = 1;
        if (wrong === 'same-id') response.user.id = 2;
        if (wrong === 'lease-loss') abort.abort(new Error('synthetic lease loss'));
      }
      return { response };
    });
    await withInventoryConnection(recordedAccounts(), async (cluster, signal) => {
      abort = signal;
      const page = { locator() { assert.fail('identity failure must precede browser work'); } };
      await assert.rejects(prepareFixtures({ cluster, page, language: 'cs', required: ['ip-inventory'] }));
    });
    assert.equal(calls.length, 2);
  });
}

test('an already lost enclosing lease refuses before account authentication or browser work', async (t) => {
  const calls = mockInventoryTransport(t, () => assert.fail('lost lease cannot authenticate a fixture account'));
  await withInventoryConnection(recordedAccounts(), async (cluster, abort) => {
    abort.abort(new Error('synthetic lease loss'));
    const page = { locator() { assert.fail('lost lease cannot use the member browser'); } };
    await assert.rejects(prepareFixtures({ cluster, page, language: 'en', required: ['ip-inventory'] }), /lease loss/);
  });
  assert.equal(calls.length, 0);
});

test('logout alone cannot admit an administrator, impersonation or wrong member session', async () => {
  const member = { id: 2, login: 'test-user1' };
  await assertInventoryMember(memberPage(), member);
  for (const page of [memberPage({ admin: true, id: 1, login: 'test-admin' }), memberPage({ impersonated: true }),
    memberPage({ id: 3 }), memberPage({ login: 'test-user2' })]) {
    assert.equal(await page.locator('#logout a[href*="action=logout"]').count(), 1);
    await assert.rejects(assertInventoryMember(page, member), /browser/);
    page.goto = async () => {};
    page.addStyleTag = async () => {};
    page.evaluate = async () => {};
    const scenario = require('../scenarios/networking.cjs');
    await assert.rejects(scenario.run({ page, fixtures: { inventoryMember: member }, session: {
      wants: (checkpoint) => checkpoint === 'networking/ip-address-list',
      locator() { assert.fail('wrong browser identity cannot publish an inventory image'); },
    } }), /browser/);
  }
});

function fixture({ disabled = false, missing = false, assigned = false, owner = 2, networkMissing = false, locationMissing = false } = {}) {
  const pool = { ...INVENTORY_POOL, id: 5, enabled: !disabled };
  let ip = missing ? null : { id: 90, addr: '203.0.113.10', prefix: 32, network: { id: 5 },
    user: { id: owner }, network_interface: assigned ? { id: 12 } : null, charged_environment: { id: 1 } };
  const calls = [];
  const api = async (method, resource, body) => {
    calls.push([method, resource, body]);
    if (resource === 'vpses/10') return { vps: { ...INVENTORY_RESOURCES, id: 10, hostname: 'ip-inventory', user: { id: 2 }, node: { id: 101 } } };
    if (resource === 'nodes/101') return { node: { location: { id: 1 } } };
    if (resource === 'locations/1') return { location: { environment: { id: 1 } } };
    if (resource === 'networks?limit=1000') return { networks: [...(networkMissing ? [] : [pool]), { address: '198.51.100.0', enabled: true }, { address: '2001:db8:106::', enabled: true }] };
    if (resource === 'location_networks?network=5&limit=1000') return { location_networks: locationMissing ? [] : [{ location: { id: 1 }, primary: false, autopick: false, userpick: false }] };
    if (resource === 'ip_addresses?network=5&limit=1000') return { ip_addresses: ip ? [ip] : [] };
    if (resource === 'ip_addresses?vps=10&version=4&limit=1000') return { ip_addresses: [{ addr: '198.51.100.10', user: { id: 2 } }] };
    if (method === 'POST' && resource === 'networks') { networkMissing = false; return { network: pool }; }
    if (method === 'POST' && resource === 'location_networks') {
      locationMissing = false;
      return { location_network: { ...body.location_network, location: { id: body.location_network.location } } };
    }
    if (method === 'POST' && resource === 'ip_addresses') {
      ip = { id: 90, addr: '203.0.113.10', prefix: 32, network: { id: 5 }, user: { id: body.ip_address.user }, network_interface: null, charged_environment: { id: 1 } };
      return { ip_address: ip };
    }
    if (method === 'PUT' && resource === 'networks/5') { pool.enabled = body.network.enabled; return { network: pool }; }
    throw new Error(`Unexpected fixture action ${method} ${resource}`);
  };
  return { api, calls, pool };
}

test('first provision uses public owned registration while enabled then disables only the dedicated pool', async () => {
  const { api, calls } = fixture({ missing: true });
  const value = await ensureIpInventory(api, { userId: 2, vpsId: 10 });
  assert.equal(value.disabledAddress, '203.0.113.10');
  assert.deepEqual(calls.filter(([method]) => method !== 'GET'), [
    ['POST', 'ip_addresses', { ip_address: { addr: '203.0.113.10/32', network: 5, user: 2, location: 1 } }],
    ['PUT', 'networks/5', { network: { enabled: false } }],
  ]);
  calls.length = 0;
  await ensureIpInventory(api, { userId: 2, vpsId: 10 });
  assert(calls.every(([method]) => method === 'GET'), 'rerun must not reenable, allocate or charge again');
});

test('a fresh dedicated public pool and location are provisioned before the owned address and disable', async () => {
  const { api, calls } = fixture({ networkMissing: true, locationMissing: true, missing: true });
  await ensureIpInventory(api, { userId: 2, vpsId: 10 });
  assert.deepEqual(calls.filter(([method]) => method !== 'GET').map(([method, resource]) => [method, resource]), [
    ['POST', 'networks'], ['POST', 'location_networks'], ['POST', 'ip_addresses'], ['PUT', 'networks/5'],
  ]);
  assert.deepEqual(calls.find(([method, resource]) => method === 'POST' && resource === 'networks')[2],
    { network: { ...INVENTORY_POOL, enabled: true } });
});

test('an existing disabled owned detached fixture performs no writes', async () => {
  const { api, calls } = fixture({ disabled: true });
  await ensureIpInventory(api, { userId: 2, vpsId: 10 });
  assert(calls.every(([method]) => method === 'GET'));
});

for (const options of [{ disabled: true, missing: true }, { owner: 3 }, { assigned: true }]) {
  test(`unexpected fixture state refuses without adoption: ${JSON.stringify(options)}`, async () => {
    const { api, calls } = fixture(options);
    await assert.rejects(ensureIpInventory(api, { userId: 2, vpsId: 10 }));
    assert(calls.every(([method]) => method === 'GET'));
  });
}

test('pool identity collision refuses before any mutation', async () => {
  const { api, calls, pool } = fixture();
  pool.label = 'foreign pool';
  await assert.rejects(ensureIpInventory(api, { userId: 2, vpsId: 10 }), /Unexpected dedicated/);
  assert(calls.every(([method]) => method === 'GET'));
});

test('first inventory preparation creates the tiny VPS in the proved member browser before explicit admin registration', async (t) => {
  let stage = 'location';
  const entries = [];
  const inventory = fixture({ missing: true });
  const calls = mockInventoryTransport(t, async (call) => {
    if (call.resource === 'users/current') return { response: currentUser(call.login) };
    assert.equal(call.login, 'test-admin');
    if (call.method === 'POST' && call.resource === 'ip_addresses') assert.equal(call.body.ip_address.user, 2);
    return { response: await inventory.api(call.method, call.resource, call.body) };
  });
  const form = (name) => ({
    count: async () => name === 'newvps-step1' ? 0 : 1,
    locator: (selector) => {
      if (selector === 'select[name="user_namespace_map"]') {
        const options = [
          { value: '2', disabled: true, textContent: ' Disabled namespace ' },
          { value: '', disabled: false, textContent: ' Choose namespace ' },
          { value: '0', disabled: false, textContent: ' Default ' },
          { value: '3', disabled: false, textContent: ' ------- ' },
          { value: '1', disabled: false, textContent: ' Namespace ' },
        ];
        return {
          count: async () => 1,
          locator: (child) => {
            assert.equal(child, 'option');
            return { evaluateAll: async (callback) => callback(options) };
          },
          selectOption: async (value) => { assert.equal(value, '1'); },
        };
      }
      return {
        count: async () => 1, nth: () => ({ click: async () => { entries.push(['submit', stage]); stage = stage === 'location' ? 'template' : stage === 'template' ? 'resources' : 'submit'; } }),
        fill: async (value) => entries.push([selector, value, stage]),
        check: async () => {}, isChecked: async () => true,
        evaluateAll: async () => [{ value: '1', disabled: false, label: 'Namespace' }],
        selectOption: async () => {}, setChecked: async () => {},
      };
    },
    getByText: (text, options) => {
      assert.equal(text, 'Debian (latest)');
      assert.equal(options.exact, true);
      const details = { open: false };
      return { first: () => ({ locator: (ancestor) => {
        assert.equal(ancestor, 'xpath=ancestor::tr[1]');
        return { locator: (selector) => {
          if (selector === 'xpath=ancestor::details[1]') {
            return { count: async () => 1, evaluate: async (callback) => {
              callback(details);
              assert.equal(details.open, true);
            } };
          }
          assert.equal(selector, 'input[type="radio"][name="os_template"]:not([disabled])');
          return { first: () => ({ count: async () => 1, check: async () => {
            assert.equal(details.open, true, 'the template details must open before checking its radio');
          } }) };
        } };
      } }) };
    },
  });
  const identityLocator = memberPage().locator;
  const page = {
    goto: async (route) => {
      assert(!route.includes('page=adminm'));
      assert.equal(calls[0]?.resource, 'users/current');
      assert.equal(calls[1]?.resource, 'users/current');
      if (route.includes('action=new-step-1')) assert(route.endsWith('&user=2'));
    }, addStyleTag: async () => {}, evaluate: async () => {}, waitForLoadState: async () => {},
    url: () => 'https://webui.example.test/?veid=10',
    locator: (selector) => {
      if (selector === '#content-in tr') return { evaluateAll: async () => [] };
      if (selector === '#content-in') return { innerText: async () => 'Running' };
      if (selector.includes('member.edit-profile') || selector === '#logbox-submit' || selector.includes('regain_admin')) {
        return identityLocator(selector);
      }
      if (selector === 'form[name="newvps-step1"]') return form('newvps-step1');
      const value = form('normal');
      value.locator = (selector2, options) => {
        if (selector2 === 'tr') return { first: () => ({ locator: () => ({ check: async () => {} }) }) };
        return form('normal').locator(selector2, options);
      };
      return value;
    },
  };
  await withInventoryConnection(recordedAccounts(), async (cluster, _abort, root) => {
    const invocationRoot = path.join(root, 'invocation');
    fs.mkdirSync(invocationRoot, { mode: 0o700 });
    const result = await prepareFixtures({ cluster, page, language: 'en', required: ['ip-inventory'], invocationRoot });
    assert.deepEqual(result.inventoryMember, { id: 2, login: 'test-user1' });
    assert.equal(cluster.account().login, 'test-user1');
    assert.deepEqual(calls.filter((call) => call.method !== 'GET').map((call) => [call.login, call.method, call.resource]),
      [['test-admin', 'POST', 'ip_addresses'], ['test-admin', 'PUT', 'networks/5']]);
  });
  for (const [name, value] of Object.entries(INVENTORY_RESOURCES)) {
    assert(entries.some(([selector, actual, at]) => selector === `input[name="${name}"]` && actual === String(value) && at === 'resources'));
  }
});

test('only the IP-list fixture token changes, other fixture contracts are retained', () => {
  const root = path.resolve(__dirname, '..');
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'captures.json')));
  const selected = manifest.assets.filter((asset) => asset.fixtures.includes('ip-inventory'));
  assert.deepEqual(selected.map((asset) => asset.id), ['networking/ip-address-list']);
  assert.deepEqual(selected[0].fixtures, ['ip-inventory']);
  assert(manifest.assets.some((asset) => asset.fixtures.includes('base-vps')));
});

test('verifier supervises its exact controller for ordinary EOF and interruption, leaving no child', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-verifier-controller-'));
  const provider = path.join(root, 'provider.cjs');
  const value = { instance_id: 'i', run_id: 'r', artifact_id: 'a', artifact_sha256: 's' };
  const expected = { schema: 1, ...value, descriptor_sha256: 'd' };
  fs.writeFileSync(provider, `process.stdout.write(${JSON.stringify(JSON.stringify(expected) + '\n')}); process.stdin.resume(); process.stdin.on('end', () => process.exit(0));`);
  value.control = { argv: [process.execPath, provider] };
  try {
    for (const interrupt of [false, true]) await heldController(value, 'd', interrupt, async (lease) => { lease.assertLive(); });
  } finally { fs.rmSync(root, { recursive: true }); }
});


test('malformed controller readiness reaps its owned child without starting work', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-verifier-bad-controller-'));
  const provider = path.join(root, 'provider.cjs');
  const marker = path.join(root, 'exited');
  fs.writeFileSync(provider, `const fs = require('node:fs'); process.on('exit', () => fs.writeFileSync(${JSON.stringify(marker)}, 'exited')); process.stdout.write('not JSON\\n'); process.stdin.resume(); process.stdin.on('end', () => process.exit(0));`);
  const value = { instance_id: 'i', run_id: 'r', artifact_id: 'a', artifact_sha256: 's', control: { argv: [process.execPath, provider] } };
  try {
    await assert.rejects(heldController(value, 'd', false, async () => assert.fail('invalid readiness must not start work')));
    assert.equal(fs.readFileSync(marker, 'utf8'), 'exited');
  } finally { fs.rmSync(root, { recursive: true }); }
});

test('actual controller stdout loss cancels acquired work and leaves no live child', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-verifier-lost-controller-'));
  const provider = path.join(root, 'provider.cjs');
  const trigger = path.join(root, 'trigger');
  const marker = path.join(root, 'exited');
  fs.writeFileSync(trigger, 'wait');
  const value = { instance_id: 'i', run_id: 'r', artifact_id: 'a', artifact_sha256: 's' };
  const expected = { schema: 1, ...value, descriptor_sha256: 'd' };
  fs.writeFileSync(provider, `const fs = require('node:fs'); process.on('exit', () => fs.writeFileSync(${JSON.stringify(marker)}, 'exited')); const watcher = fs.watch(${JSON.stringify(trigger)}, () => { fs.closeSync(1); watcher.close(); }); process.stdout.write(${JSON.stringify(JSON.stringify(expected) + '\n')}); process.stdin.resume(); process.stdin.on('end', () => process.exit(0));`);
  value.control = { argv: [process.execPath, provider] };
  try {
    await heldController(value, 'd', false, async (lease) => {
      lease.assertLive();
      fs.writeFileSync(trigger, 'close protocol');
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('controller must expose actual protocol loss')), 5000);
        lease.signal.addEventListener('abort', () => { clearTimeout(timer); resolve(); }, { once: true });
      });
      assert.throws(() => lease.assertLive(), /lost/);
    });
    assert.equal(fs.readFileSync(marker, 'utf8'), 'exited');
  } finally { fs.rmSync(root, { recursive: true }); }
});

async function withLeaseObservation(work) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-lease-observation-'));
  const stateRoot = path.join(root, 'state');
  const directory = path.join(stateRoot, 'clusters/same-slug');
  const sdk = path.resolve(__dirname, '..');
  const ids = { instance_id: crypto.randomUUID(), run_id: crypto.randomUUID(), artifact_id: crypto.randomUUID() };
  for (const name of [stateRoot, path.dirname(directory), directory, path.join(root, 'runtime'),
    path.join(root, 'runtime/reservations'), path.join(root, 'runtime/run'), path.join(directory, 'disks')]) {
    fs.mkdirSync(name, { mode: 0o700 });
  }
  const write = (filename, value) => fs.writeFileSync(filename, JSON.stringify(value) + '\n', { mode: 0o600 });
  const source = { schema: 1, revision: '1'.repeat(40), source: sdk };
  const artifact = { schema: 1, instance_id: ids.instance_id, artifact_id: ids.artifact_id, source };
  const artifactJson = JSON.stringify(artifact) + '\n';
  const value = { ...ids, owner_id: `uid:${process.getuid()}`,
    artifact_sha256: crypto.createHash('sha256').update(artifactJson).digest('hex'),
    provenance: { source, artifact_json: artifactJson } };
  const processPath = path.join(directory, `processes-${ids.run_id}.json`);
  const config = path.join(directory, 'config.json');
  const claim = path.join(root, 'runtime/reservations', `${ids.instance_id}-${ids.run_id}.json`);
  const provider = path.join(root, 'publisher.rb');
  const options = { '--config': config, '--state-dir': path.join(directory, 'disks'), '--sock-dir': path.join(root, 'runtime/run'),
    '--run-id': ids.run_id, '--instance-id': ids.instance_id, '--artifact-id': ids.artifact_id,
    '--artifact-sha256': value.artifact_sha256 };
  // Responses follow native identity acquisition or completed State.write
  // publication: this is an owned pipe barrier, not a scheduling assumption.
  fs.writeFileSync(provider, `
    require File.join(${JSON.stringify(sdk)}, 'cluster/lib/kb_process')
    require 'rbconfig'
    state = KbRuntime::State.new(${JSON.stringify(stateRoot)}, 'same-slug')
    children = []
    temporary = nil
    publication = nil
    respond = ->(value) { STDOUT.puts(JSON.generate(value)); STDOUT.flush }
    respond.call(KbRuntime::ProcessIdentity.read(Process.pid))
    begin
      STDIN.each_line do |line|
        request = JSON.parse(line)
        case request.fetch('action')
        when 'publish'
          state.write(${JSON.stringify(processPath)}, request.fetch('record'))
          respond.call('inode' => File.lstat(${JSON.stringify(processPath)}).ino)
        when 'temporary-create'
          raise 'publication already held' if publication
          temporary = ${JSON.stringify(processPath)} + '.' + SecureRandom.hex(12)
          publication = File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
          respond.call('path' => temporary)
        when 'temporary-write'
          publication.write(request.fetch('bytes'))
          publication.flush
          respond.call('position' => publication.pos)
        when 'temporary-fsync'
          publication.fsync
          respond.call('synced' => true)
        when 'temporary-publish'
          publication.close
          publication = nil
          File.rename(temporary, ${JSON.stringify(processPath)})
          temporary = nil
          File.open(${JSON.stringify(directory)}, &:fsync)
          respond.call('inode' => File.lstat(${JSON.stringify(processPath)}).ino)
        when 'child'
          input, writer = IO.pipe
          output, reader = IO.pipe
          code = <<~'CHILD'
            require File.join(ARGV.fetch(0), 'cluster/lib/kb_process')
            require 'rbconfig'
            STDOUT.puts(JSON.generate(KbRuntime::ProcessIdentity.read(Process.pid)))
            STDOUT.flush
            if STDIN.gets
              after_exec = <<~'NEXT'
                require File.join(ARGV.fetch(0), 'cluster/lib/kb_process')
                STDOUT.puts(JSON.generate(KbRuntime::ProcessIdentity.read(Process.pid)))
                STDOUT.flush
                STDIN.read
              NEXT
              exec RbConfig.ruby, '-e', after_exec, ARGV.fetch(0)
            end
          CHILD
          pid = Process.spawn(RbConfig.ruby, '-e', code, ${JSON.stringify(sdk)}, in: input, out: reader, err: STDERR, close_others: true)
          children << [pid, writer, output]
          input.close
          reader.close
          respond.call(JSON.parse(output.readline))
        when 'child-exec'
          _pid, writer, output = children.first
          writer.puts('exec')
          writer.flush
          respond.call(JSON.parse(output.readline))
        when 'child-exit'
          pid, writer, output = children.shift
          writer.close
          respond.call('pid' => Process.waitpid(pid))
          output.close
        else
          raise 'unexpected fixture action'
        end
      end
    ensure
      publication.close if publication && !publication.closed?
      File.unlink(temporary) if temporary && File.exist?(temporary)
      children.each { |_pid, writer, _output| writer.close }
      children.each { |pid, _writer, output| Process.waitpid(pid); output.close }
    end
  `, { mode: 0o600 });
  const child = spawn('ruby', [provider, 'start', ...Object.entries(options).flat()], { stdio: ['pipe', 'pipe', 'pipe'] });
  child.stderr.resume();
  child.stdin.on('error', () => {});
  const lines = createInterface({ input: child.stdout });
  const exited = new Promise((resolve) => child.once('close', (code, signal) => resolve({ code, signal })));
  const response = () => new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(new Error('owned publication barrier deadline')), 5000);
    const finish = (error, result) => {
      clearTimeout(timer); lines.off('line', line); child.off('error', failure); child.off('close', failure);
      if (error) reject(error); else resolve(result);
    };
    const line = (bytes) => { try { finish(null, JSON.parse(bytes)); } catch (error) { finish(error); } };
    const failure = () => finish(new Error('owned publisher ended before its barrier'));
    lines.once('line', line); child.once('error', failure); child.once('close', failure);
  });
  const request = async (action, detail = {}) => {
    const pending = response();
    child.stdin.write(JSON.stringify({ action, ...detail }) + '\n');
    return pending;
  };
  try {
    const runner = await response();
    write(path.join(directory, 'identity.json'), { schema: 2, instance_id: ids.instance_id, owner_uid: process.getuid(),
      state_root: stateRoot, slug: 'same-slug', created_at: new Date().toISOString() });
    write(config, { synthetic: true });
    write(path.join(directory, 'phase.json'), { schema: 1, phase: 'ready', run_id: ids.run_id });
    fs.writeFileSync(path.join(directory, `artifact-${ids.artifact_id}.json`), artifactJson, { mode: 0o600 });
    write(path.join(directory, `launch-${ids.run_id}.json`), { schema: 2, ...ids, artifact_sha256: value.artifact_sha256,
      owner_uid: process.getuid(), state_root: stateRoot, slug: 'same-slug', source, boot_id: runner.boot_id,
      config_path: config, state_dir: options['--state-dir'], socket_dir: options['--sock-dir'],
      runner_identity: { executable: runner.executable, entrypoint: provider } });
    write(claim, { ...ids, artifact_sha256: value.artifact_sha256, owner_uid: process.getuid(), boot_id: runner.boot_id, state_root: stateRoot });
    const record = { schema: 1, ...ids, artifact_sha256: value.artifact_sha256, runner, children: [], complete: false };
    await request('publish', { record });
    await work({ root, stateRoot, directory, processPath, config, claim, sdk, value, record, request, write, child, exited,
      observe: () => observeLeaseState(stateRoot, value, sdk) });
  } finally {
    if (!child.stdin.destroyed) child.stdin.end();
    let timer;
    try {
      const result = await Promise.race([exited, new Promise((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error('owned publisher cleanup deadline')), 5000);
      })]);
      assert.deepEqual(result, { code: 0, signal: null });
    } finally {
      clearTimeout(timer); lines.close();
      if (child.exitCode !== null || child.signalCode !== null) fs.rmSync(root, { recursive: true });
    }
  }
}

test('lease state permits atomic equal-byte receipt replacement and append-only live or exited children', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const before = observation.snapshot();
    const bytes = fs.readFileSync(fixture.processPath);
    const inode = fs.lstatSync(fixture.processPath).ino;
    const replaced = await fixture.request('publish', { record: fixture.record });
    assert.notEqual(replaced.inode, inode);
    assert.deepEqual(fs.readFileSync(fixture.processPath), bytes);
    observation.assertUnchanged(before);
    const child = await fixture.request('child');
    assert.equal(child.boot_id, fixture.record.runner.boot_id);
    assert.equal(child.owner_uid, process.getuid());
    const appended = { ...fixture.record, children: [child] };
    await fixture.request('publish', { record: appended });
    observation.assertUnchanged(before);
    const afterExec = await fixture.request('child-exec');
    assert.equal(afterExec.pid, child.pid);
    assert.equal(afterExec.start_ticks, child.start_ticks);
    assert.notDeepEqual(afterExec.argv, child.argv);
    await fixture.request('publish', { record: { ...appended, children: [afterExec] } });
    observation.assertUnchanged(before); // A child's legitimate exec does not remove its PID/start identity.
    assert.equal((await fixture.request('child-exit')).pid, child.pid);
    observation.assertUnchanged(before); // Retained children need not still be alive.
    await fixture.request('publish', { record: fixture.record });
    assert.throws(() => observation.assertUnchanged(before), /previously observed child identity/);
  });
});

test('lease state still protects other inodes and bytes including historical receipts and the exact claim', async () => {
  await withLeaseObservation(async (fixture) => {
    const historical = path.join(fixture.directory, `processes-${crypto.randomUUID()}.json`);
    fixture.write(historical, { historical: true });
    const observation = fixture.observe();
    let before = observation.snapshot();
    for (const filename of [fixture.config, historical, fixture.claim]) {
      const bytes = fs.readFileSync(filename);
      const inode = fs.lstatSync(filename).ino;
      const replacement = `${filename}.replacement`;
      fs.writeFileSync(replacement, bytes, { mode: 0o600 });
      fs.renameSync(replacement, filename);
      assert.notEqual(fs.lstatSync(filename).ino, inode);
      assert.throws(() => observation.assertUnchanged(before), /unchanged/);
      before = observation.snapshot(); // Isolate the next negative case; no refusal is treated as success.
      const changed = JSON.parse(bytes);
      changed.unexpected = true;
      fixture.write(filename, changed);
      assert.throws(() => observation.assertUnchanged(before), /unchanged/);
      fixture.write(filename, JSON.parse(bytes));
      before = observation.snapshot();
    }
  });
});

test('lease observation rejects foreign receipt IDs, malformed identities and changed authenticated runner', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const before = observation.snapshot();
    const child = await fixture.request('child');
    const malformed = [
      ...['instance_id', 'run_id', 'artifact_id'].map((field) => ({ ...fixture.record, [field]: crypto.randomUUID() })),
      { ...fixture.record, artifact_sha256: '0'.repeat(64) }, { ...fixture.record, schema: 2 }, { ...fixture.record, complete: true },
      { ...fixture.record, children: null }, { ...fixture.record, children: [child, child] },
      { ...fixture.record, children: [{ ...child, boot_id: crypto.randomUUID() }] },
      { ...fixture.record, children: [{ ...child, owner_uid: process.getuid() + 1 }] },
      { ...fixture.record, children: [{ ...child, start_ticks: 'invalid' }] },
      { ...fixture.record, children: [fixture.record.runner] },
      ...['pid', 'start_ticks', 'boot_id', 'owner_uid', 'executable', 'argv'].map((field) => ({ ...fixture.record,
        runner: { ...fixture.record.runner, [field]: field === 'argv' ? ['wrong-runner-argv'] :
          typeof fixture.record.runner[field] === 'number' ? fixture.record.runner[field] + 1 : `${fixture.record.runner[field]}-wrong` } })),
    ];
    for (const record of malformed) {
      await fixture.request('publish', { record });
      assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    }
    await fixture.request('publish', { record: fixture.record });
    observation.assertUnchanged(before);
  });
});

test('lease observation refuses truncated, oversized, unsafe, symlinked and missing live receipts', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const before = observation.snapshot();
    const valid = fs.readFileSync(fixture.processPath);
    for (const bytes of ['{', 'null', JSON.stringify({ unrelated: true }), ' '.repeat(2 * 1024 * 1024 + 1)]) {
      fs.writeFileSync(fixture.processPath, bytes);
      assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    }
    fs.writeFileSync(fixture.processPath, valid);
    fs.chmodSync(fixture.processPath, 0o644);
    assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    fs.chmodSync(fixture.processPath, 0o600);
    fs.unlinkSync(fixture.processPath);
    fs.symlinkSync(fixture.config, fixture.processPath);
    assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    fs.unlinkSync(fixture.processPath);
    assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    fs.mkdirSync(fixture.processPath, { mode: 0o700 });
    assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    fs.rmdirSync(fixture.processPath);
    fs.writeFileSync(fixture.processPath, valid, { mode: 0o600 });
    fs.chmodSync(fixture.directory, 0o755);
    assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    fs.chmodSync(fixture.directory, 0o700);
    observation.assertUnchanged(before);
  });
});

test('lease observation refuses changed launch or artifact binding and an exited recorded runner', async () => {
  await withLeaseObservation(async (fixture) => {
    assert.throws(() => observeLeaseState(fixture.stateRoot, { ...fixture.value, run_id: crypto.randomUUID() }, fixture.sdk), /observation refused/);
    assert.throws(() => observeLeaseState(fixture.stateRoot, { ...fixture.value, instance_id: crypto.randomUUID() }, fixture.sdk), /observation refused/);
    const observation = fixture.observe();
    const before = observation.snapshot();
    const launchPath = path.join(fixture.directory, `launch-${fixture.value.run_id}.json`);
    const launch = JSON.parse(fs.readFileSync(launchPath));
    fixture.write(launchPath, { ...launch, artifact_id: crypto.randomUUID() });
    assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    fixture.write(launchPath, launch);
    const artifactPath = path.join(fixture.directory, `artifact-${fixture.value.artifact_id}.json`);
    const artifact = fs.readFileSync(artifactPath);
    fixture.write(artifactPath, { schema: 1, instance_id: crypto.randomUUID() });
    assert.throws(() => observation.assertUnchanged(before), /observation refused/);
    fs.writeFileSync(artifactPath, artifact);
    fixture.child.stdin.end();
    assert.deepEqual(await fixture.exited, { code: 0, signal: null });
    assert.throws(() => observation.snapshot(), /observation refused/);
  });
});

test('lease observation tolerates only the current held atomic writer while the published receipt stays valid', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const before = observation.snapshot();
    const bytes = fs.readFileSync(fixture.processPath, 'utf8');
    const inode = fs.lstatSync(fixture.processPath).ino;
    const { path: temporary } = await fixture.request('temporary-create');
    assert.equal(path.dirname(temporary), fixture.directory);
    assert.match(temporary.slice(fixture.processPath.length), /^\.[0-9a-f]{24}$/);
    assert.equal(fs.lstatSync(temporary).size, 0);
    observation.assertUnchanged(before);
    assert.equal((await fixture.request('temporary-write', { bytes: bytes.slice(0, 17) })).position, 17);
    assert.equal(fs.readFileSync(temporary, 'utf8'), bytes.slice(0, 17));
    observation.assertUnchanged(before);
    await fixture.request('temporary-write', { bytes: bytes.slice(17) });
    assert.deepEqual(await fixture.request('temporary-fsync'), { synced: true });
    assert.equal(fs.readFileSync(temporary, 'utf8'), bytes);
    observation.assertUnchanged(before);

    const config = fs.readFileSync(fixture.config);
    fs.writeFileSync(fixture.config, 'protected mutation');
    assert.throws(() => observation.assertUnchanged(before), /unchanged/);
    fs.writeFileSync(fixture.config, config);
    fs.unlinkSync(fixture.processPath);
    assert.throws(() => observation.snapshot(), /observation refused/);
    fs.writeFileSync(fixture.processPath, '{', { mode: 0o600 });
    assert.throws(() => observation.snapshot(), /observation refused/);
    fs.writeFileSync(fixture.processPath, bytes);

    const published = await fixture.request('temporary-publish');
    assert.notEqual(published.inode, inode);
    assert.equal(fs.existsSync(temporary), false);
    assert.equal(fs.readFileSync(fixture.processPath, 'utf8'), bytes);
    observation.assertUnchanged(before);
  });
});

test('lease observation accepts exact temporary rename between enumeration, lstat or open without hiding protected changes', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const before = observation.snapshot();
    const bytes = fs.readFileSync(fixture.processPath);
    const temporary = `${fixture.processPath}.${'a'.repeat(24)}`;
    for (const boundary of ['enumeration', 'open', 'protected mutation']) {
      fs.writeFileSync(temporary, bytes, { mode: 0o600 });
      const descriptor = fs.openSync(temporary, fs.constants.O_RDONLY);
      const originalReaddir = fs.readdirSync;
      const originalOpen = fs.openSync;
      const config = fs.readFileSync(fixture.config);
      let renamed = false;
      const publish = () => {
        assert.equal(renamed, false);
        fs.renameSync(temporary, fixture.processPath);
        renamed = true;
        if (boundary === 'protected mutation') fs.writeFileSync(fixture.config, 'simultaneous protected mutation');
      };
      try {
        fs.readdirSync = (directory, ...args) => {
          const names = originalReaddir(directory, ...args);
          if (directory === fixture.directory && boundary !== 'open') {
            assert(names.includes(path.basename(temporary)));
            publish();
          }
          return names;
        };
        fs.openSync = (filename, ...args) => {
          if (filename === temporary && boundary === 'open') publish();
          return originalOpen(filename, ...args);
        };
        if (boundary === 'protected mutation') assert.throws(() => observation.assertUnchanged(before), /unchanged/);
        else observation.assertUnchanged(before);
        assert.equal(renamed, true);
        assert.equal(fs.fstatSync(descriptor).ino, fs.lstatSync(fixture.processPath).ino);
      } finally {
        fs.readdirSync = originalReaddir;
        fs.openSync = originalOpen;
        fs.closeSync(descriptor);
        fs.writeFileSync(fixture.config, config);
      }
      observation.assertUnchanged(before);
    }
  });
});

test('lease observation protects historical, other-directory and malformed publication names', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const before = observation.snapshot();
    for (const filename of [
      path.join(fixture.directory, `processes-${crypto.randomUUID()}.json.${'a'.repeat(24)}`),
      path.join(fixture.stateRoot, `${path.basename(fixture.processPath)}.${'a'.repeat(24)}`),
      `${fixture.processPath}.${'a'.repeat(23)}`,
      `${fixture.processPath}.${'a'.repeat(25)}`,
      `${fixture.processPath}.${'A'.repeat(24)}`,
      `${fixture.processPath}.${'a'.repeat(23)}z`,
      `${fixture.config}.${'a'.repeat(24)}`,
    ]) {
      fs.writeFileSync(filename, 'unpublished', { mode: 0o600 });
      try { assert.throws(() => observation.assertUnchanged(before), /unchanged/); }
      finally { fs.unlinkSync(filename); }
      observation.assertUnchanged(before);
    }
  });
});

test('lease observation refuses unsafe temporary metadata and safe inode substitution, closing every opened descriptor', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const before = observation.snapshot();
    const temporary = `${fixture.processPath}.${'b'.repeat(24)}`;
    fs.symlinkSync(fixture.config, temporary);
    assert.throws(() => observation.snapshot(), /unsafe unpublished/);
    fs.unlinkSync(temporary);
    fs.mkdirSync(temporary, { mode: 0o700 });
    assert.throws(() => observation.snapshot(), /unsafe unpublished/);
    fs.rmdirSync(temporary);
    fs.writeFileSync(temporary, '', { mode: 0o644 });
    assert.throws(() => observation.snapshot(), /unsafe unpublished/);
    fs.chmodSync(temporary, 0o600);
    fs.truncateSync(temporary, 2 * 1024 * 1024 + 1);
    assert.throws(() => observation.snapshot(), /unsafe unpublished/);
    fs.truncateSync(temporary, 0);
    const originalLstat = fs.lstatSync;
    const originalOpen = fs.openSync;
    const originalFstat = fs.fstatSync;
    const originalClose = fs.closeSync;
    for (const failure of ['valid', 'owner', 'opened owner', 'substitution', 'unsafe then absent', 'EACCES', 'ELOOP', 'fstat EIO']) {
      const descriptors = new Set();
      try {
        fs.lstatSync = (filename, ...args) => {
          if (filename === temporary && ['EACCES', 'ELOOP'].includes(failure)) {
            throw Object.assign(new Error(failure), { code: failure });
          }
          const stat = originalLstat(filename, ...args);
          if (filename === temporary && failure === 'owner') return new Proxy(stat, {
            get(target, key) { return key === 'uid' ? process.getuid() + 1 : Reflect.get(target, key); },
          });
          if (filename === temporary && failure === 'unsafe then absent') {
            fs.unlinkSync(filename);
            return new Proxy(stat, { get(target, key) { return key === 'mode' ? 0o644 : Reflect.get(target, key); } });
          }
          return stat;
        };
        fs.openSync = (filename, ...args) => {
          if (filename === temporary && failure === 'substitution') {
            const replacement = path.join(fixture.root, 'replacement');
            fs.writeFileSync(replacement, '', { mode: 0o600 });
            fs.renameSync(replacement, temporary);
          }
          const fd = originalOpen(filename, ...args);
          if (filename === temporary) descriptors.add(fd);
          return fd;
        };
        fs.fstatSync = (fd, ...args) => {
          if (descriptors.has(fd) && failure === 'fstat EIO') throw Object.assign(new Error('EIO'), { code: 'EIO' });
          const stat = originalFstat(fd, ...args);
          if (descriptors.has(fd) && failure === 'opened owner') return new Proxy(stat, {
            get(target, key) { return key === 'uid' ? process.getuid() + 1 : Reflect.get(target, key); },
          });
          return stat;
        };
        fs.closeSync = (fd) => { descriptors.delete(fd); return originalClose(fd); };
        if (failure === 'valid') observation.assertUnchanged(before);
        else assert.throws(() => observation.snapshot(), /unsafe unpublished|changed while opening|EACCES|ELOOP|EIO/);
        assert.equal(descriptors.size, 0);
      } finally {
        fs.lstatSync = originalLstat;
        fs.openSync = originalOpen;
        fs.fstatSync = originalFstat;
        fs.closeSync = originalClose;
        if (!fs.existsSync(temporary)) fs.writeFileSync(temporary, '', { mode: 0o600 });
      }
    }
    fs.unlinkSync(temporary);
    observation.assertUnchanged(before);
  });
});

test('lease observation never excuses a disappearing protected entry or publication directory', async () => {
  await withLeaseObservation(async (fixture) => {
    const observation = fixture.observe();
    const historical = path.join(fixture.directory, `processes-${crypto.randomUUID()}.json`);
    fs.writeFileSync(historical, 'protected history', { mode: 0o600 });
    const originalReaddir = fs.readdirSync;
    try {
      fs.readdirSync = (directory, ...args) => {
        const names = originalReaddir(directory, ...args);
        if (directory === fixture.directory) {
          assert(names.includes(path.basename(historical)));
          fs.unlinkSync(historical);
        }
        return names;
      };
      assert.throws(() => observation.snapshot(), { code: 'ENOENT' });
    } finally { fs.readdirSync = originalReaddir; }

    const temporary = `${fixture.processPath}.${'c'.repeat(24)}`;
    fs.writeFileSync(temporary, '', { mode: 0o600 });
    const originalLstat = fs.lstatSync;
    const displaced = path.join(fixture.root, 'displaced-instance');
    let renamed = false;
    try {
      fs.lstatSync = (filename, ...args) => {
        if (filename === temporary) { fs.renameSync(fixture.directory, displaced); renamed = true; }
        return originalLstat(filename, ...args);
      };
      assert.throws(() => observation.snapshot(), { code: 'ENOENT' });
      assert.equal(renamed, true);
    } finally {
      fs.lstatSync = originalLstat;
      if (renamed) fs.renameSync(displaced, fixture.directory);
      fs.unlinkSync(temporary);
    }
    observation.snapshot();
  });
});
