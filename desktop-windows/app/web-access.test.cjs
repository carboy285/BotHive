'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { WebAccess, hashPassword } = require('./web-access.cjs');

async function server(extra = {}) {
  const calls = [];
  const web = new WebAccess({
    invoke: async () => ({ ok: true, value: null }),
    config: () => ({ username: 'admin', passwordHash: hashPassword('a-long-password-1') }),
    hostName: () => 'Test Box',
    appRequest: async request => { calls.push(request); if (request.target === '/boom') throw Object.assign(new Error('x'), { publicMessage: 'Nope.' }); return { status: 200, body: Buffer.from('{"ok":true}').toString('base64') }; },
    rendererDir: path.resolve(__dirname, '../renderer'), preloadFile: path.join(__dirname, 'preload.cjs'), ...extra,
  });
  const port = await web.start({ port: 0 });
  const base = `http://127.0.0.1:${port}`;
  const post = (url, body, headers = {}) => fetch(base + url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });
  return { web, calls, base, post };
}

test('an app signs in with the web access login and gets a token', async () => {
  const { web, post } = await server();
  try {
    const bad = await post('/api/app/login', { username: 'admin', password: 'wrong-password-1' });
    assert.equal(bad.status, 401);
    const good = await post('/api/app/login', { username: 'admin', password: 'a-long-password-1' });
    assert.equal(good.status, 200);
    const body = await good.json();
    assert.equal(body.ok, true); assert.match(body.token, /^[A-Za-z0-9_-]{43}$/); assert.equal(body.name, 'Test Box');
  } finally { await web.stop(); }
});

test('requests need that token and are answered by the host in the relay shape', async () => {
  const { web, calls, post } = await server();
  try {
    const request = { method: 'GET', target: '/v1/state', body: '' };
    assert.equal((await post('/api/app/request', request)).status, 401, 'no token');
    assert.equal((await post('/api/app/request', request, { Authorization: 'Bearer ' + 'a'.repeat(43) })).status, 401, 'unknown token');
    const { token } = await (await post('/api/app/login', { username: 'admin', password: 'a-long-password-1' })).json();
    const answer = await post('/api/app/request', request, { Authorization: 'Bearer ' + token });
    assert.equal(answer.status, 200);
    assert.deepEqual(await answer.json(), { status: 200, body: Buffer.from('{"ok":true}').toString('base64') });
    assert.deepEqual(calls, [request]);
    const failed = await post('/api/app/request', { method: 'GET', target: '/boom' }, { Authorization: 'Bearer ' + token });
    assert.equal(failed.status, 409); assert.equal((await failed.json()).error, 'Nope.');
  } finally { await web.stop(); }
});

test('the app token works for the window\u2019s calls but not for host-only ones, and five wrong tries slow sign-in down', async () => {
  const { web, post } = await server();
  try {
    const { token } = await (await post('/api/app/login', { username: 'admin', password: 'a-long-password-1' })).json();
    const headers = { Authorization: 'Bearer ' + token, 'X-OGB-Request': '1' };
    assert.equal((await post('/api/invoke', { channel: 'workspace:load', args: [] }, headers)).status, 200);
    assert.equal((await post('/api/invoke', { channel: 'vault:read', args: [] }, headers)).status, 403, 'secrets stay on the host');
    assert.equal((await post('/api/invoke', { channel: 'workspace:load', args: [] }, { 'X-OGB-Request': '1' })).status, 401, 'no token, no cookie');
    for (let i = 0; i < 5; i++) await post('/api/app/login', { username: 'admin', password: 'wrong-password-' + i });
    assert.equal((await post('/api/app/login', { username: 'admin', password: 'a-long-password-1' })).status, 429);
  } finally { await web.stop(); }
});
