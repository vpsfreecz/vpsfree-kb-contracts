const labels = {
  datasets: { cs: 'Datasety', en: 'Datasets' },
  deployPublicKey: {
    cs: 'Nahrát veřejný klíč do /root/.ssh/authorized_keys',
    en: 'Deploy public key to /root/.ssh/authorized_keys',
  },
  emailRoles: { cs: 'E-mailové role', en: 'E-mail roles' },
  features: { cs: 'Funkce', en: 'Features' },
  maintenanceWindows: { cs: 'Okna údržby', en: 'Maintenance windows' },
  mounts: { cs: 'Mounty', en: 'Mounts' },
  multifactorStatus: {
    cs: 'Dvoufaktorová autentizace',
    en: 'Two-factor authentication',
  },
  remoteConsoleForVps: {
    cs: 'Vzdálená konzole pro VPS',
    en: 'Remote Console for VPS',
  },
  reinstallSystem: { cs: 'Přeinstalovat systém', en: 'Reinstall system' },
  rescueMode: {
    cs: 'Spustit VPS ze šablony (nouzový režim)',
    en: 'Boot VPS from template (rescue mode)',
  },
  resources: { cs: 'Zdroje', en: 'Resources' },
  rootPassword: {
    cs: 'Nastavit heslo uživatele root (ve VPS, ne ve vpsAdminu)',
    en: "Set root's password (in the VPS, not in the vpsAdmin)",
  },
  sessionSettings: { cs: 'Nastavení relací', en: 'Session control' },
  sshConnection: { cs: 'SSH připojení', en: 'SSH connection' },
  sshHostKeys: { cs: 'Hostitelské klíče SSH', en: 'SSH host keys' },
  startMenu: { cs: 'Start menu', en: 'Start Menu' },
  transfersIn: { cs: 'Přenosy za', en: 'Transfers in' },
  uidGidMapping: { cs: 'UID/GID mapování', en: 'UID/GID mapping' },
};

const fixtureLabels = {
  cs: {
    publicKey: 'Dokumentační klíč',
    snapshot: 'Dokumentační snapshot',
    totpDevice: 'Dokumentační zařízení',
  },
  en: {
    publicKey: 'Documentation key',
    snapshot: 'Documentation snapshot',
    totpDevice: 'Documentation device',
  },
};

function label(language, name) {
  const translations = labels[name];
  if (!translations || !translations[language]) {
    throw new Error(`Missing ${language} translation for capture label ${name}`);
  }
  return translations[language];
}

function fixturesFor(language) {
  const result = fixtureLabels[language];
  if (!result) throw new Error(`Missing fixture labels for ${language}`);
  return result;
}

module.exports = { fixturesFor, label };
