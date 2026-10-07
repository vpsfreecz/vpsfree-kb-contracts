const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');
const { test } = require('node:test');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { openLease } = require('../lib/connection.cjs');

const repoRoot = path.resolve(__dirname, '..');
const runs = new Map();
const artifactRuns = new Map();
const clip = { x: 0, y: 0, width: 1, height: 1 };
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
async function bounded(promise) {
  let timer;
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Capture fixture boundary timed out')), 4000);
    })]);
  } finally { clearTimeout(timer); }
}
async function waitFile(filename) {
  const deadline = Date.now() + 4000;
  while (!fs.existsSync(filename)) {
    if (Date.now() >= deadline) throw new Error(`Fixture did not reach ${path.basename(filename)}`);
    await delay(10);
  }
}

// Keep main, Connection, browser supervision, CaptureSession, Artifacts and the
// actual Ruby flock controller. Only guest transport, browser implementation
// and scenario/fixture contents are synthetic; no VM or Chromium is launched.
const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (request === 'playwright') return { chromium: { async launch() {
    let run;
    return {
      async newContext({ baseURL, locale }) {
        run = runs.get(new URL(baseURL).hostname);
        run.browserOpened += 1;
        const page = {
          async goto() { assert.equal(run.browserClosed, false); },
          locator() { return { first() { return this; }, async count() { return 1; },
            async getAttribute() { return locale.slice(0, 2); }, async waitFor() {} }; },
          async addStyleTag() { assert.equal(run.browserClosed, false); },
          async evaluate() { assert.equal(run.browserClosed, false); },
          async screenshot({ path: filename }) {
            assert.equal(run.browserClosed, false);
            fs.writeFileSync(filename, run.contents);
          },
          url() { return `${baseURL}?page=networking&action=ip_addresses`; },
        };
        return { async newPage() { return page; } };
      },
      async close() {
        if (run) {
          run.browserClosed = true; run.browserGone.resolve();
          if (run.cleanupRelease) {
            fs.writeFileSync(run.cleanupEntered, 'browser cleanup holds writer descriptor');
            await waitFile(run.cleanupRelease);
          }
        }
      },
    };
  } } };
  return originalLoad.call(this, request, parent, isMain);
};
function substitute(relative, exports) {
  const filename = require.resolve(relative);
  require.cache[filename] = { id: filename, filename, loaded: true, exports };
}
substitute('../fixtures/prepare.cjs', { async prepareFixtures({ cluster }) {
  cluster.assertLease();
  const run = runs.get(new URL(cluster.webuiBaseUrl).hostname);
  run.fixtures += 1;
  await cluster.ssh('services', ['fixture-check']);
  return {};
} });
substitute('../scenarios/networking.cjs', { async run(args) {
  const run = runs.get(new URL(args.cluster.webuiBaseUrl).hostname);
  if (run.scenario) return run.scenario(args);
  await args.session.shot(args.page, 'networking/ip-address-list', [], { clip });
} });
const connectionModule = require('../lib/connection.cjs');
connectionModule.openLease = async (argv, expected, options) => {
  let run;
  if (argv[1] === path.join(repoRoot, 'cluster/artifact-lock.rb')) {
    run = artifactRuns.get(argv[2]);
    const script = `
      File.write(${JSON.stringify(run.artifactPid)}, Process.pid.to_s)
      ${run.stderrOnly ? "$stderr.reopen(File::NULL, 'w'); $stderr.close" : ''}
      Thread.new do
        sleep 0.01 until File.exist?(${JSON.stringify(run.loseArtifact)})
        $stdout.reopen(File::NULL, 'w'); $stdout.close
      end
      ${run.artifactFailure === 'before' ? "$stdout.reopen(File::NULL, 'w'); $stdout.close" : ''}
      ${run.artifactFailure === 'window' ? `
        output = $stdout
        output.define_singleton_method(:puts) do |*args|
          super(*args); flush; reopen(File::NULL, 'w'); close
        end
      ` : ''}
      ARGV.replace(${JSON.stringify(argv.slice(2))})
      load ${JSON.stringify(argv[1])}
    `;
    argv = [argv[0], '-e', script];
  }
  const lease = await openLease(argv, expected, { timeout: 4000, cleanupGrace: 200, ...options });
  if (run) {
    run.artifactLease = lease;
    if (run.acquiredFile) fs.writeFileSync(run.acquiredFile, 'artifact readiness acquired');
  }
  return lease;
};
const { main, pinnedVpsadminCommit } = require('../runner/capture.cjs');
Module._load = originalLoad;
connectionModule.openLease = openLease;

