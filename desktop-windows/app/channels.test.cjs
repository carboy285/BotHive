'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { chunk, spoken, xml } = require('./channel-text.cjs');
const { ChannelHub, CALL_WORDS } = require('./channel-hub.cjs');
const { TelegramChannel } = require('./channel-telegram.cjs');
const { DiscordChannel, INTENTS } = require('./channel-discord.cjs');
const { SlackChannel } = require('./channel-slack.cjs');
const { SmsChannel, VoiceCalls, signature, validSignature } = require('./channel-twilio.cjs');
const { createVoiceServer } = require('./channel-voice-server.cjs');

const json = (body, status = 200) => ({ ok: status < 400, status, json: async () => body });

test('text helpers split long replies, read markdown out loud, and escape XML', () => {
  const pieces = chunk('a'.repeat(30) + '\n\n' + 'b'.repeat(30) + ' ' + 'c'.repeat(30), 40);
  assert.ok(pieces.every(piece => piece.length <= 40)); assert.equal(pieces.join('').replace(/\s/g, '').length, 90);
  assert.deepEqual(chunk('short', 100), ['short']);
  assert.equal(spoken('**Bold** and `code` see [the docs](https://x.example/a) or https://y.example'), 'Bold and code see the docs or a link');
  assert.ok(spoken('Sentence one. '.repeat(100), 120).endsWith('The rest is in your chat.'));
  assert.equal(xml('<a href="x">&\'</a>'), '&lt;a href=&quot;x&quot;&gt;&amp;&apos;&lt;/a&gt;');
});

test('call requests are recognised, ordinary messages are not', () => {
  for (const text of ['call me', 'Call me!', '/call', 'please call me now', 'can you call me', 'ring me', 'give me a call']) assert.ok(CALL_WORDS.test(text), text);
  for (const text of ['call me a taxi', 'what is a call option', 'recall my notes', 'call mom tomorrow']) assert.ok(!CALL_WORDS.test(text), text);
});

function hubFixture({ asked = [], sent = [], now = { t: 1_000_000 }, calls = [], answer = 'the answer', batchMs = 0, events = [], stopped = [], setTimer, clearTimer } = {}) {
  let stored = null; const adapters = {};
  const hub = new ChannelHub({
    load: async () => stored, save: async value => { stored = JSON.parse(JSON.stringify(value)); },
    makeAdapter: (id, fields, handlers) => (adapters[id] = { id, fields, handlers, started: false, async start() { this.started = true; }, async stop() { this.started = false; }, async send(chat, text) { sent.push([id, chat, text]); }, async acknowledge(message) { events.push(['read', message.chatId]); }, async typing(chat) { events.push(['typing', chat]); }, status: () => ({ state: 'on', detail: '' }) }),
    ask: async (bot, text, from, options) => { events.push(['ask', text]); asked.push([bot, text, from, options]); return typeof answer === 'function' ? answer(text, options) : answer; }, stop: bot => { stopped.push(bot); }, batchMs, setTimer, clearTimer,
    botExists: id => id === 'bot-1', call: async from => { calls.push(from); return 'Calling you now.'; }, now: () => now.t, code: (() => { let n = 100000; return () => String(++n); })(),
  });
  return { hub, adapters, asked, sent, now, calls, events, stopped, saved: () => stored };
}

test('nobody is answered until the owner approves them with the code they were given', async () => {
  const f = hubFixture(); await f.hub.init();
  await f.hub.setBot('bot-1');
  await f.hub.configure('telegram', { token: '123:abc' }); await f.hub.setEnabled('telegram', true);
  const handlers = f.adapters.telegram.handlers;
  await handlers.onMessage({ senderId: '7', senderName: 'Sam', chatId: '7', text: 'run rm -rf everything' });
  assert.equal(f.asked.length, 0, 'a stranger never reaches the Bot');
  assert.match(f.sent[0][2], /Your code is 100001/);
  await handlers.onMessage({ senderId: '7', senderName: 'Sam', chatId: '7', text: 'hello?' });
  assert.equal(f.sent.length, 1, 'the code is not repeated at once');
  assert.deepEqual(f.hub.status().channels.telegram.pending.map(x => x.code), ['100001']);
  await assert.rejects(f.hub.approve('telegram', '999999'), /not waiting/);
  assert.deepEqual(await f.hub.approve('telegram', '100001'), { name: 'Sam' });
  await handlers.onMessage({ senderId: '7', senderName: 'Sam', chatId: '7', text: 'what is 2+2?' });
  assert.deepEqual(f.asked.map(x => x[1]), ['what is 2+2?']);
  assert.equal(f.sent.at(-1)[2], 'the answer');
  await f.hub.remove('telegram', '7');
  await handlers.onMessage({ senderId: '7', senderName: 'Sam', chatId: '7', text: 'again' });
  assert.equal(f.asked.length, 1, 'removed people are strangers again');
});

