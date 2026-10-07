const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { test } = require('node:test');
const { once } = require('node:events');
const { Connection, openLease, readConnection } = require('../lib/connection.cjs');

const expected = { schema: 1, instance_id: '00000000-0000-0000-0000-000000000001',
  run_id: '00000000-0000-0000-0000-000000000002',
  artifact_id: '00000000-0000-0000-0000-000000000003', artifact_sha256: 'c'.repeat(64), descriptor_sha256: 'a'.repeat(64) };

function provenance(source) {
  const guest_identity = { schema: 1, instance_id: expected.instance_id, artifact_id: expected.artifact_id,
    config_input_sha256: 'd'.repeat(64), source };
  const artifact = { schema: 1, instance_id: expected.instance_id, artifact_id: expected.artifact_id,
    source, guest_identity, config_input_sha256: guest_identity.config_input_sha256,
    config_sha256: 'b'.repeat(64), machine_toplevels: { services: `/nix/store/${'0'.repeat(32)}-system` } };
  const artifact_json = `${JSON.stringify(artifact, null, 2)}\n`;
  return { source, guest_identity, artifact, artifact_json,
    config_sha256: artifact.config_sha256, machine_toplevels: artifact.machine_toplevels };
}

for (const [label, readiness] of [
  ['timeout', ''], ['malformed', 'console.log("not-json")'],
  ['wrong identity', 'console.log(JSON.stringify({schema:9}))'],
  ['oversized', 'console.log("x".repeat(9000))'],
]) {
  test(`failed ${label} readiness reaps its own stalled controller`, async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-controller-'));
    const pidFile = path.join(root, 'pid');
    const source = `require('fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));
      process.on('SIGTERM', () => {}); ${readiness}; setInterval(() => {}, 1000);`;
    try {
      await assert.rejects(openLease([process.execPath, '-e', source], expected, { timeout: 250, cleanupGrace: 100 }));
      const pid = Number(fs.readFileSync(pidFile, 'utf8'));
      assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
    } finally { fs.rmSync(root, { recursive: true }); }
  });
}

test('successful lease holds until supervised EOF, and controller loss cancels activity', async () => {
  const controller = [process.execPath, '-e', `console.log(${JSON.stringify(JSON.stringify(expected))});
    process.stdin.resume(); process.stdin.on('end', () => process.exit(0));`];
  const lease = await openLease(controller, expected);
  lease.assertLive();
  await lease.close();
  assert.throws(() => lease.assertLive());
  const dying = await openLease([process.execPath, '-e', `console.log(${JSON.stringify(JSON.stringify(expected))});
    setTimeout(() => process.exit(0), 100);`], expected);
  await once(dying.signal, 'abort');
  assert.throws(() => dying.assertLive());
  await dying.close();
});

test('protocol EOF after readiness aborts immediately, closes controller input and blocks later SSH', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-protocol-'));
  const pidFile = path.join(root, 'pid');
  const eofFile = path.join(root, 'eof');
  let lease;
  try {
    lease = await openLease([process.execPath, '-e', `
      const fs = require('fs'); fs.writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));
      console.log(${JSON.stringify(JSON.stringify(expected))});
      process.stdin.resume(); process.stdin.on('end', () => {
        fs.writeFileSync(${JSON.stringify(eofFile)}, 'EOF'); setTimeout(() => process.exit(0), 50);
      });
      setTimeout(() => process.stdout.end(), 50);
    `], expected, { cleanupGrace: 200 });
    if (!lease.signal.aborted) await once(lease.signal, 'abort');
    assert.throws(() => lease.assertLive(), /no longer live/);
    const connection = Object.assign(Object.create(Connection.prototype), { descriptor: { machines: {} }, lease });
    await assert.rejects(connection.ssh('services', ['echo', 'must-not-run']), /no longer live/);
    await lease.close();
    assert.equal(fs.readFileSync(eofFile, 'utf8'), 'EOF');
    assert.throws(() => process.kill(Number(fs.readFileSync(pidFile, 'utf8')), 0), { code: 'ESRCH' });
  } finally {
    if (lease) await lease.close();
    fs.rmSync(root, { recursive: true });
  }
});

