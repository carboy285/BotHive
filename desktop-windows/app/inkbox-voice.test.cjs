'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { InkboxVoice, buildInstructions, INSTRUCTIONS_MAX } = require('./channel-inkbox-voice.cjs');
const { createChannelsHost } = require('./channels-host.cjs');

const json = (body, status = 200) => ({ ok: status < 400, status, json: async () => body, headers: new Map() });

function phone({ calls = [], transcripts = {} } = {}) {
  const log = [];
  const fetchImpl = async (url, options = {}) => {
    const path = url.replace('https://inkbox.ai/api/v1/phone', ''); const body = options.body ? JSON.parse(options.body) : null;
    log.push([options.method || 'GET', path, body, options.headers['X-API-Key']]);
    if (path.startsWith('/calls?')) return json(calls);
    const t = path.match(/^\/calls\/([^/]+)\/transcripts$/); if (t) return json(transcripts[t[1]] || []);
    if (path === '/place-call') return json({ id: 'new-call', status: 'initiated' });
    if (path === '/hosted-agent-voices') return json({ voices: [{ id: 'ara', name: 'Ara', available: true }, { id: 'orion', name: 'Orion', available: false }] });
    return json({ ok: true });
  };
  return { fetchImpl, log };
}

test('the call instructions carry the Bot, its summary and notes, and never pass Inkbox’s limit', () => {
  const text = buildInstructions({ botName: 'Hive', purpose: 'Runs my errands', summary: 'Sam likes tea.', memory: ['Dentist is Dr Okafor'], ownerName: 'Sam' });
  assert.match(text, /You are Hive/); assert.match(text, /Sam likes tea/); assert.match(text, /Dentist is Dr Okafor/); assert.match(text, /cannot run tools/);
  const huge = buildInstructions({ botName: 'Hive', summary: 'x'.repeat(20000), memory: Array.from({ length: 100 }, (_, i) => 'fact '.repeat(60) + i) });
  assert.ok(huge.length <= INSTRUCTIONS_MAX);
});

test('instructions are sent once, voices are listed, and a call carries the reason as its brief', async () => {
  const { fetchImpl, log } = phone(); let t = 1_000_000;
  const voice = new InkboxVoice({ fields: { apiKey: 'ik_0123456789', voice: 'ara' }, fetchImpl, now: () => t, context: () => ({ botName: 'Hive' }), setTimer: () => 1, clearTimer: () => {} });
  assert.equal(await voice.syncInstructions(), true); assert.equal(await voice.syncInstructions(), false, 'unchanged: not sent again');
  const put = log.find(x => x[0] === 'PUT'); assert.equal(put[1], '/hosted-agent-config'); assert.equal(put[2].voice, 'ara'); assert.match(put[2].instructions, /You are Hive/); assert.equal(put[3], 'ik_0123456789');
  assert.deepEqual((await voice.voices()).map(v => v.id), ['ara', 'orion']);
  await voice.placeCall('+15551234567', 'The dentist moved your appointment.');
  const call = log.find(x => x[1] === '/place-call'); assert.deepEqual(call[2], { origination: 'shared_imessage_number', to_number: '+15551234567', mode: 'hosted_agent', reason: 'The dentist moved your appointment.', on_voicemail: 'leave_message' });
  await assert.rejects(voice.placeCall('555', 'x'), /phone number/); await assert.rejects(voice.placeCall('+15551234567', ' '), /needs a reason/);
  for (let i = 0; i < 4; i++) await voice.placeCall('+15551234567', 'again ' + i);
  await assert.rejects(voice.placeCall('+15551234567', 'one too many'), /five calls/);
  t += 3600001; await voice.placeCall('+15551234567', 'later is fine');
});

