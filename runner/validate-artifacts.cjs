const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { Artifacts, artifactPath, contract, readJsonFile, sha } = require('../lib/artifacts.cjs');
const { isDeepStrictEqual } = require('util');

function sourceMetadata(sourceRoot, receipt, metadataFile) {
  const arguments = [path.join(sourceRoot, 'cluster/source-metadata.rb'), '--validation', sourceRoot, receipt];
  if (metadataFile) arguments.push(metadataFile);
  return JSON.parse(execFileSync('ruby', arguments, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
}

function validationBundle(sourceRoot, outputRoot, update, metadataFile, verifySource = sourceMetadata) {
  const original = JSON.parse(fs.readFileSync(path.join(sourceRoot, 'captures.json')));
  const candidatePath = path.join(outputRoot, 'captures.json');
  const manifest = fs.existsSync(candidatePath) ? readJsonFile(candidatePath, false) : original;
  if (!isDeepStrictEqual(contract(manifest), contract(original))) throw new Error('Candidate immutable contract differs');
  const results = path.join(outputRoot, 'tmp/capture-results.json');
  const receipt = path.join(outputRoot, 'tmp/capture-source.json');
  let artifacts;
  if (fs.existsSync(results) || fs.existsSync(receipt) || update) {
    readJsonFile(receipt);
    const source = verifySource(sourceRoot, receipt, metadataFile);
    artifacts = new Artifacts({ sourceRoot, outputRoot, manifest: original, source, invocation: false });
  }
  const files = {};
  for (const asset of manifest.assets) {
    for (const [language, variant] of Object.entries(asset.variants)) {
      const supplied = artifactPath(outputRoot, variant.output);
      const sourceFile = artifactPath(sourceRoot, variant.output);
      const originalVariant = original.assets.find((row) => row.id === asset.id).variants[language];
      const row = artifacts?.retained.find((result) => result.language === language && result.id === asset.id);
      const changed = variant.sha256 !== originalVariant.sha256 || !isDeepStrictEqual(variant.dimensions, originalVariant.dimensions) ||
        !isDeepStrictEqual(variant.capture, originalVariant.capture);
      const suppliedChanged = fs.existsSync(supplied) && sha(fs.readFileSync(supplied)) !== originalVariant.sha256;
      if ((changed || suppliedChanged || row) && !row) throw new Error('Changed capture has no matching verified result');
      if (row) {
        if (originalVariant.review_status !== 'pending' || variant.review_status !== 'pending') throw new Error('Protected capture cannot be replaced');
        artifacts.validateResult(row, outputRoot);
      }
      files[variant.output] = fs.existsSync(supplied) ? supplied : sourceFile;
    }
  }
  return { manifest, files };
}

module.exports = { validationBundle };
if (require.main === module) {
  try {
    const [sourceRoot, outputRoot, mode, metadataFile] = process.argv.slice(2);
    process.stdout.write(JSON.stringify(validationBundle(sourceRoot, outputRoot, mode === 'update', metadataFile)));
  } catch (_error) { process.stderr.write('Artifact/source validation failed\n'); process.exitCode = 1; }
}