test('codes expire, waiting lists are capped, and nothing happens without a chosen Bot', async () => {
  const f = hubFixture(); await f.hub.init();
  await f.hub.configure('discord', { token: 't' });
  await assert.rejects(f.hub.setEnabled('discord', true), /Choose which Bot/);
  await f.hub.setBot('bot-1'); await f.hub.setEnabled('discord', true);
  const { onMessage } = f.adapters.discord.handlers;
  await onMessage({ senderId: 'a', chatId: 'c', text: 'hi' });
  f.now.t += 61 * 60 * 1000;
  assert.deepEqual(f.hub.status().channels.discord.pending, []);
  await assert.rejects(f.hub.approve('discord', '100001'), /not waiting/);
  for (let i = 0; i < 30; i++) await onMessage({ senderId: 'p' + i, chatId: 'c' + i, text: 'hi' });
  assert.equal(f.hub.status().channels.discord.pending.length, 20);
  await assert.rejects(f.hub.setBot('nope'), /Choose one of your Bots/);
});

test('approved people are rate limited, long messages refused and calls routed', async () => {
  const f = hubFixture();
  await f.hub.init(); await f.hub.setBot('bot-1'); await f.hub.configure('slack', { botToken: 'xoxb-1', appToken: 'xapp-1' }); await f.hub.setEnabled('slack', true);
  const { onMessage } = f.adapters.slack.handlers;
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'hi' });
  await f.hub.approve('slack', '100001');
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'x'.repeat(4001) });
  assert.match(f.sent.at(-1)[2], /too long/);
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'call me' });
  assert.equal(f.calls.length, 1); assert.equal(f.sent.at(-1)[2], 'Calling you now.');
  for (let i = 0; i < 40; i++) await onMessage({ senderId: 'U1', chatId: 'D1', text: 'spam ' + i });
  assert.ok(f.sent.filter(x => /a lot of messages/.test(x[2])).length === 1);
});

test('secrets never leave the hub and blank fields keep the saved value', async () => {
  const f = hubFixture(); await f.hub.init();
  await f.hub.configure('telegram', { token: 'secret-token' });
  assert.equal(f.hub.status().channels.telegram.fields.token, true);
  assert.ok(!JSON.stringify(f.hub.status()).includes('secret-token'));
  await f.hub.configure('sms', { accountSid: 'ACabc', number: '+15550001111' });
  assert.equal(f.hub.status().channels.sms.fields.number, '+15550001111');
  await f.hub.configure('telegram', { token: '' });
  assert.equal(f.hub.status().channels.telegram.configured, true, 'a blank secret keeps the old one');
  await assert.rejects(f.hub.configure('telegram', { token: 'a\nb' }), /not valid/);
  await assert.rejects(f.hub.configure('nope', {}), /Unknown/);
  // Saved settings come back after a restart and enabled channels start again.
  await f.hub.setBot('bot-1'); await f.hub.setEnabled('telegram', true);
  const again = hubFixture(); again.hub.deps.load = async () => f.saved(); await again.hub.init();
  assert.equal(again.adapters.telegram.started, true); assert.equal(again.hub.status().bot, 'bot-1');
});

function telegramFetch(updates, { ok = true, code } = {}) {
  const calls = [];
  const fetchImpl = async (url, options) => {
    const method = url.split('/').pop(); const body = JSON.parse(options.body); calls.push([method, body]);
    if (!ok) return json({ ok: false, error_code: code, description: 'nope' }, code);
    if (method === 'getMe') return json({ ok: true, result: { username: 'bothive_bot' } });
    if (method === 'getUpdates') { const next = updates.shift(); if (!next) { await new Promise(r => setTimeout(r, 5)); return json({ ok: true, result: [] }); } return json({ ok: true, result: next }); }
    return json({ ok: true, result: {} });
  };
  return { fetchImpl, calls };
}

