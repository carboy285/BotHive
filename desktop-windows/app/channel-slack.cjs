'use strict';
// Slack: an app you create at api.slack.com with Socket Mode on, so it connects out and nothing needs to be reachable from outside.
// Needs a bot token (xoxb-) and an app-level token (xapp-). Answers direct messages, and in a channel only when @mentioned.
const API = 'https://slack.com/api';

class SlackChannel {
  constructor({ fields, handlers, fetchImpl = fetch, WebSocketImpl = globalThis.WebSocket, setTimer = setTimeout, clearTimer = clearTimeout }) {
    this.botToken = fields.botToken; this.appToken = fields.appToken; this.onMessage = handlers.onMessage; this.fetch = fetchImpl; this.WS = WebSocketImpl;
    this.setTimer = setTimer; this.clearTimer = clearTimer; this.running = false; this.socket = null; this.retry = null; this.backoff = 1000; this.userId = null; this.seen = new Set();
    this.info = { state: 'starting', detail: '' };
  }
  status() { return this.info; }
  fail(error) { this.info = { state: 'error', detail: error.message }; }
  async api(method, token, body) {
    const response = await this.fetch(`${API}/${method}`, { method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify(body || {}), signal: AbortSignal.timeout(15000) });
    const reply = await response.json().catch(() => ({}));
    if (!reply.ok) { const error = new Error(reply.error || `Slack answered ${response.status}.`); error.slack = reply.error; throw error; }
    return reply;
  }
  async start() {
    if (!/^xoxb-/.test(this.botToken || '')) throw new Error('The bot token starts with xoxb-. Copy it from OAuth & Permissions.');
    if (!/^xapp-/.test(this.appToken || '')) throw new Error('The app token starts with xapp-. Make one under Basic Information → App-Level Tokens with connections:write.');
    try { const who = await this.api('auth.test', this.botToken); this.userId = who.user_id; this.team = who.team; }
    catch (error) { throw new Error(error.slack === 'invalid_auth' ? 'Slack did not accept the bot token.' : `Slack could not be reached: ${error.message}`); }
    this.running = true; await this.connect();
  }
  async stop() { this.running = false; this.clearTimer(this.retry); try { this.socket?.close(1000); } catch {} this.socket = null; this.info = { state: 'off', detail: '' }; }
  async connect() {
    if (!this.running) return;
    let url;
    try { url = (await this.api('apps.connections.open', this.appToken)).url; }
    catch (error) {
      if (error.slack === 'invalid_auth' || error.slack === 'not_allowed_token_type') { this.running = false; this.info = { state: 'error', detail: 'Slack did not accept the app token (it needs connections:write).' }; return; }
      this.info = { state: 'error', detail: 'Reconnecting…' }; this.retry = this.setTimer(() => this.connect(), this.backoff); this.backoff = Math.min(this.backoff * 2, 30000); return;
    }
    const socket = new this.WS(url); this.socket = socket;
    socket.onmessage = event => { try { this.handle(JSON.parse(typeof event.data === 'string' ? event.data : String(event.data))); } catch {} };
    socket.onclose = () => { if (!this.running || this.socket !== socket) return; this.info = { state: 'error', detail: 'Reconnecting…' }; this.retry = this.setTimer(() => this.connect(), this.backoff); this.backoff = Math.min(this.backoff * 2, 30000); };
    socket.onerror = () => {};
  }
  handle(packet) {
    if (packet.type === 'hello') { this.backoff = 1000; this.info = { state: 'on', detail: this.team ? `Workspace ${this.team}` : 'Connected' }; return; }
    if (packet.type === 'disconnect') { try { this.socket?.close(4000); } catch {} return; }
    if (packet.envelope_id) { try { this.socket?.send(JSON.stringify({ envelope_id: packet.envelope_id })); } catch {} }
    if (packet.type !== 'events_api') return;
    const event = packet.payload?.event; if (!event) return;
    const direct = event.type === 'message' && event.channel_type === 'im';
    const mention = event.type === 'app_mention';
    if (!direct && !mention) return;
    if (event.bot_id || event.subtype || !event.user || event.user === this.userId || typeof event.text !== 'string') return;
    const id = packet.payload.event_id || event.client_msg_id || event.ts; if (id) { if (this.seen.has(id)) return; this.seen.add(id); if (this.seen.size > 500) this.seen.delete(this.seen.values().next().value); }
    const text = event.text.replace(new RegExp(`<@${this.userId}>`, 'g'), '').trim(); if (!text) return;
    Promise.resolve(this.onMessage({ senderId: event.user, senderName: event.user, chatId: event.channel, text })).catch(() => {});
  }
  async send(chatId, text) { await this.api('chat.postMessage', this.botToken, { channel: chatId, text, unfurl_links: false, unfurl_media: false }); }
}
module.exports = { SlackChannel };