for (const readiness of [false, true]) {
  test(`protocol EOF ${readiness ? 'in the readiness window' : 'before readiness'} supervises its still-running child`, async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-protocol-window-'));
    const pidFile = path.join(root, 'pid');
    let lease;
    try {
      const promise = openLease([process.execPath, '-e', `
        require('fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));
        ${readiness ? `console.log(${JSON.stringify(JSON.stringify(expected))});` : ''}
        process.stdout.end(); process.stdin.resume(); process.stdin.on('end', () => process.exit(0));
      `], expected, { timeout: 1000, cleanupGrace: 200 });
      if (readiness) {
        lease = await promise;
        if (!lease.signal.aborted) await once(lease.signal, 'abort');
        assert.throws(() => lease.assertLive());
        await lease.close();
      } else {
        await assert.rejects(promise, /protocol|readiness/);
      }
      assert.throws(() => process.kill(Number(fs.readFileSync(pidFile, 'utf8')), 0), { code: 'ESRCH' });
    } finally {
      if (lease) await lease.close();
      fs.rmSync(root, { recursive: true });
    }
  });
}

test('diagnostic stderr EOF alone preserves a usable lease until intentional close', async () => {
  const lease = await openLease([process.execPath, '-e', `
    process.stderr.end(); console.log(${JSON.stringify(JSON.stringify(expected))});
    process.stdin.resume(); process.stdin.on('end', () => process.exit(0));
  `], expected);
  try {
    lease.assertLive();
    assert.equal(lease.signal.aborted, false);
    await lease.close();
    assert.equal(lease.signal.aborted, false, 'intentional EOF is normal shutdown');
  } finally { await lease.close(); }
});

test('arbitrary configured origins route exactly; unknown hosts and stale live provenance fail before fixtures', async () => {
  let live = true;
  const source = { revision: 'a'.repeat(40) };
  const descriptor = { accounts_file: null,
    instance_id: expected.instance_id, run_id: expected.run_id, artifact_id: expected.artifact_id,
    services: { api: { url: 'https://api.docs.example.test:8443/', connect_host: '127.0.0.7', connect_port: 14543 } },
    provenance: provenance(source) };
  descriptor.artifact_sha256 = crypto.createHash('sha256').update(descriptor.provenance.artifact_json).digest('hex');
  // Avoid account IO to isolate the connection's actual routing and proof path.
  const connection = Object.assign(Object.create(Connection.prototype), {
    descriptor, lease: { assertLive() { assert(live); } },
  });
  assert.deepEqual(connection.route('https://api.docs.example.test:8443/?hello'), { host: '127.0.0.7', port: 14543 });
  assert.throws(() => connection.route('https://elsewhere.example.test/'));
  let calls = 0;
  connection.ssh = async () => { calls += 1; return JSON.stringify({ schema: 1, source: { revision: 'wrong' } }); };
  await assert.rejects(connection.verify(source), /Live guest/);
  assert.equal(calls, 1);
  calls = 0;
  await assert.rejects(connection.verify({ revision: 'wrong' }), /Expected K/);
  assert.equal(calls, 0);
  live = false;
  assert.throws(() => connection.route(descriptor.services.api.url));
});

test('a fresh live run proves the same prepared artifact, while receipt and guest confusion refuse', async () => {
  const source = { revision: 'a'.repeat(40) };
  const descriptor = { instance_id: expected.instance_id, run_id: expected.run_id, artifact_id: expected.artifact_id,
    provenance: provenance(source) };
  descriptor.artifact_sha256 = crypto.createHash('sha256').update(descriptor.provenance.artifact_json).digest('hex');
  const connection = Object.assign(Object.create(Connection.prototype), {
    descriptor, lease: { assertLive() {} },
  });
  let guest = descriptor.provenance.guest_identity;
  let calls = 0;
  connection.ssh = async (_machine, argv) => {
    calls += 1;
    return argv[0] === 'cat' ? JSON.stringify(guest) : descriptor.provenance.machine_toplevels.services;
  };
  const original = await connection.verify(source);
  descriptor.run_id = '00000000-0000-0000-0000-000000000004';
  const resumed = await connection.verify(source);
  assert.notEqual(original.run_id, resumed.run_id);
  assert.equal(original.artifact_id, resumed.artifact_id);
  assert.equal(original.artifact_sha256, resumed.artifact_sha256);
  assert.deepEqual(original.machine_toplevels, resumed.machine_toplevels);
  guest = { ...guest, run_id: descriptor.run_id };
  await assert.rejects(connection.verify(source), /Live guest/);
  calls = 0;
  descriptor.provenance.artifact_json += ' ';
  await assert.rejects(connection.verify(source), /digest/);
  assert.equal(calls, 0);
  descriptor.provenance.artifact_json = descriptor.provenance.artifact_json.slice(0, -1);
  descriptor.artifact_id = descriptor.run_id;
  await assert.rejects(connection.verify(source), /provenance/);
  assert.equal(calls, 0);
});