test('Telegram: direct messages from people reach the hub; groups and bots are ignored; a bad token is explained', async () => {
  const got = [];
  const { fetchImpl, calls } = telegramFetch([[
    { update_id: 5, message: { text: 'hi', chat: { id: 9, type: 'private' }, from: { id: 9, first_name: 'Ann', last_name: 'Lee' } } },
    { update_id: 6, message: { text: 'group', chat: { id: -4, type: 'group' }, from: { id: 9 } } },
    { update_id: 7, message: { text: 'bot', chat: { id: 3, type: 'private' }, from: { id: 3, is_bot: true } } },
  ]]);
  const channel = new TelegramChannel({ fields: { token: '1:x' }, handlers: { onMessage: m => got.push(m) }, fetchImpl, sleep: async () => {} });
  await channel.start(); await new Promise(r => setTimeout(r, 30)); await channel.stop();
  assert.deepEqual(got, [{ senderId: '9', senderName: 'Ann Lee', chatId: '9', text: 'hi', media: [] }]);
  assert.ok(calls.some(([m, b]) => m === 'getUpdates' && b.offset === 8));
  await channel.send('9', 'reply'); assert.deepEqual(calls.at(-1), ['sendMessage', { chat_id: '9', text: 'reply', disable_web_page_preview: true }]);
  const bad = new TelegramChannel({ fields: { token: 'x' }, handlers: {}, fetchImpl: telegramFetch([], { ok: false, code: 401 }).fetchImpl });
  await assert.rejects(bad.start(), /did not accept that token/);
});

class FakeSocket {
  constructor(url) { this.url = url; this.sent = []; FakeSocket.all.push(this); }
  send(text) { this.sent.push(JSON.parse(text)); } close(code) { this.closed = code; this.onclose?.({ code }); }
  emit(packet) { this.onmessage({ data: JSON.stringify(packet) }); }
}
FakeSocket.all = [];

test('Discord: identifies with the right intents, answers DMs, and in servers only when mentioned', async () => {
  FakeSocket.all = [];
  const got = [], rest = [];
  const fetchImpl = async (url, options = {}) => { rest.push([url.replace('https://discord.com/api/v10', ''), options.method || 'GET', options.body]); return url.endsWith('/users/@me') ? json({ id: 'B1', username: 'Hive' }) : json({}, 204); };
  const timers = []; const channel = new DiscordChannel({ fields: { token: 'tok' }, handlers: { onMessage: m => got.push(m) }, fetchImpl, WebSocketImpl: FakeSocket, setTimer: (fn, ms) => { timers.push([fn, ms]); return timers.length; }, clearTimer: () => {} });
  await channel.start();
  const socket = FakeSocket.all[0]; assert.match(socket.url, /gateway\.discord\.gg/);
  socket.emit({ op: 10, d: { heartbeat_interval: 40000 } });
  assert.equal(socket.sent[0].op, 2); assert.equal(socket.sent[0].d.intents, INTENTS); assert.equal(socket.sent[0].d.token, 'tok');
  socket.emit({ op: 0, t: 'READY', s: 1, d: { user: { id: 'B1' } } }); assert.equal(channel.status().state, 'on');
  socket.emit({ op: 0, t: 'MESSAGE_CREATE', s: 2, d: { content: 'hello', author: { id: 'U1', username: 'sam' }, channel_id: 'DM1' } });
  socket.emit({ op: 0, t: 'MESSAGE_CREATE', s: 3, d: { content: 'hi all', author: { id: 'U1', username: 'sam' }, channel_id: 'C1', guild_id: 'G', mentions: [] } });
  socket.emit({ op: 0, t: 'MESSAGE_CREATE', s: 4, d: { content: '<@B1> status?', author: { id: 'U1', username: 'sam' }, channel_id: 'C1', guild_id: 'G', mentions: [{ id: 'B1' }] } });
  socket.emit({ op: 0, t: 'MESSAGE_CREATE', s: 5, d: { content: 'beep', author: { id: 'B9', bot: true }, channel_id: 'DM1' } });
  assert.deepEqual(got.map(m => [m.chatId, m.text]), [['DM1', 'hello'], ['C1', 'status?']]);
  await channel.send('DM1', 'yo'); assert.equal(rest.at(-1)[1], 'POST'); assert.match(rest.at(-1)[2], /"content":"yo"/); assert.match(rest.at(-1)[2], /"parse":\[\]/);
  // A dropped connection reconnects; a refused intent explains itself and stops.
  socket.onclose({ code: 1006 }); assert.equal(channel.status().state, 'error'); timers.at(-1)[0](); assert.equal(FakeSocket.all.length, 2);
  FakeSocket.all[1].onclose({ code: 4014 }); assert.match(channel.status().detail, /Message Content Intent/);
  await channel.stop();
});

