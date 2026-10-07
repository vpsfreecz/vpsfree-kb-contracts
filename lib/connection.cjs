const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { isDeepStrictEqual } = require('util');

function privateFile(filename, limit = 65536) {
  const resolved = path.resolve(filename);
  let ancestor = resolved;
  while (ancestor !== path.dirname(ancestor)) {
    if (fs.existsSync(ancestor) && fs.lstatSync(ancestor).isSymbolicLink()) {
      throw new Error('Symlink in private connection path');
    }
    ancestor = path.dirname(ancestor);
  }
  const stat = fs.lstatSync(resolved);
  if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600 || stat.size > limit) {
    throw new Error('Connection references must be private owned regular files');
  }
  return fs.readFileSync(resolved);
}

function readConnection(filename, required = []) {
  const bytes = privateFile(filename, 2 * 1024 * 1024);
  let value;
  try { value = JSON.parse(bytes); } catch (_error) { throw new Error('Invalid connection JSON'); }
  if (value.schema !== 1 || value.kind !== 'vpsfree-kb-connection' ||
      !/^uid:\d+$/.test(value.owner_id) || value.owner_id !== `uid:${process.getuid()}` ||
      ![value.instance_id, value.run_id, value.artifact_id].every((id) => /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(id)) ||
      !/^[0-9a-f]{64}$/.test(value.artifact_sha256) ||
      !Array.isArray(value.capabilities) || !['capture-lease-v1', 'ssh', ...required].every((name) => value.capabilities.includes(name))) {
    throw new Error('Unsupported connection identity or fixture capabilities');
  }
  const base = path.dirname(path.resolve(filename));
  const reference = (name) => {
    if (typeof name !== 'string' || !name) throw new Error('Missing credential reference');
    const resolved = path.resolve(base, name);
    privateFile(resolved);
    return resolved;
  };
  value.accounts_file = reference(value.accounts_file);
  value.tls.ca_file = reference(value.tls.ca_file);
  for (const endpoint of Object.values(value.machines)) {
    if (typeof endpoint.host !== 'string' || !/^[a-zA-Z0-9.:_-]+$/.test(endpoint.host) ||
        !Number.isInteger(endpoint.port) || endpoint.port < 1 || endpoint.port > 65535 ||
        typeof endpoint.user !== 'string' || !/^[a-zA-Z0-9_-]+$/.test(endpoint.user)) {
      throw new Error('Invalid explicit SSH endpoint');
    }
    endpoint.private_key = reference(endpoint.private_key);
    endpoint.known_hosts = reference(endpoint.known_hosts);
  }
  for (const service of Object.values(value.services)) {
    const url = new URL(service.url);
    if (url.protocol !== 'https:' || url.username || url.password ||
        typeof service.connect_host !== 'string' || !/^[a-zA-Z0-9.:_-]+$/.test(service.connect_host) ||
        !Number.isInteger(service.connect_port) || service.connect_port < 1 || service.connect_port > 65535) {
      throw new Error('Invalid explicit service endpoint');
    }
  }
  if (!Array.isArray(value.control?.argv) || value.control.argv.length === 0 ||
      !value.control.argv.every((argument) => typeof argument === 'string' && argument && !argument.includes('\0')) ||
      !path.isAbsolute(value.control.argv[0])) {
    throw new Error('Connection requires an explicit local controller argument vector');
  }
  return { value, digest: crypto.createHash('sha256').update(bytes).digest('hex') };
}

