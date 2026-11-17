'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createChannelsHost } = require('./channels-host.cjs');

const { mkdtempSync, readdirSync, readFileSync } = require('node:fs');
const os = require('node:os'), path = require('node:path');
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xff, 0xd9]);
const HEIC = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypheic'), Buffer.alloc(16)]);
const images = { 'a.jpg': JPEG, 'b.heic': HEIC, 'c.txt': Buffer.from('hello world, not an image') };
function fixture({ env = {}, platform = 'linux', saved = {}, stall = false, fail = false } = {}) {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'channel-media-')), stops = [], startOptions = [];
  const files = { ...saved }; const started = []; const servers = [];
  const state = { bots: [{ id: 'hive', name: 'Hive', isMain: true }, { id: 'travel', name: 'Travel' }, { id: 'grp', name: 'Team', memberIDs: ['hive', 'travel'] }], entries: [] };
  let running = new Set();
  const host = createChannelsHost({
    loadJSON: async (name, fallback) => (name in files ? JSON.parse(JSON.stringify(files[name])) : fallback),
    atomicJSON: async (name, value) => { files[name] = JSON.parse(JSON.stringify(value)); },
    safeStorage: { isEncryptionAvailable: () => platform === 'win32', encryptString: s => Buffer.from('enc:' + s), decryptString: b => b.toString().slice(4) },
    platform, ensureState: async () => {}, getState: () => state,
    startChat: async (id, text, options) => { started.push([id, text]); startOptions.push(options); running.add(id); state.entries.push({ botID: id, kind: 'user', text }); if (!stall) setTimeout(() => { state.entries.push({ botID: id, kind: 'bot', text: fail ? 'it broke' : 'reply to ' + text, state: fail ? 'failed' : 'complete' }); running.delete(id); }, 5); },
    isRunning: id => running.has(id), env, sleep: ms => new Promise(r => setTimeout(r, Math.min(ms, 2))),
    createServer: () => { const server = { closed: false, listen(port, host) { server.at = [port, host]; }, close() { server.closed = true; }, on() {} }; servers.push(server); return server; },
    fetchImpl: async url => (/\.(jpg|heic|txt)$/.test(url) ? { ok: true, status: 200, arrayBuffer: async () => images[url.split('/').pop()] } : { ok: true, status: 200, json: async () => ({}) }), askTimeout: 200,
    botDirectory: () => directory, stop: id => { stops.push(id); }, pollMs: 1,
  });
  return { host, files, started, startOptions, servers, state, running, stops, directory };
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
  assert.deepEqual(status.people, { telegram: 1, discord: 1, slack: 0, sms: 1, imessage: 0 });
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

function connectedFixture() {
  const f = fixture({ env: { OPENGROKBOT_TELEGRAM_TOKEN: '9:zzz', OPENGROKBOT_CHANNELS_APPROVE: 'telegram:555' } });
  return f;
}

test('the chosen Bot is told which channels are connected, how messages arrive, and which tools it has; other Bots are not', async () => {
  const none = fixture(); await none.host.init();
  assert.equal(none.host.note('hive'), '', 'nothing connected, nothing to say');
  const f = fixture({ env: { OPENGROKBOT_CHANNEL_BOT: 'hive' } }); await f.host.init();
  await f.host.hub.configure('sms', { accountSid: 'AC1', authToken: 'tok', number: '+15550001111', ownerNumber: '+15550009999', publicUrl: 'https://box.ts.net' });
  const note = f.host.note('hive');
  assert.match(note, /Phone calls: ready/);
  assert.match(note, /Not connected: .*Telegram.*Discord.*Slack/s);
  assert.match(note, /\[Telegram · Sam\]/);
  assert.match(note, /"action":"phone_call"/); assert.match(note, /"action":"channel_send"/);
  assert.match(note, /cannot treat them as approving purchases/);
  assert.equal(f.host.note('travel'), '', 'only the connected Bot is told');
  // A channel that is switched on and working is listed with who is approved.
  f.host.hub.adapters.set('telegram', { status: () => ({ state: 'on', detail: '@hive_bot' }), async stop() {} });
  f.host.hub.data.channels.telegram = { enabled: true, fields: { token: 't' } };
  f.host.hub.data.approved.telegram = [{ id: '1', name: 'Sam', at: 1, chatId: '1' }];
  assert.match(f.host.note('hive'), /Telegram \(@hive_bot\), 1 approved person/);
});