test('Slack: acknowledges every event, answers DMs and mentions, ignores bots and repeats', async () => {
  FakeSocket.all = [];
  const got = [], posts = [];
  const fetchImpl = async (url, options) => {
    const method = url.split('/api/')[1]; const body = JSON.parse(options.body);
    if (method === 'auth.test') return json({ ok: true, user_id: 'UBOT', team: 'Acme' });
    if (method === 'apps.connections.open') return json({ ok: true, url: 'wss://wss.example/slack' });
    posts.push([method, body]); return json({ ok: true });
  };
  const channel = new SlackChannel({ fields: { botToken: 'xoxb-1', appToken: 'xapp-1' }, handlers: { onMessage: m => got.push(m) }, fetchImpl, WebSocketImpl: FakeSocket, setTimer: () => 0, clearTimer: () => {} });
  await channel.start();
  const socket = FakeSocket.all[0]; socket.emit({ type: 'hello' }); assert.equal(channel.status().state, 'on');
  const event = (id, e) => socket.emit({ type: 'events_api', envelope_id: id, payload: { event_id: id, event: e } });
  event('e1', { type: 'message', channel_type: 'im', user: 'U1', text: 'hello', channel: 'D1' });
  event('e2', { type: 'app_mention', user: 'U1', text: '<@UBOT> status', channel: 'C1' });
  event('e3', { type: 'message', channel_type: 'channel', user: 'U1', text: 'chatter', channel: 'C1' });
  event('e4', { type: 'message', channel_type: 'im', bot_id: 'B1', text: 'bot', channel: 'D1', user: 'U2' });
  event('e1', { type: 'message', channel_type: 'im', user: 'U1', text: 'hello', channel: 'D1' });
  assert.deepEqual(got.map(m => [m.chatId, m.text]), [['D1', 'hello'], ['C1', 'status']]);
  assert.deepEqual(socket.sent.map(x => x.envelope_id), ['e1', 'e2', 'e3', 'e4', 'e1']);
  await channel.send('D1', 'answer'); assert.deepEqual(posts.at(-1), ['chat.postMessage', { channel: 'D1', text: 'answer', unfurl_links: false, unfurl_media: false }]);
  await assert.rejects(new SlackChannel({ fields: { botToken: 'nope', appToken: 'xapp-1' }, handlers: {} }).start(), /xoxb-/);
  await assert.rejects(new SlackChannel({ fields: { botToken: 'xoxb-1', appToken: 'nope' }, handlers: {} }).start(), /xapp-/);
});

test('SMS: old messages are ignored, new ones reach the hub once, answers are texted back', async () => {
  const inbox = [{ sid: 'SM1', direction: 'inbound', from: '+15550002222', body: 'old' }]; const outgoing = [];
  const fetchImpl = async (url, options = {}) => {
    if (url.includes('/Messages.json') && options.method === 'POST') { outgoing.push(Object.fromEntries(new URLSearchParams(options.body))); return json({ sid: 'SMx' }); }
    if (url.includes('/Messages.json')) return json({ messages: [...inbox].reverse() });
    return json({ sid: 'AC1' });
  };
  const got = []; let tick;
  const channel = new SmsChannel({ fields: { accountSid: 'AC1', authToken: 'tok', number: '+15550001111' }, handlers: { onMessage: m => got.push(m) }, fetchImpl, setTimer: fn => { tick = fn; return 1; }, clearTimer: () => {} });
  await channel.start();
  inbox.push({ sid: 'SM2', direction: 'inbound', from: '+15550002222', body: 'new' }, { sid: 'SM3', direction: 'outbound-api', from: '+15550001111', body: 'echo' });
  await tick(); await tick();
  assert.deepEqual(got.map(m => m.text), ['new']);
  await channel.send('+15550002222', 'hello'); assert.deepEqual(outgoing[0], { From: '+15550001111', To: '+15550002222', Body: 'hello' });
  await assert.rejects(new SmsChannel({ fields: { number: '5550001111' }, handlers: {} }).start(), /country code/);
});

test('Twilio signatures: a valid one passes, any change fails (known vector from Twilio\'s documentation)', () => {
  const url = 'https://mycompany.com/myapp.php?foo=1&bar=2';
  const params = { CallSid: 'CA1234567890ABCDE', Caller: '+14158675310', Digits: '1234', From: '+14158675310', To: '+18005551212' };
  const sig = signature('12345', url, params);
  assert.equal(sig, 'GvWf1cFY/Q7PnoempGyD5oXAezc=');
  assert.ok(validSignature('12345', url, params, sig));
  assert.ok(!validSignature('12345', url + 'x', params, sig));
  assert.ok(!validSignature('12345', url, { ...params, Digits: '9999' }, sig));
  assert.ok(!validSignature('54321', url, params, sig));
  assert.ok(!validSignature('12345', url, params, undefined));
});

