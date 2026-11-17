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
  imessage: { name: 'iMessage', limit: 4000 },
};
const PAIR_TTL = 60 * 60 * 1000, MAX_PENDING = 20, WINDOW = 10 * 60 * 1000, MAX_PER_WINDOW = 30, MAX_TEXT = 4000, NOTICE_GAP = 10 * 60 * 1000;
const STOP_WORDS = /^\s*(?:\/stop|stop|cancel|abort|never\s*mind|nevermind)(?:\s+(?:it|that|please))?[.!]*\s*$/i;
const BATCH_QUIET = 1200, BATCH_MAX = 4000, MAX_MEDIA = 3;
const DEFAULT_SETTINGS = { fast: true, whenBusy: 'steer', reachOn: null, escalate: 'call', escalateMinutes: 10, quietStart: 22, quietEnd: 8 };
const CALL_WORDS = /^\s*(?:\/call|(?:hey\s+)?(?:please\s+)?(?:can\s+you\s+|could\s+you\s+)?(?:give\s+me\s+a\s+)?(?:call|phone|ring)(?:\s+me)?(?:\s+now|\s+please)?[.!?]*)\s*$/i;

class ChannelHub {
  /**
   * @param {{
   *   load: () => Promise<object|null>, save: (value: object) => Promise<void>,
   *   makeAdapter: (id: string, config: object, handlers: object) => ({start(): Promise<void>, stop(): Promise<void>, send(chatId: string, text: string): Promise<void>, typing?(chatId: string): Promise<void>, status(): object}),
   *   ask: (botID: string, text: string, from: object, options: {media?: object[], steer?: boolean, fast?: boolean}) => Promise<string|null>,
   *   stop?: (botID: string) => void, setTimer?: Function, clearTimer?: Function, batchMs?: number, batchMaxMs?: number,
   *   botExists: (botID: string) => boolean,
   *   call?: (from: object) => Promise<string>,
   *   now?: () => number, code?: () => string
   * }} deps
   */
  constructor(deps) {
    this.deps = deps; this.now = deps.now || Date.now;
    this.makeCode = deps.code || (() => String(crypto.randomInt(100000, 1000000)));
    this.adapters = new Map(); this.bots = new Map(); this.batches = new Map(); this.recent = new Map(); this.notices = new Map();
    this.setTimer = deps.setTimer || setTimeout; this.clearTimer = deps.clearTimer || clearTimeout;
    this.batchMs = deps.batchMs ?? BATCH_QUIET; this.batchMaxMs = deps.batchMaxMs ?? BATCH_MAX;
    this.data = { bot: null, channels: {}, approved: {}, pending: {}, settings: { ...DEFAULT_SETTINGS } };
    this.saving = Promise.resolve();
  }