test('a finished call is imported once with its transcript and action items; old calls are ignored', async () => {
  const done = { id: 'c1', status: 'completed', ended_at: '2026-03-10T12:03:42Z', started_at: '2026-03-10T12:00:42Z', direction: 'inbound', remote_phone_number: '+15551234567', reason: null, hangup_reason: 'remote', post_call_action_items: [{ action: 'Book the dentist', details: 'next week' }] };
  const old = { ...done, id: 'old' }; const calls = [old]; const timers = []; const got = [];
  const { fetchImpl } = phone({ calls, transcripts: { c1: [{ seq: 1, party: 'local', text: 'Sure.' }, { seq: 0, party: 'remote', text: 'Please book the dentist' }] } });
  const voice = new InkboxVoice({ fields: { apiKey: 'ik_0123456789' }, fetchImpl, setTimer: fn => { timers.push(fn); return timers.length; }, clearTimer: () => {}, onCall: async c => { got.push(c); } });
  await voice.start(); calls.unshift(done);
  await voice.poll(); await voice.poll();
  assert.equal(got.length, 1); assert.deepEqual(got[0].transcript, [{ party: 'person', text: 'Please book the dentist' }, { party: 'assistant', text: 'Sure.' }]);
  assert.deepEqual(got[0].items, [{ action: 'Book the dentist', details: 'next week' }]); assert.equal(got[0].seconds, 180); assert.equal(got[0].direction, 'inbound');
});

// ----- The host: reaching out first -----
const hosts = [];
test.after(async () => { for (const h of hosts) await h.stop(); });
function hostFixture({ fail = false } = {}) {
  const files = {}; const sent = []; const approvals = []; const records = []; const settled = [];
  const state = { bots: [{ id: 'hive', name: 'Hive', purpose: 'Errands', isMain: true, memory: ['likes tea'], summary: 'Sam is busy.' }, { id: 'travel', name: 'Travel', purpose: 'Trips' }], entries: [] }; const hooks = {}; const forced = []; let t = new Date('2026-03-10T14:00:00').getTime(); let running = new Set();
  const calls = []; const apiCalls = [];
  const fetchImpl = async (url, options = {}) => {
    apiCalls.push([options.method || 'GET', url.replace('https://inkbox.ai/api/v1/', ''), options.body ? JSON.parse(options.body) : null]);
    if (url.includes('/imessage/messages?')) return json([]); if (url.includes('/imessage/conversations?')) return json([]);
    if (url.includes('/imessage/messages') && options.method === 'POST') { if (fail) return json({ detail: 'imessage_connection_expired' }, 404); sent.push(JSON.parse(options.body)); return json({ status: 'sent' }); }
    if (url.includes('/phone/calls?')) return json([]); if (url.includes('/phone/hosted-agent-voices')) return json([{ id: 'ara', name: 'Ara' }]);
    if (url.includes('/phone/place-call')) { calls.push(JSON.parse(options.body)); return json({ id: 'p1' }); }
    return json({});
  };
  const host = createChannelsHost({
    loadJSON: async (n, d) => (n in files ? JSON.parse(JSON.stringify(files[n])) : d), atomicJSON: async (n, v) => { files[n] = JSON.parse(JSON.stringify(v)); },
    safeStorage: { isEncryptionAvailable: () => false }, platform: 'linux', ensureState: async () => {}, getState: () => state,
    startChat: async (id, text) => { state.entries.push({ id: require('node:crypto').randomUUID(), botID: id, kind: 'user', text, date: new Date(t).toISOString() }); running.add(id); setTimeout(() => { const reply = { id: require('node:crypto').randomUUID(), botID: id, kind: 'bot', text: 'Done: ' + text.slice(0, 40), state: 'complete', date: new Date(t).toISOString() }; state.entries.push(reply); hooks.onReply?.(text, reply); running.delete(id); }, 2); },
    isRunning: id => running.has(id), env: {}, sleep: () => new Promise(r => setTimeout(r, 1)), fetchImpl, askTimeout: 500, batchMs: 0, pollMs: 1, now: () => t,
    record: async (id, text) => { records.push(text); }, settleApproval: (id, yes) => { settled.push([id, yes]); return true; }, afterTurn: () => {}, forceMemory: async id => { forced.push(id); }, syncDelay: 1, askCheckMs: 100000,
  });
  hosts.push(host);
  return { host, files, sent, calls, apiCalls, records, settled, state, hooks, forced, advance: ms => { t += ms; }, setTime: value => { t = value; } };
}
async function setup(f, { me = true, number = '+15551234567' } = {}) {
  await f.host.init(); await f.host.hub.setBot('hive');
  await f.host.hub.configure('imessage', { apiKey: 'ik_0123456789', ownerNumber: number }); await f.host.hub.setEnabled('imessage', true);
  const onMessage = f.host.hub.adapters.get('imessage').onMessage;
  await onMessage({ senderId: number, senderName: number, chatId: 'conv-1', text: 'hi' });
  await f.host.hub.approve('imessage', f.host.hub.status().channels.imessage.pending[0].code, { me });
  f.sent.length = 0; f.apiCalls.length = 0;
  return onMessage;
}

