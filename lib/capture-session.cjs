const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const { exact, normalizeDynamicValues, preparePage } = require('./webui.cjs');

function sanitizeUrl(raw) {
  const url = new URL(raw);
  if (url.protocol === 'about:') return 'about:blank';
  for (const name of ['code', 'dev', 'session', 'state', 't', 'token']) {
    url.searchParams.delete(name);
  }
  return `${url.pathname}${url.search}`;
}

async function contentBox(locator) {
  const target = locator.first();
  await target.waitFor({ state: 'visible' });
  await target.scrollIntoViewIfNeeded();
  const outer = await target.boundingBox();
  const inner = await target.evaluate((root) => {
    const rects = [];
    const add = (rect) => {
      if (rect && rect.width > 0 && rect.height > 0) {
        rects.push({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
      }
    };
    const visible = (element) => {
      const style = getComputedStyle(element);
      return style.display !== 'none' && style.visibility !== 'hidden' && style.opacity !== '0';
    };
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.nodeValue.trim() || !node.parentElement || !visible(node.parentElement)) continue;
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) add(rect);
    }
    if (root.matches('table, fieldset')) add(root.getBoundingClientRect());
    for (const element of root.querySelectorAll(
      'table, fieldset, input, select, textarea, button, img, canvas, svg, iframe, pre, code, video',
    )) {
      if (visible(element)) add(element.getBoundingClientRect());
    }
    if (rects.length === 0) add(root.getBoundingClientRect());
    const left = Math.min(...rects.map((rect) => rect.x));
    const right = Math.max(...rects.map((rect) => rect.x + rect.width));
    const rootRect = root.getBoundingClientRect();
    const preserveLineBox = root.matches('h1, h2, h3, h4, h5, h6');
    const top = preserveLineBox
      ? rootRect.y
      : Math.min(...rects.map((rect) => rect.y));
    const bottom = preserveLineBox
      ? rootRect.y + rootRect.height
      : Math.max(...rects.map((rect) => rect.y + rect.height));
    return {
      x: left,
      y: top,
      width: right - left,
      height: bottom - top,
      rootX: rootRect.x,
      rootY: rootRect.y,
    };
  });
  if (!outer) return null;
  return {
    x: outer.x + inner.x - inner.rootX,
    y: outer.y + inner.y - inner.rootY,
    width: inner.width,
    height: inner.height,
  };
}

async function unionBox(locators, padding = 8) {
  const boxes = [];
  for (const locator of locators) {
    const box = await contentBox(locator);
    if (box) boxes.push(box);
  }
  if (boxes.length === 0) throw new Error('Capture target has no bounding box');

  const left = Math.max(0, Math.min(...boxes.map((box) => box.x)) - padding);
  const top = Math.max(0, Math.min(...boxes.map((box) => box.y)) - padding);
  const right = Math.max(...boxes.map((box) => box.x + box.width)) + padding;
  const bottom = Math.max(...boxes.map((box) => box.y + box.height)) + padding;
  return { x: left, y: top, width: right - left, height: bottom - top };
}

class CaptureSession {
  constructor({ assets, checkpoint, language, repoRoot, scenario }) {
    this.language = language;
    this.assets = assets.filter((asset) => !asset.retired).flatMap((asset) => {
      const variant = asset.variants?.[language];
      return variant ? [{ ...asset, ...variant, language, variants: undefined }] : [];
    }).filter((asset) =>
      (!scenario || asset.scenario === scenario) &&
      (!checkpoint || `${asset.scenario}/${asset.checkpoint}` === checkpoint ||
        asset.checkpoint === checkpoint),
    );
    this.repoRoot = repoRoot;
    this.results = [];
    this.seen = new Set();
  }

  wants(checkpoint) {
    return this.assets.some((asset) => asset.checkpoint === checkpoint);
  }

  asset(checkpoint) {
    const matches = this.assets.filter((asset) => asset.checkpoint === checkpoint);
    if (matches.length !== 1) {
      throw new Error(`${checkpoint}: expected one inventory entry, found ${matches.length}`);
    }
    if (this.seen.has(checkpoint)) {
      throw new Error(`${checkpoint}: checkpoint was captured more than once`);
    }
    return matches[0];
  }

  async shot(page, checkpoint, locators, options = {}) {
    if (!this.wants(checkpoint)) return;
    const asset = this.asset(checkpoint);
    const output = path.join(this.repoRoot, asset.output);
    if (asset.review_status !== 'pending' && fs.existsSync(output)) {
      throw new Error(
        `${asset.id}: ${asset.review_status} capture cannot be overwritten`,
      );
    }
    await preparePage(page);
    await normalizeDynamicValues(page);
    const targets = Array.isArray(locators) ? locators : [locators];
    const clip = options.clip || await unionBox(targets, options.padding);
    fs.mkdirSync(path.dirname(output), { recursive: true });

    await page.screenshot({
      path: output,
      clip,
      mask: options.mask || [],
      maskColor: '#d8dee9',
    });

    const contents = fs.readFileSync(output);
    this.seen.add(checkpoint);
    this.results.push({
      id: asset.id,
      language: this.language,
      checkpoint,
      driver: asset.driver,
      output: asset.output,
      page: sanitizeUrl(page.url()),
      sha256: crypto.createHash('sha256').update(contents).digest('hex'),
    });
  }

  async locator(page, checkpoint, locator, options = {}) {
    await this.shot(page, checkpoint, locator, options);
  }

  async section(page, checkpoint, headingText, options = {}) {
    if (!this.wants(checkpoint)) return;
    const heading = page.locator('#content-in h2', { hasText: exact(headingText) }).first();
    const content = heading.locator('xpath=following-sibling::*[1]');
    await heading.evaluate((element) => element.scrollIntoView({ block: 'center' }));
    await this.shot(page, checkpoint, [heading, content], options);
  }

  async documentationSection(page, checkpoint, documentationId, options = {}) {
    if (!this.wants(checkpoint)) return;
    const heading = page.locator(
      `[data-vpsadmin-doc-id="${documentationId}"]`,
    ).first();
    const content = heading.locator('xpath=following-sibling::*[1]');
    await heading.evaluate((element) => element.scrollIntoView({ block: 'center' }));
    await this.shot(page, checkpoint, [heading, content], options);
  }

  async titleAndFirstTable(page, checkpoint, options = {}) {
    await this.shot(page, checkpoint, [
      page.locator('#content-in h1').first(),
      page.locator('#content-in table').first(),
    ], options);
  }

  async tableByText(page, checkpoint, text, options = {}) {
    await this.locator(
      page,
      checkpoint,
      page.locator('#content-in table', { hasText: text }).first(),
      options,
    );
  }

  finish() {
    const missing = this.assets
      .map((asset) => asset.checkpoint)
      .filter((checkpoint) => !this.seen.has(checkpoint));
    if (missing.length > 0) {
      throw new Error(`Missing checkpoints: ${missing.join(', ')}`);
    }
    const target = path.join(this.repoRoot, 'tmp/capture-results.json');
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, `${JSON.stringify(this.results, null, 2)}\n`);
    return this.results;
  }
}

module.exports = { CaptureSession, contentBox, sanitizeUrl, unionBox };
