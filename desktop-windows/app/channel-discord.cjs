'use strict';
// Discord: a bot made in the Discord developer portal. Answers direct messages, and in a server only when it is @mentioned.
// It connects out to Discord's gateway, so nothing needs to be reachable from outside. Turn on "Message Content Intent" for the bot.
const REST = 'https://discord.com/api/v10';
const INTENTS = (1 << 9) | (1 << 12) | (1 << 15); // server messages, direct messages, message content

class DiscordChannel {
  constructor({ fields, handlers, fetchImpl = fetch, WebSocketImpl = globalThis.WebSocket, setTimer = setTimeout, clearTimer = clearTimeout }) {
    this.token = fields.token; this.onMessage = handlers.onMessage; this.fetch = fetchImpl; this.WS = WebSocketImpl; this.setTimer = setTimer; this.clearTimer = clearTimer;
    this.running = false; this.info = { state: 'starting', detail: '' }; this.socket = null; this.sequence = null; this.heartbeat = null; this.retry = null; this.userId = null; this.backoff = 1000;
  }
  status() { return this.info; }
  fail(error) { this.info = { state: 'error', detail: error.message }; }
  headers() { return { Authorization: 'Bot ' + this.token, 'Content-Type': 'application/json' }; }
  async rest(path, options = {}) {
    const response = await this.fetch(REST + path, { ...options, headers: { ...this.headers(), ...(options.headers || {}) }, signal: AbortSignal.timeout(15000) });
    if (response.status === 401) { const error = new Error('Discord did not accept that token. Copy it again from the bot page.'); error.code = 401; throw error; }
    if (response.status === 429) { const wait = Number((await response.json().catch(() => ({}))).retry_after) || 1; await new Promise(r => this.setTimer(r, Math.min(wait, 5) * 1000)); return this.rest(path, options); }
    if (!response.ok) throw new Error(`Discord answered ${response.status}.`);
    return response.status === 204 ? null : response.json().catch(() => null);
  }
  async start() {
    this.running = true;
    const me = await this.rest('/users/@me'); this.userId = me.id; this.username = me.username;
    this.connect();
  }
  async stop() { this.running = false; this.clearTimer(this.heartbeat); this.clearTimer(this.retry); try { this.socket?.close(1000); } catch {} this.socket = null; this.info = { state: 'off', detail: '' }; }
  connect(url = 'wss://gateway.discord.gg/?v=10&encoding=json') {
    if (!this.running) return;
    this.info = { state: 'starting', detail: 'Connecting…' };
    const socket = new this.WS(url); this.socket = socket; this.sequence = null;
    socket.onmessage = event => { try { this.handle(JSON.parse(typeof event.data === 'string' ? event.data : String(event.data))); } catch {} };
    socket.onclose = event => {
      this.clearTimer(this.heartbeat);
      if (!this.running || this.socket !== socket) return;
      const code = event?.code;
      if (code === 4004) { this.running = false; this.info = { state: 'error', detail: 'Discord did not accept that token.' }; return; }
      if (code === 4014 || code === 4013) { this.running = false; this.info = { state: 'error', detail: 'Turn on “Message Content Intent” for this bot in the Discord developer portal, then switch it on again.' }; return; }
      this.info = { state: 'error', detail: 'Reconnecting…' };
      this.retry = this.setTimer(() => this.connect(), this.backoff); this.backoff = Math.min(this.backoff * 2, 30000);
    };
    socket.onerror = () => {};
  }
  sendOp(op, d) { try { this.socket?.send(JSON.stringify({ op, d })); } catch {} }
  handle(packet) {
    if (packet.s != null) this.sequence = packet.s;
    if (packet.op === 10) {
      const every = packet.d.heartbeat_interval;
      const beat = () => { this.sendOp(1, this.sequence); this.heartbeat = this.setTimer(beat, every); };
      this.heartbeat = this.setTimer(beat, Math.floor(every * 0.5));
      this.sendOp(2, { token: this.token, intents: INTENTS, properties: { os: 'bothive', browser: 'bothive', device: 'bothive' } });
    } else if (packet.op === 7 || packet.op === 9) {
      try { this.socket?.close(4000); } catch {}
    } else if (packet.op === 0 && packet.t === 'READY') {
      this.userId = packet.d.user?.id || this.userId; this.backoff = 1000; this.info = { state: 'on', detail: this.username ? `Bot ${this.username}` : 'Connected' };
    } else if (packet.op === 0 && packet.t === 'MESSAGE_CREATE') this.message(packet.d);
  }
  message(d) {
    if (!d || d.author?.bot || d.author?.id === this.userId || typeof d.content !== 'string') return;
    let text = d.content;
    if (d.guild_id) {
      // In a server the Bot only answers when someone mentions it.
      const mention = new RegExp(`<@!?${this.userId}>`, 'g');
      if (!(d.mentions || []).some(user => user.id === this.userId) && !mention.test(text)) return;
      text = text.replace(new RegExp(`<@!?${this.userId}>`, 'g'), '').trim();
    }
    const media = (Array.isArray(d.attachments) ? d.attachments : []).filter(item => item?.url && /^image\//i.test(item.content_type || '')).map(item => ({ url: item.url, contentType: item.content_type, size: item.size || 0, name: item.filename }));
    if (!text && !media.length) return;
    Promise.resolve(this.onMessage({ senderId: d.author.id, senderName: d.author.global_name || d.author.username, chatId: d.channel_id, text, media })).catch(() => {});
  }
  async send(chatId, text) { await this.rest(`/channels/${encodeURIComponent(chatId)}/messages`, { method: 'POST', body: JSON.stringify({ content: text, allowed_mentions: { parse: [] } }) }); }
  async typing(chatId) { await this.rest(`/channels/${encodeURIComponent(chatId)}/typing`, { method: 'POST' }); }
}
module.exports = { DiscordChannel, INTENTS };
