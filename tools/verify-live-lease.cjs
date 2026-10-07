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

function retained(root, additional = [], currentProcessPath) {
  const value = {};
  const publicationDirectory = currentProcessPath && path.dirname(currentProcessPath);
  const publicationPrefix = currentProcessPath && `${path.basename(currentProcessPath)}.`;
  const safeTemporary = (filename, directory) => {
    const parent = fs.lstatSync(directory);
    const safeParent = (stat) => stat.isDirectory() && !stat.isSymbolicLink() &&
      stat.uid === process.getuid() && (stat.mode & 0o777) === 0o700;
    assert(safeParent(parent), 'unsafe process publication directory');
    const missing = (error) => {
      if (error.code !== 'ENOENT') throw error;
      const current = fs.lstatSync(directory);
      assert(safeParent(current) && current.dev === parent.dev && current.ino === parent.ino,
        'process publication directory changed');
    };
    let stat;
    try { stat = fs.lstatSync(filename); } catch (error) { missing(error); return; }
    const safe = (entry) => entry.isFile() && !entry.isSymbolicLink() && entry.uid === process.getuid() &&
      (entry.mode & 0o777) === 0o600 && entry.size <= 2 * 1024 * 1024;
    assert(safe(stat), 'unsafe unpublished process receipt');
    let fd;
    try { fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
    catch (error) { missing(error); return; }
    try {
      const opened = fs.fstatSync(fd);
      assert(safe(opened) && opened.dev === stat.dev && opened.ino === stat.ino,
        'unpublished process receipt changed while opening');
    } finally { fs.closeSync(fd); }
  };
  const walk = (directory) => {
    for (const name of fs.readdirSync(directory)) {
      const filename = path.join(directory, name);
      if (filename === currentProcessPath) continue;
      // Only this validated current publisher's exact unpublished namespace
      // can disappear during rename. All other entries remain protected.
      if (directory === publicationDirectory && name.startsWith(publicationPrefix) &&
        /^[0-9a-f]{24}$/.test(name.slice(publicationPrefix.length))) {
        safeTemporary(filename, directory);
        continue;
      }
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

// The selected subject SDK owns private atomic reads and native PID identity.
// This observation grants no lifecycle, signalling or complete-exit authority.
const liveObservation = String.raw`
  require File.join(ARGV.fetch(0), 'cluster/lib/kb_process')
  begin
    input = STDIN.read(2 * 1024 * 1024 + 1)
    raise KbRuntime::Error, 'descriptor exceeds limit' if input.bytesize > 2 * 1024 * 1024
    expected = JSON.parse(input)
    fields = %w[instance_id run_id artifact_id artifact_sha256]
    raise KbRuntime::Error, 'invalid expected identity' unless
      fields.first(3).all? { |key| KbRuntime::State::UUID.match?(expected.fetch(key)) } &&
      /\A[0-9a-f]{64}\z/.match?(expected.fetch('artifact_sha256')) &&
      expected.fetch('owner_id') == "uid:#{Process.uid}" &&
      expected.fetch('provenance').fetch('source').fetch('source') == ARGV.fetch(0)
    state = KbRuntime::State.new(ARGV.fetch(1), 'same-slug')
    raise KbRuntime::Error, 'state root differs' unless state.root == ARGV.fetch(1)
    raise KbRuntime::Error, 'instance differs' unless state.identity.fetch('instance_id') == expected.fetch('instance_id')
    phase = state.read(state.path('phase.json'))
    raise KbRuntime::Error, 'not the current ready run' unless
      phase == { 'schema' => 1, 'phase' => 'ready', 'run_id' => expected.fetch('run_id') }
    launch = state.read(state.path("launch-#{expected.fetch('run_id')}.json"))
    raise KbRuntime::Error, 'launch differs' unless launch['schema'] == KbRuntime::State::SCHEMA &&
      fields.all? { |key| launch[key] == expected[key] } && launch['state_root'] == state.root &&
      launch['slug'] == state.slug && launch['owner_uid'] == Process.uid &&
      launch['source'] == expected.fetch('provenance').fetch('source') &&
      launch['boot_id'] == KbRuntime::ProcessIdentity.boot_id
    bytes = state.file(state.path("artifact-#{expected.fetch('artifact_id')}.json"))
    artifact = JSON.parse(bytes)
    raise KbRuntime::Error, 'artifact differs' unless
      Digest::SHA256.hexdigest(bytes) == expected.fetch('artifact_sha256') &&
      bytes == expected.fetch('provenance').fetch('artifact_json') && artifact['schema'] == 1 &&
      artifact['instance_id'] == expected['instance_id'] && artifact['artifact_id'] == expected['artifact_id'] &&
      artifact['source'] == launch['source']
    claim = File.join(File.dirname(launch.fetch('socket_dir')), 'reservations', "#{expected.fetch('instance_id')}-#{expected.fetch('run_id')}.json")
    raise KbRuntime::Error, 'claim directory absent' unless state.private_directory(File.dirname(claim))
    reservation = state.read(claim)
    raise KbRuntime::Error, 'claim differs' unless fields.all? { |key| reservation[key] == expected[key] } &&
      reservation['state_root'] == state.root && reservation['owner_uid'] == Process.uid &&
      reservation['boot_id'] == launch['boot_id']
    process_path = state.path("processes-#{expected.fetch('run_id')}.json")
    record = state.read(process_path)
    raise KbRuntime::Error, 'process receipt differs' unless record.is_a?(Hash) &&
      record.keys.sort == (fields + %w[schema runner children complete]).sort && record['schema'] == 1 &&
      fields.all? { |key| record[key] == expected[key] } && record['complete'] == false && record['children'].is_a?(Array)
    valid = lambda do |identity|
      identity.is_a?(Hash) && identity.keys.sort == %w[argv boot_id executable owner_uid pid start_ticks] &&
        identity['pid'].is_a?(Integer) && identity['pid'] > 1 && identity['pid'] <= 2**31 - 1 &&
        identity['start_ticks'].is_a?(Integer) && identity['start_ticks'] >= 0 && identity['start_ticks'] <= 2**53 - 1 &&
        identity['boot_id'] == launch['boot_id'] && identity['owner_uid'] == Process.uid &&
        identity['executable'].is_a?(String) && identity['executable'].start_with?('/') &&
        !identity['executable'].include?("\0") && identity['argv'].is_a?(Array) &&
        identity['argv'].all? { |argument| argument.is_a?(String) && !argument.include?("\0") }
    end
    runner = record['runner']
    raise KbRuntime::Error, 'runner differs' unless valid.call(runner) && KbRuntime::ProcessIdentity.runner_matches?(runner, launch)
    keys = record['children'].map do |child|
      raise KbRuntime::Error, 'invalid child identity' unless valid.call(child) && child['pid'] != runner['pid']
      [child['pid'], child['start_ticks']]
    end
    raise KbRuntime::Error, 'duplicate child identity' unless keys.uniq == keys
    STDOUT.write(JSON.generate('process_path' => process_path, 'claim_path' => claim, 'record' => record))
  rescue StandardError => error
    warn "Live process observation refused: #{error.class}"
    exit 1
  end
`;

function observeLeaseState(root, value, sdkSource) {
  const read = () => {
    try {
      return JSON.parse(execFileSync('ruby', ['-e', liveObservation, '--', sdkSource, root], {
        input: JSON.stringify(value), encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, timeout: 10000,
        stdio: ['pipe', 'pipe', 'pipe'],
      }));
    } catch (error) { throw new Error('Live process observation refused', { cause: error }); }
  };
  const initial = read();
  const seen = new Set();
  const update = (observation) => {
    assert.equal(observation.process_path, initial.process_path);
    assert.equal(observation.claim_path, initial.claim_path);
    assert.deepEqual(observation.record.runner, initial.record.runner, 'authenticated runner must remain unchanged');
    const keys = new Set(observation.record.children.map((child) => JSON.stringify([child.pid, child.start_ticks])));
    for (const key of seen) assert(keys.has(key), 'previously observed child identity must remain recorded');
    for (const key of keys) seen.add(key);
  };
  update(initial);
  return {
    snapshot() {
      update(read());
      const protectedFiles = retained(root, [initial.claim_path], initial.process_path);
      update(read());
      return protectedFiles;
    },
    assertUnchanged(before) {
      assert(isDeepStrictEqual(this.snapshot(), before), 'lease rejection leaves state/credentials/claims unchanged');
    },
  };
}

async function main(argv) {
  const [descriptorPath, metadataPath, runtimePackage, stateRoot, configPath] = argv;
  const { value, digest } = readConnection(descriptorPath, ['ip-inventory']);
  const source = JSON.parse(fs.readFileSync(metadataPath));
  const engine = path.join(runtimePackage, 'bin/vpsfree-kb-devcluster');
  let observation;
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
      observation ||= observeLeaseState(stateRoot, value, source.source);
      const before = observation.snapshot();
      for (const command of ['stop', 'update', 'reset']) {
        const args = ['--state-root', stateRoot, command, 'same-slug'];
        if (command === 'update') args.push('--network', 'local', '--config', configPath);
        lease.assertLive();
        let code;
        try { execFileSync(engine, args, { stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000 }); code = 0; }
        catch (error) { if (error.signal) throw error; code = error.status; }
        assert.equal(code, 75, `public ${command} must refuse before lease release`);
        lease.assertLive();
        observation.assertUnchanged(before);
      }
    });
  }
  const current = JSON.parse(execFileSync(engine, ['--state-root', stateRoot, 'connection', 'same-slug']));
  assert.equal(current.run_id, value.run_id);
  process.stdout.write('Public lease proof complete\n');
}
module.exports = { heldController, main, retained, observeLeaseState };
if (require.main === module) main(process.argv.slice(2)).catch((error) => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
