'use strict';
// The chat channels hub (10.1.1): one Bot you choose answers messages that arrive on Telegram, Discord, Slack, SMS and more.
//
// Safety first. A channel is a way to reach a Bot that can run tasks on this computer, so nobody is answered until you approve them:
//  - A stranger who messages the Bot gets a short code and nothing else. The code does nothing until you type it into Bothive
//    (Settings → Channels). Codes expire after an hour, and each channel keeps at most 20 waiting.
//  - Approved people are rate limited, and a message is one Bot turn like any other (the Bot's own permission prompts still apply).
//  - In group channels (a Discord server, a Slack channel) the Bot only answers when it is mentioned.
const crypto = require('node:crypto');
const { chunk } = require('./channel-text.cjs');

const CHANNELS = {
  telegram: { name: 'Telegram', limit: 4000 },
  discord: { name: 'Discord', limit: 1900 },
  slack: { name: 'Slack', limit: 3000 },
  sms: { name: 'SMS', limit: 1500 },
};
const PAIR_TTL = 60 * 60 * 1000, MAX_PENDING = 20, WINDOW = 10 * 60 * 1000, MAX_PER_WINDOW = 30, MAX_TEXT = 4000, NOTICE_GAP = 10 * 60 * 1000;
const CALL_WORDS = /^\s*(?:\/call|(?:hey\s+)?(?:please\s+)?(?:can\s+you\s+|could\s+you\s+)?(?:give\s+me\s+a\s+)?(?:call|phone|ring)(?:\s+me)?(?:\s+now|\s+please)?[.!?]*)\s*$/i;

class ChannelHub {
  /**
   * @param {{
   *   load: () => Promise<object|null>, save: (value: object) => Promise<void>,
   *   makeAdapter: (id: string, config: object, handlers: object) => ({start(): Promise<void>, stop(): Promise<void>, send(chatId: string, text: string): Promise<void>, typing?(chatId: string): Promise<void>, status(): object}),
   *   ask: (botID: string, text: string, from: object) => Promise<string>,
   *   botExists: (botID: string) => boolean,
   *   call?: (from: object) => Promise<string>,
   *   now?: () => number, code?: () => string
   * }} deps
   */
  constructor(deps) {
    this.deps = deps; this.now = deps.now || Date.now;
    this.makeCode = deps.code || (() => String(crypto.randomInt(100000, 1000000)));
    this.adapters = new Map(); this.busy = new Set(); this.recent = new Map(); this.notices = new Map();
    this.data = { bot: null, channels: {}, approved: {}, pending: {} };
    this.saving = Promise.resolve();
  }

  async init() {
    const saved = await this.deps.load().catch(() => null);
    if (saved && typeof saved === 'object') this.data = { bot: saved.bot ?? null, channels: saved.channels || {}, approved: saved.approved || {}, pending: saved.pending || {} };
    for (const id of Object.keys(CHANNELS)) if (this.data.channels[id]?.enabled) await this.start(id).catch(() => {});
  }

  persist() { this.saving = this.saving.then(() => this.deps.save(this.data)).catch(() => {}); return this.saving; }

  // ----- Settings -----
  /** What the settings screen shows. Secrets never leave: only whether each one is set. */
  status() {
    const channels = {};
    for (const [id, info] of Object.entries(CHANNELS)) {
      const config = this.data.channels[id] || {}, adapter = this.adapters.get(id);
      channels[id] = {
        name: info.name, enabled: !!config.enabled, configured: this.configured(id),
        fields: Object.fromEntries(Object.entries(config.fields || {}).map(([key, value]) => [key, this.secretField(id, key) ? Boolean(value) : value])),
        state: adapter?.status?.() || { state: config.enabled ? 'starting' : 'off', detail: '' },
        approved: (this.data.approved[id] || []).map(({ id: who, name, at }) => ({ id: who, name, at })),
        pending: this.livePending(id).map(({ name, code, at }) => ({ name, code, at })),
      };
    }
    return { bot: this.data.bot, channels };
  }
  secretField(id, key) { return /token|secret|password|key|pin/i.test(key); }
  configured(id) { return this.requirements(id).every(key => this.data.channels[id]?.fields?.[key]); }
  requirements(id) { return { telegram: ['token'], discord: ['token'], slack: ['botToken', 'appToken'], sms: ['accountSid', 'authToken', 'number'] }[id] || []; }

  async setBot(botID) {
    if (botID !== null && !this.deps.botExists(botID)) throw new Error('Choose one of your Bots.');
    this.data.bot = botID; await this.persist();
  }

  /** Saves a channel's settings. Fields left blank keep their saved value, so a token is never shown again just to keep it. */
  async configure(id, fields = {}) {
    if (!CHANNELS[id]) throw new Error('Unknown channel.');
    const current = { ...(this.data.channels[id]?.fields || {}) };
    for (const [key, value] of Object.entries(fields)) {
      if (typeof value !== 'string' || value.length > 500 || /[\u0000-\u001f]/.test(value)) throw new Error('One of the values is not valid.');
      const clean = value.trim();
      if (clean) current[key] = clean; else if (value === '' && !this.secretField(id, key)) delete current[key];
    }
    this.data.channels[id] = { ...(this.data.channels[id] || {}), fields: current };
    await this.persist();
    if (this.data.channels[id].enabled) { await this.stop(id); await this.start(id); }
  }

