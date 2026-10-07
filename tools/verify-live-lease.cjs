const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const { isDeepStrictEqual } = require('node:util');
const { Connection, readConnection } = require('../lib/connection.cjs');

// A verifier controller is an explicitly spawned, unreaped child. It grants no
// authority over guests, unrelated processes or a controller found by PID scan.
async function heldController(value, digest, interrupt, work) {
  const expected = { schema: 1, instance_id: value.instance_id, run_id: value.run_id,
    artifact_id: value.artifact_id, artifact_sha256: value.artifact_sha256, descriptor_sha256: digest };
  const argv = [...value.control.argv, '--instance-id', value.instance_id, '--run-id', value.run_id,
    '--artifact-id', value.artifact_id, '--artifact-sha256', value.artifact_sha256, '--descriptor-sha256', digest];
  const child = spawn(argv[0], argv.slice(1), { stdio: ['pipe', 'pipe', 'pipe'] });
  child.stderr.resume();
  child.stdin.on('error', () => {});
  let closed = false;
  let failed;
  const exited = new Promise((resolve) => {
    child.once('error', (error) => { failed = error; });
    child.once('close', (code, signal) => { closed = true; resolve({ code, signal }); });
  });
  const abort = new AbortController();
  const lost = () => abort.abort(new Error('Owned verifier controller protocol ended'));
  child.stdout.on('end', lost);
  child.stdout.on('close', lost);
  child.stdout.on('error', lost);
  child.once('close', lost);
  const lease = { signal: abort.signal, assertLive() {
    if (closed || failed || abort.signal.aborted) throw new Error('Owned verifier controller is lost');
  } };
  try {
    await new Promise((resolve, reject) => {
      let buffer = '';
      const timer = setTimeout(() => reject(new Error('Public lease readiness deadline')), 120000);
      const end = () => { clearTimeout(timer); reject(new Error('Public lease ended before readiness')); };
      abort.signal.addEventListener('abort', end, { once: true });
      child.once('error', (error) => { clearTimeout(timer); reject(error); });
      let ready = false;
      child.stdout.on('data', (chunk) => {
        if (ready) { lost(); return; }
        buffer += chunk;
        if (buffer.length > 65536) { clearTimeout(timer); reject(new Error('Public lease readiness exceeds limit')); return; }
        const index = buffer.indexOf('\n');
        if (index < 0) return;
        clearTimeout(timer);
        abort.signal.removeEventListener('abort', end);
        try { assert.deepEqual(JSON.parse(buffer.slice(0, index)), expected); assert.equal(buffer.slice(index + 1), ''); ready = true; resolve(); }
        catch (error) { reject(error); }
      });
    });
    lease.assertLive();
    await work(lease);
  } finally {
    const signalOwned = (signal) => {
      if (!closed && child.exitCode === null && child.signalCode === null) child.kill(signal);
    };
    const wait = async (milliseconds) => {
      let timer;
      try { return await Promise.race([exited, new Promise((resolve) => { timer = setTimeout(() => resolve(null), milliseconds); })]); }
      finally { clearTimeout(timer); }
    };
    if (interrupt) signalOwned('SIGTERM');
    if (!child.stdin.destroyed) child.stdin.end();
    let result = await wait(10000);
    if (!result) { signalOwned('SIGTERM'); result = await wait(2000); }
    if (!result) { signalOwned('SIGKILL'); result = await wait(2000); }
    // No PID scan, process-group signal, detached waiter or background cleanup.
    // Every signal uses only this still-unreaped ChildProcess handle.
    assert(result && closed, 'exact spawned controller must be reaped before return');
    if (!interrupt) assert.equal(result.code, 0, 'ordinary lease EOF must exit successfully');
  }
}

function retained(root, additional = []) {
  const value = {};
  const walk = (directory) => {
    for (const name of fs.readdirSync(directory)) {
      const filename = path.join(directory, name);
      const stat = fs.lstatSync(filename);
      if (stat.isDirectory()) { walk(filename); continue; }
      if (stat.isFile() && !filename.endsWith('.img') && !filename.endsWith('.log')) {
        value[filename] = [stat.ino, crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex')];
      }
    }
  };
  walk(root);
  for (const filename of additional) {
    const stat = fs.lstatSync(filename);
    assert(stat.isFile() && !stat.isSymbolicLink() && stat.uid === process.getuid() && (stat.mode & 0o777) === 0o600);
    value[filename] = [stat.ino, crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex')];
  }
  return value;
}

async function main(argv) {
  const [descriptorPath, metadataPath, runtimePackage, stateRoot, configPath] = argv;
  const { value, digest } = readConnection(descriptorPath, ['ip-inventory']);
  const source = JSON.parse(fs.readFileSync(metadataPath));
  const engine = path.join(runtimePackage, 'bin/vpsfree-kb-devcluster');
  for (const interrupt of [false, true, false]) {
    await heldController(value, digest, interrupt, async (lease) => {
      const connection = new Connection(value, lease);
      await connection.verify(source);
      const actual = connection.route(connection.apiUrl);
      assert.deepEqual(actual, { host: value.services.api.connect_host, port: value.services.api.connect_port });
      assert.throws(() => connection.route('https://unrelated.example.test/'));
      let ssh = 0;
      const method = connection.ssh.bind(connection);
      connection.ssh = async (...args) => { ssh += 1; return method(...args); };
      await assert.rejects(connection.verify({ ...source, revision: '0'.repeat(40) }), /Expected K source/);
      assert.equal(ssh, 0, 'wrong source must fail before SSH or fixtures');
      const directory = path.join(stateRoot, 'clusters/same-slug');
      const launch = JSON.parse(fs.readFileSync(path.join(directory, `launch-${value.run_id}.json`)));
      assert.equal(launch.instance_id, value.instance_id);
      assert.equal(launch.run_id, value.run_id);
      const claim = path.join(path.dirname(launch.socket_dir), 'reservations', `${value.instance_id}-${value.run_id}.json`);
      const reservation = JSON.parse(fs.readFileSync(claim));
      assert.equal(reservation.state_root, stateRoot);
      assert.equal(reservation.instance_id, value.instance_id);
      assert.equal(reservation.run_id, value.run_id);
      const before = retained(stateRoot, [claim]);
      for (const command of ['stop', 'update', 'reset']) {
        const args = ['--state-root', stateRoot, command, 'same-slug'];
        if (command === 'update') args.push('--network', 'local', '--config', configPath);
        lease.assertLive();
        let code;
        try { execFileSync(engine, args, { stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000 }); code = 0; }
        catch (error) { if (error.signal) throw error; code = error.status; }
        assert.equal(code, 75, `public ${command} must refuse before lease release`);
        lease.assertLive();
        assert(isDeepStrictEqual(retained(stateRoot, [claim]), before), 'lease rejection leaves state/credentials/claims unchanged');
      }
    });
  }
  const current = JSON.parse(execFileSync(engine, ['--state-root', stateRoot, 'connection', 'same-slug']));
  assert.equal(current.run_id, value.run_id);
  process.stdout.write('Public lease proof complete\n');
}
module.exports = { heldController, main, retained };
if (require.main === module) main(process.argv.slice(2)).catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
