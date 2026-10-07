const fs = require('fs');
const path = require('path');
const { main } = require('./capture.cjs');
const sourceMetadata = JSON.parse(fs.readFileSync(process.argv[2]));
main({ argv: process.argv.slice(3), sourceMetadata, defaultOutputRoot: process.cwd(), defaultStateRoot: path.join(process.cwd(), '.devcluster/v2') }).catch(() => { process.stderr.write('Capture failed; no unverified result is accepted.\n'); process.exitCode = 1; });
