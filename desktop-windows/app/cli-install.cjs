'use strict';
// Installs an AI CLI for Bothive from inside the app (10.1.1), so nobody has to open a terminal on the computer that runs it.
// CLIs go into a folder under the app's data (npm install -g --prefix), never into the system, and only the packages listed
// in local-cli.cjs can be installed. The folder is searched when Bothive looks for installed CLIs.
const path = require('node:path');
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const { providers } = require('./local-cli.cjs');

const TIMEOUT_MS = 10 * 60 * 1000;
const installable = () => providers.filter(x => !x.local && typeof x.package === 'string' && /^(@[a-z0-9-]+\/)?[a-z0-9._-]+$/.test(x.package));

/** The CLIs this app knows how to install: [{ id, name, package, guide }]. */
const catalog = () => installable().map(({ id, name, package: pkg, guide }) => ({ id, name, package: pkg, guide }));

/** The folder that holds the CLIs Bothive installed, and the bin folder inside it. */
const root = base => path.join(base, 'cli');
// With -g and a prefix, Windows puts the launchers in the prefix itself and other systems put them in prefix/bin.
const binDirectory = base => (process.platform === 'win32' ? root(base) : path.join(root(base), 'bin'));

function npmCommand() { return process.platform === 'win32' ? 'npm.cmd' : 'npm'; }

/** The real installer: npm install -g --prefix <folder> <package>. Resolves { ok, output }. Output is the tail of what npm printed. */
function runNpm({ prefix, pkg }, { spawnImpl = spawn, timeout = TIMEOUT_MS } = {}) {
  return new Promise(resolve => {
    let output = '';
    let child;
    try {
      child = spawnImpl(npmCommand(), ['install', '-g', '--prefix', prefix, '--no-audit', '--no-fund', '--loglevel=error', pkg], { shell: process.platform === 'win32', windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, npm_config_update_notifier: 'false' } });
    } catch (error) { resolve({ ok: false, output: error.message }); return; }
    const timer = setTimeout(() => { try { child.kill(); } catch { /* already gone */ } resolve({ ok: false, output: output.slice(-1500) + '\nTimed out after 10 minutes.' }); }, timeout);
    const take = chunk => { output = (output + chunk).slice(-4000); };
    child.stdout?.on('data', take); child.stderr?.on('data', take);
    child.on('error', error => { clearTimeout(timer); resolve({ ok: false, output: error.code === 'ENOENT' ? 'npm was not found. Install Node.js (nodejs.org) on this computer, then try again.' : error.message }); });
    child.on('close', code => { clearTimeout(timer); resolve({ ok: code === 0, output: output.slice(-1500) }); });
  });
}

/** Tracks installs so a screen can ask how one is going. */
class Installer {
  constructor({ base, run = runNpm, onDone = async () => {} }) { this.base = base; this.run = run; this.onDone = onDone; this.states = new Map(); }

  status() {
    return Object.fromEntries([...this.states].map(([id, value]) => [id, { state: value.state, message: value.message }]));
  }

  /** Starts an install and returns at once. Throws an Error for an unknown CLI or one already installing. */
  start(id) {
    const found = installable().find(x => x.id === id);
    if (!found) throw new Error('That CLI cannot be installed from here.');
    if (this.states.get(id)?.state === 'installing') throw new Error(`${found.name} is already installing.`);
    this.states.set(id, { state: 'installing', message: `Installing ${found.name}…` });
    fs.mkdirSync(root(this.base), { recursive: true });
    this.run({ prefix: root(this.base), pkg: found.package }).then(async result => {
      this.states.set(id, result.ok
        ? { state: 'done', message: `${found.name} is installed.` }
        : { state: 'failed', message: (result.output || 'The install failed.').trim().split('\n').slice(-4).join(' ').slice(0, 400) });
      try { await this.onDone(id, result.ok); } catch { /* the install result stands */ }
    });
    return this.states.get(id);
  }
}

module.exports = { catalog, root, binDirectory, Installer, runNpm, installable };