  async setEnabled(id, enabled) {
    if (!CHANNELS[id]) throw new Error('Unknown channel.');
    if (enabled && !this.configured(id)) throw new Error(`Finish setting up ${CHANNELS[id].name} first.`);
    if (enabled && !this.data.bot) throw new Error('Choose which Bot answers first.');
    this.data.channels[id] = { ...(this.data.channels[id] || {}), enabled: !!enabled };
    await this.persist();
    if (enabled) await this.start(id); else await this.stop(id);
  }

  async start(id) {
    if (this.adapters.has(id)) return;
    const adapter = this.deps.makeAdapter(id, this.data.channels[id]?.fields || {}, { onMessage: message => this.inbound({ ...message, channel: id }) });
    this.adapters.set(id, adapter);
    try { await adapter.start(); } catch (error) { adapter.fail?.(error); }
  }
  async stop(id) { const adapter = this.adapters.get(id); this.adapters.delete(id); await adapter?.stop().catch(() => {}); }
  async stopAll() { await Promise.all([...this.adapters.keys()].map(id => this.stop(id))); }

  // ----- People -----
  livePending(id) { const now = this.now(); return (this.data.pending[id] ||= []).filter(item => now - item.at < PAIR_TTL); }

  /** You typed the code a person was given. They are approved from now on. */
  async approve(id, code) {
    if (!CHANNELS[id]) throw new Error('Unknown channel.');
    const entry = this.livePending(id).find(item => item.code === String(code ?? '').trim());
    if (!entry) throw new Error('That code is not waiting. Ask them to message the Bot again to get a new one.');
    this.data.pending[id] = this.livePending(id).filter(item => item !== entry);
    const list = (this.data.approved[id] ||= []);
    if (!list.some(item => item.id === entry.senderId)) list.push({ id: entry.senderId, name: entry.name, at: this.now(), chatId: entry.chatId });
    await this.persist();
    this.send(id, entry.chatId, 'You’re approved. Send a message and the Bot will answer.').catch(() => {});
    return { name: entry.name };
  }
  async remove(id, senderId) {
    this.data.approved[id] = (this.data.approved[id] || []).filter(item => item.id !== senderId);
    this.data.pending[id] = this.livePending(id).filter(item => item.senderId !== senderId);
    await this.persist();
  }
  isApproved(id, senderId) { return (this.data.approved[id] || []).some(item => item.id === senderId); }
  approvedPeople(id) { return this.data.approved[id] || []; }

  async send(id, chatId, text) {
    const adapter = this.adapters.get(id); if (!adapter) return;
    for (const part of chunk(text, CHANNELS[id].limit)) await adapter.send(chatId, part);
  }

  // ----- Messages -----
  async inbound(message) {
    const { channel, senderId, chatId } = message; const text = String(message.text ?? '').trim();
    if (!CHANNELS[channel] || !senderId || !chatId || !text || !this.data.bot) return;
    if (!this.deps.botExists(this.data.bot)) return;
    const reply = body => this.send(channel, chatId, body).catch(() => {});
    if (!this.isApproved(channel, senderId)) {
      // Strangers get a code once in a while and nothing else. Nothing they write reaches the Bot.
      const key = channel + ':' + senderId, now = this.now();
      let entry = this.livePending(channel).find(item => item.senderId === senderId);
      if (!entry) {
        const list = this.livePending(channel);
        if (list.length >= MAX_PENDING) return;
        entry = { senderId, name: String(message.senderName || senderId).slice(0, 80), code: this.makeCode(), at: now, chatId };
        this.data.pending[channel] = [...list, entry]; await this.persist();
      }
      if (now - (this.notices.get(key) || 0) > NOTICE_GAP) {
        this.notices.set(key, now);
        await reply(`This Bot only answers people its owner has approved. Your code is ${entry.code}. The owner types it in Bothive under Settings → Channels to let you in.`);
      }
      return;
    }
    // Rate limit approved people.
    const now = this.now(), key = channel + ':' + senderId;
    const times = (this.recent.get(key) || []).filter(time => now - time < WINDOW);
    if (times.length >= MAX_PER_WINDOW) { if (times.length === MAX_PER_WINDOW) { times.push(now); this.recent.set(key, times); await reply('That is a lot of messages. Give it a few minutes.'); } return; }
    times.push(now); this.recent.set(key, times);
    if (text.length > MAX_TEXT) { await reply(`That message is too long (the limit is ${MAX_TEXT} characters).`); return; }
    if (CALL_WORDS.test(text)) {
      if (!this.deps.call) { await reply('Phone calls are not set up. Add a Twilio number under Settings → Channels → SMS and calls.'); return; }
      try { await reply(await this.deps.call({ channel, senderId, senderName: message.senderName })); } catch (error) { await reply(error.message || 'The call could not be placed.'); }
      return;
    }
    if (this.busy.has(this.data.bot)) { await reply('Still working on the last message. I’ll answer that first.'); return; }
    this.busy.add(this.data.bot);
    const adapter = this.adapters.get(channel);
    const typing = setInterval(() => adapter?.typing?.(chatId).catch?.(() => {}), 4000); typing.unref?.();
    adapter?.typing?.(chatId)?.catch?.(() => {});
    try {
      const answer = await this.deps.ask(this.data.bot, text, { channel, senderId, senderName: message.senderName });
      await reply(answer || 'The Bot did not have anything to say.');
    } catch (error) { await reply(error.message || 'The Bot could not answer right now.'); }
    finally { clearInterval(typing); this.busy.delete(this.data.bot); }
  }
}

module.exports = { ChannelHub, CHANNELS, CALL_WORDS };