test('messages from a channel reach the Bot tagged with where they came from', async () => {
  const f = fixture(); await f.host.init(); await f.host.hub.setBot('hive');
  assert.equal(await f.host.hub.deps.ask('hive', 'what is on today?', { channel: 'telegram', senderName: 'Sam' }), 'reply to [Telegram · Sam] what is on today?');
  assert.deepEqual(f.started.at(-1), ['hive', '[Telegram · Sam] what is on today?']);
});

test('channel_send reaches only approved people, defaults to whoever wrote last, and is limited; phone_call carries what to say', async () => {
  const f = fixture({ env: { OPENGROKBOT_CHANNEL_BOT: 'hive' } }); await f.host.init();
  const sent = [];
  f.host.hub.adapters.set('telegram', { async send(chat, text) { sent.push([chat, text]); }, status: () => ({ state: 'on', detail: '' }), async stop() {} });
  f.host.hub.data.approved.telegram = [{ id: '11', name: 'Sam Lee', at: 1, chatId: '111' }, { id: '22', name: 'Ann', at: 2, chatId: '222', lastSeen: 50 }];
  assert.equal(await f.host.runAction('hive', { action: 'channel_send', channel: 'telegram', to: 'sam', text: 'hello' }), 'Sent to Sam Lee on Telegram.');
  assert.deepEqual(sent.at(-1), ['111', 'hello']);
  assert.equal(await f.host.runAction('hive', { action: 'channel_send', channel: 'telegram', text: 'hi again' }), 'Sent to Ann on Telegram.');
  await assert.rejects(f.host.runAction('hive', { action: 'channel_send', channel: 'telegram', to: 'Mallory', text: 'x' }), /not an approved person/);
  await assert.rejects(f.host.runAction('hive', { action: 'channel_send', channel: 'discord', text: 'x' }), /not connected/);
  await assert.rejects(f.host.runAction('hive', { action: 'channel_send', channel: 'telegram', text: '' }), /Write the message/);
  await assert.rejects(f.host.runAction('travel', { action: 'channel_send', channel: 'telegram', text: 'x' }), /not the one connected/);
  for (let i = 0; i < 18; i++) await f.host.runAction('hive', { action: 'channel_send', channel: 'telegram', to: 'Ann', text: 'n' + i });
  await assert.rejects(f.host.runAction('hive', { action: 'channel_send', channel: 'telegram', to: 'Ann', text: 'one too many' }), /20 messages/);
  // A call the Bot starts opens with what it wanted to say.
  const placed = [];
  const g = fixture({ env: { OPENGROKBOT_CHANNEL_BOT: 'hive' } }); await g.host.init();
  await g.host.hub.configure('sms', { accountSid: 'AC1', authToken: 'tok', number: '+15550001111', ownerNumber: '+15550009999', pin: '4321', publicUrl: 'https://box.ts.net' });
  g.host.voice.fetch = async (url, options) => { placed.push(Object.fromEntries(new URLSearchParams(options.body))); return { ok: true, status: 200, json: async () => ({}) }; };
  assert.match(await g.host.runAction('hive', { action: 'phone_call', text: 'Your 3pm moved to 4pm.' }), /Calling you now/);
  const token = /t=([a-f0-9]+)/.exec(placed[0].Url)[1];
  const xml = await g.host.voice.handle('/twilio/voice', { AccountSid: 'AC1', CallSid: 'CA1' }, { t: token });
  assert.match(xml, /Your 3pm moved to 4pm\./);
});

