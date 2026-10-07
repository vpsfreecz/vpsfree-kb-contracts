const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { test } = require('node:test');
const { Artifacts, artifactPath, atomicJson, contract, sha } = require('../lib/artifacts.cjs');
const { validationBundle } = require('../runner/validate-artifacts.cjs');

const source = { schema: 1, revision: 'a'.repeat(40), source: '/nix/store/source', lock_sha256: 'b'.repeat(64) };
const provenance = { instance_id: '00000000-0000-0000-0000-000000000001',
  run_id: '00000000-0000-0000-0000-000000000002', source, config_sha256: 'c'.repeat(64),
  artifact_id: '00000000-0000-0000-0000-000000000003', artifact_sha256: 'e'.repeat(64),
  machine_toplevels: { services: `/nix/store/${'0'.repeat(32)}-services` } };
function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'kb-artifacts-'));
  const sourceRoot = path.join(root, 'immutable');
  const outputRoot = path.join(root, 'output');
  fs.mkdirSync(sourceRoot); fs.mkdirSync(outputRoot);
  const manifest = { schema: 5, vpsadmin_commit: 'd'.repeat(40), assets: [{ id: 'networking/ip-address-list',
    checkpoint: 'networking/ip-address-list', scenario: 'networking', driver: 'webui', fixtures: ['base-vps'],
    variants: Object.fromEntries(['cs', 'en'].map((language) => [language, {
      output: `screenshots/${language}/networking/ip-address-list.png`, review_status: 'pending',
      sha256: sha('old'), dimensions: { width: 1, height: 1 }, capture: { driver: 'webui' },
    }])) }] };
  fs.writeFileSync(path.join(sourceRoot, 'captures.json'), JSON.stringify(manifest));
  for (const variant of Object.values(manifest.assets[0].variants)) {
    const target = artifactPath(sourceRoot, variant.output);
    fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, 'old');
  }
  fs.chmodSync(sourceRoot, 0o555);
  return { root, sourceRoot, outputRoot, manifest };
}
function capture(fixture, language, contents) {
  const artifacts = new Artifacts({ ...fixture, source });
  const asset = { ...fixture.manifest.assets[0], ...fixture.manifest.assets[0].variants[language], language };
  fs.writeFileSync(artifacts.stage(asset), contents);
  const row = { id: asset.id, checkpoint: asset.checkpoint, driver: asset.driver, language,
    output: asset.output, page: '/?page=networking', sha256: sha(contents), provenance };
  artifacts.finish([row]);
  return artifacts;
}
function clean(fixture) { fs.chmodSync(fixture.sourceRoot, 0o700); fs.rmSync(fixture.root, { recursive: true }); }

test('read-only source + writable output retain both languages and preserve the original receipt after metadata update', () => {
  const value = fixture();
  try {
    const before = fs.readFileSync(path.join(value.sourceRoot, 'captures.json'));
    capture(value, 'cs', 'new-cs');
    const en = capture(value, 'en', 'new-en');
    assert.equal(en.retained.length, 1);
    assert.deepEqual(JSON.parse(fs.readFileSync(en.resultsPath)).map((row) => row.language).sort(), ['cs', 'en']);
    const verified = validationBundle(value.sourceRoot, value.outputRoot, true, undefined, () => source);
    assert.equal(Object.keys(verified.files).length, 2);
    assert(Object.values(verified.files).every((filename) => filename.startsWith(value.outputRoot)));
    assert.throws(() => validationBundle(value.sourceRoot, value.outputRoot, true, undefined, () => ({ ...source, revision: 'f'.repeat(40) })), /Mixed/);
    const receipt = fs.readFileSync(en.receiptPath);
    const candidate = structuredClone(value.manifest);
    candidate.assets[0].variants.cs.sha256 = sha('new-cs');
    atomicJson(path.join(value.outputRoot, 'captures.json'), candidate);
    const next = new Artifacts({ ...value, source });
    assert.equal(next.retained.length, 2);
    assert.deepEqual(fs.readFileSync(en.receiptPath), receipt);
    assert.deepEqual(fs.readFileSync(path.join(value.sourceRoot, 'captures.json')), before);
    const replacement = capture(value, 'cs', 'newer-cs');
    assert.equal(JSON.parse(fs.readFileSync(replacement.resultsPath)).length, 2);
  } finally { clean(value); }
});