test('ask_owner texts the person marked Me, trims a cold first message, and remembers the question', async () => {
  const f = hostFixture(); await setup(f);
  const note = f.host.note('hive'); assert.match(note, /ask_owner/);
  const result = await f.host.askOwner('hive', { action: 'ask_owner', text: 'Should I book the 3pm slot at https://dentist.example or the 5pm? Call 555-123-4567 if you want to change it later, and tell me which one you prefer so I can confirm it today.', urgent: true });
  assert.match(result, /Asked .* on iMessage/);
  assert.ok(f.sent[0].text.length <= 159 && !/https|555-123/.test(f.sent[0].text), 'first message: short, no link, no number');
  assert.equal(f.host.hub.pendingAsk.urgent, true);
  assert.equal(f.host.status().inkbox.pendingAsk.question.slice(0, 20), 'Should I book the 3p');
});

test('the owner’s next message is tagged as the answer; a friend’s message is not', async () => {
  const f = hostFixture(); const onMessage = await setup(f);
  await f.host.askOwner('hive', { action: 'ask_owner', text: 'Which slot?' });
  const asked = []; const original = f.host.hub.deps.ask; f.host.hub.deps.ask = (...args) => { asked.push(args); return original(...args); };
  await onMessage({ senderId: '+15551234567', senderName: 'Sam', chatId: 'conv-1', text: 'the 5pm one' });
  assert.equal(asked[0][2].replyTo, 'Which slot?'); assert.equal(f.host.hub.pendingAsk, null);
  assert.match(f.state.entries.find(e => e.kind === 'user' && /5pm/.test(e.text)).text, /answers the question you asked them: “Which slot\?”/);
});

test('without a Me person the Bot is told how to fix it, and limits apply', async () => {
  const f = hostFixture(); await setup(f, { me: false });
  await assert.rejects(f.host.askOwner('hive', { text: 'hello?' }), /tick Me/);
  assert.doesNotMatch(f.host.note('hive'), /ask_owner/);
  const g = hostFixture(); await setup(g);
  for (let i = 0; i < 5; i++) await g.host.askOwner('hive', { text: 'q' + i });
  await assert.rejects(g.host.askOwner('hive', { text: 'q6' }), /as many messages/);
});

test('when Inkbox refuses the text, an urgent question becomes a call, and a plain one explains what to do', async () => {
  const f = hostFixture({ fail: true }); await setup(f);
  await assert.rejects(f.host.askOwner('hive', { text: 'Can you talk?' }), /text the Bot once first/);
  const result = await f.host.askOwner('hive', { text: 'Can you talk?', urgent: true });
  assert.match(result, /Phoned/); assert.equal(f.calls[0].to_number, '+15551234567'); assert.match(f.calls[0].reason, /Can you talk\?/);
});

