const fs = require('fs');
const path = require('path');

class DevCluster {
  constructor({ repoRoot, slug }) {
    this.repoRoot = repoRoot;
    this.slug = slug;
    this.configPath = path.join(
      repoRoot,
      '.devcluster/clusters',
      slug,
      'config.json',
    );
    this.config = JSON.parse(fs.readFileSync(this.configPath, 'utf8'));
    this.network = fs.readFileSync(
      path.join(path.dirname(this.configPath), 'network'),
      'utf8',
    ).trim();
  }

  account(login = 'test-user1') {
    const account = this.config.seed.users.find((user) => user.login === login);
    if (!account) {
      throw new Error(`Unable to find ${login} in ${this.configPath}`);
    }
    return account;
  }

  hostname(service) {
    const hostname = this.config.domains[service];
    if (!hostname) {
      throw new Error(`Unknown dev-cluster service: ${service}`);
    }
    return hostname;
  }

  get webuiBaseUrl() {
    const port = this.network === 'local' ? ':10443' : '';
    return `https://${this.hostname('webui')}${port}`;
  }

  get servicesIp() {
    return this.config.services.ip;
  }

  get apiUrl() {
    return `https://${this.hostname('api')}`;
  }

  get consoleBaseUrl() {
    return `https://${this.hostname('console')}`;
  }

  get caPath() {
    return path.join(
      this.repoRoot,
      '.devcluster/certs/default/vpsadmin-ca.crt',
    );
  }

  get commandPath() {
    return path.join(this.repoRoot, 'bin/devcluster');
  }

  sshArgs(machine, command) {
    return ['ssh', this.slug, machine, '--', ...command];
  }
}

module.exports = { DevCluster };