  async init() {
    const saved = await this.deps.load().catch(() => null);
    if (saved && typeof saved === 'object') this.data = { bot: saved.bot ?? null, channels: saved.channels || {}, approved: saved.approved || {}, pending: saved.pending || {}, settings: { ...DEFAULT_SETTINGS, ...(saved.settings || {}) } };
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
        approved: (this.data.approved[id] || []).map(({ id: who, name, display, me, at }) => ({ id: who, name: display || name, me: !!me, at })),
        pending: this.livePending(id).map(({ name, code, at }) => ({ name, code, at })),
      };
    }
    return { bot: this.data.bot, settings: { ...this.data.settings }, channels };
  }

  /** The few switches on the Channels screen. */
  async setSettings(patch = {}) {
    const next = { ...this.data.settings };
    if ('fast' in patch) next.fast = patch.fast !== false;
    if ('whenBusy' in patch) { if (!['steer', 'queue'].includes(patch.whenBusy)) throw new Error('Choose Steer or Queue.'); next.whenBusy = patch.whenBusy; }
    if ('reachOn' in patch) next.reachOn = patch.reachOn && CHANNELS[patch.reachOn] ? patch.reachOn : null;
    if ('escalate' in patch) { if (!['call', 'text', 'none'].includes(patch.escalate)) throw new Error('Choose call, text or nothing.'); next.escalate = patch.escalate; }
    if ('escalateMinutes' in patch) next.escalateMinutes = Math.min(120, Math.max(1, Math.round(Number(patch.escalateMinutes)) || 10));
    for (const key of ['quietStart', 'quietEnd']) if (key in patch) next[key] = Math.min(23, Math.max(0, Math.round(Number(patch[key]))));
    this.data.settings = next; await this.persist(); return next;
  }
  get settings() { return this.data.settings; }
  secretField(id, key) { return /token|secret|password|key|pin/i.test(key); }
  configured(id) { return this.requirements(id).every(key => this.data.channels[id]?.fields?.[key]); }
  requirements(id) { return { telegram: ['token'], discord: ['token'], slack: ['botToken', 'appToken'], sms: ['accountSid', 'authToken', 'number'], imessage: ['apiKey'] }[id] || []; }

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
  async approve(id, code, options = {}) {
    if (!CHANNELS[id]) throw new Error('Unknown channel.');
    const entry = this.livePending(id).find(item => item.code === String(code ?? '').trim());
    if (!entry) throw new Error('That code is not waiting. Ask them to message the Bot again to get a new one.');
    this.data.pending[id] = this.livePending(id).filter(item => item !== entry);
    const list = (this.data.approved[id] ||= []);
    const existing = list.find(item => item.id === entry.senderId);
    if (existing) { if (options.me) existing.me = true; }
    else list.push({ id: entry.senderId, name: entry.name, at: this.now(), chatId: entry.chatId, me: !!options.me });
    await this.persist();
    this.send(id, entry.chatId, 'You’re approved. Send a message and the Bot will answer.').catch(() => {});
    return { name: entry.name };
  }
  async remove(id, senderId) {
    this.data.approved[id] = (this.data.approved[id] || []).filter(item => item.id !== senderId);
    this.data.pending[id] = this.livePending(id).filter(item => item.senderId !== senderId);
    await this.persist();
  }
  /** Rename an approved person (the same name on two channels is one person to the Bot) or mark them as you. */
  async setPerson(id, senderId, patch = {}) {
    const person = (this.data.approved[id] || []).find(item => item.id === senderId);
    if (!person) throw new Error('That person is not approved.');
    if ('name' in patch) { const clean = String(patch.name ?? '').replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, 80); person.display = clean || undefined; }
    if ('me' in patch) person.me = !!patch.me;
    await this.persist();
  }
  /** The person marked Me, preferring a channel. Unprompted messages and calls go only to them. */
  owner(preferred) {
    const channels = [preferred, ...Object.keys(CHANNELS)].filter(Boolean);
    for (const channel of channels) { const person = (this.data.approved[channel] || []).find(item => item.me && item.chatId); if (person) return { channel, person }; }
    return null;
  }
  isApproved(id, senderId) { return (this.data.approved[id] || []).some(item => item.id === senderId); }
  approvedPeople(id) { return this.data.approved[id] || []; }

  async send(id, chatId, text) {
    const adapter = this.adapters.get(id); if (!adapter) return;
    for (const part of chunk(text, CHANNELS[id].limit)) await adapter.send(chatId, part);
  }

  // ----- Messages -----
  async inbound(message) {
    const { channel, senderId, chatId } = message;
    let text = String(message.text ?? '').trim();
    const media = Array.isArray(message.media) ? message.media.filter(item => item?.url).slice(0, MAX_MEDIA) : [];
    if (!CHANNELS[channel] || !senderId || !chatId || (!text && !media.length) || !this.data.bot) return;
    if (!this.deps.botExists(this.data.bot)) return;
    const reply = body => this.send(channel, chatId, body).catch(() => {});
    if (!this.isApproved(channel, senderId)) {
      // Strangers get a code once in a while and nothing else. Nothing they write (or send) reaches the Bot.
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
        await reply(`I only answer people my owner approved. Your code is ${entry.code}. The owner enters it in Bothive, Settings > Channels.`);
      }
      return;
    }
    // Approved: show it was read right away, before anything slow happens.
    const adapter = this.adapters.get(channel);
    adapter?.acknowledge?.(message)?.catch?.(() => {});
    adapter?.typing?.(chatId)?.catch?.(() => {});
    // Rate limit approved people.
    const now = this.now(), key = channel + ':' + senderId;
    const times = (this.recent.get(key) || []).filter(time => now - time < WINDOW);
    if (times.length >= MAX_PER_WINDOW) { if (times.length === MAX_PER_WINDOW) { times.push(now); this.recent.set(key, times); await reply('That is a lot of messages. Give it a few minutes.'); } return; }
    times.push(now); this.recent.set(key, times);
    const person = this.approvedPeople(channel).find(item => item.id === senderId); if (person) { person.lastSeen = now; person.chatId = chatId; }
    if (text.length > MAX_TEXT) { await reply(`That message is too long (the limit is ${MAX_TEXT} characters).`); return; }
    if (STOP_WORDS.test(text) && !media.length) {
      const state = this.bots.get(this.data.bot);
      if (state?.active) { this.deps.stop?.(this.data.bot); await reply('Stopped.'); } else await reply('Nothing is running right now.');
      return;
    }
    if (CALL_WORDS.test(text) && !media.length) {
      if (!this.deps.call) { await reply('Phone calls are not set up. Add a Twilio number under Settings → Channels → SMS and calls, or turn on iMessage through Inkbox.'); return; }
      try { await reply(await this.deps.call({ channel, senderId, senderName: message.senderName, me: !!person?.me })); } catch (error) { await reply(error.message || 'The call could not be placed.'); }
      return;
    }
    const from = { channel, senderId, senderName: person?.display || message.senderName || person?.name || senderId, me: !!person?.me, chatId };
    return this.collect(key, from, text, media);
  }

  /** Messages from one person within a short window become one request, so a photo and "add these to my reminders" arrive together. */
  collect(key, from, text, media) {
    return new Promise(resolve => {
      let batch = this.batches.get(key);
      if (!batch) { batch = { from, texts: [], media: [], resolvers: [], started: this.now(), timer: null }; this.batches.set(key, batch); }
      if (text) batch.texts.push(text); batch.media.push(...media); batch.resolvers.push(resolve);
      const flush = () => { this.batches.delete(key); this.clearTimer(batch.timer); this.dispatch(batch).then(() => batch.resolvers.forEach(done => done()), () => batch.resolvers.forEach(done => done())); };
      if (this.batchMs <= 0) { flush(); return; }
      this.clearTimer(batch.timer);
      const remaining = Math.max(0, this.batchMaxMs - (this.now() - batch.started));
      batch.timer = this.setTimer(flush, Math.min(this.batchMs, remaining)); batch.timer?.unref?.();
    });
  }

  /** Runs one request on the Bot. If the Bot is already working, Steer stops that turn and carries on with this one; Queue waits for it. */
  async dispatch(batch) {
    const botID = this.data.bot, { from } = batch; if (!botID || !this.deps.botExists(botID)) return;
    const chatId = from.chatId, channel = from.channel;
    const text = batch.texts.join('\n').slice(0, MAX_TEXT * 2), media = batch.media.slice(0, MAX_MEDIA);
    const state = this.bots.get(botID) || { active: 0, tail: Promise.resolve() }; this.bots.set(botID, state);
    const steer = state.active > 0 && this.data.settings.whenBusy !== 'queue';
    state.active++;
    if (steer) this.deps.stop?.(botID);
    const previous = state.tail;
    const turn = (async () => {
      await previous.catch(() => {});
      const adapter = this.adapters.get(channel);
      const typing = setInterval(() => adapter?.typing?.(chatId)?.catch?.(() => {}), 4000); typing.unref?.();
      try {
        const answer = await this.deps.ask(botID, text, from, { media, steer, fast: this.data.settings.fast !== false });
        if (answer === null) return;
        await this.send(channel, chatId, answer || 'The Bot did not have anything to say.').catch(() => {});
      } catch (error) { await this.send(channel, chatId, error.message || 'The Bot could not answer right now.').catch(() => {}); }
      finally { clearInterval(typing); }
    })();
    state.tail = turn.catch(() => {});
    try { await turn; } finally { state.active--; }
  }
}

module.exports = { ChannelHub, CHANNELS, CALL_WORDS, STOP_WORDS, DEFAULT_SETTINGS };