test('an urgent question nobody answers is escalated to a call after the wait, never in quiet hours', async () => {
  const f = hostFixture(); await setup(f);
  await f.host.askOwner('hive', { text: 'Server is down, restart it?', urgent: true });
  await f.host.checkAsks(); assert.equal(f.calls.length, 0, 'not yet');
  f.advance(11 * 60000); await f.host.checkAsks(); assert.equal(f.calls.length, 1); assert.match(f.calls[0].reason, /Server is down/);
  await f.host.checkAsks(); assert.equal(f.calls.length, 1, 'once');
  const q = hostFixture(); await setup(q); q.setTime(new Date('2026-03-10T23:30:00').getTime());
  await q.host.askOwner('hive', { text: 'Late question', urgent: true }); q.sent.length = 0; q.advance(11 * 60000); await q.host.checkAsks();
  assert.equal(q.calls.length, 0, 'quiet hours: no call'); assert.match(q.sent[0].text, /Still need your answer/);
});

test('approval prompts go to the owner’s chat, only the owner’s yes counts, and the answer settles the prompt', async () => {
  const f = hostFixture(); const onMessage = await setup(f);
  assert.equal(await f.host.routeApproval({ id: 'ap-1', title: 'Add 6 reminders', detail: 'Buy milk, …' }), true);
  assert.match(f.sent[0].text, /Needs your OK: Add 6 reminders/);
  await onMessage({ senderId: '+15551234567', senderName: 'Sam', chatId: 'conv-1', text: 'yes' });
  assert.deepEqual(f.settled, [['ap-1', true]]); assert.match(f.sent.at(-1).text, /Approved/);
  await onMessage({ senderId: '+15551234567', senderName: 'Sam', chatId: 'conv-1', text: 'yes' });
  assert.equal(f.settled.length, 1, 'a stray yes does nothing');
  const g = hostFixture(); await setup(g, { me: false }); assert.equal(await g.host.routeApproval({ id: 'ap-2', title: 'x', detail: '' }), false, 'nobody is marked Me');
});

test('a finished call lands in the chat, and what was left to do goes to the Bot', async () => {
  const f = hostFixture(); await setup(f);
  const texts = []; f.host.hub.send = async (channel, chat, text) => { texts.push(text); };
  const importer = f.host.inkbox; assert.ok(importer);
  await importer.onCall({ id: 'c9', direction: 'inbound', number: '+15551234567', reason: '', status: 'completed', seconds: 95, outcome: 'remote', transcript: [{ party: 'person', text: 'Book the dentist' }, { party: 'assistant', text: 'I will follow up.' }], items: [{ action: 'Book the dentist', details: '' }] });
  assert.match(f.records[0], /\[Phone call · .*\] They phoned you, 2 min/); assert.match(f.records[0], /Book the dentist/);
  const turn = f.state.entries.find(e => e.kind === 'user' && /Left to do/.test(e.text)).text;
  assert.match(turn, /Book the dentist/); assert.match(turn, /full transcript/); assert.equal(texts.length, 1); assert.deepEqual(f.forced, ['hive']);
});

const until = async check => { for (let i = 0; i < 200 && !check(); i++) await new Promise(r => setTimeout(r, 5)); };

test('every call becomes a turn for the Bot with the whole transcript, even with nothing left to do', async () => {
  const f = hostFixture(); await setup(f);
  await f.host.inkbox.onCall({ id: 'c10', direction: 'outbound', number: '+15551234567', reason: 'Check in', status: 'completed', seconds: 40, outcome: 'remote', transcript: [{ party: 'person', text: 'Dinner is at 7 on Friday' }], items: [] });
  const turn = f.state.entries.find(e => e.kind === 'user' && /Automatic follow-up after a phone call/.test(e.text));
  assert.ok(turn, 'the Bot gets a turn'); assert.match(turn.text, /Dinner is at 7 on Friday/); assert.match(turn.text, /voice assistant spoke for you/);
  assert.equal(f.sent.length, 1, 'the recap is texted'); assert.deepEqual(f.forced, ['hive'], 'the summary is refreshed right away');
});

