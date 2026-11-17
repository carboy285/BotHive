'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { WebAccess, hashPassword } = require('./web-access.cjs');

async function server(extra = {}, admin = false) {
  const calls = [];
  const web = new WebAccess({
    invoke: async (channel, args, context) => ({ ok: true, value: { channel, admin: context?.admin === true } }),
    config: () => ({ username: 'admin', passwordHash: hashPassword('a-long-password-1'), admin }),
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
    assert.equal((await bad.json()).code, 'bad_credentials', 'a wrong password is told apart from a server that lacks the route');
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

test('settings, keys and CLI installs are for app tokens, and only while the owner turned remote administration on', async () => {
  const off = await server({}, false);
  try {
    const { token } = await (await off.post('/api/app/login', { username: 'admin', password: 'a-long-password-1' })).json();
    const headers = { Authorization: 'Bearer ' + token, 'X-OGB-Request': '1' };
    const refused = await off.post('/api/invoke', { channel: 'cli:install', args: ['claude'] }, headers);
    assert.equal(refused.status, 403); assert.match((await refused.json()).error, /Remote administration is off/);
  } finally { await off.web.stop(); }
  const on = await server({}, true);
  try {
    const { token } = await (await on.post('/api/app/login', { username: 'admin', password: 'a-long-password-1' })).json();
    const headers = { Authorization: 'Bearer ' + token, 'X-OGB-Request': '1' };
    for (const channel of ['cli:install', 'cli-keys:set', 'setup:choose', 'composio:connect', 'cloud:sign-in', 'vault:read']) {
      const answer = await on.post('/api/invoke', { channel, args: [] }, headers);
      assert.equal(answer.status, 200, channel); assert.deepEqual((await answer.json()).value, { channel, admin: true });
    }
    // Never available over a server, even for an administrator: the web access settings themselves, file pickers and backups.
    for (const channel of ['web:configure', 'web:signout', 'backup:export', 'files:attach', 'updates:install', 'cloud:delete-account']) {
      assert.equal((await on.post('/api/invoke', { channel, args: [] }, headers)).status, 403, channel);
    }
  } finally { await on.web.stop(); }
});
