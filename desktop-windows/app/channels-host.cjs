'use strict';
// Connects the chat channels (hub, adapters, phone calls) to this app: storage, the Bot that answers, the public phone listener,
// and settings from environment variables for a headless Docker server.
const { ChannelHub, CHANNELS } = require('./channel-hub.cjs');
const { TelegramChannel } = require('./channel-telegram.cjs');
const { DiscordChannel } = require('./channel-discord.cjs');
const { SlackChannel } = require('./channel-slack.cjs');
const { SmsChannel, VoiceCalls, E164 } = require('./channel-twilio.cjs');
const { createVoiceServer } = require('./channel-voice-server.cjs');
const { InkboxIMessageChannel } = require('./channel-inkbox.cjs');
const attachments = require('./attachments.cjs');

const FILE = 'channels.json', ENCRYPTED = 'channels.encrypted.json';
const VOICE_FIELDS = ['ownerNumber', 'pin', 'publicUrl', 'language'];

/**
 * @param {{
 *  loadJSON, atomicJSON, safeStorage, platform?: string, ensureState: () => Promise<void>, getState: () => object,
 *  startChat: (botID: string, text: string, options?: object) => Promise<void>, stop?: (botID: string) => void, botDirectory?: (botID: string) => string, isRunning: (botID: string) => boolean,
 *  env?: object, fetchImpl?: typeof fetch, WebSocketImpl?: any, createServer?: Function, log?: (e: Error) => void, sleep?: (ms: number) => Promise<void>,
 *  voiceHost?: string, askTimeout?: number, batchMs?: number, pollMs?: number
 * }} deps
 */
