'use strict';
// Phone calls through Inkbox Voice AI (inkbox.ai): Inkbox answers and places the calls with its own voice model, so it feels instant and
// needs no public address. Bothive feeds it the Bot (name, style, a summary and notes) as the call instructions, places calls with the
// reason as its brief, and reads finished calls back over REST so the transcript lands in the Bot's chat and memory.
// This is Inkbox's voice model, not the Bot's own CLI, so it cannot run the Bot's tools during a call.
const BASE = 'https://inkbox.ai/api/v1/phone';
const E164 = /^\+[1-9]\d{6,14}$/;
const INSTRUCTIONS_MAX = 8000, REASON_MAX = 2000, CALLS_PER_HOUR = 5;

/** The call instructions, built from the Bot. Always within Inkbox's 8,000 character limit. */
function buildInstructions({ botName = 'the assistant', purpose = '', summary = '', memory = [], ownerName = '' } = {}) {
  const head = `You are ${botName}, a personal AI assistant, speaking with ${ownerName || 'your owner'} on the phone. ${purpose ? 'Your job: ' + purpose.slice(0, 400) + ' ' : ''}` +
    'Talk like a person: short sentences, warm, no lists, no spelling out links or symbols. Answer at once and ask one question at a time. ' +
    'You can talk and remember, but you cannot run tools, browse, send messages or change anything during a call. When something needs doing, say you will follow up in the chat and write it down as an action item; the real assistant picks it up right after the call. ' +
    'Never read out passwords or codes. Do not confirm purchases, deletions or messages to other people on a call.';
  const notes = (memory || []).filter(Boolean).map(x => '- ' + String(x).slice(0, 300));
  let out = head;
  if (summary) out += `\n\nWhat you know so far:\n${String(summary).slice(0, 3000)}`;
  let list = '';
  for (const line of notes) { if ((out + '\n\nThings to remember:\n' + list + line + '\n').length > INSTRUCTIONS_MAX) break; list += line + '\n'; }
  if (list) out += `\n\nThings to remember:\n${list.trimEnd()}`;
  return out.slice(0, INSTRUCTIONS_MAX);
}

class InkboxVoice {
  constructor({ fields, fetchImpl = fetch, now = Date.now, setTimer = setTimeout, clearTimer = clearTimeout, interval = 10000, context = () => ({}), onCall = async () => {}, log = () => {} }) {
    this.key = fields.apiKey; this.voice = fields.voice || ''; this.origination = fields.voiceLine === 'dedicated_imessage_number' ? 'dedicated_imessage_number' : 'shared_imessage_number';
    this.fetch = fetchImpl; this.now = now; this.setTimer = setTimer; this.clearTimer = clearTimer; this.interval = interval;
    this.context = context; this.onCall = onCall; this.log = log;
    this.seen = new Set(); this.placed = []; this.timer = null; this.running = false; this.lastSync = ''; this.info = { state: 'off', detail: '' };
  }
  status() { return { ...this.info, voice: this.voice, line: this.origination }; }
  ready() { return !!this.key; }

  async api(path, { method = 'GET', body } = {}) {
    const response = await this.fetch(BASE + path, { method, headers: { 'X-API-Key': this.key, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000) });
    const data = await response.json().catch(() => null);
    if (response.status === 401) { const error = new Error('Inkbox did not accept that API key.'); error.code = 401; throw error; }
    if (!response.ok) {
      const detail = typeof data?.detail === 'string' ? data.detail : data?.detail?.error || data?.error || '';
      const error = new Error(response.status === 403 ? 'Inkbox says this key cannot use phone calls. Turn on Voice AI and calls for the agent in the Inkbox console.' : response.status === 429 ? 'Inkbox says the call limit was reached.' : `Inkbox answered ${response.status}${detail ? ': ' + String(detail).slice(0, 200) : ''}.`);
      error.code = response.status; throw error;
    }
    return data;
  }

