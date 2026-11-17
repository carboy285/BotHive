'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');
const { EventEmitter } = require('node:events');
const install = require('./cli-install.cjs');

test('only CLIs Bothive lists can be installed', () => {
  const ids = install.catalog().map(x => x.id);
  assert.ok(ids.includes('claude') && ids.includes('codex'));
  assert.ok(!ids.includes('ollama') && !ids.includes('lmstudio'), 'local model servers are not npm packages');
  for (const item of install.catalog()) assert.match(item.package, /^(@[a-z0-9-]+\/)?[a-z0-9._-]+$/);
});

test('an install runs npm with a prefix folder and reports success', async () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'cli-'));
  const seen = []; const done = [];
  const installer = new install.Installer({ base, run: async args => { seen.push(args); return { ok: true, output: '' }; }, onDone: async (id, ok) => { done.push([id, ok]); } });
  assert.equal(installer.start('claude').state, 'installing');
  assert.throws(() => installer.start('claude'), /already installing/);
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.deepEqual(seen, [{ prefix: path.join(base, 'cli'), pkg: '@anthropic-ai/claude-code' }]);
  assert.deepEqual(installer.status().claude, { state: 'done', message: 'Claude Code is installed.' });
  assert.deepEqual(done, [['claude', true]]);
  assert.throws(() => installer.start('rm -rf /'), /cannot be installed/);
  assert.throws(() => installer.start('ollama'), /cannot be installed/);
  fs.rmSync(base, { recursive: true, force: true });
});

test('a failed install keeps the end of npm’s message', async () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'cli-'));
  const installer = new install.Installer({ base, run: async () => ({ ok: false, output: 'npm ERR! network\nnpm ERR! offline' }) });
  installer.start('codex'); await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(installer.status().codex.state, 'failed'); assert.match(installer.status().codex.message, /offline/);
  installer.start('codex'); // a failed install can be tried again
  fs.rmSync(base, { recursive: true, force: true });
});

test('runNpm passes fixed arguments and reads the exit code and a missing npm', async () => {
  const calls = [];
  const fake = (command, args) => { calls.push([command, args]); const child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter(); child.kill = () => {}; setImmediate(() => { child.stderr.emit('data', 'oops'); child.emit('close', 1); }); return child; };
  const result = await install.runNpm({ prefix: '/data/cli', pkg: 'opencode-ai' }, { spawnImpl: fake });
  assert.equal(result.ok, false); assert.equal(result.output, 'oops');
  assert.deepEqual(calls[0][1], ['install', '-g', '--prefix', '/data/cli', '--no-audit', '--no-fund', '--loglevel=error', 'opencode-ai']);
  const missing = () => { const child = new EventEmitter(); child.stdout = new EventEmitter(); child.stderr = new EventEmitter(); setImmediate(() => child.emit('error', Object.assign(new Error('x'), { code: 'ENOENT' }))); return child; };
  assert.match((await install.runNpm({ prefix: '/x', pkg: 'y' }, { spawnImpl: missing })).output, /npm was not found/);
});