test('interrupted PNG publication, duplicate results and mixed source cannot certify output', () => {
  const value = fixture();
  try {
    const artifacts = capture(value, 'cs', 'cs');
    fs.writeFileSync(artifactPath(value.outputRoot, value.manifest.assets[0].variants.cs.output), 'partial');
    assert.throws(() => new Artifacts({ ...value, source }), /hash/);
    fs.writeFileSync(artifactPath(value.outputRoot, value.manifest.assets[0].variants.cs.output), 'cs');
    assert.throws(() => new Artifacts({ ...value, source: { ...source, revision: 'f'.repeat(40) } }), /Mixed/);
    const rows = JSON.parse(fs.readFileSync(artifacts.resultsPath));
    atomicJson(artifacts.resultsPath, [...rows, ...rows]);
    assert.throws(() => new Artifacts({ ...value, source }), /Duplicate/);
  } finally { clean(value); }
});

test('empty alternate output cannot bypass protected source assets; candidate immutable drift and paths fail', () => {
  const value = fixture();
  try {
    value.manifest.assets[0].variants.cs.review_status = 'reviewed';
    const artifacts = new Artifacts({ ...value, source });
    assert.throws(() => artifacts.stage({ ...value.manifest.assets[0], language: 'cs' }), /Protected/);
    const candidate = structuredClone(value.manifest);
    candidate.assets[0].scenario = 'elsewhere';
    atomicJson(path.join(value.outputRoot, 'captures.json'), candidate);
    assert.throws(() => new Artifacts({ ...value, source }), /contract/);
    assert.throws(() => artifactPath(value.outputRoot, '../elsewhere.png'));
    fs.symlinkSync(value.sourceRoot, path.join(value.outputRoot, 'screenshots'));
    assert.throws(() => artifactPath(value.outputRoot, 'screenshots/cs/networking/ip-address-list.png'), /Symlink/);
    assert.notDeepEqual(contract(candidate), contract(value.manifest));
  } finally { clean(value); }
});

test('strict full-inventory validation uses immutable PNG fallback for unchanged alternate output', () => {
  const value = fixture();
  try {
    const bundle = validationBundle(value.sourceRoot, value.outputRoot, false);
    assert.equal(Object.keys(bundle.files).length, 2);
    assert(Object.values(bundle.files).every((filename) => filename.startsWith(value.sourceRoot)));
    const candidate = structuredClone(value.manifest);
    candidate.assets[0].variants.cs.sha256 = sha('different');
    atomicJson(path.join(value.outputRoot, 'captures.json'), candidate);
    assert.throws(() => validationBundle(value.sourceRoot, value.outputRoot, false), /verified result/);
  } finally { clean(value); }
});

const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { setTimeout: delay } = require('node:timers/promises');
const { openLease } = require('../lib/connection.cjs');
const { openArtifactLock } = require('../lib/artifacts.cjs');
const lockHelper = path.resolve(__dirname, '../cluster/artifact-lock.rb');
const lockReady = { schema: 1, kind: 'kb-artifact-lock' };
async function waitFile(filename) {
  const deadline = Date.now() + 4000;
  while (!fs.existsSync(filename)) {
    if (Date.now() > deadline) throw new Error(`Owned lock fixture did not reach ${path.basename(filename)}`);
    await delay(10);
  }
}
function compete(root, started) {
  return openLease(['ruby', '-e', `
    File.write(${JSON.stringify(started)}, Process.pid.to_s)
    ARGV.replace([${JSON.stringify(root)}]); load ${JSON.stringify(lockHelper)}
  `], lockReady, { timeout: 8000 });
}