test('when the Bot hands work to another Bot, the answer comes back to the person', async () => {
  const f = hostFixture(); const onMessage = await setup(f);
  f.hooks.onReply = (text, reply) => { if (/plan a trip/.test(text)) f.state.teamMessages = [{ id: 'm1', rootID: reply.id, from: 'hive', to: 'travel', text: 'Find flights', depth: 1, status: 'running' }]; };
  await onMessage({ senderId: '+15551234567', senderName: 'Sam', chatId: 'conv-1', text: 'plan a trip to Rome' });
  assert.equal(f.sent.length, 1, 'the first answer');
  await f.host.afterReply('hive', { text: 'x', origin: 'app' }); assert.equal(f.sent.length, 1, 'nothing while Travel works');
  f.hooks.onReply = null;
  f.state.teamMessages[0].status = 'complete';
  f.state.entries.push({ id: 'res', botID: 'hive', kind: 'bot', senderBotID: 'travel', senderName: 'Travel', text: 'Flights to Rome are $300', state: 'complete', date: new Date(Date.now() + 1e10).toISOString() });
  await f.host.afterReply('travel', { text: 'Flights to Rome are $300', origin: 'delivery' });
  await until(() => f.sent.length === 2);
  const followUp = f.state.entries.filter(e => e.kind === 'user').at(-1).text;
  assert.match(followUp, /The Bots you asked have finished/); assert.match(followUp, /Travel: Flights to Rome are \$300/);
  assert.equal(f.sent[1].conversation_id, 'conv-1'); assert.match(f.sent[1].text, /^Done:/);
});

test('"Where replies go": a text gets a text, app messages stay in the app, scheduled tasks text you, or everything does', async () => {
  const f = hostFixture(); await setup(f);
  assert.equal(await f.host.afterReply('hive', { text: 'From the app', origin: 'app' }), false);
  assert.equal(await f.host.afterReply('hive', { text: 'Already answered', origin: 'channel' }), false);
  assert.equal(await f.host.afterReply('travel', { text: 'Other Bot', origin: 'scheduled' }), false);
  assert.equal(await f.host.afterReply('hive', { text: 'Your morning summary', origin: 'scheduled' }), true);
  assert.equal(f.sent.at(-1).text, 'Your morning summary');
  await f.host.hub.setSettings({ replies: 'always' });
  assert.equal(await f.host.afterReply('hive', { text: 'Typed in the app', origin: 'app' }), true);
  assert.equal(f.sent.at(-1).text, 'Typed in the app');
  assert.equal(await f.host.afterReply('hive', { text: '', origin: 'app' }), false);
  await assert.rejects(f.host.hub.setSettings({ replies: 'sometimes' }), /where replies go/);
});

test('the first person approved is the owner unless one is already set, and older setups are fixed', async () => {
  const f = hostFixture(); await f.host.init(); await f.host.hub.setBot('hive');
  await f.host.hub.configure('imessage', { apiKey: 'ik_0123456789', ownerNumber: '+15551234567' }); await f.host.hub.setEnabled('imessage', true);
  const onMessage = f.host.hub.adapters.get('imessage').onMessage;
  await onMessage({ senderId: '+15551234567', senderName: 'Sam', chatId: 'c1', text: 'hi' });
  await onMessage({ senderId: '+15559998888', senderName: 'Ann', chatId: 'c2', text: 'hi' });
  for (const p of f.host.hub.status().channels.imessage.pending) await f.host.hub.approve('imessage', p.code);
  assert.deepEqual(f.host.hub.status().channels.imessage.approved.map(p => p.me), [true, false]);
  const { ChannelHub } = require('./channel-hub.cjs');
  const old = new ChannelHub({ load: async () => ({ bot: 'hive', channels: {}, approved: { telegram: [{ id: '7', name: 'Sam', chatId: '7', at: 1 }] }, pending: {} }), save: async () => {}, makeAdapter: () => ({}), ask: async () => '', botExists: () => true });
  await old.init(); assert.equal(old.owner().person.id, '7');
});
