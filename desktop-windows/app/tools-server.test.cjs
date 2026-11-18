'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createToolsServer, note, CATALOG } = require('./tools-server.cjs');

async function withServer(options, body) {
  const calls = [];
  const server = createToolsServer({ run: async (action, context) => { calls.push({ action, context }); return options.reply ? options.reply(action) : 'ok: ' + action.action; }, available: options.available, version: '10.2.0' });
  await server.start();
  try { await body(server, calls); } finally { await server.stop(); }
}
const rpc = async (url, token, message, headers = {}) => {
  const response = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...headers }, body: JSON.stringify(message) });
  const raw = await response.text();
  return { status: response.status, body: raw ? JSON.parse(raw) : null };
};

test('the MCP handshake, tool list and a tool call, bound to one Bot', async () => {
  await withServer({}, async (server, calls) => {
    const { token, url, revoke } = server.grant({ botID: 'b1', botName: 'Hive', unattended: false });
    assert.match(url, /^http:\/\/127\.0\.0\.1:\d+\/mcp$/);
    const init = await rpc(url, token, { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'claude-code', version: '2' } } });
    assert.equal(init.status, 200);
    assert.equal(init.body.result.protocolVersion, '2025-06-18');
    assert.equal(init.body.result.serverInfo.name, 'bothive');
    assert.equal((await rpc(url, token, { jsonrpc: '2.0', method: 'notifications/initialized' })).status, 202);
    const list = await rpc(url, token, { jsonrpc: '2.0', id: 2, method: 'tools/list' });
    assert.deepEqual(list.body.result.tools.map(x => x.name), ['search_web', 'read_feed', 'search_knowledge', 'read_knowledge'], 'no channel tools without channels');
    const call = await rpc(url, token, { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'search_web', arguments: { query: 'weather' } } });
    assert.deepEqual(call.body.result, { content: [{ type: 'text', text: 'ok: search_web' }], isError: false });
    assert.deepEqual(calls[0], { action: { text: 'weather', action: 'search_web' }, context: { botID: 'b1', botName: 'Hive', unattended: false } });
    // A tool cannot be called with the action name of another one.
    await rpc(url, token, { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'read_knowledge', arguments: { file: 'notes.md', part: 2, action: 'secure_login' } } });
    assert.deepEqual(calls[1].action, { text: 'notes.md', part: 2, action: 'read_knowledge' });
    revoke();
    assert.equal((await rpc(url, token, { jsonrpc: '2.0', id: 5, method: 'tools/list' })).status, 401, 'the token stops working when the run ends');
  });
});

test('refuses requests without the token, from a browser page, or for another host name', async () => {
  await withServer({}, async server => {
    const { token, url } = server.grant({ botID: 'b1' });
    assert.equal((await rpc(url, null, { jsonrpc: '2.0', id: 1, method: 'tools/list' })).status, 401);
    assert.equal((await rpc(url, 'x'.repeat(32), { jsonrpc: '2.0', id: 1, method: 'tools/list' })).status, 401);
    assert.equal((await rpc(url, token, { jsonrpc: '2.0', id: 1, method: 'tools/list' }, { Origin: 'https://evil.example' })).status, 403);
    const http = require('node:http');
    const status = await new Promise(resolve => { const request = http.request({ host: '127.0.0.1', port: server.port, path: '/mcp', method: 'POST', headers: { Host: 'evil.example', Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' } }, response => { response.resume(); resolve(response.statusCode); }); request.end('{}'); });
    assert.equal(status, 403, 'DNS rebinding is refused');
    assert.equal((await fetch(url, { headers: { Authorization: 'Bearer ' + token } })).status, 405, 'no server stream');
  });
});

test('channel tools only for the channel Bot, errors come back as tool errors, unknown tools are refused', async () => {
  await withServer({ available: context => ({ channels: context.channels === true, calls: false }), reply: action => action.text === 'boom' ? { text: 'Telegram is not connected.', isError: true } : 'sent' }, async server => {
    const plain = server.grant({ botID: 'b2' }), channel = server.grant({ botID: 'b1', channels: true });
    assert.equal((await rpc(plain.url, plain.token, { jsonrpc: '2.0', id: 1, method: 'tools/list' })).body.result.tools.some(x => x.name === 'channel_send'), false);
    const tools = (await rpc(channel.url, channel.token, { jsonrpc: '2.0', id: 1, method: 'tools/list' })).body.result.tools.map(x => x.name);
    assert.ok(tools.includes('channel_send')); assert.ok(!tools.includes('phone_call'));
    const refused = await rpc(plain.url, plain.token, { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'channel_send', arguments: { channel: 'telegram', text: 'hi' } } });
    assert.equal(refused.body.error.code, -32602);
    const failed = await rpc(channel.url, channel.token, { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'channel_send', arguments: { channel: 'telegram', text: 'boom' } } });
    assert.deepEqual(failed.body.result, { content: [{ type: 'text', text: 'Telegram is not connected.' }], isError: true });
    const missing = await rpc(channel.url, channel.token, { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'channel_send', arguments: { channel: 'telegram' } } });
    assert.equal(missing.body.result.isError, true);
    assert.equal((await rpc(channel.url, channel.token, { jsonrpc: '2.0', id: 5, method: 'resources/list' })).body.error.code, -32601);
  });
});

test('every tool has a schema the CLIs accept, and the Bot is told to call them as tools', () => {
  for (const tool of CATALOG) { assert.equal(tool.inputSchema.type, 'object'); assert.ok(tool.description.length > 20); assert.match(tool.name, /^[a-z_]+$/); }
  assert.equal(note([]), '');
  assert.match(note(CATALOG.slice(0, 2)), /mcp__bothive__.*search_web, read_feed/s);
});
