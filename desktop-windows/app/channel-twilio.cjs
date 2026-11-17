'use strict';
// Twilio (10.1.1): SMS to and from the Bot, and phone calls where you talk to it.
//  - SMS: polled over Twilio's REST API, so nothing needs to be reachable from outside.
//  - Calls: Twilio asks a public web address what to say. That address is a tiny separate listener (channel-voice-server.cjs) that only
//    answers Twilio, checks Twilio's signature on every request and serves nothing else. Calls are turn by turn: Twilio turns your speech
//    into text, the Bot answers, Twilio reads the answer. A Bot answer can take longer than a call allows silence, so the call holds
//    with short pauses until the answer is ready.
const crypto = require('node:crypto');
const { spoken, xml } = require('./channel-text.cjs');

const API = 'https://api.twilio.com/2010-04-01';

class TwilioApi {
  constructor({ accountSid, authToken, fetchImpl = fetch }) { this.sid = accountSid; this.token = authToken; this.fetch = fetchImpl; }
  async request(path, { method = 'GET', form } = {}) {
    const response = await this.fetch(`${API}/Accounts/${encodeURIComponent(this.sid)}/${path}`, {
      method, headers: { Authorization: 'Basic ' + Buffer.from(`${this.sid}:${this.token}`).toString('base64'), ...(form ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}) },
      body: form ? new URLSearchParams(form).toString() : undefined, signal: AbortSignal.timeout(20000),
    });
    const reply = await response.json().catch(() => ({}));
    if (response.status === 401) { const error = new Error('Twilio did not accept that Account SID and Auth Token.'); error.code = 401; throw error; }
    if (!response.ok) throw new Error(reply.message || `Twilio answered ${response.status}.`);
    return reply;
  }
  account() { return this.request('.json'); }
  inbound(to) { return this.request(`Messages.json?${new URLSearchParams({ To: to, PageSize: '50' })}`).then(reply => (reply.messages || []).filter(message => message.direction === 'inbound')); }
  sendMessage(from, to, body) { return this.request('Messages.json', { method: 'POST', form: { From: from, To: to, Body: body } }); }
  call(from, to, url) { return this.request('Calls.json', { method: 'POST', form: { From: from, To: to, Url: url, Method: 'POST' } }); }
}

