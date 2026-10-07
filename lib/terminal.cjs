const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const { generateTrafficSamples } = require('../fixtures/prepare.cjs');

async function collect(child, timeout) {
  const chunks = [];
  child.stdout.on('data', (chunk) => chunks.push(chunk));
  child.stderr.on('data', (chunk) => chunks.push(chunk));
  let timedOut = false;
  const status = await new Promise((resolve, reject) => {
    let transportError;
    const timer = timeout && setTimeout(() => {
      timedOut = true;
      child.kill('SIGINT');
    }, timeout);
    child.on('error', (error) => { transportError = error; });
    child.on('close', (code, signal) => {
      if (timer) clearTimeout(timer);
      if (transportError) reject(new Error('CLI transport was interrupted'));
      else resolve({ code, signal });
    });
  });
  return { output: Buffer.concat(chunks).toString('utf8'), status, timedOut };
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function monitorAttempt(command, environment, signal) {
  const terminal = spawn('script', ['-q', '-f', '-c', command, '/dev/null'], {
    env: environment,
    signal,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return collect(terminal);
}

function terminalText(output) {
  return output
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, ' ')
    .replace(/\u001b[()][A-Z0-9]/g, ' ')
    .replace(/[\u0000-\u001f\u007f]/g, ' ');
}

function canonicalMonitorTranscript(output, vpsId, networkInterface) {
  const clean = output.replace(/\r?\nSession terminated[\s\S]*$/, '');
  const cursor = (row, column) => `\u001b[${row};${column}H`;
  const escapedInterface = networkInterface.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const rowMatch = clean.match(
    new RegExp(`\u001b\\[(\\d+);8H[\\s\\S]{0,80}?${vpsId} ${escapedInterface}`),
  );
  if (!rowMatch) throw new Error('Unable to locate the fixture VPS row in the ANSI monitor');
  const vpsRow = Number(rowMatch[1]);
  const overlay = [
    `${cursor(1, 26)}12:00:00`,
    `${cursor(1, 51)}12:00:10`,
    `${cursor(vpsRow, 25)}\u001b[1m  1.20 K\u001b[0m`,
    `${cursor(vpsRow, 40)}800.00     `,
    `${cursor(vpsRow, 51)}400.00     `,
    `${cursor(vpsRow, 63)}12.00        `,
    `${cursor(vpsRow, 76)}8.00          `,
    `${cursor(vpsRow, 90)}4.00      `,
    `${cursor(20, 18)}800.00      `,
    `${cursor(20, 30)}8.00      `,
    `${cursor(21, 18)}400.00      `,
    `${cursor(21, 30)}4.00      `,
    `${cursor(22, 18)}\u001b[1m  1.20 K\u001b[0m`,
    `${cursor(22, 30)}\u001b[1m12.00\u001b[0m`,
  ].join('');
  return `${clean}${overlay}`;
}

async function runTrafficMonitor({ cluster, fixtures, proxyUrl, sourceRoot, invocationRoot }) {
  const account = cluster.account();
  const home = path.join(invocationRoot, 'cli-home');
  fs.mkdirSync(home, { recursive: true });

  const environment = {
    ...process.env,
    COLUMNS: '100',
    HOME: home,
    HTTP_PROXY: proxyUrl,
    HTTPS_PROXY: proxyUrl,
    LINES: '22',
    NO_PROXY: '',
    RUBYOPT: `-r${path.join(sourceRoot, 'lib/rest-client-proxy.rb')}`,
    SSL_CERT_FILE: cluster.caPath,
    TERM: 'xterm-256color',
    http_proxy: proxyUrl,
    https_proxy: proxyUrl,
    no_proxy: '',
    VPSADMIN_CAPTURE_HTTP_PROXY: proxyUrl,
  };
  const authentication = spawn('vpsfreectl', [
    '-u', cluster.apiUrl,
    '-a', 'basic',
    '--user', account.login,
    '--password', account.password,
    '--save',
    'user', 'current',
  ], {
    env: environment,
    signal: cluster.lease.signal,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const authResult = await collect(authentication, 30_000);
  if (authResult.status.code !== 0 ||
      /Fatal API error|certificate verify failed/i.test(authResult.output)) {
    throw new Error('vpsfreectl authentication failed');
  }
  const config = path.join(home, '.haveapi-client.yml');
  if (fs.existsSync(config)) fs.chmodSync(config, 0o600);

  const command = `timeout --signal=INT --kill-after=2s 30s vpsfreectl -u '${cluster.apiUrl.replaceAll("'", "'\"'\"'")}' network top`;
  let lastOutput = '';
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    await generateTrafficSamples(cluster, fixtures.node, fixtures.vpsId);
    await delay(12_000);
    cluster.assertLease();
    const result = await monitorAttempt(command, environment, cluster.lease.signal);
    lastOutput = result.output;
    const text = terminalText(result.output);
    const row = new RegExp(
      `\\b${fixtures.vpsId}\\s+${fixtures.networkInterface}\\s+.*\\d`,
    );
    if (!/NaN/.test(text) && row.test(text)) {
      fs.writeFileSync(path.join(invocationRoot, 'traffic-monitor.raw'), result.output);
      return canonicalMonitorTranscript(
        result.output,
        fixtures.vpsId,
        fixtures.networkInterface,
      );
    }
  }

  fs.writeFileSync(path.join(invocationRoot, 'traffic-monitor.raw'), lastOutput);
  throw new Error(
    `vpsfreectl network top did not produce a finite ${fixtures.networkInterface} row ` +
      `for VPS #${fixtures.vpsId}`,
  );
}

async function renderTerminal(page, consoleBaseUrl, command, output) {
  await page.setContent(`<!doctype html>
    <html lang="cs"><head><meta charset="utf-8"><link rel="stylesheet" href="${consoleBaseUrl}/xterm.css"><style>
      html, body { margin: 0; background: #eef1f4; }
      #terminal {
        box-sizing: border-box;
        width: max-content;
        padding: 18px 22px;
        border: 1px solid #18212b;
        border-radius: 5px;
        background: #101820;
      }
    </style></head><body>
      <div id="terminal"></div>
    </body></html>`);
  await page.addScriptTag({ url: `${consoleBaseUrl}/xterm.js` });
  await page.evaluate(({ commandText, transcript }) => new Promise((resolve) => {
    const term = new window.Terminal({
      cols: 100,
      rows: 22,
      convertEol: true,
      cursorBlink: false,
      disableStdin: true,
      fontFamily: 'Liberation Mono, monospace',
      fontSize: 14,
      lineHeight: 1.2,
      theme: {
        background: '#101820',
        foreground: '#e7edf3',
        green: '#70c0a8',
      },
    });
    term.open(document.getElementById('terminal'));
    term.write(`\u001b[32mdocs@example.test:~$\u001b[0m ${commandText}\r\n${transcript}`, resolve);
  }), { commandText: command, transcript: output });
  await page.evaluate(() => document.fonts?.ready);
}

module.exports = { canonicalMonitorTranscript, renderTerminal, runTrafficMonitor };
