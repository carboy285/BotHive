'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { mkdtemp, readFile, rm, access } = require('node:fs/promises');
const { createHash } = require('node:crypto');
const os = require('node:os');
const path = require('node:path');
const { check, download, trustedDownload, newer } = require('./updates.cjs');

const base = 'https://github.com/carboy285/opengrokbot/releases/';
const release = (tag, assets = []) => ({ tag_name: tag, draft: false, prerelease: true, html_url: base + 'tag/' + tag, assets });

test('check reports the newest release and its Windows installer', async () => {
  const exe = { name: 'OpenGrokBot-0.7.6-Windows-x64-Setup.exe', browser_download_url: base + 'download/v0.7.6/OpenGrokBot-0.7.6-Windows-x64-Setup.exe', size: 3, digest: 'sha256:abc' };
  const evil = { name: 'x-Windows-x64-Setup.exe', browser_download_url: 'https://evil.example/x.exe' };
  const result = await check('0.7.5', async () => new Response(JSON.stringify([release('v0.7.5'), release('v0.7.6', [evil, exe])])));
  assert.equal(result.available, true);
  assert.equal(result.version, 'v0.7.6');
  assert.deepEqual(result.installer, { url: exe.browser_download_url, size: 3, digest: 'sha256:abc' });
  const none = await check('0.7.6', async () => new Response(JSON.stringify([release('v0.7.6', [evil])])));
  assert.equal(none.available, false);
  assert.equal(none.installer, null);
});

test('only official release downloads are trusted', () => {
  assert.equal(trustedDownload(base + 'download/v1/a.exe'), true);
  assert.equal(trustedDownload(base + 'download/v1/a.dmg'), false);
  assert.equal(trustedDownload('https://github.com/other/repo/releases/download/v1/a.exe'), false);
  assert.equal(trustedDownload('not a url'), false);
});