function voiceFixture(extra = {}) {
  const placed = []; let ids = 0;
  const settings = { accountSid: 'AC1', authToken: 'tok', number: '+15550001111', ownerNumber: '+15550009999', pin: '4321', publicUrl: 'https://box.tailnet.ts.net', language: 'en-US', botName: 'Hive', ...extra };
  const fetchImpl = async (url, options) => { placed.push(Object.fromEntries(new URLSearchParams(options.body))); return json({ sid: 'CA1' }); };
  const asked = [];
  const voice = new VoiceCalls({ settings: () => settings, ask: async text => { asked.push(text); return 'It is **sunny**, see https://w.example.'; }, fetchImpl, token: () => 'tok' + ++ids, now: () => Date.now() });
  return { voice, placed, asked, settings };
}

test('Calls: the Bot rings only the owner\'s number, a limited number of times, and the call is a hold-and-answer conversation', async () => {
  const f = voiceFixture();
  assert.equal(await f.voice.placeCall(), 'Calling you now.');
  assert.deepEqual([f.placed[0].From, f.placed[0].To], ['+15550001111', '+15550009999']);
  assert.match(f.placed[0].Url, /^https:\/\/box\.tailnet\.ts\.net\/twilio\/voice\?t=tok1$/);
  const base = { AccountSid: 'AC1', CallSid: 'CA1' };
  // Twilio answers: greeting and listen.
  let xml = await f.voice.handle('/twilio/voice', base, { t: 'tok1' });
  assert.match(xml, /Hi, it is Hive/); assert.match(xml, /<Gather input="speech"/);
  const callId = /c=([a-z0-9]+)/.exec(xml)[1];
  // The caller speaks; the Bot is slow, so the call holds, then speaks the answer in plain words.
  xml = await f.voice.handle('/twilio/voice/turn', { ...base, SpeechResult: 'What is the weather?' }, { c: callId });
  assert.match(xml, /One moment/); assert.match(xml, /Redirect/);
  await new Promise(r => setImmediate(r));
  xml = await f.voice.handle('/twilio/voice/wait', base, { c: callId });
  assert.match(xml, /It is sunny, see a link\./); assert.ok(!/\*\*/.test(xml));
  assert.match(f.asked[0], /Phone call.*What is the weather\?/);
  // Saying goodbye hangs up, and an unknown call or another account's request gets nothing useful.
  xml = await f.voice.handle('/twilio/voice/turn', { ...base, SpeechResult: 'ok goodbye' }, { c: callId });
  assert.match(xml, /Hangup/);
  assert.match(await f.voice.handle('/twilio/voice/turn', { ...base, SpeechResult: 'hi' }, { c: callId }), /ended/);
  assert.match(await f.voice.handle('/twilio/voice', { ...base, AccountSid: 'ACother' }, { t: 'x' }), /not set up/);
  for (let i = 0; i < 4; i++) await f.voice.placeCall();
  await assert.rejects(f.voice.placeCall(), /five calls/);
  await assert.rejects(voiceFixture({ ownerNumber: '' }).voice.placeCall(), /not set up/);
  await assert.rejects(voiceFixture({ publicUrl: 'http://insecure.example' }).voice.placeCall(), /not set up/);
});

test('Calls: inbound callers must be the owner AND enter the PIN; three wrong tries end the call', async () => {
  const f = voiceFixture();
  const base = { AccountSid: 'AC1', CallSid: 'CA7', From: '+15550009999' };
  assert.match(await f.voice.handle('/twilio/voice', { ...base, From: '+15551230000' }, {}), /only take calls from my owner/);
  assert.match(await voiceFixture({ pin: '' }).voice.handle('/twilio/voice', base, {}), /only take calls from my owner/);
  let xml = await f.voice.handle('/twilio/voice', base, {});
  assert.match(xml, /Enter your pin/); const id = /c=([a-z0-9]+)/.exec(xml)[1];
  assert.match(await f.voice.handle('/twilio/voice/turn', { ...base, SpeechResult: 'hello' }, { c: id }), /Goodbye/, 'no speech is accepted before the PIN');
  assert.equal(f.asked.length, 0);
  xml = await f.voice.handle('/twilio/voice/pin', { ...base, Digits: '0000' }, { c: id }); assert.match(xml, /Try again/);
  xml = await f.voice.handle('/twilio/voice/pin', { ...base, Digits: '4321' }, { c: id }); assert.match(xml, /What can I do for you/);
  const g = voiceFixture(); xml = await g.voice.handle('/twilio/voice', base, {}); const gid = /c=([a-z0-9]+)/.exec(xml)[1];
  for (let i = 0; i < 2; i++) await g.voice.handle('/twilio/voice/pin', { ...base, Digits: '1' }, { c: gid });
  assert.match(await g.voice.handle('/twilio/voice/pin', { ...base, Digits: '1' }, { c: gid }), /Hangup/);
});

