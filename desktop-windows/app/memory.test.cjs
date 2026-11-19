'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { mkdtempSync, readFileSync, existsSync } = require('node:fs');
const os = require('node:os'), path = require('node:path');
const { createMemory, rankEntries, parsePass, passPrompt, MERGE_AT, MERGE_TO, ARCHIVE_AT, ARCHIVE_MOVE } = require('./memory.cjs');
const B1 = '11111111-1111-4111-8111-111111111111';
const { validateWorkspace } = require('./workspace.cjs');

function fixture({ messages = 12, memory = [], reply } = {}) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'memory-'));
  const state = { version: 2, bots: [{ id: B1, name: 'Hive', purpose: 'x', color: 'white', isMain: true, memory }], entries: [], sessions: {} };
  for (let i = 0; i < messages; i++) state.entries.push({ id: 'e' + i, botID: B1, kind: i % 2 ? 'bot' : 'user', text: i % 2 ? 'ok ' + i : `[iMessage · Sam] message ${i} my dentist is Dr Okafor`, date: '2026-03-' + String(10 + (i % 9)).padStart(2, '0'), state: 'complete' });
  const prompts = []; let saves = 0;
  const memoryModule = createMemory({
    getState: () => state, persist: async () => { saves++; }, archivePath: id => path.join(dir, id + '.jsonl'),
    quickTurn: async (botID, prompt) => { prompts.push(prompt); return typeof reply === 'function' ? reply(prompt) : (reply ?? '{"summary":"Sam is a dentist patient.","remember":["Sam’s dentist is Dr Okafor"]}'); },
  });
  return { memory: memoryModule, state, prompts, dir, saves: () => saves };
}

test('a summary and lasting facts are written once ten new messages have piled up, and only then', async () => {
  const quiet = fixture({ messages: 9 }); assert.equal(await quiet.memory.noteActivity(B1), false); assert.equal(quiet.prompts.length, 0);
  const f = fixture({ messages: 12 });
  assert.equal(await f.memory.noteActivity(B1), true);
  const bot = f.state.bots[0];
  assert.equal(bot.summary, 'Sam is a dentist patient.'); assert.deepEqual(bot.memory, ['Sam’s dentist is Dr Okafor']); assert.equal(bot.summaryAt, 'e11');
  assert.equal(await f.memory.noteActivity(B1), false, 'nothing new since the last pass');
  assert.match(f.prompts[0], /message 10 my dentist/); assert.doesNotMatch(f.prompts[0], /"memory":\[/);
  assert.doesNotThrow(() => validateWorkspace(f.state));
});

test('a bad reply from the model changes nothing, and duplicate facts are not added twice', async () => {
  const bad = fixture({ reply: 'sorry, I cannot do that' }); assert.equal(await bad.memory.runPass(B1), false); assert.equal(bad.state.bots[0].summary, undefined);
  const dup = fixture({ memory: ['Sam’s dentist is Dr Okafor'] }); await dup.memory.runPass(B1); assert.equal(dup.state.bots[0].memory.length, 1);
  assert.deepEqual(parsePass('Here you go: {"summary":"S","remember":["a",5,"  b  "]} done'), { summary: 'S', remember: ['a', 'b'], memory: null });
});

test('at 90 notes the pass asks for them to be merged down, and the result is used', async () => {
  const many = Array.from({ length: MERGE_AT }, (_, i) => 'fact number ' + i);
  const f = fixture({ memory: many, reply: JSON.stringify({ summary: 's', remember: ['new one'], memory: many.slice(0, 40) }) });
  assert.match(passPrompt(f.state.bots[0], []), /"memory":\["..."\]/);
  await f.memory.runPass(B1);
  assert.equal(f.state.bots[0].memory.length, 41); assert.ok(f.state.bots[0].memory.length <= MERGE_TO);
  const full = fixture({ memory: Array.from({ length: 100 }, (_, i) => 'n' + i), reply: '{"summary":"s","remember":["one more"]}' });
  await full.memory.runPass(B1); assert.equal(full.state.bots[0].memory.length, 100, 'never past the limit');
});

test('recall finds old messages from any channel, ranked, and tags where they came from', async () => {
  const f = fixture({ messages: 4 });
  f.state.entries.push({ id: 'x1', botID: B1, kind: 'user', text: '[Telegram · Sam] the plumber Marta charges 80 an hour', date: '2026-01-02', state: 'complete' },
    { id: 'x2', botID: B1, kind: 'user', text: '[Slack · Lee] lunch is at noon', date: '2026-01-03', state: 'complete' },
    { id: 'x3', botID: '22222222-2222-4222-8222-222222222222', kind: 'user', text: 'plumber from a different Bot', date: '2026-01-04', state: 'complete' });
  const text = await f.memory.recall(B1, 'what did the plumber charge');
  assert.match(text, /2026-01-02 · Telegram · Sam · the plumber Marta/); assert.doesNotMatch(text, /different Bot|lunch/);
  assert.match(await f.memory.recall(B1, 'zebra giraffe'), /nothing found/);
  assert.deepEqual(rankEntries('', [{ text: 'a' }]), []);
});

test('near the entry limit the oldest messages move to an archive that recall still searches', async () => {
  const f = fixture({ messages: 0 });
  for (let i = 0; i < ARCHIVE_AT + 5; i++) f.state.entries.push({ id: 'n' + i, botID: B1, kind: 'user', text: i === 3 ? 'the safe code word is pineapple' : 'filler ' + i, date: '2026-02-01', state: 'complete' });
  assert.equal(await f.memory.archiveIfNeeded(), ARCHIVE_MOVE);
  assert.equal(f.state.entries.length, ARCHIVE_AT + 5 - ARCHIVE_MOVE); assert.ok(f.state.entries.length < 10000);
  assert.ok(existsSync(path.join(f.dir, B1 + '.jsonl')));
  assert.match(await f.memory.recall(B1, 'pineapple code word'), /pineapple/);
  assert.equal(await f.memory.archiveIfNeeded(), 0);
});

test('a Bot with a summary is valid, an oversized one is refused', () => {
  const f = fixture({ messages: 0 }); f.state.bots[0].summary = 'x'.repeat(6000); assert.doesNotThrow(() => validateWorkspace(f.state));
  f.state.bots[0].summary = 'x'.repeat(6001); assert.throws(() => validateWorkspace(f.state), /Invalid Bot summary/);
});