test('download verifies size and sha256 and removes bad files', async () => {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'grok-upd-'));
  try {
    const bytes = Buffer.from('MZ!');
    const digest = 'sha256:' + createHash('sha256').update(bytes).digest('hex');
    const url = base + 'download/v0.7.6/Setup.exe';
    const ok = path.join(dir, 'ok.exe');
    await download({ url, size: 3, digest }, ok, async () => new Response(bytes));
    assert.deepEqual(await readFile(ok), bytes);
    const bad = path.join(dir, 'bad.exe');
    await assert.rejects(download({ url, size: 3, digest: 'sha256:00' }, bad, async () => new Response(bytes)), /integrity/);
    await assert.rejects(access(bad));
    await assert.rejects(download({ url, size: 9, digest: null }, bad, async () => new Response(bytes)), /incomplete/);
    await assert.rejects(download({ url: 'https://evil.example/a.exe' }, bad, async () => new Response(bytes)), /official/);
    await assert.rejects(download({ url }, bad, async () => new Response('', { status: 404 })), /could not be downloaded/);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('installCommand builds a silent install-then-relaunch command and refuses risky paths', () => {
  const { installCommand } = require('./updates.cjs');
  const command = installCommand('C:\\Users\\Me\\AppData\\Local\\Temp\\OpenGrokBot-v0.7.7-Setup.exe', 'C:\\Users\\Me\\AppData\\Local\\Programs\\OpenGrokBot\\OpenGrokBot.exe');
  assert.equal(command.file, 'cmd.exe');
  assert.deepEqual(command.args.slice(0, 3), ['/d', '/s', '/c']);
  assert.match(command.args[3], /\/S && start "" "C:\\Users\\Me\\AppData\\Local\\Programs\\OpenGrokBot\\OpenGrokBot\.exe"/);
  assert.equal(installCommand('C:\\Temp\\a&calc.exe', 'C:\\x\\y.exe'), null);
  assert.equal(installCommand('C:\\Temp\\ok.exe', 'C:\\x\\100%.exe'), null);
  assert.equal(installCommand('relative.exe', 'C:\\x\\y.exe'), null);
  assert.equal(installCommand(undefined, 'C:\\x\\y.exe'), null);
});

test('four-part versions such as 0.7.9.1 compare correctly with three-part ones', async () => {
  assert.ok(newer('v0.8.0', '0.7.9.1'), 'An installed 0.7.9.1 must see 0.8.0');
  assert.ok(newer('v0.7.9.2', '0.7.9.1'));
  assert.ok(newer('v0.7.9.1', '0.7.9'));
  assert.ok(!newer('v0.7.9', '0.7.9.1'));
  assert.ok(!newer('v0.7.9.1', '0.7.9.1'));
  assert.ok(!newer('v0.8.0', '0.8.0'));
  assert.ok(newer('v0.8.0', '0.7.9-1'));
  assert.ok(!newer('garbage', '0.7.9.1') && !newer('v0.8.0', 'garbage') && !newer('v0.8.0.1.2', '0.8.0'));
  const result = await check('0.7.9.1', async () => new Response(JSON.stringify([release('v0.7.9.1'), release('v0.8.0')])));
  assert.equal(result.available, true);
  assert.equal(result.version, 'v0.8.0');
});

test('10.0: updates work before and after the repository is renamed to bothive', async () => {
  const oldBase = 'https://github.com/carboy285/opengrokbot/releases/', newBase = 'https://github.com/carboy285/bothive/releases/';
  const asked = [];
  const exe = base => ({ name: 'Bothive-10.0.0-Windows-x64-Setup.exe', browser_download_url: base + 'download/v10.0.0/Bothive-10.0.0-Windows-x64-Setup.exe', size: 3, digest: 'sha256:abc' });
  const rel = base => ({ tag_name: 'v10.0.0', draft: false, prerelease: false, html_url: base + 'tag/v10.0.0', assets: [exe(base)] });
  // Before the rename: the new name isn't found, so the old one answers.
  const before = await check('0.9.9', async url => { asked.push(url); return url.includes('/bothive/') ? new Response('[]', { status: 404 }) : new Response(JSON.stringify([rel(oldBase)])); });
  assert.deepEqual(asked.map(url => url.includes('/bothive/') ? 'new' : 'old'), ['new', 'old']);
  assert.equal(before.available, true); assert.equal(before.installer.url, exe(oldBase).browser_download_url);
  // After the rename: the new name answers straight away, and its downloads are trusted.
  const after = await check('0.9.9', async url => url.includes('/bothive/') ? new Response(JSON.stringify([rel(newBase)])) : new Response('[]', { status: 404 }));
  assert.equal(after.available, true); assert.equal(after.installer.url, exe(newBase).browser_download_url);
  assert.equal(trustedDownload(newBase + 'download/v10.0.0/a.exe'), true);
  assert.equal(trustedDownload('https://github.com/carboy285/bothive-fake/releases/download/v1/a.exe'), false);
  assert.equal(trustedDownload('https://github.com/someone/bothive/releases/download/v1/a.exe'), false);
});

test('10.0: the repository name is matched without regard to case (it is shown as BotHive)', async () => {
  const shown = 'https://github.com/carboy285/BotHive/releases/';
  const exe = { name: 'Bothive-10.0.0-Windows-x64-Setup.exe', browser_download_url: shown + 'download/v10.0.0/Bothive-10.0.0-Windows-x64-Setup.exe', size: 3, digest: 'sha256:abc' };
  const result = await check('0.9.9', async () => new Response(JSON.stringify([{ tag_name: 'v10.0.0', draft: false, prerelease: false, html_url: shown + 'tag/v10.0.0', assets: [exe] }])));
  assert.equal(result.available, true);
  assert.equal(result.installer.url, exe.browser_download_url);
  assert.equal(trustedDownload('https://github.com/carboy285/BOTHIVE-evil/releases/download/v1/a.exe'), false);
});
