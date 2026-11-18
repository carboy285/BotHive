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
const { InkboxVoice } = require('./channel-inkbox-voice.cjs');

const FILE = 'channels.json', ENCRYPTED = 'channels.encrypted.json';
const VOICE_FIELDS = ['ownerNumber', 'pin', 'publicUrl', 'language'];

/**
 * @param {{
 *  loadJSON, atomicJSON, safeStorage, platform?: string, ensureState: () => Promise<void>, getState: () => object,
 *  record?: (botID: string, text: string) => Promise<void>, afterTurn?: (botID: string) => void, settleApproval?: (id: string, yes: boolean) => boolean, now?: () => number,
 *  startChat: (botID: string, text: string, options?: object) => Promise<void>, stop?: (botID: string) => void, botDirectory?: (botID: string) => string, isRunning: (botID: string) => boolean,
 *  env?: object, fetchImpl?: typeof fetch, WebSocketImpl?: any, createServer?: Function, log?: (e: Error) => void, sleep?: (ms: number) => Promise<void>,
 *  voiceHost?: string, askTimeout?: number, batchMs?: number, pollMs?: number
 * }} deps
 */
function createChannelsHost(deps) {
  const env = deps.env || process.env, platform = deps.platform || process.platform, sleep = deps.sleep || (ms => new Promise(r => setTimeout(r, ms)));
  const askTimeout = deps.askTimeout ?? 15 * 60 * 1000, pollMs = deps.pollMs ?? 150;
  const turns = new Map(), cancelled = new Set(); let turnCounter = 0;
  const now = () => (deps.now ? deps.now() : Date.now());
  const turnFrom = new Map(), approvalAsks = new Map(), outreachLog = [], delegations = new Map(), mirrorLog = [];
  let inkboxVoice = null, inkboxKey = '', voicesCache = [], askTimer = null, syncTimer = null;
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
    if (from?.replyTo) body = `(This answers the question you asked them: \u201c${String(from.replyTo).slice(0, 300)}\u201d. Carry on with what you were doing.)\n${body}`;
    if (from) body = `[${CHANNELS[from.channel]?.name || from.channel} \u00b7 ${String(from.senderName || 'someone').slice(0, 60)}${from.me ? ' \u00b7 the owner' : ''}] ${body}`;
    if (options.steer) body += STEER_NOTE;
    const token = ++turnCounter; turns.set(botID, token); if (from?.channel && from.channel !== 'phone') turnFrom.set(botID, from);
    await deps.startChat(botID, body, { channelTurn: options.fast !== false && from?.channel !== 'phone', channel: true });
    const deadline = Date.now() + askTimeout;
    while (deps.isRunning(botID)) {
      if (Date.now() > deadline) return 'Still working on it, or waiting for your OK in Bothive. I’ll leave the answer in the chat.';
      await sleep(pollMs);
    }
    if (turnFrom.get(botID) === from) turnFrom.delete(botID);
    if (cancelled.delete(token)) return null;
    const reply = deps.getState().entries.slice(before).filter(e => e.botID === botID && e.kind === 'bot').at(-1);
    if (!reply) return 'The Bot did not answer.';
    // The Bot handed part of this to other Bots: when they answer, it gets a follow-up turn so the person hears back.
    if (from && from.channel !== 'phone' && (deps.getState().teamMessages || []).some(m => m.rootID === reply.id && m.from === botID)) delegations.set(reply.id, { botID, from, at: now() });
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
    load: storage.load, save: async value => { await storage.save(value); syncVoice(); syncInkbox(); },
    makeAdapter, ask: askBot, stop: stopTurn, botExists: id => !!deps.getState?.()?.bots?.some(x => x.id === id && !x.memberIDs),
    call: from => callOwner(from), answerApproval: (from, yes) => answerApproval(from, yes), batchMs: deps.batchMs,
  });

  // ----- Phone calls through Inkbox Voice AI -----
  const ownerNumber = () => {
    const mine = hub.owner('imessage')?.person; if (mine && E164.test(mine.id)) return mine.id;
    const typed = hub.data.channels.imessage?.fields?.ownerNumber; return typed && E164.test(typed) ? typed : '';
  };
  const quiet = () => { const hour = new Date(now()).getHours(), { quietStart: a, quietEnd: b } = hub.settings; return a === b ? false : a < b ? hour >= a && hour < b : hour >= a || hour < b; };

  function syncInkbox() {
    const config = hub?.data.channels.imessage, want = config?.enabled && config.fields?.apiKey ? [config.fields.apiKey, config.fields.voice || '', config.fields.voiceLine || ''].join('|') : '';
    if (want === inkboxKey) return;
    inkboxVoice?.stop(); inkboxVoice = null; inkboxKey = want;
    if (!want) return;
    const voiceBot = () => { const state = deps.getState?.(); return state?.bots?.find(x => x.id === hub.data.bot); };
    inkboxVoice = new InkboxVoice({
      fields: config.fields, fetchImpl: deps.fetchImpl, now, log: deps.log,
      context: () => { const bot = voiceBot(); const owner = hub.owner('imessage')?.person; return { botName: bot?.name, purpose: bot?.purpose, summary: bot?.summary, memory: bot?.memory, ownerName: owner?.display || owner?.name }; },
      onCall: importCall,
    });
    inkboxVoice.start().then(() => inkboxVoice.voices().then(list => { voicesCache = list; }).catch(() => {})).catch(error => { if (inkboxVoice) inkboxVoice.info = { state: 'error', detail: error.message }; });
  }
  /** Tell the voice agent about new memory. Waits a little so a burst of changes is one update. */
  function voiceInstructionsChanged() {
    if (!inkboxVoice) return; clearTimeout(syncTimer);
    syncTimer = setTimeout(() => inkboxVoice?.syncInstructions().catch(() => {}), deps.syncDelay ?? 30000); syncTimer.unref?.();
  }

  /** A finished call: its transcript goes into the Bot's chat and memory, and whatever it needs done is handed to the Bot. */
  async function importCall(call) {
    const botID = hub.data.bot; if (!botID || !deps.record) return;
    const owner = hub.owner('imessage')?.person, name = owner?.display || owner?.name || call.number || 'someone';
    const lines = call.transcript.map(x => `${x.party === 'person' ? name : 'You'}: ${x.text}`).join('\n').slice(0, 6000);
    const transcript = lines || (call.transcriptError ? `(the transcript could not be downloaded: ${call.transcriptError})` : '(no speech was recorded)');
    const minutes = call.seconds >= 60 ? `${Math.round(call.seconds / 60)} min` : `${call.seconds} s`;
    const what = `${call.direction === 'outbound' ? 'You phoned them' : 'They phoned you'}${call.reason ? ` (${call.reason.slice(0, 200)})` : ''}, ${minutes}${call.outcome && call.status !== 'completed' ? ', ' + call.outcome : ''}`;
    await deps.record(botID, `[Phone call · ${name}] ${what}.\n${transcript}`);
    const ask = hub.pendingAsk, spoke = call.transcript.filter(x => x.party === 'person').map(x => x.text).join(' ').trim();
    const todo = call.items.map(x => `- ${x.action}${x.details ? ': ' + x.details : ''}`).join('\n');
    let text = '';
    if (ask && spoke && call.number && call.number === ownerNumber()) { await hub.clearAsk(); text = `(This call answers the question you asked them: “${ask.question.slice(0, 300)}”.)\n`; }
    // Every call becomes a turn for the Bot, so its own session knows what was said and it can carry on.
    text += `(Automatic follow-up after a phone call, not a new text from them.) You just finished a phone call with ${name}: ${what}. Inkbox’s voice assistant spoke for you on the call and could not use your tools. The full transcript:\n${transcript}\n${todo ? 'Left to do from the call:\n' + todo + '\n' : ''}Keep what matters from this call in mind from now on. Carry on with anything that is left to do (anything that sends, buys, posts or deletes still needs the human’s OK), then reply with a one-line recap for them.`;
    const target = hub.owner('imessage') || hub.owner();
    try {
      if (target && hub.adapters.has(target.channel)) await hub.followUp({ channel: target.channel, senderId: target.person.id, senderName: name, me: true, chatId: target.person.chatId || target.person.id }, text);
      else await askBot(botID, text, { channel: 'phone', senderName: name, me: true }, { fast: false });
    } catch (error) { deps.log?.(error); }
    try { await deps.forceMemory?.(botID); } catch {}
  }

  /** Other Bots finished the work the channel Bot handed them: give it a follow-up turn with their answers so the person hears back. */
  async function checkDelegations() {
    const state = deps.getState?.(); if (!state || !hub) return;
    for (const [root, job] of [...delegations]) {
      if (now() - job.at > 15 * 60000) { delegations.delete(root); continue; }
      const messages = (state.teamMessages || []).filter(m => m.rootID === root);
      if (messages.some(m => m.status === 'queued' || m.status === 'running')) continue;
      delegations.delete(root);
      const since = job.at - 1000;
      const answers = state.entries.filter(e => e.botID === job.botID && e.kind === 'bot' && e.senderBotID && Date.parse(e.date || 0) >= since).map(e => `${e.senderName || 'A Bot'}: ${String(e.text).slice(0, 3000)}`);
      const failed = messages.filter(m => m.from === job.botID && m.status !== 'complete').map(m => state.bots.find(b => b.id === m.to)?.name || 'A Bot');
      if (!answers.length && !failed.length) continue;
      const text = `(Automatic follow-up, not a new message from them.) The Bots you asked have finished.\n${answers.join('\n\n')}${failed.length ? `\n${failed.join(', ')} could not finish.` : ''}\nUse this to finish their request and reply to them.`;
      hub.followUp(job.from, text).catch(error => deps.log?.(error));
    }
  }

  /** A reply the Bot gave outside a chat channel. Depending on "Where replies go", it is also texted to the owner. */
  async function afterReply(botID, { text, origin } = {}) {
    await checkDelegations();
    if (!hub || botID !== hub.data.bot || origin === 'channel' || origin === 'delivery') return false;
    if (origin === 'app' && hub.settings.replies !== 'always') return false;
    const clean = String(text || '').trim(); if (!clean) return false;
    const target = hub.owner(hub.settings.reachOn); if (!target || !hub.adapters.has(target.channel)) return false;
    const t = now(); while (mirrorLog.length && t - mirrorLog[0] > 3600000) mirrorLog.shift();
    if (mirrorLog.length >= 30) return false;
    mirrorLog.push(t);
    try { await hub.send(target.channel, target.person.chatId || target.person.id, clean.slice(0, 6000)); return true; } catch (error) { deps.log?.(error); return false; }
  }

  /** "Call me" from a chat, or the Call me now button. */
  async function callOwner(from) {
    if (inkboxVoice?.ready()) {
      const number = ownerNumber();
      if (from && !from.me && !(from.channel === 'imessage' && E164.test(from.senderId) && from.senderId === number)) throw new Error('Only the owner can ask for a call.');
      if (!number) throw new Error('Add your own phone number under Settings → Channels → iMessage, or mark yourself as Me.');
      await inkboxVoice.placeCall(number, 'The owner asked you to phone them. Greet them by name, say you are ready, and ask how you can help.');
      return 'Calling you now.';
    }
    return voice.placeCall();
  }
  const callsReady = () => voice.ready() || !!inkboxVoice?.ready();

  // ----- The Bot asks the owner something, or needs an OK -----
  function approvalFrom(ask) { return `Needs your OK: ${ask.title}${ask.detail ? ' — ' + ask.detail.slice(0, 600) : ''}\nReply yes or no.`; }
  /** Sends an approval prompt to the owner's chat. Returns true when it was sent. The window prompt stays; the first answer wins. */
  async function routeApproval({ id, title, detail }) {
    const target = hub?.owner(hub.settings.reachOn); if (!target || !hub.adapters.has(target.channel)) return false;
    try { await hub.send(target.channel, target.person.chatId || target.person.id, approvalFrom({ title, detail })); } catch { return false; }
    approvalAsks.set(id, { channel: target.channel, senderId: target.person.id, at: now() });
    return true;
  }
  function answerApproval(from, yes) {
    for (const [id, ask] of approvalAsks) {
      if (now() - ask.at > 3600000) { approvalAsks.delete(id); continue; }
      if (ask.channel === from.channel && ask.senderId === from.senderId) { approvalAsks.delete(id); return deps.settleApproval?.(id, yes) !== false; }
    }
    return false;
  }
  function approvalSettled(id) { approvalAsks.delete(id); }

  const OUTREACH_HOUR = 5, OUTREACH_DAY = 20;
  /** Text that is safe as the first message of a conversation: Inkbox wants under 160 characters, no links and no phone numbers until the person replies. */
  function openingText(text) {
    const clean = String(text).replace(/https?:\/\/\S+|www\.\S+/gi, '').replace(/\+?\d[\d\s().-]{7,}\d/g, '').replace(/\s+/g, ' ').trim();
    return clean.length <= 159 ? clean : clean.slice(0, 156).replace(/\s+\S*$/, '') + '…';
  }
  async function askOwner(botID, action) {
    const question = typeof action.text === 'string' ? action.text.trim() : '';
    if (!question || question.length > 1500) throw new Error('Write the question first (up to 1,500 characters).');
    const target = hub.owner(hub.settings.reachOn);
    if (!target) throw new Error('Nobody is marked Me yet. Open Settings → Channels and tick Me next to your own name, so the Bot knows who to reach out to.');
    const t = now(); while (outreachLog.length && t - outreachLog[0] > 86400000) outreachLog.shift();
    if (outreachLog.length >= OUTREACH_DAY || outreachLog.filter(x => t - x < 3600000).length >= OUTREACH_HOUR) throw new Error('That is as many messages to the owner as allowed for now. Try again later.');
    const { channel, person } = target, label = person.display || person.name;
    const talking = turnFrom.get(botID); const alreadyThere = talking && talking.channel === channel && talking.senderId === person.id;
    const ask = { botID, channel, senderId: person.id, chatId: person.chatId || person.id, question, askedAt: t, urgent: action.urgent === true, escalated: false };
    if (!alreadyThere) {
      let how = 'text';
      try {
        if (!hub.adapters.has(channel)) throw new Error(`${CHANNELS[channel].name} is not connected.`);
        const fresh = channel === 'imessage' && (!person.lastSeen || t - person.lastSeen > 12 * 3600000);
        await hub.send(channel, ask.chatId, fresh ? openingText(question) : question);
      } catch (error) {
        const number = ownerNumber();
        if (ask.urgent && inkboxVoice?.ready() && number && !quiet()) { await inkboxVoice.placeCall(number, `Ask the owner this and record the answer: ${question}`); how = 'call'; }
        else throw new Error(`Could not reach ${label} on ${CHANNELS[channel].name}${channel === 'imessage' ? ' (they need to text the Bot once first, or Inkbox’s link has lapsed)' : ''}: ${error.message}`);
      }
      outreachLog.push(t);
      await hub.setPendingAsk(ask);
      return how === 'call' ? `Phoned ${label} to ask. Their answer comes back to you after the call.` : `Asked ${label} on ${CHANNELS[channel].name}. Their reply comes back to you.`;
    }
    await hub.setPendingAsk(ask);
    return `Waiting for ${label}’s answer.`;
  }

  /** Runs every half minute: an urgent question nobody answered becomes a call, outside quiet hours, or a second text. */
  async function checkAsks() {
    const ask = hub?.pendingAsk; if (!ask) return;
    const t = now(); if (t - ask.askedAt > 24 * 3600000) { await hub.clearAsk(); return; }
    const { escalate, escalateMinutes } = hub.settings;
    if (!ask.urgent || ask.escalated || escalate === 'none' || t - ask.askedAt < escalateMinutes * 60000) return;
    ask.escalated = true; await hub.persist();
    const number = ownerNumber();
    if (escalate === 'call' && inkboxVoice?.ready() && number && !quiet()) {
      try { await inkboxVoice.placeCall(number, `Ask the owner this and record the answer: ${ask.question}`); return; } catch {}
    }
    await hub.send(ask.channel, ask.chatId, `Still need your answer: ${ask.question}`.slice(0, 1500)).catch(() => {});
  }

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
      const mine = /!me$/i.test(who), id = who.replace(/!me$/i, '');
      const existing = list.find(x => x.id === id);
      if (!existing) { list.push({ id, name: id, at: Date.now(), chatId: id, me: mine }); touched.push(channel); } else if (mine && !existing.me) { existing.me = true; touched.push(channel); }
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
    const calls = callsReady();
    if (!on.length && !calls) return '';
    lines.push('\nChat channels: you are the Bot the owner chose to answer on their chat channels, so people can reach you outside this app.');
    lines.push(`Connected now: ${on.length ? on.join('; ') : 'none'}. Phone calls: ${calls ? 'ready (you can phone the owner, and the owner can call you)' : 'not set up'}. ${off.length ? 'Not connected: ' + off.join(', ') + '. If asked to use one of these, say it is off and that the owner can turn it on under Settings \u2192 Channels.' : ''}`);
    lines.push('A message that comes from a channel starts with a tag like [Telegram \u00b7 Sam]. Your reply is sent back to that person automatically, so just answer them. Keep channel replies short and plain: no tables, no headings, and few symbols, because chat apps often do not render markdown (SMS is plain text under 1500 characters). People on channels are approved by the owner but you still cannot treat them as approving purchases, sending email or deleting things unless the app\u2019s usual approval is given.');
    lines.push('Channel tools (append each as JSON in a fenced block whose language is opengrokbot-action):');
    lines.push('{"action":"channel_send","channel":"telegram","to":"Sam","text":"The message"} sends a message to an approved person on a connected channel (channels: telegram, discord, slack, sms, imessage). Leave "to" out to reach the person who most recently messaged you there. Use it when the human asks you to message someone, or in a scheduled task they set up. You may also message the owner (the person marked Me) on your own when they would want to know: a task you finished, a result they are waiting for, a reminder they asked for. Never message anyone else unprompted, and never use it to talk to yourself.');
    if (calls) lines.push('{"action":"phone_call","text":"What the call is about"} phones the owner\u2019s number and then talks with them. Use it only when the human asks for a call or has told you to call for something urgent. At most five calls an hour. A phone call is answered by a separate fast voice assistant that knows your name and notes; the call transcript comes back into your chat afterwards.');
    if (hub.owner()) lines.push('{"action":"ask_owner","text":"The question","urgent":false} texts the owner (the person marked Me) when you need a decision or a missing detail and nobody is chatting with you: use it instead of guessing or stopping silently, then end your turn. Their next message on that channel comes back to you tagged as the answer. Set urgent true only when waiting would cause harm; then the app calls them if they do not answer. Do not use it just to report progress.');
    lines.push('If a person texts \u201ccall me\u201d, the app places that call for you. Strangers who message the channels get a pairing code and cannot reach you until the owner approves them.');
    return lines.join('\n');
  }

  const sentLog = [];
  /** Runs one of the Bot's channel actions. Only people the owner approved can be messaged, a few times an hour. */
  async function runAction(botID, action) {
    if (!hub || botID !== hub.data.bot) throw new Error('This Bot is not the one connected to the channels.');
    if (action.action === 'ask_owner') return await askOwner(botID, action);
    if (action.action === 'phone_call') {
      const text = typeof action.text === 'string' ? action.text.trim() : '';
      if (inkboxVoice?.ready()) {
        const number = ownerNumber(); if (!number) throw new Error('Add your own phone number under Settings \u2192 Channels \u2192 iMessage, or mark yourself as Me.');
        await inkboxVoice.placeCall(number, text || 'Phone the owner and ask how you can help.'); return 'Calling the owner now.';
      }
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
    async init() { await deps.ensureState(); await hub.init(); await seedFromEnvironment().catch(error => deps.log?.(error)); syncVoice(); syncInkbox(); askTimer = setInterval(() => { checkAsks().catch(() => {}); checkDelegations().catch(() => {}); }, deps.askCheckMs ?? 30000); askTimer.unref?.(); },
    async stop() { clearInterval(askTimer); clearTimeout(syncTimer); inkboxVoice?.stop(); inkboxVoice = null; inkboxKey = ''; await hub.stopAll(); voiceServer?.close(); voiceServer = null; voiceKey = ''; },
    get turnActive() { return turnFrom.size > 0; },
    afterReply, checkDelegations, importCall,
    askOwner, checkAsks, routeApproval, approvalSettled, voiceInstructionsChanged, callOwner, get inkbox() { return inkboxVoice; },
    async testCall() { return callOwner(null); },
    async setVoice(id) { await hub.configure('imessage', { voice: String(id || '') }); return this.status(); },
    status: () => ({ ...hub.status(), bots: (deps.getState?.()?.bots || []).filter(x => !x.memberIDs).map(x => ({ id: x.id, name: x.name })), calls: { ready: callsReady(), listening: !!voiceServer }, inkbox: { ready: !!inkboxVoice?.ready(), state: inkboxVoice?.status() || { state: 'off', detail: '' }, ownerNumber: ownerNumber(), voices: voicesCache, pendingAsk: hub.pendingAsk ? { question: hub.pendingAsk.question, askedAt: hub.pendingAsk.askedAt } : null }, voiceFields: VOICE_FIELDS.filter(key => smsFields()[key]), people: Object.fromEntries(Object.keys(CHANNELS).map(id => [id, hub.approvedPeople(id).length])) }),
    askBot,
    E164,
  };
}

module.exports = { createChannelsHost };