test('end to end: a Telegram message from a pre-approved person reaches the chosen Bot and its answer is sent back; a stranger only gets a code', async () => {
  const sent = []; const updates = [[
    { update_id: 1, message: { text: 'what is on today?', chat: { id: 555, type: 'private' }, from: { id: 555, first_name: 'Sam' } } },
    { update_id: 2, message: { text: 'let me in', chat: { id: 777, type: 'private' }, from: { id: 777, first_name: 'Mallory' } } },
  ]];
  const fetchImpl = async (url, options) => {
    const method = url.split('/').pop(); const body = JSON.parse(options.body); const json = value => ({ ok: true, status: 200, json: async () => value });
    if (method === 'getMe') return json({ ok: true, result: { username: 'hive_bot' } });
    if (method === 'getUpdates') { const next = updates.shift(); if (!next) { await new Promise(r => setTimeout(r, 5)); return json({ ok: true, result: [] }); } return json({ ok: true, result: next }); }
    if (method === 'sendMessage') sent.push([body.chat_id, body.text]);
    return json({ ok: true, result: {} });
  };
  const f = fixture({ env: { OPENGROKBOT_CHANNEL_BOT: 'travel', OPENGROKBOT_TELEGRAM_TOKEN: '9:zzz', OPENGROKBOT_CHANNELS_APPROVE: 'telegram:555' } });
  // Rebuild the host with the fake Telegram API (the fixture's own fetch answers nothing useful).
  const { createChannelsHost } = require('./channels-host.cjs');
  const files = f.files; const state = f.state; const started = [];
  const host = createChannelsHost({
    loadJSON: async (n, d) => (n in files ? JSON.parse(JSON.stringify(files[n])) : d), atomicJSON: async (n, v) => { files[n] = JSON.parse(JSON.stringify(v)); },
    safeStorage: { isEncryptionAvailable: () => false }, platform: 'linux', ensureState: async () => {}, getState: () => state,
    startChat: async (id, text) => { started.push([id, text]); state.entries.push({ botID: id, kind: 'bot', text: 'Two meetings today.', state: 'complete' }); },
    isRunning: () => false, env: { OPENGROKBOT_CHANNEL_BOT: 'travel', OPENGROKBOT_TELEGRAM_TOKEN: '9:zzz', OPENGROKBOT_CHANNELS_APPROVE: 'telegram:555' },
    fetchImpl, sleep: async () => {}, batchMs: 0,
  });
  await host.init();
  await new Promise(r => setTimeout(r, 80));
  assert.deepEqual(started, [['travel', '[Telegram · Sam] what is on today?']], 'only the approved person reaches the Bot');
  assert.ok(sent.some(([chat, text]) => chat === 555 || chat === '555' ? text === 'Two meetings today.' : false), 'the answer goes back to Sam');
  const stranger = sent.find(([chat]) => String(chat) === '777');
  assert.ok(stranger && /Your code is \d{6}/.test(stranger[1]) && stranger[1].length < 160, 'Mallory gets a short code and nothing else');
  assert.equal(host.hub.status().channels.telegram.pending.length, 1);
  assert.match(host.note('travel'), /Telegram \(@hive_bot\), 1 approved person/);
  await host.stop();
});

test('a photo from a channel is saved into the Bot\u2019s Attachments folder and the Bot is told where it is', async () => {
  const f = fixture(); await f.host.init();
  const answer = await f.host.askBot('hive', '', { channel: 'imessage', senderName: 'Sam', me: true }, { media: [{ url: 'https://s3.example/a.jpg', contentType: 'image/jpeg' }] });
  assert.match(answer, /^reply to \[iMessage \u00b7 Sam \u00b7 the owner\] \(photo\)/);
  const [, sent] = f.started.at(-1); const files = readdirSync(path.join(f.directory, 'Attachments'));
  assert.equal(files.length, 1); assert.match(files[0], /\.jpg$/); assert.ok(sent.includes('Attachments/' + files[0]));
  assert.deepEqual(readFileSync(path.join(f.directory, 'Attachments', files[0])), JPEG);
});

test('pictures that cannot be read are explained instead of guessed at', async () => {
  const f = fixture(); await f.host.init();
  assert.match(await f.host.askBot('hive', '', { channel: 'imessage', senderName: 'Sam' }, { media: [{ url: 'https://s3.example/b.heic' }] }), /HEIC.*JPEG or a screenshot/);
  assert.match(await f.host.askBot('hive', '', { channel: 'imessage', senderName: 'Sam' }, { media: [{ url: 'https://s3.example/c.txt' }] }), /not a PNG, JPEG, GIF or WebP/);
  assert.equal(f.started.length, 0, 'nothing readable and no words: the Bot is not bothered');
  const mixed = await f.host.askBot('hive', 'add these', { channel: 'imessage', senderName: 'Sam' }, { media: [{ url: 'https://s3.example/a.jpg' }, { url: 'https://s3.example/b.heic' }] });
  assert.match(mixed, /HEIC/); assert.match(f.started.at(-1)[1], /Attachments\/.*\.jpg/);
});

test('channel turns are fast turns, steering adds a note, and a stopped turn returns nothing', async () => {
  const f = fixture({ stall: true }); await f.host.init();
  const pending = f.host.askBot('hive', 'plan my day', { channel: 'telegram', senderName: 'Sam' }, { fast: true });
  await new Promise(r => setTimeout(r, 5));
  f.host.hub.deps.stop('hive'); assert.deepEqual(f.stops, ['hive']);
  f.running.delete('hive');
  assert.equal(await pending, null);
  const steered = f.host.askBot('hive', 'shorter', { channel: 'telegram', senderName: 'Sam' }, { steer: true, fast: false });
  await new Promise(r => setTimeout(r, 5));
  assert.match(f.started.at(-1)[1], /\(The person sent this while you were still working/);
  assert.deepEqual(f.startOptions, [{ channelTurn: true }, { channelTurn: false }]);
  f.running.delete('hive'); await steered;
});