test('local and external descriptors enforce the same required capabilities and private references', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-connection-'));
  const file = path.join(root, 'connection.json');
  try {
    for (const name of ['accounts', 'key', 'known-hosts', 'ca']) fs.writeFileSync(path.join(root, name), '{}', { mode: 0o600 });
    const descriptor = { ...expected, schema: 1, kind: 'vpsfree-kb-connection', owner_id: `uid:${process.getuid()}`,
      capabilities: ['capture-lease-v1', 'ssh'], tls: { ca_file: 'ca' }, accounts_file: 'accounts',
      services: { api: { url: 'https://api.example.test/', connect_host: '127.0.0.1', connect_port: 14043 } },
      machines: { services: { host: '127.0.0.1', port: 14022, user: 'root', private_key: 'key', known_hosts: 'known-hosts' } },
      control: { argv: [process.execPath, '-e', ''] } };
    descriptor.control.argv[2] = 'process.stdin.read()';
    fs.writeFileSync(file, JSON.stringify(descriptor), { mode: 0o600 });
    assert.throws(() => readConnection(file, ['base-vps']), /capabilities/);
    descriptor.capabilities.push('base-vps');
    fs.writeFileSync(file, JSON.stringify(descriptor));
    assert.equal(readConnection(file, ['base-vps']).value.services.api.connect_port, 14043);
    delete descriptor.artifact_id;
    fs.writeFileSync(file, JSON.stringify(descriptor));
    assert.throws(() => readConnection(file, ['base-vps']), /identity/);
    descriptor.artifact_id = expected.artifact_id;
    fs.writeFileSync(file, JSON.stringify(descriptor));
    fs.chmodSync(path.join(root, 'key'), 0o644);
    assert.throws(() => readConnection(file, ['base-vps']), /private/);
  } finally { fs.rmSync(root, { recursive: true }); }
});

test('an enclosing lease cancels pending readiness and reaps only the newly spawned controller', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-enclosing-lease-'));
  const pidFile = path.join(root, 'pid');
  const eofFile = path.join(root, 'eof');
  const enclosing = new AbortController();
  let pending;
  try {
    const alreadyLost = new AbortController();
    alreadyLost.abort(new Error('already lost'));
    await assert.rejects(openLease([process.execPath, '-e', `require('fs').writeFileSync(${JSON.stringify(pidFile)}, 'unexpected')`],
      expected, { signal: alreadyLost.signal }), /already lost/);
    assert.equal(fs.existsSync(pidFile), false, 'already-lost parent must not spawn a controller');
    pending = openLease([process.execPath, '-e', `
      const fs = require('fs'); fs.writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));
      process.stderr.end(); process.stdin.resume(); process.stdin.on('end', () => {
        fs.writeFileSync(${JSON.stringify(eofFile)}, 'EOF'); process.exit(0);
      });
    `], expected, { signal: enclosing.signal, timeout: 2000, cleanupGrace: 200 });
    const deadline = Date.now() + 1500;
    while (!fs.existsSync(pidFile)) {
      if (Date.now() > deadline) throw new Error('Owned readiness fixture failed to start');
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    enclosing.abort(new Error('artifact authority lost'));
    await assert.rejects(pending, /enclosing lease/);
    assert.equal(fs.readFileSync(eofFile, 'utf8'), 'EOF');
    assert.throws(() => process.kill(Number(fs.readFileSync(pidFile)), 0), { code: 'ESRCH' });
  } finally {
    enclosing.abort(new Error('owned fixture cleanup'));
    if (pending) await pending.catch(() => {});
    fs.rmSync(root, { recursive: true });
  }
});

test('acquired cluster readiness leaves enclosing cancellation to capture cleanup rather than releasing its controller early', async () => {
  const enclosing = new AbortController();
  const lease = await openLease([process.execPath, '-e', `
    console.log(${JSON.stringify(JSON.stringify(expected))});
    process.stdin.resume(); process.stdin.on('end', () => process.exit(0));
  `], expected, { signal: enclosing.signal });
  try {
    enclosing.abort(new Error('artifact authority lost'));
    lease.assertLive();
    assert.equal(lease.signal.aborted, false, 'capture composite cancels work while controller survives until cleanup');
    await lease.close();
  } finally { await lease.close(); }
});