test('The public voice listener answers only signed Twilio requests on its own paths', async () => {
  const f = voiceFixture();
  const server = createVoiceServer({ voice: f.voice }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const post = (path, params, signed = true, sigOverride) => new Promise((resolve, reject) => {
    const body = new URLSearchParams(params).toString();
    const headers = { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) };
    if (signed) headers['X-Twilio-Signature'] = sigOverride || signature('tok', 'https://box.tailnet.ts.net' + path, params);
    const req = http.request({ host: '127.0.0.1', port, path, method: 'POST', headers }, res => { let data = ''; res.on('data', c => data += c); res.on('end', () => resolve({ status: res.statusCode, data })); });
    req.on('error', reject); req.end(body);
  });
  try {
    const params = { AccountSid: 'AC1', CallSid: 'CA9', From: '+15550009999' };
    const ok = await post('/twilio/voice', params); assert.equal(ok.status, 200); assert.match(ok.data, /Enter your pin/);
    assert.equal((await post('/twilio/voice', params, false)).status, 403, 'no signature');
    assert.equal((await post('/twilio/voice', params, true, 'AAAA')).status, 403, 'wrong signature');
    assert.equal((await post('/api/invoke', params)).status, 404, 'nothing else is served');
    const get = await new Promise(resolve => http.get({ host: '127.0.0.1', port, path: '/' }, res => resolve(res.statusCode)));
    assert.equal(get, 404);
  } finally { server.close(); }
});

test('iMessage through Inkbox: old messages are ignored, new one-to-one messages reach the hub once and are marked read, replies go into the same conversation', async () => {
  const { InkboxIMessageChannel } = require('./channel-inkbox.cjs');
  const inbox = [{ id: 'm1', direction: 'inbound', is_group: false, is_blocked: false, content: 'old', remote_number: '+15550002222', conversation_id: 'c1' }];
  const calls = []; let tick;
  const fetchImpl = async (url, options = {}) => {
    const path = url.replace('https://inkbox.ai/api/v1/imessage', ''); calls.push([options.method || 'GET', path, options.body ? JSON.parse(options.body) : null, options.headers]);
    if (path.startsWith('/messages?')) return { ok: true, status: 200, json: async () => [...inbox].reverse() };
    if (path.startsWith('/conversations?')) return { ok: true, status: 200, json: async () => [] };
    return { ok: true, status: 200, json: async () => ({ status: 'sent' }) };
  };
  const got = [];
  const channel = new InkboxIMessageChannel({ fields: { apiKey: 'ik_0123456789abcdef' }, handlers: { onMessage: m => got.push(m) }, fetchImpl, setTimer: fn => { tick = fn; return 1; }, clearTimer: () => {}, uuid: () => 'key-1' });
  await channel.start();
  assert.ok(calls.every(c => c[3]['X-API-Key'] === 'ik_0123456789abcdef'));
  inbox.push(
    { id: 'm2', direction: 'inbound', is_group: false, is_blocked: false, content: 'hello', remote_number: '+15550002222', conversation_id: 'c1' },
    { id: 'm3', direction: 'inbound', is_group: true, is_blocked: false, content: 'group', remote_number: '+15550003333', conversation_id: 'g1' },
    { id: 'm4', direction: 'inbound', is_group: false, is_blocked: false, content: 'from email', remote_number: 'sam@example.com', conversation_id: 'c2' },
    { id: 'm5', direction: 'outbound', is_group: false, is_blocked: false, content: 'mine', remote_number: '+15550002222', conversation_id: 'c1' },
    { id: 'm6', direction: 'inbound', is_group: false, is_blocked: false, content: null, remote_number: '+15550002222', conversation_id: 'c1' },
    { id: 'm7', direction: 'inbound', is_group: false, is_blocked: false, content: '', remote_number: '+15550002222', conversation_id: 'c1', media: [{ url: 'https://s3.example/a.jpg', content_type: 'image/jpeg', size: 10 }, { url: 'https://s3.example/b.pdf', content_type: 'application/pdf', size: 10 }] });
  await tick(); await tick();
  assert.deepEqual(got, [
    { senderId: '+15550002222', senderName: '+15550002222', chatId: 'c1', text: 'hello', media: [] },
    { senderId: '+15550002222', senderName: '+15550002222', chatId: 'c1', text: '', media: [{ url: 'https://s3.example/a.jpg', contentType: 'image/jpeg', size: 10 }] },
  ], 'a photo with no words is still passed on; a PDF is not');
  assert.equal(calls.filter(c => c[1] === '/mark-read').length, 0, 'the poll alone does not mark anything read; the hub does that for approved people');
  await channel.acknowledge({ chatId: 'c1' });
  assert.deepEqual(calls.filter(c => c[1] === '/mark-read').map(c => c[2]), [{ conversation_id: 'c1' }]);
  await channel.send('c1', 'on it'); const sent = calls.at(-1);
  assert.deepEqual([sent[0], sent[1], sent[2]], ['POST', '/messages', { conversation_id: 'c1', text: 'on it' }]);
  assert.equal(sent[3]['Idempotency-Key'], 'key-1');
  await channel.typing('c1'); assert.deepEqual(calls.at(-1).slice(0, 3), ['POST', '/typing', { conversation_id: 'c1' }]);
  // A key Inkbox refuses, or an agent without iMessage, is explained.
  const refuse = status => new InkboxIMessageChannel({ fields: { apiKey: 'ik_0123456789abcdef' }, handlers: {}, fetchImpl: async () => ({ ok: false, status, json: async () => ({}), headers: new Map() }) });
  await assert.rejects(refuse(401).start(), /did not accept that API key/);
  await assert.rejects(refuse(400).start(), /iMessage is not turned on/);
  await assert.rejects(new InkboxIMessageChannel({ fields: { apiKey: 'x' }, handlers: {} }).start(), /Paste the API key/);
});

