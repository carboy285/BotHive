'use strict';
// iMessage through Inkbox (inkbox.ai): a hosted service that gives an agent its own iMessage identity, so this works from Windows,
// a Docker server or a Mac alike, with nothing reachable from outside. Bothive checks Inkbox's inbox every few seconds (REST,
// X-API-Key) and answers in the same conversation. Direct messages only; group chats are ignored.
//
// Set up once at inkbox.ai: create an agent with iMessage turned on and make an API key for that agent. People then text
// "connect @your-agent-handle" to Inkbox's router number (the Settings screen shows it) and their messages reach this Bot. Inkbox
// limits an agent to about 100 iMessages a day on the base plan, and a reply to someone who has not written back yet must be
// short with no links, so Bothive sends one message per reply.
const BASE = 'https://inkbox.ai/api/v1/imessage';
const E164 = /^\+[1-9]\d{6,14}$/;

class InkboxIMessageChannel {
  constructor({ fields, handlers, fetchImpl = fetch, interval = 4000, setTimer = setTimeout, clearTimer = clearTimeout, uuid = () => crypto.randomUUID() }) {
    this.key = fields.apiKey; this.onMessage = handlers.onMessage; this.fetch = fetchImpl; this.interval = interval;
    this.setTimer = setTimer; this.clearTimer = clearTimer; this.uuid = uuid;
    this.running = false; this.seen = new Set(); this.timer = null; this.info = { state: 'starting', detail: '' };
  }
  status() { return this.info; }
  fail(error) { this.info = { state: 'error', detail: error.message }; }

  async api(path, { method = 'GET', body, headers = {} } = {}) {
    const response = await this.fetch(BASE + path, {
      method, headers: { 'X-API-Key': this.key, ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000),
    });
    if (response.status === 401 || response.status === 403 && path.startsWith('/conversations?')) { const error = new Error('Inkbox did not accept that API key. Make an API key for this agent in the Inkbox console and paste it again.'); error.code = 401; throw error; }
    if (response.status === 400) { const error = new Error('iMessage is not turned on for this Inkbox agent. Turn it on in the Inkbox console (the agent’s settings), then switch it on again here.'); error.code = 400; throw error; }
    if (response.status === 429) { const error = new Error('Inkbox says the message limit was reached. It resets on a rolling 24 hours.'); error.code = 429; error.retryAfter = Number(response.headers?.get?.('Retry-After')) || 60; throw error; }
    const data = await response.json().catch(() => null);
    if (!response.ok) { const detail = data?.detail?.error || data?.detail || data?.error; const error = new Error(`Inkbox answered ${response.status}${typeof detail === 'string' ? ': ' + detail : ''}.`); error.code = response.status; throw error; }
    return data;
  }

  /** The unread, incoming, one-to-one messages, oldest first. */
  async unread() {
    const list = await this.api('/messages?' + new URLSearchParams({ limit: '50', is_read: 'false' }));
    return (Array.isArray(list) ? list : []).filter(m => m.direction === 'inbound' && !m.is_group && !m.is_blocked).reverse();
  }

  async start() {
    if (!/^\S{10,}$/.test(this.key || '')) throw new Error('Paste the API key from the Inkbox console.');
    try { await this.api('/conversations?limit=1'); }
    catch (error) { if (error.code) throw error; throw new Error(`Inkbox could not be reached: ${error.message}`); }
    // What is already waiting is old. Only messages that arrive from now on are answered.
    for (const message of await this.unread()) this.seen.add(message.id);
    this.running = true; this.info = { state: 'on', detail: 'Connected to Inkbox' }; this.schedule(this.interval);
  }
  async stop() { this.running = false; this.clearTimer(this.timer); this.info = { state: 'off', detail: '' }; }
  schedule(ms) { if (this.running) this.timer = this.setTimer(() => this.poll(), ms); }

  async poll() {
    let wait = this.interval;
    try {
      const fresh = (await this.unread()).filter(message => !this.seen.has(message.id));
      const conversations = new Set();
      for (const message of fresh) {
        this.seen.add(message.id);
        // Messages from an address that is not a phone number cannot be answered, so they are not passed on.
        if (!message.content || !E164.test(message.remote_number || '')) continue;
        conversations.add(message.conversation_id);
        Promise.resolve(this.onMessage({ senderId: message.remote_number, senderName: message.remote_number, chatId: message.conversation_id, text: message.content })).catch(() => {});
      }
      // Marking read shows "Read" to the person and keeps these messages out of the next check.
      for (const id of conversations) this.api('/mark-read', { method: 'POST', body: { conversation_id: id } }).catch(() => {});
      if (this.seen.size > 1000) this.seen = new Set([...this.seen].slice(-500));
      if (this.running) this.info = { state: 'on', detail: 'Connected to Inkbox' };
    } catch (error) {
      if (error.code === 401 || error.code === 400) { this.running = false; this.info = { state: 'error', detail: error.message }; return; }
      this.info = { state: 'error', detail: error.code === 429 ? error.message : `Reconnecting: ${error.message}` };
      wait = error.retryAfter ? Math.min(error.retryAfter, 300) * 1000 : Math.min(this.interval * 4, 30000);
    }
    this.schedule(wait);
  }

  async send(conversationId, text) {
    await this.api('/messages', { method: 'POST', body: { conversation_id: conversationId, text }, headers: { 'Idempotency-Key': this.uuid(), Prefer: 'idempotency-replay' } });
  }
  async typing(conversationId) { await this.api('/typing', { method: 'POST', body: { conversation_id: conversationId } }); }
}

module.exports = { InkboxIMessageChannel };
