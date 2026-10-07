#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const { prepareFixtures } = require('../fixtures/prepare.cjs');
const { launchBrowser, login } = require('../lib/browser.cjs');
const { CaptureSession } = require('../lib/capture-session.cjs');
const { Connection, readConnection, openLease } = require('../lib/connection.cjs');
const { Artifacts, openArtifactLock } = require('../lib/artifacts.cjs');
const { execFileSync } = require('child_process');
const { parseArgs, usage } = require('./args.cjs');

const repoRoot = path.resolve(__dirname, '..');

function pinnedVpsadminCommit() {
  const lock = JSON.parse(fs.readFileSync(path.join(repoRoot, 'flake.lock')));
  const input = lock.nodes.root.inputs.vpsadmin;
  const nodeName = Array.isArray(input) ? input.at(-1) : input;
  const revision = lock.nodes[nodeName]?.locked?.rev;
  if (!revision) throw new Error('flake.lock does not pin a vpsAdmin revision');
  return revision;
}

async function main({ argv = process.argv.slice(2), sourceMetadata, defaultOutputRoot = repoRoot, defaultStateRoot = path.join(repoRoot, '.devcluster/v2') } = {}) {
  const options = parseArgs(argv);
  if (options.help) { process.stdout.write(usage); return; }
  const outputRoot = path.resolve(options.outputRoot || defaultOutputRoot);
  process.stdout.write(`Source: ${repoRoot}\nOutput: ${outputRoot}\n`);
  const artifactFd = openArtifactLock(outputRoot);
  let artifactLease;
  let lease;
  let capture;
  const assertLive = () => {
    artifactLease.assertLive();
    if (lease) lease.assertLive();
  };
  try {
    artifactLease = await openLease(
      ['ruby', path.join(repoRoot, 'cluster/artifact-lock.rb'), outputRoot, '--inherited-fd', '3'],
      { schema: 1, kind: 'kb-artifact-lock' }, { inheritedFd: artifactFd });
    assertLive();
    const manifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'captures.json')));
    const expected = sourceMetadata || JSON.parse(execFileSync('ruby',
      [path.join(repoRoot, 'cluster/source-metadata.rb'), '--checkout', repoRoot], { encoding: 'utf8' }));
    if (manifest.vpsadmin_commit !== pinnedVpsadminCommit() || expected.inputs.vpsadmin.rev !== manifest.vpsadmin_commit) {
      throw new Error('Inventory, pinned input and immutable K source disagree');
    }
    const artifacts = new Artifacts({ sourceRoot: repoRoot, outputRoot, manifest, source: expected, assertLive });
    const session = new CaptureSession({ assets: manifest.assets, checkpoint: options.checkpoint,
      language: options.language, repoRoot, scenario: options.scenario, artifacts });
    if (session.assets.length === 0) throw new Error('No inventory entries match the request');
    const required = [...new Set(session.assets.flatMap((asset) => asset.fixtures))];
    let descriptor = options.connection;
    if (!descriptor) {
      descriptor = path.join(artifacts.invocationRoot, 'connection.json');
      const bytes = execFileSync('ruby', [path.join(repoRoot, 'cluster/launcher.rb'),
        '--state-root', path.resolve(options.stateRoot || defaultStateRoot), 'connection', options.cluster]);
      fs.writeFileSync(descriptor, bytes, { mode: 0o600, flag: 'wx' });
    }
    const { value, digest } = readConnection(descriptor, required);
    lease = await openLease([...value.control.argv, '--instance-id', value.instance_id,
      '--run-id', value.run_id, '--artifact-id', value.artifact_id, '--artifact-sha256', value.artifact_sha256,
      '--descriptor-sha256', digest],
      { schema: 1, instance_id: value.instance_id, run_id: value.run_id,
        artifact_id: value.artifact_id, artifact_sha256: value.artifact_sha256, descriptor_sha256: digest },
    { signal: artifactLease.signal });
    // Both locks must remain live. Keep the cluster controller until browser/SSH
    // cleanup completes; an artifact failure only cancels its pending handshake.
    const cluster = new Connection(value, {
      signal: AbortSignal.any([artifactLease.signal, lease.signal]),
      assertLive,
    });
    session.provenance = await cluster.verify(expected);
    capture = await launchBrowser(cluster, options.viewport, options.language);
    cluster.assertLease();
    const page = await capture.context.newPage();
    cluster.assertLease();
    await login(page, cluster, options.language);
    cluster.assertLease();
    const fixtures = await prepareFixtures({ cluster, page, language: options.language, required,
      repoRoot, invocationRoot: artifacts.invocationRoot });
    for (const scenario of [...new Set(session.assets.map((asset) => asset.scenario))]) {
      cluster.assertLease();
      process.stdout.write(`Capturing ${scenario}\n`);
      const driver = require(path.join(repoRoot, 'scenarios', `${scenario}.cjs`));
      await driver.run({ cluster, context: capture.context, fixtures, language: options.language,
        page, proxyUrl: capture.proxyUrl, repoRoot, sourceRoot: repoRoot,
        outputRoot, invocationRoot: artifacts.invocationRoot, session });
    }
    cluster.assertLease();
    const results = session.finish();
    cluster.assertLease();
    process.stdout.write(`Captured ${results.length} checkpoint(s)\n`);
  } finally {
    // Complete browser/SSH cleanup before EOF releases the capture gate.
    try { if (capture) await capture.close(); }
    finally {
      try { if (lease) await lease.close(); }
      finally {
        try { if (artifactLease) await artifactLease.close(); }
        finally {
          // Close only: LOCK_UN on either duplicate would release the shared
          // flock before this writer finishes publication and all cleanup.
          fs.closeSync(artifactFd);
        }
      }
    }
  }
}

module.exports = { main, pinnedVpsadminCommit };

if (require.main === module) main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