async function openLease(argv, expected, { timeout = 120000, cleanupGrace = 500, signal, inheritedFd } = {}) {
  signal?.throwIfAborted();
  const child = spawn(argv[0], argv.slice(1), {
    stdio: ['pipe', 'pipe', 'pipe', ...(inheritedFd === undefined ? [] : [inheritedFd])],
  });
  const abort = new AbortController();
  let closing = false;
  let ready = false;
  let closed = false;
  let protocolLost = false;
  let cleanup;
  let rejectReadiness;
  const exited = new Promise((resolve) => {
    child.once('close', (code) => {
      closed = true;
      if (!closing) abort.abort(new Error('Capture controller lost; fixture activity is cancelled'));
      resolve(code);
    });
  });
  const waitExit = async () => {
    let timer;
    try {
      return await Promise.race([exited.then((code) => ({ code })), new Promise((resolve) => {
        timer = setTimeout(() => resolve(null), cleanupGrace);
      })]);
    } finally { clearTimeout(timer); }
  };
  const shutdown = () => {
    if (cleanup) return cleanup;
    cleanup = (async () => {
    closing = true;
    child.stdin.end();
    let result = await waitExit();
    for (const signal of ['SIGTERM', 'SIGKILL']) {
      if (result) return result.code;
      // Only this unreaped ChildProcess is supervised. No PID search, delayed
      // callback or process-group signaling can select an unrelated controller.
      if (!closed) child.kill(signal);
      result = await waitExit();
    }
    if (!result) throw new Error('Owned capture controller did not exit after cleanup');
    return result.code;
    })();
    return cleanup;
  };
  const loseProtocol = (message) => {
    if (closing || protocolLost) return;
    protocolLost = true;
    const error = new Error(message);
    abort.abort(error);
    rejectReadiness?.(error);
    // Start confined cleanup immediately even if the caller has not reached
    // its finally block yet. close() observes the same cleanup result.
    shutdown().catch(() => {});
  };
  child.stdin.on('error', () => {}); // Close/handshake determines the failure.
  child.stdout.on('end', () => loseProtocol('Capture controller protocol EOF; fixture activity is cancelled'));
  child.stdout.on('close', () => loseProtocol('Capture controller protocol closed; fixture activity is cancelled'));
  child.stdout.on('error', () => loseProtocol('Capture controller protocol failed; fixture activity is cancelled'));
  child.stderr.on('error', () => {}); // Diagnostic loss alone is not lease loss.
  child.stderr.resume();
  const cancelReadiness = () => loseProtocol(
    'Capture lease acquisition cancelled by its enclosing lease',
  );
  signal?.addEventListener('abort', cancelReadiness, { once: true });
  if (signal?.aborted) cancelReadiness();
  await new Promise((resolve, reject) => {
    let buffered = '';
    const timer = setTimeout(() => reject(new Error('Capture controller readiness timed out')), timeout);
    rejectReadiness = (error) => { clearTimeout(timer); reject(error); };
    if (signal?.aborted) { rejectReadiness(signal.reason); return; }
    const fail = () => { clearTimeout(timer); reject(new Error('Capture controller failed before readiness')); };
    child.once('error', fail);
    child.once('close', () => { if (!ready) fail(); });
    child.stdout.on('data', (chunk) => {
      if (ready) { loseProtocol('Unexpected controller output'); return; }
      buffered += chunk.toString('utf8');
      if (Buffer.byteLength(buffered) > 8192) { fail(); return; }
      const end = buffered.indexOf('\n');
      if (end < 0) return;
      try {
        const value = JSON.parse(buffered.slice(0, end));
        if (!isDeepStrictEqual(value, expected) || buffered.slice(end + 1)) {
          throw new Error('Capture lease readiness identity differs');
        }
        ready = true;
        clearTimeout(timer);
        resolve();
      } catch (_error) {
        clearTimeout(timer);
        reject(new Error('Capture lease readiness identity differs'));
      }
    });
  }).catch(async (error) => { await shutdown(); throw error; })
    .finally(() => signal?.removeEventListener('abort', cancelReadiness));
  rejectReadiness = null;
  return {
    signal: abort.signal,
    assertLive() {
      if (protocolLost || abort.signal.aborted || closed || child.exitCode !== null || child.signalCode !== null) {
        throw new Error('Capture lease is no longer live');
      }
    },
    async close() {
      const code = await shutdown();
      if (code !== 0) throw new Error('Capture controller cleanup failed');
    },
  };
}

class Connection {
  constructor(descriptor, lease) {
    this.descriptor = descriptor;
    this.lease = lease;
    try { this.accounts = JSON.parse(privateFile(descriptor.accounts_file)).users; }
    catch (_error) { throw new Error('Invalid fixture account file'); }
    if (!Array.isArray(this.accounts)) throw new Error('Invalid fixture accounts');
  }

  assertLease() { this.lease.assertLive(); }
  account(login = 'test-user1') {
    this.assertLease();
    const value = this.accounts.find((account) => account.login === login);
    if (!value) throw new Error('Required fixture account is absent');
    return value;
  }
  get webuiBaseUrl() { return this.descriptor.services.webui.url; }
  get apiUrl() { return this.descriptor.services.api.url; }
  get consoleBaseUrl() { return this.descriptor.services.console.url.replace(/\/$/, ''); }
  get caPath() { return this.descriptor.tls.ca_file; }