for (const abnormal of [false, true]) {
  test(`${abnormal ? 'abnormal' : 'normal'} artifact helper exit cannot unlock the writer descriptor or leak it to an unrelated child`, { timeout: 10000 }, async () => {
    const value = fixture();
    const pidFile = path.join(value.root, 'helper.pid');
    let fd = openArtifactLock(value.outputRoot);
    let helper;
    let contender;
    let pending;
    let peer;
    let peerExit;
    try {
      helper = await openLease(['ruby', '-e', `
        File.write(${JSON.stringify(pidFile)}, Process.pid.to_s)
        ARGV.replace([${JSON.stringify(value.outputRoot)}, '--inherited-fd', '3']); load ${JSON.stringify(lockHelper)}
      `], lockReady, { inheritedFd: fd, timeout: 4000 });
      if (abnormal) {
        const pid = Number(fs.readFileSync(pidFile));
        const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
        assert.equal(Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[1]), process.pid);
        process.kill(pid, 'SIGKILL');
        if (!helper.signal.aborted) await once(helper.signal, 'abort');
        await assert.rejects(helper.close(), /cleanup failed/);
      } else { await helper.close(); }
      const independentRoot = path.join(value.root, 'independent');
      fs.mkdirSync(independentRoot);
      const independentFd = openArtifactLock(independentRoot);
      try {
        const independent = await openLease(['ruby', lockHelper, independentRoot, '--inherited-fd', '3'], lockReady, { inheritedFd: independentFd, timeout: 4000 });
        await independent.close();
      } finally { fs.closeSync(independentFd); }
      const identity = fs.fstatSync(fd);
      peer = spawn(process.execPath, ['-e', `
        const fs = require('fs');
        const leaked = fs.readdirSync('/proc/self/fd').some((fd) => {
          try { const stat = fs.fstatSync(Number(fd)); return stat.dev === ${identity.dev} && stat.ino === ${identity.ino}; }
          catch (_) { return false; }
        });
        console.log(JSON.stringify({ leaked }));
        process.stdin.resume(); process.stdin.on('end', () => process.exit(0));
      `], { stdio: ['pipe', 'pipe', 'pipe'] });
      peer.stderr.resume(); peerExit = once(peer, 'close');
      const [bytes] = await once(peer.stdout, 'data');
      assert.equal(JSON.parse(bytes).leaked, false);
      let acquired = false;
      pending = compete(value.outputRoot, path.join(value.root, 'contender.pid')).then((lease) => { contender = lease; acquired = true; return lease; });
      await waitFile(path.join(value.root, 'contender.pid'));
      await delay(100);
      assert.equal(acquired, false, 'helper close/death must not LOCK_UN the shared description');
      fs.closeSync(fd); fd = undefined;
      await pending;
      contender.assertLive();
      assert.equal(peer.exitCode, null, 'unrelated child remains alive but cannot retain the lock');
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
      if (helper) { try { await helper.close(); } catch (_) { /* Expected abnormal child status. */ } }
      if (pending) await pending.catch(() => {});
      if (contender) await contender.close();
      if (peer) { peer.stdin.end(); await peerExit; }
      clean(value);
    }
  });
}