const source = { schema: 1, revision: 'a'.repeat(40), source: '/nix/store/synthetic-k-source',
  lock_sha256: 'b'.repeat(64), inputs: { vpsadmin: { rev: pinnedVpsadminCommit() } } };
const oldPath = process.env.PATH;
const oldChromium = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

function fixture(root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-capture-lease-'))) {
  const outputRoot = path.join(root, 'output');
  const executables = path.join(root, 'bin');
  fs.mkdirSync(outputRoot, { recursive: true }); fs.mkdirSync(executables, { recursive: true });
  fs.writeFileSync(path.join(executables, 'ssh'), `#!${process.execPath}
    const fs = require('fs'), path = require('path');
    const args = process.argv.slice(2);
    const root = path.dirname(args[args.indexOf('-i') + 1]);
    const value = JSON.parse(fs.readFileSync(path.join(root, 'transport.json')));
    const lock = fs.statSync(path.join(path.dirname(root), 'output/tmp/capture.lock'));
    const leaked = fs.readdirSync('/proc/self/fd').some((fd) => {
      try { const stat = fs.fstatSync(Number(fd)); return stat.dev === lock.dev && stat.ino === lock.ino; }
      catch (_) { return false; }
    });
    fs.writeFileSync(path.join(root, 'ssh-lock-leaked'), JSON.stringify(leaked));
    const command = args.at(-1);
    if (command.includes('stall')) {
      fs.writeFileSync(path.join(root, 'ssh.pid'), String(process.pid));
      setInterval(() => {
        if (fs.existsSync(path.join(root, 'fixture-cleanup'))) process.exit(0);
      }, 20);
    } else if (command.includes('/etc/vpsfree-kb-capture.json')) {
      process.stdout.write(JSON.stringify(value.guest_identity));
    } else if (command.includes('/run/current-system')) {
      process.stdout.write(value.machine_toplevels.services);
    }
  `, { mode: 0o700 });
  process.env.PATH = `${executables}:${oldPath}`;
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE = process.execPath; // Fake chromium never executes it.
  return { root, outputRoot, clean() {
    process.env.PATH = oldPath;
    if (oldChromium === undefined) delete process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
    else process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE = oldChromium;
    fs.rmSync(root, { recursive: true });
    runs.clear(); artifactRuns.clear();
  } };
}
function runFixture(value, contents, { pending = false, stderrOnly = false, artifactFailure } = {}) {
  const run_id = crypto.randomUUID();
  const directory = path.join(value.root, run_id);
  fs.mkdirSync(directory, { mode: 0o700 });
  const run = { contents, directory, fixtures: 0, browserOpened: 0, browserClosed: false,
    browserGone: deferred(), cancelled: deferred(), continueAfterCompetitor: deferred(), stderrOnly, artifactFailure,
    artifactPid: path.join(directory, 'artifact.pid'), loseArtifact: path.join(directory, 'lose-artifact'),
    clusterPid: path.join(directory, 'cluster.pid'), clusterEof: path.join(directory, 'cluster-eof') };
  const instance_id = crypto.randomUUID();
  const artifact_id = crypto.randomUUID();
  const guest_identity = { schema: 1, instance_id, artifact_id, config_input_sha256: 'd'.repeat(64), source };
  const artifact = { schema: 1, instance_id, artifact_id, source, guest_identity,
    config_input_sha256: guest_identity.config_input_sha256, config_sha256: 'c'.repeat(64),
    machine_toplevels: { services: `/nix/store/${'0'.repeat(32)}-synthetic-system` } };
  const artifact_json = `${JSON.stringify(artifact, null, 2)}\n`;
  const controller = `
    const fs = require('fs');
    const lock = fs.statSync(${JSON.stringify(path.join(value.outputRoot, 'tmp/capture.lock'))});
    const leaked = fs.readdirSync('/proc/self/fd').some((fd) => {
      try { const stat = fs.fstatSync(Number(fd)); return stat.dev === lock.dev && stat.ino === lock.ino; }
      catch (_) { return false; }
    });
    fs.writeFileSync(${JSON.stringify(path.join(directory, 'cluster-lock-leaked'))}, JSON.stringify(leaked));
    fs.writeFileSync(${JSON.stringify(run.clusterPid)}, String(process.pid));
    const args = process.argv.slice(1);
    const identity = Object.fromEntries(Array.from({length: args.length / 2}, (_, i) =>
      [args[i * 2].slice(2).replaceAll('-', '_'), args[i * 2 + 1]]));
    ${pending ? '' : 'console.log(JSON.stringify({schema: 1, ...identity}));'}
    process.stderr.end();
    process.stdin.resume(); process.stdin.on('end', () => {
      fs.writeFileSync(${JSON.stringify(run.clusterEof)}, 'EOF'); process.exit(0);
    });
  `;
  for (const name of ['key', 'known-hosts', 'ca']) fs.writeFileSync(path.join(directory, name), '{}', { mode: 0o600 });
  fs.writeFileSync(path.join(directory, 'accounts'), JSON.stringify({ users: [{ login: 'test-user1', password: 'synthetic' }] }), { mode: 0o600 });
  fs.writeFileSync(path.join(directory, 'transport.json'), JSON.stringify(artifact), { mode: 0o600 });
  const services = Object.fromEntries(['webui', 'api', 'console'].map((name) => [name, {
    url: `https://${run_id}.example.test/${name === 'webui' ? '' : name}`,
    connect_host: '127.0.0.1', connect_port: 14043,
  }]));
  const descriptor = { schema: 1, kind: 'vpsfree-kb-connection', owner_id: `uid:${process.getuid()}`,
    instance_id, run_id, artifact_id, artifact_sha256: crypto.createHash('sha256').update(artifact_json).digest('hex'),
    capabilities: ['capture-lease-v1', 'ssh', 'base-vps', 'traffic-samples', 'ip-inventory'],
    accounts_file: 'accounts', tls: { ca_file: 'ca' }, services,
    machines: { services: { host: '127.0.0.1', port: 14022, user: 'root', private_key: 'key', known_hosts: 'known-hosts' } },
    provenance: { source, artifact, artifact_json, guest_identity,
      config_sha256: artifact.config_sha256, machine_toplevels: artifact.machine_toplevels },
    control: { argv: [process.execPath, '-e', controller, '--'] },
  };
  run.connection = path.join(directory, 'connection.json');
  fs.writeFileSync(run.connection, JSON.stringify(descriptor), { mode: 0o600 });
  runs.set(new URL(services.webui.url).hostname, run);
  return run;
}
async function capture(value, run, language) {
  artifactRuns.set(value.outputRoot, run);
  return main({ argv: ['--connection', run.connection, '--language', language,
    '--checkpoint', 'networking/ip-address-list', '--output-root', value.outputRoot], sourceMetadata: source });
}
function published(value) {
  return ['tmp/capture-source.json', 'tmp/capture-results.json',
    'screenshots/cs/networking/ip-address-list.png', 'screenshots/en/networking/ip-address-list.png']
    .filter((relative) => fs.existsSync(path.join(value.outputRoot, relative)))
    .map((relative) => [relative, fs.readFileSync(path.join(value.outputRoot, relative))]);
}
function assertGone(filename) {
  assert.throws(() => process.kill(Number(fs.readFileSync(filename)), 0), { code: 'ESRCH' });
}