/** Twilio signs every request: base64(HMAC-SHA1(authToken, full URL + each POST parameter name and value, sorted by name)). */
function signature(authToken, url, params) {
  const text = url + Object.keys(params).sort().map(key => key + params[key]).join('');
  return crypto.createHmac('sha1', authToken).update(text).digest('base64');
}
function validSignature(authToken, url, params, given) {
  if (!authToken || typeof given !== 'string') return false;
  const expected = Buffer.from(signature(authToken, url, params)), actual = Buffer.from(given);
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

const E164 = /^\+[1-9]\d{6,14}$/;

/** SMS: texts to your Twilio number reach the Bot, and its answers go back as texts. */
class SmsChannel {
  constructor({ fields, handlers, fetchImpl = fetch, interval = 6000, setTimer = setTimeout, clearTimer = clearTimeout }) {
    this.fields = fields; this.onMessage = handlers.onMessage; this.api = new TwilioApi({ accountSid: fields.accountSid, authToken: fields.authToken, fetchImpl });
    this.interval = interval; this.setTimer = setTimer; this.clearTimer = clearTimer; this.running = false; this.seen = new Set(); this.timer = null; this.info = { state: 'starting', detail: '' };
  }
  status() { return this.info; }
  fail(error) { this.info = { state: 'error', detail: error.message }; }
  async start() {
    if (!E164.test(this.fields.number || '')) throw new Error('Use the Twilio number with its country code, for example +15551234567.');
    try { await this.api.account(); } catch (error) { throw error; }
    // Whatever is already in the inbox is old. Only messages that arrive from now on are answered.
    for (const message of await this.api.inbound(this.fields.number)) this.seen.add(message.sid);
    this.running = true; this.info = { state: 'on', detail: this.fields.number }; this.schedule();
  }
  async stop() { this.running = false; this.clearTimer(this.timer); this.info = { state: 'off', detail: '' }; }
  schedule() { if (this.running) this.timer = this.setTimer(() => this.poll(), this.interval); }
  async poll() {
    try {
      const messages = (await this.api.inbound(this.fields.number)).filter(message => !this.seen.has(message.sid)).reverse();
      for (const message of messages) {
        this.seen.add(message.sid);
        if (message.body && message.from) Promise.resolve(this.onMessage({ senderId: message.from, senderName: message.from, chatId: message.from, text: message.body })).catch(() => {});
      }
      if (this.seen.size > 1000) this.seen = new Set([...this.seen].slice(-500));
      if (this.running) this.info = { state: 'on', detail: this.fields.number };
    } catch (error) {
      if (error.code === 401) { this.running = false; this.info = { state: 'error', detail: 'Twilio no longer accepts these keys.' }; return; }
      this.info = { state: 'error', detail: `Reconnecting: ${error.message}` };
    }
    this.schedule();
  }
  async send(chatId, text) { await this.api.sendMessage(this.fields.number, chatId, text); }
}

/** Phone calls. `settings()` returns { accountSid, authToken, number, ownerNumber, pin, publicUrl, language, botName }. */
class VoiceCalls {
  constructor({ settings, ask, fetchImpl = fetch, now = Date.now, token = () => crypto.randomBytes(12).toString('hex') }) {
    this.settings = settings; this.ask = ask; this.fetch = fetchImpl; this.now = now; this.makeToken = token;
    this.calls = new Map(); this.placed = []; this.outbound = new Map();
  }
  get config() { return this.settings(); }
  ready() { const c = this.config; return !!(c.accountSid && c.authToken && E164.test(c.number || '') && E164.test(c.ownerNumber || '') && /^https:\/\//.test(c.publicUrl || '')); }

  /** Rings the owner. At most 5 calls an hour, and only ever the owner's own number. */
  async placeCall() {
    const c = this.config;
    if (!this.ready()) throw new Error('Calls are not set up. Under Settings → Channels → SMS and calls, add your Twilio number, your own number and the public address.');
    this.placed = this.placed.filter(time => this.now() - time < 3600000);
    if (this.placed.length >= 5) throw new Error('That is five calls in the last hour. Try again later.');
    const token = this.makeToken(); this.outbound.set(token, this.now());
    for (const [key, time] of this.outbound) if (this.now() - time > 600000) this.outbound.delete(key);
    try { await new TwilioApi({ accountSid: c.accountSid, authToken: c.authToken, fetchImpl: this.fetch }).call(c.number, c.ownerNumber, `${c.publicUrl.replace(/\/$/, '')}/twilio/voice?t=${token}`); }
    catch (error) { this.outbound.delete(token); throw error; }
    this.placed.push(this.now());
    return 'Calling you now.';
  }

  say(text) { const c = this.config; return `<Say voice="Polly.Joanna" language="${xml(c.language || 'en-US')}">${xml(text)}</Say>`; }
  twiml(body) { return `<?xml version="1.0" encoding="UTF-8"?><Response>${body}</Response>`; }
  link(path, query) { const c = this.config; return `${c.publicUrl.replace(/\/$/, '')}/twilio/voice${path}?${new URLSearchParams(query)}`; }
  listen(call, prompt) {
    const c = this.config;
    return `<Gather input="speech" action="${xml(this.link('/turn', { c: call.id }))}" method="POST" speechTimeout="auto" timeout="6" language="${xml(c.language || 'en-US')}">${prompt ? this.say(prompt) : ''}</Gather>${this.say('I did not hear anything. Goodbye.')}<Hangup/>`;
  }

  /** One request from Twilio (already signature checked). Returns TwiML. */
  async handle(pathname, params, query) {
    const c = this.config;
    if (!this.ready() || params.AccountSid !== c.accountSid) return this.twiml(this.say('This number is not set up. Goodbye.') + '<Hangup/>');
    const callSid = params.CallSid;
    if (pathname === '/twilio/voice') {
      const outbound = query.t && this.outbound.has(query.t);
      const call = { id: this.makeToken(), sid: callSid, authed: !!outbound, tries: 0, silent: 0, started: this.now(), job: null };
      if (outbound) this.outbound.delete(query.t);
      else if (!(c.pin && /^\d{4,8}$/.test(c.pin)) || params.From !== c.ownerNumber) return this.twiml(this.say('Sorry, I can only take calls from my owner. Goodbye.') + '<Hangup/>');
      this.calls.set(call.id, call);
      for (const [id, item] of this.calls) if (this.now() - item.started > 3600000) this.calls.delete(id);
      if (!call.authed) return this.twiml(`<Gather input="dtmf" numDigits="${c.pin.length}" action="${xml(this.link('/pin', { c: call.id }))}" method="POST" timeout="8">${this.say('Enter your pin.')}</Gather>${this.say('Goodbye.')}<Hangup/>`);
      return this.twiml(this.listen(call, `Hi, it is ${c.botName || 'your Bot'}. What can I do for you?`));
    }
    const call = this.calls.get(query.c);
    if (!call || call.sid !== callSid) return this.twiml(this.say('That call has ended. Goodbye.') + '<Hangup/>');
    if (pathname === '/twilio/voice/pin') {
      const given = String(params.Digits || '');
      const ok = given.length === c.pin.length && crypto.timingSafeEqual(Buffer.from(given), Buffer.from(c.pin));
      if (ok) { call.authed = true; return this.twiml(this.listen(call, `Hi, it is ${c.botName || 'your Bot'}. What can I do for you?`)); }
      if (++call.tries >= 3) { this.calls.delete(call.id); return this.twiml(this.say('That is not right. Goodbye.') + '<Hangup/>'); }
      return this.twiml(`<Gather input="dtmf" numDigits="${c.pin.length}" action="${xml(this.link('/pin', { c: call.id }))}" method="POST" timeout="8">${this.say('That is not right. Try again.')}</Gather><Hangup/>`);
    }
    if (!call.authed) return this.twiml(this.say('Goodbye.') + '<Hangup/>');
    if (pathname === '/twilio/voice/turn') {
      const said = String(params.SpeechResult || '').trim();
      if (!said) { if (++call.silent >= 2) return this.twiml(this.say('I did not hear anything. Goodbye.') + '<Hangup/>'); return this.twiml(this.listen(call, 'Sorry, I did not catch that.')); }
      call.silent = 0;
      if (/^(?:(?:ok(?:ay)?|thanks?(?: you)?|yeah|alright|great)[,.!]?\s+)?(?:good\s?bye|bye|hang up|that'?s all|that is all)\b/i.test(said)) { this.calls.delete(call.id); return this.twiml(this.say('Goodbye.') + '<Hangup/>'); }
      call.job = { done: false, text: '', started: this.now() };
      const job = call.job;
      Promise.resolve(this.ask(`[Phone call. Answer in one to three short spoken sentences, with no lists, links or markdown.] ${said.slice(0, 1000)}`))
        .then(text => { job.text = spoken(text) || 'I have nothing to add.'; }, error => { job.text = spoken(error.message || 'Sorry, I could not answer that.'); })
        .finally(() => { job.done = true; });
      return this.twiml(this.say('One moment.') + `<Redirect method="POST">${xml(this.link('/wait', { c: call.id }))}</Redirect>`);
    }
    if (pathname === '/twilio/voice/wait') {
      const job = call.job;
      if (!job) return this.twiml(this.listen(call, ''));
      if (job.done) { call.job = null; return this.twiml(this.listen(call, job.text)); }
      if (this.now() - job.started > 150000) { call.job = null; return this.twiml(this.listen(call, 'That is taking too long. Ask me again, or check the chat.')); }
      return this.twiml(`<Pause length="3"/><Redirect method="POST">${xml(this.link('/wait', { c: call.id }))}</Redirect>`);
    }
    return this.twiml(this.say('Goodbye.') + '<Hangup/>');
  }
}

module.exports = { TwilioApi, SmsChannel, VoiceCalls, signature, validSignature, E164 };
