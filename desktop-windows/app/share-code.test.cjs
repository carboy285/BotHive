'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const share = require('./share-code.cjs');

const bot = { id: 'b', name: 'Study Buddy', purpose: 'Helps me study.', appearance: { shape: 'star', color: 'teal' }, memory: ['secret'], schedules: [{}] };

test('a code carries the Bot and chosen skills, and nothing private', () => {
  const code = share.make(bot, [{ name: 'Cite', description: 'Sources', text: 'List sources.' }]);
  assert.ok(code.startsWith('bothive-bot:'));
  assert.ok(!Buffer.from(code.slice(12), 'base64url').toString().includes('secret'));
  assert.deepEqual(share.read(code), { name: 'Study Buddy', purpose: 'Helps me study.', color: 'teal', shape: 'star', skills: [{ name: 'Cite', description: 'Sources', text: 'List sources.' }] });
});

test('a code can sit inside a message', () => {
  const code = share.make(bot);
  assert.equal(share.read(`Hey, try this! ${code}\nThanks`).name, 'Study Buddy');
});

test('groups cannot be shared and bad codes say why', () => {
  assert.throws(() => share.make({ ...bot, memberIDs: ['x'] }), /individual/);
  assert.throws(() => share.read('hello'), /not a Bothive Bot code/);
  assert.throws(() => share.read('bothive-bot:'), /incomplete/);
  assert.throws(() => share.read('bothive-bot:@@@@'), /incomplete/);
  assert.throws(() => share.read('bothive-bot:' + Buffer.from('not json').toString('base64url')), /damaged/);
  assert.throws(() => share.read('bothive-bot:' + Buffer.from('{"v":2,"name":"x"}').toString('base64url')), /newer/);
  assert.throws(() => share.read('bothive-bot:' + Buffer.from('{"v":1,"name":"  "}').toString('base64url')), /no name/);
});

test('reading rebuilds every field with limits', () => {
  const hostile = { v: 1, name: 'A\nB'.repeat(100), purpose: 'p'.repeat(5000), color: 'javascript:', shape: '<x>', skills: [{ name: '', text: 'x' }, { name: 'ok', text: 'fine' }, ...Array(10).fill({ name: 's', text: 't' })] };
  const out = share.read('bothive-bot:' + Buffer.from(JSON.stringify(hostile)).toString('base64url'));
  assert.ok(out.name.length <= 60 && !out.name.includes('\n'));
  assert.equal(out.purpose.length, 2000);
  assert.equal(out.color, 'purple'); assert.equal(out.shape, 'hexagon');
  assert.ok(out.skills.length <= share.MAX_SKILLS); assert.equal(out.skills[0].name, 'ok');
});

test('a code that would be too large is refused', () => {
  assert.throws(() => share.make(bot, Array(5).fill({ name: 'big', description: '', text: 'x'.repeat(40000) })), /too large|too big/);
});