  /** Puts the Bot's name, style, summary and notes into the voice agent. Skipped when nothing changed. */
  async syncInstructions(force = false) {
    const instructions = buildInstructions(this.context());
    const signature = instructions + '|' + this.voice;
    if (!force && signature === this.lastSync) return false;
    await this.api('/hosted-agent-config', { method: 'PUT', body: { instructions, voice: this.voice || null } });
    this.lastSync = signature; return true;
  }
  async voices() {
    const data = await this.api('/hosted-agent-voices');
    const list = Array.isArray(data) ? data : Array.isArray(data?.voices) ? data.voices : [];
    return list.map(v => ({ id: String(v.id ?? v.voice ?? ''), name: String(v.name ?? v.display_name ?? v.id ?? ''), available: v.available !== false })).filter(v => v.id);
  }

  /** Phones a person. `reason` is the voice agent's brief for the call. Only a handful an hour. */
  async placeCall(to, reason) {
    if (!E164.test(String(to || ''))) throw new Error('Add your own phone number (like +15551234567) first.');
    const text = String(reason || '').replace(/\s+/g, ' ').trim().slice(0, REASON_MAX);
    if (!text) throw new Error('A call needs a reason.');
    const now = this.now(); this.placed = this.placed.filter(t => now - t < 3600000);
    if (this.placed.length >= CALLS_PER_HOUR) throw new Error('That is five calls in the last hour. Try again later.');
    this.placed.push(now);
    try {
      const body = { origination: this.origination, to_number: to, mode: 'hosted_agent', reason: text, on_voicemail: 'leave_message' };
      const call = await this.api('/place-call', { method: 'POST', body });
      if (call?.id) this.seen.add(call.id);
      return call;
    } catch (error) { this.placed.pop(); throw error; }
  }

  // ----- Bringing finished calls back -----
  async start() {
    if (!this.ready()) throw new Error('Paste the Inkbox API key first.');
    for (const call of await this.recentCalls()) if (this.finished(call)) this.seen.add(call.id);
    this.running = true; this.info = { state: 'on', detail: 'Phone calls ready' };
    this.schedule();
    this.syncInstructions().catch(error => { this.info = { state: 'error', detail: error.message }; });
  }
  stop() { this.running = false; this.clearTimer(this.timer); this.info = { state: 'off', detail: '' }; }
  schedule(ms = this.interval) { if (this.running) { this.timer = this.setTimer(() => this.poll(), ms); this.timer?.unref?.(); } }
  async recentCalls() { const list = await this.api('/calls?limit=20'); return Array.isArray(list) ? list : []; }
  finished(call) { return !!call && !!call.ended_at && ['completed', 'failed', 'canceled'].includes(call.status); }

  async poll() {
    let wait = this.interval;
    try {
      const fresh = (await this.recentCalls()).filter(call => this.finished(call) && !this.seen.has(call.id)).reverse();
      for (const call of fresh) {
        this.seen.add(call.id);
        let lines = [], transcriptError = '';
        try { lines = (await this.api(`/calls/${encodeURIComponent(call.id)}/transcripts`)) || []; } catch (error) { this.log(error); transcriptError = error.message; }
        const transcript = (Array.isArray(lines) ? lines : []).sort((a, b) => a.seq - b.seq).filter(x => x.text).map(x => ({ party: x.party === 'local' ? 'assistant' : 'person', text: String(x.text) }));
        const items = (Array.isArray(call.post_call_action_items) ? call.post_call_action_items : []).filter(x => x?.action).map(x => ({ action: String(x.action), details: x.details ? String(x.details) : '' }));
        await this.onCall({ id: call.id, direction: call.direction, number: call.remote_phone_number, reason: call.reason || '', status: call.status, seconds: call.started_at && call.ended_at ? Math.max(0, Math.round((Date.parse(call.ended_at) - Date.parse(call.started_at)) / 1000)) : 0, outcome: call.hangup_reason || '', transcript, items, transcriptError });
      }
      if (this.seen.size > 500) this.seen = new Set([...this.seen].slice(-250));
      if (this.running) this.info = { state: 'on', detail: 'Phone calls ready' };
    } catch (error) {
      if (error.code === 401) { this.running = false; this.info = { state: 'error', detail: error.message }; return; }
      this.info = { state: 'error', detail: `Reconnecting: ${error.message}` }; wait = Math.min(this.interval * 4, 60000);
    }
    this.schedule(wait);
  }
}

module.exports = { InkboxVoice, buildInstructions, INSTRUCTIONS_MAX, CALLS_PER_HOUR, E164 };