async function approvedSlack(f, options = {}) {
  await f.hub.init(); await f.hub.setBot('bot-1'); await f.hub.configure('slack', { botToken: 'xoxb-1', appToken: 'xapp-1' }); await f.hub.setEnabled('slack', true);
  const { onMessage } = f.adapters.slack.handlers;
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'hi' });
  await f.hub.approve('slack', '100001', options);
  f.events.length = 0; f.sent.length = 0;
  return onMessage;
}

test('an approved message is marked read and shows typing before the Bot is asked, and a stranger gets neither', async () => {
  const f = hubFixture(); await f.hub.init(); await f.hub.setBot('bot-1'); await f.hub.configure('slack', { botToken: 'xoxb-1', appToken: 'xapp-1' }); await f.hub.setEnabled('slack', true);
  const { onMessage } = f.adapters.slack.handlers;
  await onMessage({ senderId: 'U9', chatId: 'D9', text: 'let me in' });
  assert.deepEqual(f.events, [], 'strangers are not acknowledged');
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'hi' }); await f.hub.approve('slack', '100002'); f.events.length = 0;
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'what is on today?' });
  assert.deepEqual(f.events.slice(0, 3).map(e => e[0]), ['read', 'typing', 'ask']);
});

test('a burst of messages becomes one request, with pictures kept together with the words', async () => {
  const timers = []; const f = hubFixture({ batchMs: 1200, setTimer: fn => { timers.push(fn); return timers.length; }, clearTimer: id => { timers[id - 1] = null; } });
  const onMessage = await approvedSlack(f);
  const photo = { url: 'https://x.example/a.jpg', contentType: 'image/jpeg' };
  const first = onMessage({ senderId: 'U1', chatId: 'D1', text: '', media: [photo] });
  const second = onMessage({ senderId: 'U1', chatId: 'D1', text: 'add these to my reminders' });
  await new Promise(r => setImmediate(r));
  assert.equal(f.asked.length, 0, 'still waiting for the burst to finish');
  timers.filter(Boolean).at(-1)(); await Promise.all([first, second]);
  assert.equal(f.asked.length, 1); assert.equal(f.asked[0][1], 'add these to my reminders'); assert.deepEqual(f.asked[0][3].media, [photo]);
  assert.equal(f.asked[0][3].steer, false);
});

test('a message while the Bot works steers it: the old turn is stopped and the new one carries on', async () => {
  let release; const gate = new Promise(r => { release = r; });
  const f = hubFixture({ answer: (text, options) => (text === 'slow' ? gate.then(() => null) : options.steer ? 'carrying on' : 'ok') });
  const onMessage = await approvedSlack(f);
  const slow = onMessage({ senderId: 'U1', chatId: 'D1', text: 'slow' });
  await new Promise(r => setImmediate(r));
  const next = onMessage({ senderId: 'U1', chatId: 'D1', text: 'actually make it short' });
  await new Promise(r => setImmediate(r));
  assert.deepEqual(f.stopped, ['bot-1']); assert.equal(f.asked.length, 1, 'the new turn waits for the stopped one to finish');
  release(); await Promise.all([slow, next]);
  assert.equal(f.asked[1][3].steer, true); assert.deepEqual(f.sent.map(x => x[2]), ['carrying on'], 'the stopped turn says nothing');
});