function createChannelsHost(deps) {
  const env = deps.env || process.env, platform = deps.platform || process.platform, sleep = deps.sleep || (ms => new Promise(r => setTimeout(r, ms)));
  const askTimeout = deps.askTimeout ?? 15 * 60 * 1000, pollMs = deps.pollMs ?? 150;
  const turns = new Map(), cancelled = new Set(); let turnCounter = 0;
  let voiceServer = null, voiceKey = '', hub;

  // ----- Storage. Tokens are encrypted where the OS can do it (Windows). A Linux server keeps them in a private file (mode 0600). -----
  const storage = {
    async load() {
      const encrypted = await deps.loadJSON(ENCRYPTED, null);
      if (encrypted?.encrypted) {
        if (!deps.safeStorage.isEncryptionAvailable()) throw new Error('Secure storage is unavailable.');
        return JSON.parse(deps.safeStorage.decryptString(Buffer.from(encrypted.encrypted, 'base64')));
      }
      return deps.loadJSON(FILE, null);
    },
    async save(value) {
      if (deps.safeStorage.isEncryptionAvailable() && platform === 'win32') await deps.atomicJSON(ENCRYPTED, { encrypted: deps.safeStorage.encryptString(JSON.stringify(value)).toString('base64') });
      else if (platform !== 'win32') await deps.atomicJSON(FILE, value);
      else throw new Error('Windows encryption is unavailable, so channel tokens cannot be saved.');
    },
  };

  const smsFields = () => hub?.data.channels.sms?.fields || {};
  const voice = new VoiceCalls({
    settings: () => {
      const f = smsFields(), state = deps.getState?.(), bot = state?.bots?.find(x => x.id === hub?.data.bot);
      return { accountSid: f.accountSid, authToken: f.authToken, number: f.number, ownerNumber: f.ownerNumber, pin: f.pin, publicUrl: f.publicUrl, language: f.language, botName: bot?.name };
    },
    ask: text => askBot(hub.data.bot, text, { channel: 'phone', senderName: 'phone call' }),
    fetchImpl: deps.fetchImpl,
  });

  const STEER_NOTE = '\n\n(The person sent this while you were still working. Carry on with their original request with this in mind. Do not redo work that is already finished.)';

  /** Downloads the pictures that came with a message into the Bot's Attachments folder. Returns the stored names and what went wrong. */
  async function saveMedia(botID, media) {
    const names = [], problems = [];
    const directory = deps.botDirectory?.(botID);
    for (const item of (media || []).slice(0, 3)) {
      try {
        if (!directory) throw Object.assign(new Error('no folder'), { code: 'unsupported' });
        const where = item.resolve ? await item.resolve() : item;
        const response = await (deps.fetchImpl || fetch)(where.url, { headers: where.headers || item.headers || {}, signal: AbortSignal.timeout(30000) });
        if (!response.ok) throw new Error('download failed');
        const bytes = Buffer.from(await response.arrayBuffer());
        names.push(await attachments.saveChannelImage(directory, bytes, item.name || 'Photo'));
      } catch (error) {
        problems.push(error.code === 'heic' ? 'a photo arrived in the HEIC format, which cannot be read here. Ask them to send it as a JPEG or a screenshot' : error.code === 'unsupported' ? 'a file that is not a PNG, JPEG, GIF or WebP image was skipped' : 'a picture could not be downloaded');
      }
    }
    return { names, problems };
  }

  /** Sends a message to the chosen Bot like someone typing it, waits for the run to finish, and returns its reply (null if the turn was stopped). */
  async function askBot(botID, text, from, options = {}) {
    await deps.ensureState();
    const state = deps.getState(); const before = state.entries.length;
    if (!state.bots.some(x => x.id === botID)) throw new Error('That Bot is gone. Choose another under Settings → Channels.');
    let body = String(text || '');
    if (options.media?.length) {
      const { names, problems } = await saveMedia(botID, options.media);
      if (!names.length && !body.trim()) return `I could not use that: ${problems[0] || 'nothing readable came through'}.`;
      body = attachments.attachmentMessage(body.trim() || '(photo)', names);
      if (problems.length) body += `\n(Also: ${problems.join('; ')}.)`;
    }
    if (from) body = `[${CHANNELS[from.channel]?.name || from.channel} \u00b7 ${String(from.senderName || 'someone').slice(0, 60)}${from.me ? ' \u00b7 the owner' : ''}] ${body}`;
    if (options.steer) body += STEER_NOTE;
    const token = ++turnCounter; turns.set(botID, token);
    await deps.startChat(botID, body, { channelTurn: options.fast !== false && from?.channel !== 'phone' });
    const deadline = Date.now() + askTimeout;
    while (deps.isRunning(botID)) {
      if (Date.now() > deadline) return 'Still working on it, or waiting for your OK in Bothive. I’ll leave the answer in the chat.';
      await sleep(pollMs);
    }
    if (cancelled.delete(token)) return null;
    const reply = deps.getState().entries.slice(before).filter(e => e.botID === botID && e.kind === 'bot').at(-1);
    if (!reply) return 'The Bot did not answer.';
    if (reply.state === 'failed') throw new Error(reply.text || 'The Bot could not finish that.');
    return reply.text;
  }
  /** Stops the turn that is running for this Bot. Its answer is discarded. */
  function stopTurn(botID) { const token = turns.get(botID); if (token) cancelled.add(token); deps.stop?.(botID); }

  function makeAdapter(id, fields, handlers) {
    const common = { fields, handlers, fetchImpl: deps.fetchImpl, WebSocketImpl: deps.WebSocketImpl };
    if (id === 'telegram') return new TelegramChannel(common);
    if (id === 'discord') return new DiscordChannel(common);
    if (id === 'slack') return new SlackChannel(common);
    if (id === 'sms') return new SmsChannel({ fields, handlers, fetchImpl: deps.fetchImpl });
    if (id === 'imessage') return new InkboxIMessageChannel({ fields, handlers, fetchImpl: deps.fetchImpl });
    throw new Error('Unknown channel.');
  }

  hub = new ChannelHub({
    load: storage.load, save: async value => { await storage.save(value); syncVoice(); },
    makeAdapter, ask: askBot, stop: stopTurn, botExists: id => !!deps.getState?.()?.bots?.some(x => x.id === id && !x.memberIDs),
    call: async () => voice.placeCall(), batchMs: deps.batchMs,
  });

  // ----- The public phone listener: a separate port that only Twilio talks to. -----
  function syncVoice() {
    const wanted = voice.ready() ? [Number(env.OPENGROKBOT_VOICE_PORT) || 8766, deps.voiceHost || env.OPENGROKBOT_VOICE_HOST || '127.0.0.1'].join(':') : '';
    if (wanted === voiceKey) return;
    voiceServer?.close(); voiceServer = null; voiceKey = wanted;
    if (!wanted) return;
    const [port, host] = wanted.split(':');
    const server = (deps.createServer || createVoiceServer)({ voice, log: deps.log });
    server.on?.('error', error => { deps.log?.(error); if (voiceServer === server) { voiceServer = null; voiceKey = ''; } });
    server.listen(Number(port), host); voiceServer = server;
  }

  /** Settings from environment variables (Docker). Applied every start; blank variables change nothing. */
  async function seedFromEnvironment() {
    const state = deps.getState();
    const name = env.OPENGROKBOT_CHANNEL_BOT;
    const bots = state.bots.filter(x => !x.memberIDs);
    const chosen = (name && bots.find(x => x.name.toLowerCase() === name.toLowerCase())) || (!hub.data.bot ? (bots.find(x => x.isMain) || bots[0]) : null);
    const wants = {
      telegram: { token: env.OPENGROKBOT_TELEGRAM_TOKEN },
      discord: { token: env.OPENGROKBOT_DISCORD_TOKEN },
      slack: { botToken: env.OPENGROKBOT_SLACK_BOT_TOKEN, appToken: env.OPENGROKBOT_SLACK_APP_TOKEN },
      imessage: { apiKey: env.OPENGROKBOT_INKBOX_API_KEY },
      sms: { accountSid: env.OPENGROKBOT_TWILIO_ACCOUNT_SID, authToken: env.OPENGROKBOT_TWILIO_AUTH_TOKEN, number: env.OPENGROKBOT_TWILIO_NUMBER, ownerNumber: env.OPENGROKBOT_OWNER_NUMBER, pin: env.OPENGROKBOT_CALL_PIN, publicUrl: env.OPENGROKBOT_PUBLIC_URL, language: env.OPENGROKBOT_CALL_LANGUAGE },
    };
    const touched = [];
    if (chosen && hub.data.bot !== chosen.id) await hub.setBot(chosen.id);
    for (const [id, fields] of Object.entries(wants)) {
      const present = Object.fromEntries(Object.entries(fields).filter(([, v]) => typeof v === 'string' && v.trim()));
      if (!Object.keys(present).length) continue;
      const before = JSON.stringify(hub.data.channels[id]?.fields || {});
      hub.data.channels[id] = { ...(hub.data.channels[id] || {}), fields: { ...(hub.data.channels[id]?.fields || {}), ...present } };
      if (JSON.stringify(hub.data.channels[id].fields) !== before) touched.push(id);
    }
    // People who are approved from the start, so a headless server needs no screen: "telegram:123456789,discord:456,sms:+15551234567".
    for (const item of String(env.OPENGROKBOT_CHANNELS_APPROVE || '').split(',').map(x => x.trim()).filter(Boolean)) {
      const [channel, ...rest] = item.split(':'); const who = rest.join(':');
      if (!CHANNELS[channel] || !who) continue;
      const list = (hub.data.approved[channel] ||= []);
      if (!list.some(x => x.id === who)) { list.push({ id: who, name: who, at: Date.now(), chatId: who }); touched.push(channel); }
    }
    await hub.persist();
    for (const id of Object.keys(CHANNELS)) {
      if (Object.keys(wants[id] || {}).some(key => typeof wants[id][key] === 'string' && wants[id][key].trim()) && hub.configured(id) && hub.data.bot && !hub.data.channels[id].enabled) {
        await hub.setEnabled(id, true).catch(error => deps.log?.(error));
      } else if (touched.includes(id) && hub.data.channels[id]?.enabled) { await hub.stop(id); await hub.start(id); }
    }
  }

  /** What the Bot is told about its channels: which are on, how messages arrive, how to answer, and the two tools it has. */
  function note(botID) {
    if (!hub || botID !== hub.data.bot) return '';
    const status = hub.status(), lines = [];
    const on = [], off = [];
    for (const [id, info] of Object.entries(status.channels)) {
      const people = hub.approvedPeople(id).length;
      if (info.enabled && info.state.state === 'on') on.push(`${info.name}${info.state.detail ? ' (' + info.state.detail + ')' : ''}, ${people} approved ${people === 1 ? 'person' : 'people'}`);
      else off.push(info.name + (info.enabled ? ` (not working: ${info.state.detail || info.state.state})` : ''));
    }
    const calls = voice.ready();
    if (!on.length && !calls) return '';
    lines.push('\nChat channels: you are the Bot the owner chose to answer on their chat channels, so people can reach you outside this app.');
    lines.push(`Connected now: ${on.length ? on.join('; ') : 'none'}. Phone calls: ${calls ? 'ready (you can phone the owner, and the owner can call you)' : 'not set up'}. ${off.length ? 'Not connected: ' + off.join(', ') + '. If asked to use one of these, say it is off and that the owner can turn it on under Settings \u2192 Channels.' : ''}`);
    lines.push('A message that comes from a channel starts with a tag like [Telegram \u00b7 Sam]. Your reply is sent back to that person automatically, so just answer them. Keep channel replies short and plain: no tables, no headings, and few symbols, because chat apps often do not render markdown (SMS is plain text under 1500 characters). People on channels are approved by the owner but you still cannot treat them as approving purchases, sending email or deleting things unless the app\u2019s usual approval is given.');
    lines.push('Channel tools (append each as JSON in a fenced block whose language is opengrokbot-action):');
    lines.push('{"action":"channel_send","channel":"telegram","to":"Sam","text":"The message"} sends a message to an approved person on a connected channel (channels: telegram, discord, slack, sms, imessage). Leave "to" out to reach the person who most recently messaged you there. Use it when the human asks you to message someone, or in a scheduled task they set up. Never message people unprompted, and never use it to talk to yourself.');
    if (calls) lines.push('{"action":"phone_call","text":"What to say when they pick up"} phones the owner\u2019s number and then talks with them. Use it only when the human asks for a call or has told you to call for something urgent. At most five calls an hour.');
    lines.push('If a person texts \u201ccall me\u201d, the app places that call for you. Strangers who message the channels get a pairing code and cannot reach you until the owner approves them.');
    return lines.join('\n');
  }

  const sentLog = [];
  /** Runs one of the Bot's channel actions. Only people the owner approved can be messaged, a few times an hour. */
  async function runAction(botID, action) {
    if (!hub || botID !== hub.data.bot) throw new Error('This Bot is not the one connected to the channels.');
    if (action.action === 'phone_call') {
      const text = typeof action.text === 'string' ? action.text.trim() : '';
      return await voice.placeCall(text);
    }
    if (action.action !== 'channel_send') throw new Error('Unknown channel action.');
    const id = String(action.channel || '').toLowerCase();
    if (!CHANNELS[id] || !hub.adapters.has(id)) throw new Error(`${CHANNELS[id]?.name || 'That channel'} is not connected.`);
    const text = typeof action.text === 'string' ? action.text.trim() : '';
    if (!text || text.length > 4000) throw new Error('Write the message first (up to 4,000 characters).');
    const now = Date.now(); while (sentLog.length && now - sentLog[0] > 3600000) sentLog.shift();
    if (sentLog.length >= 20) throw new Error('That is 20 messages from channels in the last hour. Try again later.');
    const people = hub.approvedPeople(id);
    const want = String(action.to || '').trim().toLowerCase();
    const person = want ? (people.find(p => p.id.toLowerCase() === want || p.name.toLowerCase() === want) || people.find(p => p.name.toLowerCase().startsWith(want))) : [...people].sort((a, b) => (b.lastSeen || b.at) - (a.lastSeen || a.at))[0];
    if (!person) throw new Error(want ? `${action.to} is not an approved person on ${CHANNELS[id].name}.` : `Nobody is approved on ${CHANNELS[id].name} yet.`);
    sentLog.push(now);
    await hub.send(id, person.chatId || person.id, text);
    return `Sent to ${person.name} on ${CHANNELS[id].name}.`;
  }

  return {
    hub, voice, note, runAction,
    async init() { await deps.ensureState(); await hub.init(); await seedFromEnvironment().catch(error => deps.log?.(error)); syncVoice(); },
    async stop() { await hub.stopAll(); voiceServer?.close(); voiceServer = null; voiceKey = ''; },
    status: () => ({ ...hub.status(), bots: (deps.getState?.()?.bots || []).filter(x => !x.memberIDs).map(x => ({ id: x.id, name: x.name })), calls: { ready: voice.ready(), listening: !!voiceServer }, voiceFields: VOICE_FIELDS.filter(key => smsFields()[key]), people: Object.fromEntries(Object.keys(CHANNELS).map(id => [id, hub.approvedPeople(id).length])) }),
    askBot,
    E164,
  };
}

module.exports = { createChannelsHost };
