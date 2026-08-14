const assert = require('assert');

const { CaptureSession } = require('../lib/capture-session.cjs');
const { fixturesFor, label } = require('../lib/i18n.cjs');
const { parseArgs } = require('../runner/args.cjs');

assert.strictEqual(label('cs', 'features'), 'Funkce');
assert.strictEqual(label('en', 'features'), 'Features');
assert.strictEqual(label('cs', 'sshHostKeys'), 'Hostitelské klíče SSH');
assert.strictEqual(label('en', 'sshHostKeys'), 'SSH host keys');
assert.strictEqual(label('en', 'startMenu'), 'Start Menu');
assert.strictEqual(fixturesFor('cs').publicKey, 'Dokumentační klíč');
assert.strictEqual(fixturesFor('en').publicKey, 'Documentation key');
assert.throws(() => label('de', 'features'), /Missing de translation/);
assert.throws(() => parseArgs(['--cluster', 'docs']), /--language is required/);
assert.strictEqual(
  parseArgs(['--cluster', 'docs', '--language', 'en']).language,
  'en',
);

const concept = {
  id: 'topic/view',
  topic: 'topic',
  scenario: 'scenario',
  checkpoint: 'topic/view',
  variants: {
    cs: { output: 'screenshots/cs/topic/view.png' },
    en: { output: 'screenshots/en/topic/view.png' },
  },
};
const session = new CaptureSession({
  assets: [concept],
  language: 'en',
  repoRoot: '/tmp',
});
assert.strictEqual(session.assets.length, 1);
assert.strictEqual(session.assets[0].language, 'en');
assert.strictEqual(session.assets[0].output, 'screenshots/en/topic/view.png');
assert.strictEqual(typeof session.documentationSection, 'function');
