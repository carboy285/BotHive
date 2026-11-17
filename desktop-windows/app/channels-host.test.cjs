'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createChannelsHost } = require('./channels-host.cjs');

function fixture({ env = {}, platform = 'linux', saved = {}, stall = false, fail = false } = {}) {
  const files = { ...saved }; const started = []; const servers = [];
  const state = { bots: [{ id: 'hive', name: 'Hive', isMain: true }, { id: 'travel', name: 'Travel' }, { id: 'grp', name: 'Team', memberIDs: ['hive', 'travel'] }], entries: [] };
  let running = new Set();
  const host = createChannelsHost({
    loadJSON: async (name, fallback) => (name in files ? JSON.parse(JSON.stringify(files[name])) : fallback),
    atomicJSON: async (name, value) => { files[name] = JSON.parse(JSON.stringify(value)); },
    safeStorage: { isEncryptionAvailable: () => platform === 'win32', encryptString: s => Buffer.from('enc:' + s), decryptString: b => b.toString().slice(4) },
    platform, ensureState: async () => {}, getState: () => state,
    startChat: async (id, text) => { started.push([id, text]); running.add(id); state.entries.push({ botID: id, kind: 'user', text }); if (!stall) setTimeout(() => { state.entries.push({ botID: id, kind: 'bot', text: fail ? 'it broke' : 'reply to ' + text, state: fail ? 'failed' : 'complete' }); running.delete(id); }, 5); },
    isRunning: id => running.has(id), env, sleep: ms => new Promise(r => setTimeout(r, Math.min(ms, 2))),
    createServer: () => { const server = { closed: false, listen(port, host) { server.at = [port, host]; }, close() { server.closed = true; }, on() {} }; servers.push(server); return server; },
    fetchImpl: async () => ({ ok: true, status: 200, json: async () => ({}) }), askTimeout: 200,
  });
  return { host, files, started, servers, state, running };
}

test('a message is sent to the chosen Bot and its reply comes back', async () => {
  const f = fixture(); await f.host.init();
  assert.equal(await f.host.askBot('hive', 'hello'), 'reply to hello');
  assert.deepEqual(f.started, [['hive', 'hello']]);
  await assert.rejects(f.host.askBot('gone', 'x'), /That Bot is gone/);
});

test('a run that fails is reported, and one that never finishes gives up politely', async () => {
  const failing = fixture({ fail: true }); await failing.host.init();
  await assert.rejects(failing.host.askBot('hive', 'hello'), /it broke/);
  const stuck = fixture({ stall: true }); await stuck.host.init();
  assert.match(await stuck.host.askBot('travel', 'hello'), /Still working|waiting for your OK/);
});

test('settings are kept in a private file on a Linux server and encrypted on Windows', async () => {
  const linux = fixture(); await linux.host.init(); await linux.host.hub.setBot('hive'); await linux.host.hub.configure('telegram', { token: '1:abc' });
  assert.equal(linux.files['channels.json'].channels.telegram.fields.token, '1:abc');
  const win = fixture({ platform: 'win32' }); await win.host.init(); await win.host.hub.setBot('hive'); await win.host.hub.configure('telegram', { token: '1:abc' });
  assert.ok(win.files['channels.encrypted.json'].encrypted); assert.ok(!('channels.json' in win.files)); assert.ok(!JSON.stringify(win.files).includes('1:abc') || Buffer.from(win.files['channels.encrypted.json'].encrypted, 'base64').toString().startsWith('enc:'));
  const again = fixture({ platform: 'win32', saved: win.files }); await again.host.init();
  assert.equal(again.host.hub.status().bot, 'hive'); assert.equal(again.host.status().channels.telegram.configured, true);
  assert.ok(!JSON.stringify(again.host.status()).includes('1:abc'));
});

test('a Docker server can be set up from environment variables, with people approved ahead of time', async () => {
  const f = fixture({ env: { OPENGROKBOT_CHANNEL_BOT: 'travel', OPENGROKBOT_TELEGRAM_TOKEN: '9:zzz', OPENGROKBOT_CHANNELS_APPROVE: 'telegram:555, discord:777 ,bogus:1, sms:+15550001111' } });
  await f.host.init();
  const status = f.host.status();
  assert.equal(status.bot, 'travel');
  assert.equal(status.channels.telegram.enabled, true, 'a configured channel switches on');
  assert.equal(status.channels.discord.enabled, false);
  assert.deepEqual(status.people, { telegram: 1, discord: 1, slack: 0, sms: 1 });
  await f.host.stop();
  // With no Bot named, the main Bot answers. A group is never chosen.
  const g = fixture(); await g.host.init(); assert.equal(g.host.status().bot, 'hive');
  await assert.rejects(g.host.hub.setBot('grp'), /Choose one of your Bots/);
});

test('the public phone listener starts only when calls are fully set up, on its own port, and stops when they are not', async () => {
  const f = fixture({ env: { OPENGROKBOT_VOICE_HOST: '0.0.0.0', OPENGROKBOT_VOICE_PORT: '8766' } }); await f.host.init();
  assert.equal(f.servers.length, 0); assert.equal(f.host.status().calls.ready, false);
  await f.host.hub.configure('sms', { accountSid: 'AC1', authToken: 'tok', number: '+15550001111', ownerNumber: '+15550009999', publicUrl: 'https://box.ts.net' });
  assert.equal(f.servers.length, 1); assert.deepEqual(f.servers[0].at, [8766, '0.0.0.0']); assert.equal(f.host.status().calls.listening, true);
  await f.host.hub.configure('sms', { publicUrl: 'https://box2.ts.net' });
  assert.equal(f.servers.length, 1, 'changing only the address does not restart the listener');
  await f.host.stop(); assert.equal(f.servers[0].closed, true);
  const insecure = fixture(); await insecure.host.init();
  await insecure.host.hub.configure('sms', { accountSid: 'AC1', authToken: 'tok', number: '+15550001111', ownerNumber: '+15550009999', publicUrl: 'http://plain.example' });
  assert.equal(insecure.servers.length, 0, 'calls need an https address');
});