if (!['--publication-worker', '--competitor-worker'].includes(process.argv[2])) {
test('actual capture refuses missing IP inventory capability before cluster work or publication', async () => {
  const value = fixture();
  const run = runFixture(value, 'must-not-publish');
  try {
    const descriptor = JSON.parse(fs.readFileSync(run.connection));
    descriptor.capabilities = descriptor.capabilities.filter((name) => name !== 'ip-inventory');
    fs.writeFileSync(run.connection, JSON.stringify(descriptor));
    await assert.rejects(capture(value, run, 'en'), /capabilities/);
    assert.equal(run.fixtures, 0);
    assert.equal(run.browserOpened, 0);
    assert.equal(fs.existsSync(run.clusterPid), false);
    assert.equal(fs.existsSync(path.join(value.outputRoot, 'tmp/capture-results.json')), false);
    assert.equal(fs.existsSync(path.join(value.outputRoot, 'screenshots/en/networking/ip-address-list.png')), false);
    assertGone(run.artifactPid);
  } finally { value.clean(); }
});

test('artifact-controller loss cancels actual capture and prevents stale publication over a competing writer', { timeout: 10000 }, async () => {
  const value = fixture();
  let firstOutcome;
  let competing;
  const first = runFixture(value, 'stale-first-en');
  try {
    await capture(value, runFixture(value, 'successful-cs'), 'cs');
    first.scenario = async ({ cluster, page, session }) => {
      await session.shot(page, 'networking/ip-address-list', [], { clip });
      try { await cluster.ssh('services', ['stall']); }
      catch (error) {
        await bounded(first.browserGone.promise);
        assertGone(path.join(first.directory, 'ssh.pid'));
        assert.throws(() => cluster.account(), /no longer live/);
        assert.throws(() => cluster.route(cluster.apiUrl), /no longer live/);
        first.cancelled.resolve();
        await first.continueAfterCompetitor.promise;
        assert.throws(() => session.finish(), /no longer live/);
        assert.throws(() => session.artifacts.finish(session.results), /no longer live/);
        assert.throws(() => session.artifacts.stage(session.assets[0]), /no longer live/);
        throw error;
      }
      throw new Error('Lost artifact lease failed to cancel leased SSH');
    };
    firstOutcome = capture(value, first, 'en').then(() => null, (error) => error);
    await waitFile(path.join(first.directory, 'ssh.pid'));
    fs.writeFileSync(first.loseArtifact, 'close protocol');
    await bounded(first.cancelled.promise);
    assert.equal(first.browserClosed, true);
    assert.equal(fs.existsSync(first.clusterEof), false, 'cluster gate stays held until browser/SSH cleanup and unwind');
    const beforeCompetitor = published(value);
    const competitor = runFixture(value, 'successful-competitor-en');
    let competitorReady = false;
    competing = capture(value, competitor, 'en').then(() => { competitorReady = true; });
    await waitFile(competitor.artifactPid);
    await delay(100);
    assert.equal(competitorReady, false);
    assert.equal(competitor.artifactLease, undefined, 'competitor cannot read retained results before first writer cleanup');
    assert.deepEqual(published(value), beforeCompetitor);
    first.continueAfterCompetitor.resolve();
    assert.match((await firstOutcome).message, /no longer live/);
    await competing;
    const rows = JSON.parse(fs.readFileSync(path.join(value.outputRoot, 'tmp/capture-results.json')));
    assert.deepEqual(rows.map((row) => row.language).sort(), ['cs', 'en']);
    assert.equal(fs.readFileSync(path.join(value.outputRoot, 'screenshots/en/networking/ip-address-list.png'), 'utf8'), 'successful-competitor-en');
    assertGone(first.artifactPid); assertGone(first.clusterPid);
    assert.equal(fs.readFileSync(first.clusterEof, 'utf8'), 'EOF');
  } finally {
    first.continueAfterCompetitor.resolve();
    fs.writeFileSync(path.join(first.directory, 'fixture-cleanup'), 'stop owned fixture transport');
    if (first.artifactLease && !first.artifactLease.signal.aborted) fs.writeFileSync(first.loseArtifact, 'cleanup fixture');
    if (firstOutcome) await firstOutcome;
    if (competing) await competing.catch(() => {});
    value.clean();
  }
});

test('artifact loss cancels pending cluster acquisition before fixtures or browser work and reaps the controller', { timeout: 10000 }, async () => {
  const value = fixture();
  const pending = runFixture(value, 'must-not-publish', { pending: true });
  let outcome;
  try {
    outcome = capture(value, pending, 'cs').then(() => null, (error) => error);
    await waitFile(pending.clusterPid);
    fs.writeFileSync(pending.loseArtifact, 'close protocol');
    assert.match((await outcome).message, /enclosing lease/);
    assert.equal(pending.fixtures, 0); assert.equal(pending.browserOpened, 0);
    assert.equal(fs.existsSync(path.join(value.outputRoot, 'tmp/capture-results.json')), false);
    assertGone(pending.artifactPid); assertGone(pending.clusterPid);
    assert.equal(fs.readFileSync(pending.clusterEof, 'utf8'), 'EOF');
    await capture(value, runFixture(value, 'successful-next-cs'), 'cs');
    assert.equal(fs.readFileSync(path.join(value.outputRoot, 'screenshots/cs/networking/ip-address-list.png'), 'utf8'), 'successful-next-cs');
  } finally {
    if (pending.artifactLease && !pending.artifactLease.signal.aborted) fs.writeFileSync(pending.loseArtifact, 'cleanup fixture');
    if (outcome) await outcome;
    value.clean();
  }
});

test('sequential CS and EN orchestration preserves both rows despite diagnostic stderr EOF', { timeout: 10000 }, async () => {
  const value = fixture();
  try {
    for (const language of ['cs', 'en']) {
      const run = runFixture(value, `successful-${language}`, { stderrOnly: true });
      await capture(value, run, language);
      assert.equal(run.fixtures, 1); assert.equal(run.browserOpened, 1);
      assert.equal(run.browserClosed, true);
      assert.equal(run.artifactLease.signal.aborted, false);
      assert.equal(JSON.parse(fs.readFileSync(path.join(run.directory, 'ssh-lock-leaked'))), false);
      assert.equal(JSON.parse(fs.readFileSync(path.join(run.directory, 'cluster-lock-leaked'))), false);
      assertGone(run.artifactPid); assertGone(run.clusterPid);
    }
    const rows = JSON.parse(fs.readFileSync(path.join(value.outputRoot, 'tmp/capture-results.json')));
    assert.deepEqual(rows.map((row) => row.language).sort(), ['cs', 'en']);
    for (const row of rows) assert.equal(row.sha256, crypto.createHash('sha256').update(`successful-${row.language}`).digest('hex'));
  } finally { value.clean(); }
});

for (const artifactFailure of ['before', 'window']) {
  test(`artifact loss ${artifactFailure === 'before' ? 'before readiness' : 'in its readiness window'} closes the writer descriptor before next capture`, { timeout: 10000 }, async () => {
    const value = fixture();
    try {
      const failed = runFixture(value, 'must-not-publish', { artifactFailure, pending: true });
      await assert.rejects(capture(value, failed, 'cs'), /controller|lease|protocol/i);
      assert.equal(failed.fixtures, 0); assert.equal(failed.browserOpened, 0);
      assert.equal(fs.existsSync(path.join(value.outputRoot, 'tmp/capture-results.json')), false);
      assertGone(failed.artifactPid);
      await capture(value, runFixture(value, 'successful-next-cs'), 'cs');
    } finally { value.clean(); }
  });
}

test('helper death while actual PNG publication blocks the event loop cannot admit a competitor until final writer close', { timeout: 15000 }, async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-publication-block-'));
  const writer = spawn(process.execPath, [__filename, '--publication-worker', root], { stdio: ['ignore', 'pipe', 'pipe'] });
  let errorOutput = '';
  writer.stdout.resume(); writer.stderr.on('data', (bytes) => { errorOutput += bytes; });
  const writerExit = once(writer, 'close');
  let competitor;
  let competitorExit;
  let competitorError = '';
  try {
    await waitFile(path.join(root, 'publication-paused'));
    const receipt = JSON.parse(fs.readFileSync(path.join(root, 'publication-paused')));
    const stat = fs.readFileSync(`/proc/${receipt.helper_pid}/stat`, 'utf8');
    assert.equal(Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1]), writer.pid);
    // The writer cannot dispatch child exit/abort while synchronously blocked;
    // this still-unreaped helper PID remains its exact owned child here.
    process.kill(receipt.helper_pid, 'SIGKILL');
    competitor = spawn(process.execPath, [__filename, '--competitor-worker', root], { stdio: ['ignore', 'pipe', 'pipe'] });
    competitor.stdout.resume(); competitor.stderr.on('data', (bytes) => { competitorError += bytes; });
    competitorExit = once(competitor, 'close');
    await waitFile(path.join(root, 'competitor-artifact.pid'));
    await delay(100);
    assert.equal(fs.existsSync(path.join(root, 'competitor-acquired')), false, 'helper death cannot release writer authority during synchronous publication');
    fs.writeFileSync(path.join(root, 'release-publication'), 'resume owned writer');
    await waitFile(path.join(root, 'cleanup-entered'));
    await delay(100);
    assert.equal(fs.existsSync(path.join(root, 'competitor-acquired')), false, 'writer retains authority through cleanup');
    fs.writeFileSync(path.join(root, 'release-cleanup'), 'finish owned cleanup');
    const [writerCode] = await writerExit;
    assert.equal(writerCode, 1, errorOutput);
    assert.match(errorOutput, /controller cleanup failed/i);
    const [competitorCode] = await competitorExit;
    assert.equal(competitorCode, 0, competitorError);
    assert.equal(fs.existsSync(path.join(root, 'competitor-acquired')), true);
    const rows = JSON.parse(fs.readFileSync(path.join(root, 'output/tmp/capture-results.json')));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].sha256, crypto.createHash('sha256').update('successful-competitor-cs').digest('hex'));
    assert.equal(fs.readFileSync(path.join(root, 'output/screenshots/cs/networking/ip-address-list.png'), 'utf8'), 'successful-competitor-cs');
    assertGone(path.join(root, 'first-artifact.pid'));
  } finally {
    fs.writeFileSync(path.join(root, 'release-publication'), 'resume owned writer');
    fs.writeFileSync(path.join(root, 'release-cleanup'), 'finish owned cleanup');
    await writerExit;
    if (competitorExit) await competitorExit;
    fs.rmSync(root, { recursive: true });
  }
});
} else {
  const root = process.argv[3];
  const value = fixture(root);
  const competing = process.argv[2] === '--competitor-worker';
  const run = runFixture(value, competing ? 'successful-competitor-cs' : 'synchronous-first-cs');
  run.artifactPid = path.join(root, competing ? 'competitor-artifact.pid' : 'first-artifact.pid');
  if (competing) run.acquiredFile = path.join(root, 'competitor-acquired');
  if (!competing) {
    run.cleanupEntered = path.join(root, 'cleanup-entered');
    run.cleanupRelease = path.join(root, 'release-cleanup');
    const rename = fs.renameSync;
    fs.renameSync = function publicationBoundary(from, to) {
      if (to.endsWith('screenshots/cs/networking/ip-address-list.png')) {
        fs.writeFileSync(path.join(root, 'publication-paused'), JSON.stringify({
          helper_pid: Number(fs.readFileSync(run.artifactPid)), writer_pid: process.pid,
        }));
        const deadline = Date.now() + 10000;
        while (!fs.existsSync(path.join(root, 'release-publication'))) {
          if (Date.now() > deadline) throw new Error('Synchronous publication fixture release timed out');
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10);
        }
      }
      return rename(from, to);
    };
  }
  capture(value, run, 'cs').then(() => { process.exitCode = 0; }, (error) => {
    process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1;
  });
}
