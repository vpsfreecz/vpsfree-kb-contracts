#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const { prepareFixtures } = require('../fixtures/prepare.cjs');
const { launchBrowser, login } = require('../lib/browser.cjs');
const { CaptureSession } = require('../lib/capture-session.cjs');
const { DevCluster } = require('../lib/dev-cluster.cjs');
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

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(usage);
    return;
  }

  const manifest = JSON.parse(fs.readFileSync(path.join(repoRoot, 'captures.json')));
  const session = new CaptureSession({
    assets: manifest.assets,
    checkpoint: options.checkpoint,
    language: options.language,
    repoRoot,
    scenario: options.scenario,
  });
  if (session.assets.length === 0) throw new Error('No inventory entries match the request');

  const actualCommit = pinnedVpsadminCommit();
  if (manifest.vpsadmin_commit !== actualCommit) {
    throw new Error(
      `Inventory expects vpsAdmin ${manifest.vpsadmin_commit}, found ${actualCommit}`,
    );
  }

  const cluster = new DevCluster({ repoRoot, slug: options.cluster });
  const capture = await launchBrowser(cluster, options.viewport, options.language);
  const page = await capture.context.newPage();
  try {
    await login(page, cluster, options.language);
    const required = [...new Set(session.assets.flatMap((asset) => asset.fixtures))];
    const fixtures = required.length === 0
      ? {}
      : await prepareFixtures({
        cluster,
        page,
        language: options.language,
        required,
        repoRoot,
      });
    const scenarios = [...new Set(session.assets.map((asset) => asset.scenario))];
    for (const scenario of scenarios) {
      process.stdout.write(`Capturing ${scenario}\n`);
      const driver = require(path.join(repoRoot, 'scenarios', `${scenario}.cjs`));
      await driver.run({
        cluster,
        context: capture.context,
        fixtures,
        language: options.language,
        page,
        proxyUrl: capture.proxyUrl,
        repoRoot,
        session,
      });
    }
    const results = session.finish();
    process.stdout.write(`Captured ${results.length} checkpoint(s)\n`);
  } finally {
    await capture.close();
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
