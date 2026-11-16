'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const servers = require('./servers.cjs');

test('addresses people type become a clean origin', () => {
  assert.deepEqual(servers.normalize('https://my-box.tailnet-name.ts.net'), { origin: 'https://my-box.tailnet-name.ts.net', host: 'my-box.tailnet-name.ts.net', https: true });
  assert.equal(servers.normalize('http://100.101.102.103:8765/').origin, 'http://100.101.102.103:8765');
  assert.equal(servers.normalize('100.101.102.103:8765').origin, 'http://100.101.102.103:8765', 'a private address with no scheme gets http');
  assert.equal(servers.normalize('192.168.1.20:8765').origin, 'http://192.168.1.20:8765');
  assert.equal(servers.normalize('my-box').origin, 'http://my-box', 'a short Tailscale name gets http');
  assert.equal(servers.normalize('bots.example.com').origin, 'https://bots.example.com', 'a public name gets https');
  assert.equal(servers.normalize('  HTTPS://Bots.Example.com  ').origin, 'https://bots.example.com');
});

test('addresses that are unsafe or wrong are refused with a reason', () => {
  const bad = ['', '   ', 'ftp://x.example.com', 'javascript:alert(1)', 'file:///etc/passwd', 'https://user:pw@x.example.com', 'https://x.example.com/page', 'https://x.example.com/?a=1',
    'https://x.example.com/#top', 'http://bots.example.com', 'http://8.8.8.8:8765', 'https://', 'x'.repeat(400)];
  for (const input of bad) assert.throws(() => servers.normalize(input), Error, input);
  assert.throws(() => servers.normalize('http://bots.example.com'), /private addresses/);
  assert.throws(() => servers.normalize('https://u:p@x.example.com'), /username and password/);
});

test('private hosts are the ones plain http may reach', () => {
  for (const host of ['100.64.0.1', '100.127.255.254', '10.0.0.5', '192.168.0.9', '172.16.1.1', '127.0.0.1', 'localhost', 'mac.local', 'box.tailnet.ts.net', 'my-box']) assert.equal(servers.privateHost(host), true, host);
  for (const host of ['8.8.8.8', '100.128.0.1', '172.32.0.1', 'example.com', 'x.y.z']) assert.equal(servers.privateHost(host), false, host);
});

test('the saved list keeps only valid entries and is capped', () => {
  const good = { id: '11111111-1111-4111-8111-111111111111', name: 'Home', url: 'https://box.ts.net' };
  const loaded = servers.load({ servers: [good, { id: 'x', name: 'bad', url: 'https://a.b' }, { ...good, id: '22222222-2222-4222-8222-222222222222', url: 'https://a.example.com/page' }, null] });
  assert.deepEqual(loaded.servers, [good]);
  const many = Array.from({ length: 40 }, (_, i) => ({ id: `${String(i).padStart(8, '0')}-1111-4111-8111-111111111111`, name: 'n' + i, url: 'https://box.ts.net' }));
  assert.equal(servers.load({ servers: many }).servers.length, servers.MAX_SERVERS);
  assert.equal(servers.cleanName('  Home\nlab  ', 'x'), 'Home lab');
  assert.equal(servers.cleanName('', 'Fallback'), 'Fallback');
});