test('writer death and helper stdin EOF release the last description without foreign cleanup', { timeout: 10000 }, async () => {
  const value = fixture();
  const pidFile = path.join(value.root, 'orphan-helper.pid');
  const readyFile = path.join(value.root, 'writer-ready');
  const writer = spawn(process.execPath, ['-e', `
    const fs = require('fs');
    const { openArtifactLock } = require(${JSON.stringify(path.resolve(__dirname, '../lib/artifacts.cjs'))});
    const { openLease } = require(${JSON.stringify(path.resolve(__dirname, '../lib/connection.cjs'))});
    const fd = openArtifactLock(${JSON.stringify(value.outputRoot)});
    openLease(['ruby', '-e', ${JSON.stringify(`File.write(${JSON.stringify(pidFile)}, Process.pid.to_s)
      ARGV.replace([${JSON.stringify(value.outputRoot)}, '--inherited-fd', '3']); load ${JSON.stringify(lockHelper)}`)}],
      ${JSON.stringify(lockReady)}, { inheritedFd: fd }).then(() => {
        fs.writeFileSync(${JSON.stringify(readyFile)}, 'ready'); process.stdin.resume();
      }).catch((error) => { console.error(error); process.exitCode = 1; });
  `], { stdio: ['pipe', 'pipe', 'pipe'] });
  writer.stdout.resume(); writer.stderr.resume();
  const writerExit = once(writer, 'close');
  let contender;
  try {
    await waitFile(readyFile);
    writer.kill('SIGKILL');
    await writerExit;
    contender = await compete(value.outputRoot, path.join(value.root, 'contender.pid'));
    contender.assertLive();
    const pid = Number(fs.readFileSync(pidFile));
    let stat;
    try { stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (stat) assert.equal(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[0], 'Z', 'exited orphan may await init reaping');
  } finally {
    writer.stdin.end();
    if (writer.exitCode === null && writer.signalCode === null) writer.kill('SIGKILL');
    await writerExit;
    if (contender) await contender.close();
    clean(value);
  }
});

test('validator writing child retains exclusion after its artifact-lock wrapper dies', { timeout: 10000 }, async () => {
  const value = fixture();
  const readyFile = path.join(value.root, 'validator-ready');
  const releaseFile = path.join(value.root, 'validator-release');
  const wrapper = spawn('ruby', [lockHelper, value.outputRoot, '--exec', process.execPath, '-e', `
    const fs = require('fs');
    fs.writeFileSync(${JSON.stringify(readyFile)}, String(process.pid));
    setInterval(() => {
      if (fs.existsSync(${JSON.stringify(releaseFile)})) process.exit(0);
    }, 10);
  `], { stdio: ['ignore', 'pipe', 'pipe'] });
  wrapper.stdout.resume(); wrapper.stderr.resume();
  const wrapperClose = once(wrapper, 'close');
  const wrapperExit = once(wrapper, 'exit');
  let pending;
  let contender;
  try {
    await waitFile(readyFile);
    wrapper.kill('SIGKILL');
    await wrapperExit;
    let acquired = false;
    pending = compete(value.outputRoot, path.join(value.root, 'contender.pid')).then((lease) => { contender = lease; acquired = true; return lease; });
    await waitFile(path.join(value.root, 'contender.pid'));
    await delay(100);
    assert.equal(acquired, false, 'writing child retains validator wrapper same-description authority');
    fs.writeFileSync(releaseFile, 'finish owned validator writer');
    await wrapperClose;
    await pending;
    contender.assertLive();
  } finally {
    fs.writeFileSync(releaseFile, 'finish owned validator writer');
    if (wrapper.exitCode === null && wrapper.signalCode === null) wrapper.kill('SIGKILL');
    await wrapperClose;
    if (pending) await pending.catch(() => {});
    if (contender) await contender.close();
    clean(value);
  }
});

test('writer open rejects unsafe paths/modes and helper rejects inherited descriptor/path mismatch without truncation', async () => {
  const value = fixture();
  let fd;
  let otherFd;
  try {
    fs.chmodSync(value.outputRoot, 0o777);
    assert.throws(() => openArtifactLock(value.outputRoot), /safely owned/);
    assert.equal(fs.existsSync(path.join(value.outputRoot, 'tmp')), false);
    fs.chmodSync(value.outputRoot, 0o755);
    fs.mkdirSync(path.join(value.outputRoot, 'tmp'), { mode: 0o777 });
    fs.chmodSync(path.join(value.outputRoot, 'tmp'), 0o777);
    assert.throws(() => openArtifactLock(value.outputRoot), /safely owned/);
    fs.chmodSync(path.join(value.outputRoot, 'tmp'), 0o700);
    const lock = path.join(value.outputRoot, 'tmp/capture.lock');
    fs.writeFileSync(lock, 'retained lock bytes', { mode: 0o644 });
    assert.throws(() => openArtifactLock(value.outputRoot), /private owned/);
    fs.chmodSync(lock, 0o600);
    fd = openArtifactLock(value.outputRoot);
    assert.equal(fs.readFileSync(lock, 'utf8'), 'retained lock bytes');
    const alias = path.join(value.root, 'alias');
    fs.symlinkSync(value.outputRoot, alias);
    assert.throws(() => openArtifactLock(alias), /ancestor/);
    const other = path.join(value.root, 'other');
    fs.mkdirSync(other);
    otherFd = openArtifactLock(other);
    await assert.rejects(openLease(['ruby', lockHelper, other, '--inherited-fd', '3'], lockReady, { inheritedFd: fd, timeout: 4000 }));
    assert.equal(fs.readFileSync(lock, 'utf8'), 'retained lock bytes');
    fs.closeSync(fd); fd = undefined;
    fs.unlinkSync(lock);
    fs.symlinkSync(path.join(other, 'tmp/capture.lock'), lock);
    assert.throws(() => openArtifactLock(value.outputRoot), /private owned/);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    if (otherFd !== undefined) fs.closeSync(otherFd);
    clean(value);
  }
});
