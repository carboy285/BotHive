'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { WebAccess, hashPassword } = require('./web-access.cjs');
const { RemoteBackend } = require('./remote-backend.cjs');

async function pair() {
  const invoked = [];
  const web = new WebAccess({
    invoke: async (channel, args) => { invoked.push([channel, args]); return { ok: true, value: { channel, args } }; },
    config: () => ({ username: 'admin', passwordHash: hashPassword('a-long-password-1') }),
    hostName: () => 'Test Box', appRequest: async () => ({ status: 200, body: '' }),
    rendererDir: path.resolve(__dirname, '../renderer'), preloadFile: path.join(__dirname, 'preload.cjs'),
  });
  const port = await web.start({ port: 0 });
  const events = []; let changes = 0;
  const backend = new RemoteBackend({ onEvent: (channel, value) => events.push([channel, value]), onChange: () => { changes++; } });
  return { web, backend, events, invoked, address: `http://127.0.0.1:${port}`, changes: () => changes };
}

test('sign in, then the window’s calls run on the server and its events come back', async () => {
  const { web, backend, events, invoked, address, changes } = await pair();
  try {
    await assert.rejects(backend.connect(address, 'admin', 'wrong-password-1'), /don’t match/);
    assert.equal(backend.active, false);
    const status = await backend.connect(address, 'admin', 'a-long-password-1');
    assert.deepEqual(status, { active: true, name: 'Test Box', url: address });
    assert.equal(changes(), 1);
    assert.deepEqual(await backend.invoke('workspace:load', []), { ok: true, value: { channel: 'workspace:load', args: [] } });
    assert.deepEqual(await backend.invoke('chat:send', ['bot-1', 'hello']), { ok: true, value: { channel: 'chat:send', args: ['bot-1', 'hello'] } });
    assert.deepEqual(invoked.at(-1), ['chat:send', ['bot-1', 'hello']]);
    assert.equal((await backend.invoke('vault:read', [])).ok, false, 'host-only calls are not available over a server');
    await new Promise(resolve => setTimeout(resolve, 150));
    web.broadcast('workspace:changed', { workspace: { bots: [] }, running: ['b'] });
    for (let i = 0; i < 40 && !events.length; i++) await new Promise(resolve => setTimeout(resolve, 50));
    assert.deepEqual(events, [['workspace:changed', { workspace: { bots: [] }, running: ['b'] }]]);
    backend.disconnect();
    assert.equal(backend.active, false); assert.equal(changes(), 2);
    assert.equal((await backend.invoke('workspace:load', [])).ok, false);
  } finally { backend.disconnect(false); await web.stop(); }
});

test('a server that is not there or has Web access off gives a clear message', async () => {
  const backend = new RemoteBackend({ onEvent() {} });
  await assert.rejects(backend.connect('http://127.0.0.1:9', 'admin', 'x'), /Could not reach 127.0.0.1:9/);
  await assert.rejects(backend.connect('ftp://x.example.com', 'a', 'b'), /https:\/\/ or http:\/\//);
});

test('when the server forgets the sign-in the window is let go of', async () => {
  const { web, backend, address } = await pair();
  try {
    await backend.connect(address, 'admin', 'a-long-password-1');
    web.signOutEverywhere();
    const answer = await backend.invoke('workspace:load', []);
    assert.equal(answer.ok, false); assert.match(answer.error, /no longer knows this sign-in/);
    assert.equal(backend.active, false);
  } finally { backend.disconnect(false); await web.stop(); }
});

test('an older Bothive that has no app sign-in is named as old, not as a wrong password', async () => {
  const http = require('node:http');
  const old = http.createServer((req, res) => { res.writeHead(401, { 'Content-Type': 'application/json' }); res.end('{"ok":false,"error":"Sign in again."}'); });
  await new Promise(resolve => old.listen(0, '127.0.0.1', resolve));
  try {
    const backend = new RemoteBackend({ onEvent() {} });
    await assert.rejects(backend.connect(`http://127.0.0.1:${old.address().port}`, 'admin', 'a-long-password-1'), /older Bothive/);
  } finally { old.close(); }
});
