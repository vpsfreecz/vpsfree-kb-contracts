#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const { chromiumExecutable } = require('../lib/browser.cjs');

const repoRoot = path.resolve(__dirname, '..');
const { openLease } = require('../lib/connection.cjs');
const { validationBundle } = require('../runner/validate-artifacts.cjs');
const args = process.argv.slice(2);
const outputIndex = args.indexOf('--output-root');
const outputRoot = path.resolve(outputIndex < 0 ? repoRoot : args[outputIndex + 1]);
if (outputIndex >= 0) args.splice(outputIndex, 2);
if (args.length > 2) throw new Error('Usage: contact-sheet [GROUP] [cs|en] [--output-root DIR]');
const [group, language = 'cs'] = args;
if (!['cs', 'en'].includes(language)) throw new Error('Invalid contact-sheet language');
let bundle;
let assets;

async function main() {
  const lock = await openLease(['ruby', path.join(repoRoot, 'cluster/artifact-lock.rb'), outputRoot],
    { schema: 1, kind: 'kb-artifact-lock' });
  let browser;
  try {
    bundle = validationBundle(repoRoot, outputRoot, false);
    const manifest = bundle.manifest;
    assets = manifest.assets.flatMap((asset) => {
      const variant = asset.variants?.[language];
      return variant ? [{ ...asset, ...variant, language, variants: undefined }] : [];
    }).filter((asset) => !group || asset.topic === group || asset.scenario === group);
    if (assets.length === 0) throw new Error('No assets match the requested contact sheet');
    browser = await chromium.launch({
    executablePath: chromiumExecutable(),
    headless: true,
    args: ['--no-sandbox'],
  });
  const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
    const cards = assets.map((asset) => ({
      id: asset.id,
      image: `data:image/png;base64,${fs.readFileSync(bundle.files[asset.output]).toString('base64')}`,
    }));
    await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>
      body { margin: 20px; background: #dfe4ea; font: 15px sans-serif; }
      main { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }
      article { background: white; border: 1px solid #aab2bd; padding: 10px; }
      h2 { margin: 0 0 8px; font: 600 15px monospace; }
      img { display: block; width: 100%; height: 300px; object-fit: contain; object-position: top left; }
    </style></head><body><main id="cards"></main></body></html>`);
    await page.locator('#cards').evaluate((container, items) => {
      for (const item of items) {
        const card = document.createElement('article');
        const title = document.createElement('h2');
        title.textContent = item.id;
        const image = document.createElement('img');
        image.src = item.image;
        card.append(title, image);
        container.append(card);
      }
    }, cards);
    await page.waitForFunction(() => Array.from(document.images).every((image) => image.complete));
    await page.screenshot({
      path: path.join(outputRoot, 'tmp', `contact-sheet-${language}-${group || 'all'}.png`),
      fullPage: true,
    });
  } finally {
    try { if (browser) await browser.close(); } finally { await lock.close(); }
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});
