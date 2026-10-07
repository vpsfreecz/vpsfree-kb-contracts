const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const https = require('node:https');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { Connection } = require('../lib/connection.cjs');
const { assertInventoryMember, ensureIpInventory,
  INVENTORY_POOL, INVENTORY_RESOURCES, prepareFixtures } = require('../fixtures/prepare.cjs');
const { heldController } = require('./verify-live-lease.cjs');

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