test('with Queue the second message waits its turn instead of stopping the first', async () => {
  let release; const gate = new Promise(r => { release = r; });
  const f = hubFixture({ answer: text => (text === 'slow' ? gate.then(() => 'first done') : 'second done') });
  const onMessage = await approvedSlack(f); await f.hub.setSettings({ whenBusy: 'queue' });
  const slow = onMessage({ senderId: 'U1', chatId: 'D1', text: 'slow' }); await new Promise(r => setImmediate(r));
  const next = onMessage({ senderId: 'U1', chatId: 'D1', text: 'then this' }); await new Promise(r => setImmediate(r));
  assert.deepEqual(f.stopped, []); release(); await Promise.all([slow, next]);
  assert.deepEqual(f.sent.map(x => x[2]), ['first done', 'second done']); assert.equal(f.asked[1][3].steer, false);
  await assert.rejects(f.hub.setSettings({ whenBusy: 'later' }), /Steer or Queue/);
});

test('"stop" only stops the running turn and is never sent to the Bot', async () => {
  let release; const gate = new Promise(r => { release = r; });
  const f = hubFixture({ answer: text => (text === 'slow' ? gate.then(() => null) : 'ok') });
  const onMessage = await approvedSlack(f);
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'stop' }); assert.match(f.sent.at(-1)[2], /Nothing is running/);
  const slow = onMessage({ senderId: 'U1', chatId: 'D1', text: 'slow' }); await new Promise(r => setImmediate(r));
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'Cancel.' });
  assert.deepEqual(f.stopped, ['bot-1']); assert.equal(f.sent.at(-1)[2], 'Stopped.'); release(); await slow;
  assert.deepEqual(f.asked.map(x => x[1]), ['slow']);
});

test('you can mark yourself as the owner, rename a person, and change the channel settings', async () => {
  const f = hubFixture(); const onMessage = await approvedSlack(f, { me: true });
  assert.equal(f.hub.status().channels.slack.approved[0].me, true);
  assert.equal(f.hub.owner('slack').person.id, 'U1');
  await f.hub.setPerson('slack', 'U1', { name: 'Sam Rivera' });
  await onMessage({ senderId: 'U1', chatId: 'D1', text: 'hello' });
  assert.equal(f.asked[0][2].senderName, 'Sam Rivera'); assert.equal(f.asked[0][2].me, true);
  await assert.rejects(f.hub.setPerson('slack', 'nobody', {}), /not approved/);
  assert.equal(f.hub.status().settings.fast, true);
  await f.hub.setSettings({ fast: false, quietStart: 23, escalateMinutes: 999 });
  assert.deepEqual([f.hub.status().settings.fast, f.hub.status().settings.quietStart, f.hub.status().settings.escalateMinutes], [false, 23, 120]);
});

test('Telegram, Discord and Slack hand pictures to the hub, and Slack accepts file shares', async () => {
  const got = [];
  const tg = new TelegramChannel({ fields: { token: 't' }, handlers: { onMessage: m => got.push(m) }, fetchImpl: async (url, init) => json({ ok: true, result: JSON.parse(init.body).file_id ? { file_path: 'photos/1.jpg' } : [] }) });
  const media = tg.mediaOf({ photo: [{ file_id: 'small', file_size: 1 }, { file_id: 'big', file_size: 9 }], document: { file_id: 'doc', mime_type: 'application/pdf' } });
  assert.equal(media.length, 1); assert.deepEqual(await media[0].resolve(), { url: 'https://api.telegram.org/file/bott/photos/1.jpg', headers: {} });
  const dc = new DiscordChannel({ fields: { token: 't' }, handlers: { onMessage: m => got.push(m) } }); dc.userId = 'bot';
  dc.message({ author: { id: 'u', username: 'sam' }, channel_id: 'c', content: '', attachments: [{ url: 'https://cdn.example/a.png', content_type: 'image/png', size: 5, filename: 'a.png' }, { url: 'https://cdn.example/b.pdf', content_type: 'application/pdf' }] });
  assert.equal(got.at(-1).media.length, 1); assert.equal(got.at(-1).text, '');
  const sl = new SlackChannel({ fields: { botToken: 'xoxb-9', appToken: 'xapp' }, handlers: { onMessage: m => got.push(m) } }); sl.userId = 'UBOT';
  sl.handle({ type: 'events_api', payload: { event_id: 'E1', event: { type: 'message', channel_type: 'im', subtype: 'file_share', user: 'U1', channel: 'D1', text: '', files: [{ url_private: 'https://files.slack.com/x.png', mimetype: 'image/png', name: 'x.png' }] } } });
  assert.equal(got.at(-1).media[0].headers.Authorization, 'Bearer xoxb-9');
});
