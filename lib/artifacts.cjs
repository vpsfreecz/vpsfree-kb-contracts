const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { isDeepStrictEqual } = require('util');

const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}
function contract(manifest) {
  return canonical({ ...manifest, assets: manifest.assets.map((asset) => ({ ...asset,
    variants: Object.fromEntries(Object.entries(asset.variants).map(([language, variant]) => {
      const { dimensions, sha256, capture, ...immutable } = variant;
      return [language, immutable];
    })),
  })) });
}

function artifactPath(root, relative) {
  if (!/^screenshots\/(cs|en)\/[a-z0-9-]+\/[a-z0-9-]+\.png$/.test(relative) || path.posix.normalize(relative) !== relative) {
    throw new Error('Capture output is not a canonical screenshot path');
  }
  const absolute = path.join(root, relative);
  let cursor = absolute;
  while (cursor !== path.dirname(root)) {
    if (fs.lstatSync(cursor, { throwIfNoEntry: false })?.isSymbolicLink()) throw new Error('Symlink in artifact output');
    if (cursor === root) break;
    cursor = path.dirname(cursor);
  }
  return absolute;
}

function openArtifactLock(root) {
  root = path.resolve(root);
  if (root === '/nix/store' || root.startsWith('/nix/store/')) throw new Error('Artifact root must not be in the Nix store');
  for (let ancestor = root; ; ancestor = path.dirname(ancestor)) {
    const stat = fs.lstatSync(ancestor, { throwIfNoEntry: false });
    if (stat && (!stat.isDirectory() || stat.isSymbolicLink())) throw new Error('Unsafe artifact root ancestor');
    if (ancestor === path.dirname(ancestor)) break;
  }
  const safeDirectory = (directory) => {
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o022)) {
      throw new Error('Artifact directory is not safely owned');
    }
    fs.accessSync(directory, fs.constants.W_OK);
  };
  safeDirectory(root);
  const temporary = path.join(root, 'tmp');
  try { fs.mkdirSync(temporary, { mode: 0o700 }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  safeDirectory(temporary);
  const filename = path.join(temporary, 'capture.lock');
  const safeFile = (stat) => {
    if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600) {
      throw new Error('Artifact lock is not a private owned regular file');
    }
  };
  let fd;
  try {
    try { fd = fs.openSync(filename, fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      safeFile(fs.lstatSync(filename));
      fd = fs.openSync(filename, fs.constants.O_RDWR | fs.constants.O_NOFOLLOW);
    }
    const opened = fs.fstatSync(fd);
    const named = fs.lstatSync(filename);
    safeFile(opened); safeFile(named);
    if (opened.dev !== named.dev || opened.ino !== named.ino) throw new Error('Artifact lock changed while opening');
    return fd;
  } catch (error) {
    if (fd !== undefined) fs.closeSync(fd);
    throw error;
  }
}

function atomicJson(filename, value) {
  const temporary = `${filename}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
  const fd = fs.openSync(temporary, 'r');
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, filename);
}

function readJsonFile(filename, privateMode = true) {
  const stat = fs.lstatSync(filename);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid() ||
      (privateMode && (stat.mode & 0o777) !== 0o600) || stat.size > 2 * 1024 * 1024) {
    throw new Error('Unsafe capture metadata file');
  }
  try { return JSON.parse(fs.readFileSync(filename)); }
  catch (_error) { throw new Error('Invalid capture metadata JSON'); }
}

function validProvenance(value, source) {
  const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
  return value && uuid.test(value.instance_id) && uuid.test(value.run_id) && uuid.test(value.artifact_id) &&
    /^[0-9a-f]{64}$/.test(value.artifact_sha256) &&
    /^[0-9a-f]{64}$/.test(value.config_sha256) &&
    value.machine_toplevels && Object.keys(value.machine_toplevels).length > 0 &&
    Object.values(value.machine_toplevels).every((system) => /^\/nix\/store\/[a-z0-9]{32}-[^/]+$/.test(system)) &&
    isDeepStrictEqual(value.source, source);
}

class Artifacts {
  constructor({ sourceRoot, outputRoot, manifest, source, invocation = true, assertLive = () => {} }) {
    this.assertLive = assertLive;
    this.assertLive();
    this.sourceRoot = sourceRoot;
    this.outputRoot = path.resolve(outputRoot);
    if (this.outputRoot.startsWith('/nix/store/') || !fs.existsSync(this.outputRoot)) throw new Error('Output root must be an existing writable directory outside the store');
    const stat = fs.lstatSync(this.outputRoot);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Output root is not an owned directory');
    fs.accessSync(this.outputRoot, fs.constants.W_OK);
    this.manifest = manifest;
    this.source = source;
    this.receipt = { schema: 1, source, inventory_sha256: sha(fs.readFileSync(path.join(sourceRoot, 'captures.json'))),
      contract_sha256: sha(JSON.stringify(contract(manifest))), vpsadmin_revision: manifest.vpsadmin_commit };
    this.temporaryRoot = path.join(this.outputRoot, 'tmp');
    fs.mkdirSync(this.temporaryRoot, { mode: 0o700, recursive: true });
    if (fs.lstatSync(this.temporaryRoot).isSymbolicLink()) throw new Error('Unsafe artifact temporary root');
    if (invocation) {
      this.invocationRoot = fs.mkdtempSync(path.join(this.temporaryRoot, 'capture-'));
      fs.chmodSync(this.invocationRoot, 0o700);
    }
    this.resultsPath = path.join(this.temporaryRoot, 'capture-results.json');
    this.receiptPath = path.join(this.temporaryRoot, 'capture-source.json');
    this.retained = this.readRetained();
    const candidate = path.join(this.outputRoot, 'captures.json');
    this.candidate = fs.existsSync(candidate) ? readJsonFile(candidate, false) : manifest;
    if (!isDeepStrictEqual(contract(this.candidate), contract(manifest))) throw new Error('Candidate immutable capture contract differs');
  }

  readRetained() {
    const present = [this.receiptPath, this.resultsPath].map((filename) => fs.existsSync(filename));
    if (!present.some(Boolean)) return [];
    if (!present.every(Boolean)) throw new Error('Incomplete retained capture results/source receipt');
    const receipt = readJsonFile(this.receiptPath);
    // A candidate metadata update must not rebind the original inventory receipt.
    const { inventory_sha256, ...oldContract } = receipt;
    const { inventory_sha256: _current, ...newContract } = this.receipt;
    if (!isDeepStrictEqual(oldContract, newContract)) throw new Error('Mixed/stale capture source receipt');
    if (this.sourceRoot !== this.outputRoot && receipt.inventory_sha256 !== this.receipt.inventory_sha256) throw new Error('Original inventory identity differs');
    this.receipt = receipt;
    const rows = readJsonFile(this.resultsPath);
    if (!Array.isArray(rows) || new Set(rows.map((row) => `${row.language}:${row.id}`)).size !== rows.length) throw new Error('Duplicate/unsupported retained capture results');
    for (const row of rows) this.validateResult(row, this.outputRoot);
    return rows;
  }

  validateResult(row, root) {
    const asset = this.manifest.assets.find((item) => item.id === row.id);
    const variant = asset?.variants?.[row.language];
    if (!variant || row.output !== variant.output || row.checkpoint !== asset.checkpoint || row.driver !== asset.driver ||
        !validProvenance(row.provenance, this.source) ||
        sha(fs.readFileSync(artifactPath(root, row.output))) !== row.sha256) throw new Error('Capture result identity/provenance/hash differs');
  }

  stage(asset) {
    this.assertLive();
    const source = this.manifest.assets.find((row) => row.id === asset.id)?.variants[asset.language];
    const candidate = this.candidate.assets.find((row) => row.id === asset.id)?.variants[asset.language];
    if (!source || source.review_status !== 'pending' || candidate?.review_status !== 'pending') throw new Error('Protected capture cannot be overwritten');
    const filename = artifactPath(this.invocationRoot, asset.output);
    fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
    return filename;
  }

  finish(results) {
    this.assertLive();
    if (new Set(results.map((row) => `${row.language}:${row.id}`)).size !== results.length) throw new Error('Duplicate capture publication');
    for (const row of results) this.validateResult(row, this.invocationRoot);
    const replacing = new Set(results.map((row) => `${row.language}:${row.id}`));
    const merged = [...this.retained.filter((row) => !replacing.has(`${row.language}:${row.id}`)), ...results];
    for (const row of results) {
      const filename = artifactPath(this.outputRoot, row.output);
      fs.mkdirSync(path.dirname(filename), { recursive: true });
      this.assertLive();
      fs.renameSync(artifactPath(this.invocationRoot, row.output), filename);
    }
    // Interruption after bitmap publication leaves a stale hash and cannot certify it.
    this.assertLive();
    atomicJson(this.receiptPath, this.receipt);
    this.assertLive();
    atomicJson(this.resultsPath, merged);
    return results;
  }
}

module.exports = { readJsonFile, validProvenance, Artifacts, artifactPath, openArtifactLock, atomicJson, canonical, contract, sha };
