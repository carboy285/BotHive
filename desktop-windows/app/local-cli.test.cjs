const {test}=require('node:test');const assert=require('node:assert/strict');const {EventParser,command}=require('./local-cli.cjs');
test('parses Unicode streaming replies without duplicating completed messages',()=>{
 const parser=new EventParser();let events=parser.parse(JSON.stringify({type:'thread.started',thread_id:'session-test'}));assert.equal(events[0].id,'session-test');
 parser.parse(JSON.stringify({type:'item.updated',item:{id:'one',type:'agent_message',text:'Hello 🌎'}}));parser.parse(JSON.stringify({type:'item.completed',item:{id:'one',type:'agent_message',text:'Hello 🌎'}}));assert.equal(parser.text,'Hello 🌎');
 const claude=new EventParser();claude.parse(JSON.stringify({type:'stream_event',event:{delta:{type:'text_delta',text:'reply'}}}));claude.parse(JSON.stringify({type:'result',result:'reply'}));assert.equal(claude.text,'reply');
 const open=new EventParser();open.parse(JSON.stringify({type:'text',sessionID:'session-open',part:{id:'p',text:'OpenCode'}}));assert.equal(open.text,'OpenCode');
 const gemini=new EventParser();gemini.parse(JSON.stringify({type:'message',role:'assistant',content:'Gemini',delta:true}));assert.equal(gemini.text,'Gemini');
});
test('commands preserve per-provider sessions without approval bypass flags',()=>{for(const id of ['codex','claude','grok','opencode','gemini']){const args=command(id,'saved-session','private-prompt.txt');assert.ok(args.includes('saved-session'));assert.ok(!args.some(x=>/dangerously|yolo|auto-approve/.test(x)));}});

test('Claude Code reports connected-apps problems and only pre-approves the connected-apps server when asked', () => {
  const { EventParser, command, CONNECTED_APPS_SERVER } = require('./local-cli.cjs');
  assert.equal(CONNECTED_APPS_SERVER, 'opengrokbot-composio');
  const failed = new EventParser().parse(JSON.stringify({ type: 'system', subtype: 'init', session_id: 'abc', mcp_servers: [{ name: 'opengrokbot-composio', status: 'failed' }] }));
  assert.ok(failed.some(e => e.type === 'notice' && /failed/.test(e.text) && /Refresh connections/.test(e.text)));
  const fine = new EventParser().parse(JSON.stringify({ type: 'system', subtype: 'init', session_id: 'abc', mcp_servers: [{ name: 'opengrokbot-composio', status: 'connected' }, { name: 'other', status: 'failed' }] }));
  assert.ok(!fine.some(e => e.type === 'notice'));
  const blocked = new EventParser().parse(JSON.stringify({ type: 'result', result: 'could not', permission_denials: [{ tool_name: 'mcp__opengrokbot-composio__COMPOSIO_SEARCH_TOOLS' }] }));
  assert.ok(blocked.some(e => e.type === 'notice' && /Let Claude Code use connected apps/.test(e.text)));
  assert.ok(!new EventParser().parse(JSON.stringify({ type: 'result', result: 'ok', permission_denials: [{ tool_name: 'Bash' }] })).some(e => e.type === 'notice'));
  assert.ok(!command('claude', null, 'p.txt').includes('--allowedTools'));
  const on = command('claude', null, 'p.txt', '', { allowConnectedApps: true });
  assert.equal(on[on.indexOf('--allowedTools') + 1], 'mcp__opengrokbot-composio');
  assert.ok(!command('codex', null, 'p.txt', '', { allowConnectedApps: true }).includes('--allowedTools'));
});

test('Codex answers sent in pieces stream into the chat, then the final text wins', () => {
  const { EventParser } = require('./local-cli.cjs');
  const parser = new EventParser();
  const texts = [];
  for (const line of [
    '{"type":"item.agent_message.delta","item_id":"m1","delta":"Hello"}',
    '{"type":"item.agent_message.delta","item_id":"m1","delta":" there."}',
    '{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"Hello there!"}}'
  ]) for (const event of parser.parse(line)) if (event.type === 'text') texts.push(event.text);
  assert.deepEqual(texts, ['Hello', 'Hello there.', 'Hello there!']);
  assert.equal(parser.text, 'Hello there!');
});

test('Claude Code gets Bothive tools pre-approved alongside connected apps (10.2)', () => {
  const { command } = require('./local-cli.cjs');
  const both = command('claude', 'session-1', 'p.txt', 'sonnet', { allowConnectedApps: true, tools: true });
  const at = both.indexOf('--allowedTools');
  assert.deepEqual(both.slice(at + 1, at + 3), ['mcp__opengrokbot-composio', 'mcp__bothive']);
  assert.equal(both[at + 3], '--resume', 'the list ends before the next flag');
  const toolsOnly = command('claude', null, 'p.txt', '', { tools: true });
  assert.deepEqual(toolsOnly.slice(toolsOnly.indexOf('--allowedTools') + 1), ['mcp__bothive']);
  assert.ok(!command('codex', null, 'p.txt', '', { tools: true }).includes('--allowedTools'));
});

test('the Claude Code MCP config names the tools token variable and never contains the token', async () => {
  const fs = require('node:fs/promises'), os = require('node:os'), path = require('node:path');
  const { configure } = require('./mcp-config.cjs');
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'bothive-tools-'));
  const tools = { url: 'http://127.0.0.1:43210/mcp', token: 'secret-token-abcdefghijklmnopqrstuvwxyz' };
  const result = await configure('claude', dir, null, tools);
  const file = result.arguments[result.arguments.indexOf('--mcp-config') + 1];
  const body = await fs.readFile(file, 'utf8');
  assert.ok(!body.includes(tools.token), 'the token is not written to disk');
  assert.deepEqual(JSON.parse(body).mcpServers.bothive, { type: 'http', url: tools.url, headers: { Authorization: 'Bearer ${OPENGROKBOT_TOOLS_TOKEN}' } });
  assert.equal(result.environment.OPENGROKBOT_TOOLS_TOKEN, tools.token);
  await result.cleanup();
  await assert.rejects(fs.stat(file));
  // Other CLIs and other addresses get nothing.
  assert.deepEqual((await configure('codex', dir, null, tools)).arguments, []);
  assert.deepEqual((await configure('claude', dir, null, { url: 'http://evil.example/mcp', token: 'x' })).arguments, []);
  await fs.rm(dir, { recursive: true, force: true });
});
