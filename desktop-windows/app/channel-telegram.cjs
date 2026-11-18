'use strict';
// Telegram: a bot made with @BotFather. Direct messages only. Long polling, so nothing needs to be reachable from outside.
const API = 'https://api.telegram.org';

class TelegramChannel {
  constructor({ fields, handlers, fetchImpl = fetch, sleep = ms => new Promise(r => setTimeout(r, ms)) }) {
    this.token = fields.token; this.onMessage = handlers.onMessage; this.fetch = fetchImpl; this.sleep = sleep;
    this.running = false; this.offset = 0; this.info = { state: 'starting', detail: '' };
  }
  status() { return this.info; }
  fail(error) { this.info = { state: 'error', detail: error.message }; }
  async call(method, body, timeout = 15000) {
    const response = await this.fetch(`${API}/bot${this.token}/${method}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}), signal: AbortSignal.timeout(timeout) });
    const reply = await response.json().catch(() => ({}));
    if (!reply.ok) { const error = new Error(reply.description || `Telegram answered ${response.status}.`); error.code = reply.error_code || response.status; throw error; }
    return reply.result;
  }
  async start() {
    let me;
    try { me = await this.call('getMe'); } catch (error) { throw new Error(error.code === 401 ? 'Telegram did not accept that token. Copy it again from @BotFather.' : `Telegram could not be reached: ${error.message}`); }
    this.username = me.username; this.info = { state: 'on', detail: `@${me.username}` }; this.running = true;
    this.loop();
  }
  async stop() { this.running = false; this.info = { state: 'off', detail: '' }; }
  async loop() {
    let delay = 1000;
    while (this.running) {
      try {
        const updates = await this.call('getUpdates', { offset: this.offset, timeout: 25, allowed_updates: ['message'] }, 40000);
        delay = 1000; if (this.running) this.info = { state: 'on', detail: `@${this.username}` };
        for (const update of updates) {
          this.offset = Math.max(this.offset, update.update_id + 1);
          const message = update.message;
          if (message?.text && message.chat?.type === 'private' && message.from && !message.from.is_bot) {
            const name = [message.from.first_name, message.from.last_name].filter(Boolean).join(' ') || message.from.username || String(message.from.id);
            Promise.resolve(this.onMessage({ senderId: String(message.from.id), senderName: name, chatId: String(message.chat.id), text: message.text })).catch(() => {});
          }
        }
      } catch (error) {
        if (!this.running) return;
        if (error.code === 401) { this.running = false; this.info = { state: 'error', detail: 'Telegram no longer accepts this token.' }; return; }
        this.info = { state: 'error', detail: error.code === 409 ? 'Another program is reading this Telegram bot. Stop it, or make a new bot.' : `Reconnecting: ${error.message}` };
        await this.sleep(delay); delay = Math.min(delay * 2, 30000);
      }
    }
  }
  async send(chatId, text) { await this.call('sendMessage', { chat_id: chatId, text, disable_web_page_preview: true }); }
  async typing(chatId) { await this.call('sendChatAction', { chat_id: chatId, action: 'typing' }, 8000); }
}
module.exports = { TelegramChannel };