  route(url) {
    this.assertLease();
    const parsed = new URL(url);
    const service = Object.values(this.descriptor.services).find((item) => new URL(item.url).origin === parsed.origin);
    if (!service) throw new Error('Destination is outside the explicit capture connection');
    return { host: service.connect_host, port: service.connect_port };
  }

  async ssh(machine, command, { input = '', accepted = [0], timeout = 30000 } = {}) {
    this.assertLease();
    const endpoint = this.descriptor.machines[machine];
    if (!endpoint) throw new Error('Unknown leased SSH machine');
    const argv = ['-F', '/dev/null', '-i', endpoint.private_key, '-p', String(endpoint.port), '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
      '-o', 'StrictHostKeyChecking=yes', '-o', `UserKnownHostsFile=${endpoint.known_hosts}`,
      '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=5',
      `${endpoint.user}@${endpoint.host}`, command.map((argument) => `'${String(argument).replaceAll("'", "'\"'\"'")}'`).join(' ')];
    return new Promise((resolve, reject) => {
      const child = spawn('ssh', argv, { signal: this.lease.signal, stdio: ['pipe', 'pipe', 'pipe'] });
      let output = '';
      child.stdout.on('data', (chunk) => { output += chunk; });
      child.stderr.resume();
      child.stdin.end(input);
      const timer = setTimeout(() => child.kill('SIGTERM'), timeout);
      let transportError;
      child.once('error', (error) => { transportError = error; });
      child.once('close', (code) => {
        clearTimeout(timer);
        try {
          this.assertLease();
          if (transportError) throw new Error(`Leased SSH transport failed on ${machine}`);
          if (!accepted.includes(code)) throw new Error(`Leased SSH operation failed on ${machine}`);
          resolve(output);
        } catch (error) { reject(error); }
      });
    });
  }

  async verify(expected) {
    this.assertLease();
    const actual = this.descriptor.provenance;
    if (!isDeepStrictEqual(actual.source, expected)) throw new Error('Expected K source or input identity differs');
    if (typeof actual.artifact_json !== 'string' ||
        crypto.createHash('sha256').update(actual.artifact_json).digest('hex') !== this.descriptor.artifact_sha256) {
      throw new Error('Prepared artifact receipt digest differs');
    }
    const artifact = JSON.parse(actual.artifact_json);
    if (!isDeepStrictEqual(artifact, actual.artifact) || artifact.schema !== 1 ||
        artifact.instance_id !== this.descriptor.instance_id || artifact.artifact_id !== this.descriptor.artifact_id ||
        !isDeepStrictEqual(artifact.source, expected) || !isDeepStrictEqual(artifact.guest_identity, actual.guest_identity) ||
        artifact.config_sha256 !== actual.config_sha256 || !isDeepStrictEqual(artifact.machine_toplevels, actual.machine_toplevels)) {
      throw new Error('Prepared artifact provenance differs');
    }
    if (actual.guest_identity?.schema !== 1 || actual.guest_identity.instance_id !== this.descriptor.instance_id ||
        actual.guest_identity.artifact_id !== this.descriptor.artifact_id || 'run_id' in actual.guest_identity ||
        actual.guest_identity.config_input_sha256 !== artifact.config_input_sha256 ||
        !/^[0-9a-f]{64}$/.test(artifact.config_input_sha256) || !isDeepStrictEqual(actual.guest_identity.source, expected)) {
      throw new Error('Guest identity does not bind the prepared artifact');
    }
    for (const [machine, system] of Object.entries(actual.machine_toplevels)) {
      const identity = JSON.parse(await this.ssh(machine, ['cat', '/etc/vpsfree-kb-capture.json']));
      if (!isDeepStrictEqual(identity, actual.guest_identity)) throw new Error('Live guest source/fixture identity differs');
      if ((await this.ssh(machine, ['readlink', '-f', '/run/current-system'])).trim() !== system) {
        throw new Error('Live guest system closure differs');
      }
    }
    this.assertLease();
    return { instance_id: this.descriptor.instance_id, run_id: this.descriptor.run_id,
      artifact_id: this.descriptor.artifact_id, artifact_sha256: this.descriptor.artifact_sha256, source: expected,
      config_sha256: actual.config_sha256, machine_toplevels: actual.machine_toplevels };
  }
}

module.exports = { Connection, openLease, privateFile, readConnection };
