'use strict';
// Connects the chat channels (hub, adapters, phone calls) to this app: storage, the Bot that answers, the public phone listener,
// and settings from environment variables for a headless Docker server.
const { ChannelHub, CHANNELS } = require('./channel-hub.cjs');
const { TelegramChannel } = require('./channel-telegram.cjs');
const { DiscordChannel } = require('./channel-discord.cjs');
const { SlackChannel } = require('./channel-slack.cjs');
const { SmsChannel, VoiceCalls, E164 } = require('./channel-twilio.cjs');
const { createVoiceServer } = require('./channel-voice-server.cjs');

const FILE = 'channels.json', ENCRYPTED = 'channels.encrypted.json';
const VOICE_FIELDS = ['ownerNumber', 'pin', 'publicUrl', 'language'];

/**
 * @param {{
 *  loadJSON, atomicJSON, safeStorage, platform?: string, ensureState: () => Promise<void>, getState: () => object,
 *  startChat: (botID: string, text: string) => Promise<void>, isRunning: (botID: string) => boolean,
 *  env?: object, fetchImpl?: typeof fetch, WebSocketImpl?: any, createServer?: Function, log?: (e: Error) => void, sleep?: (ms: number) => Promise<void>,
 *  voiceHost?: string, askTimeout?: number
 * }} deps
 */
function createChannelsHost(deps) {
  const env = deps.env || process.env, platform = deps.platform || process.platform, sleep = deps.sleep || (ms => new Promise(r => setTimeout(r, ms)));
  const askTimeout = deps.askTimeout ?? 15 * 60 * 1000;
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
    ask: text => askBot(hub.data.bot, text, { channel: 'phone' }),
    fetchImpl: deps.fetchImpl,
  });

  /** Sends a message to the chosen Bot like someone typing it, waits for the run to finish, and returns its reply. */
  async function askBot(botID, text) {
    await deps.ensureState();
    const state = deps.getState(); const before = state.entries.length;
    if (!state.bots.some(x => x.id === botID)) throw new Error('That Bot is gone. Choose another under Settings → Channels.');
    await deps.startChat(botID, text);
    const deadline = Date.now() + askTimeout;
    while (deps.isRunning(botID)) {
      if (Date.now() > deadline) return 'Still working on it, or waiting for your OK in Bothive. I’ll leave the answer in the chat.';
      await sleep(400);
    }
    const reply = deps.getState().entries.slice(before).filter(e => e.botID === botID && e.kind === 'bot').at(-1);
    if (!reply) return 'The Bot did not answer.';
    if (reply.state === 'failed') throw new Error(reply.text || 'The Bot could not finish that.');
    return reply.text;
  }

  function makeAdapter(id, fields, handlers) {
    const common = { fields, handlers, fetchImpl: deps.fetchImpl, WebSocketImpl: deps.WebSocketImpl };
    if (id === 'telegram') return new TelegramChannel(common);
    if (id === 'discord') return new DiscordChannel(common);
    if (id === 'slack') return new SlackChannel(common);
    if (id === 'sms') return new SmsChannel({ fields, handlers, fetchImpl: deps.fetchImpl });
    throw new Error('Unknown channel.');
  }

  hub = new ChannelHub({
    load: storage.load, save: async value => { await storage.save(value); syncVoice(); },
    makeAdapter, ask: askBot, botExists: id => !!deps.getState?.()?.bots?.some(x => x.id === id && !x.memberIDs),
    call: async () => voice.placeCall(),
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

  return {
    hub, voice,
    async init() { await deps.ensureState(); await hub.init(); await seedFromEnvironment().catch(error => deps.log?.(error)); syncVoice(); },
    async stop() { await hub.stopAll(); voiceServer?.close(); voiceServer = null; voiceKey = ''; },
    status: () => ({ ...hub.status(), calls: { ready: voice.ready(), listening: !!voiceServer }, voiceFields: VOICE_FIELDS.filter(key => smsFields()[key]), people: Object.fromEntries(Object.keys(CHANNELS).map(id => [id, hub.approvedPeople(id).length])) }),
    askBot,
    E164,
  };
}

module.exports = { createChannelsHost };
