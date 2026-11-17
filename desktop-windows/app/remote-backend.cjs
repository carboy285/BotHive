'use strict';
// Uses a Bothive server by its address for this app's whole window (10.1.1).
// After you sign in once, the calls the window makes (load Bots, send a message, stop, approve) go to that server, and what it
// reports (new messages, running Bots, approvals) comes back as the same events a local Bot would raise. The window does not change.
const { normalize } = require('./servers.cjs');

class RemoteBackend {
  /** @param {{fetchImpl?: typeof fetch, onEvent: (channel:string, value:any)=>void, onChange?: ()=>void}} options */
  constructor({ fetchImpl = fetch, onEvent, onChange = () => {} }) {
    this.fetch = fetchImpl; this.onEvent = onEvent; this.onChange = onChange;
    this.session = null; this.abort = null;
  }
  get active() { return !!this.session; }
  status() { return this.session ? { active: true, name: this.session.name, url: this.session.origin } : { active: false, name: '', url: '' }; }

  /** Signs in and starts listening. Throws an Error whose message says what went wrong. */
  async connect(address, username, password, label = '') {
    const found = normalize(address);
    let response;
    try {
      response = await this.fetch(found.origin + '/api/app/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: String(username ?? ''), password: String(password ?? '') }), signal: AbortSignal.timeout(20000) });
    } catch { throw new Error(`Could not reach ${found.host}. Check the address, that Bothive is running there with Web access on, and that Tailscale is on if you use it.`); }
    const reply = await response.json().catch(() => null);
    if (response.status === 200 && reply?.ok && typeof reply.token === 'string') {
      this.disconnect(false);
      this.session = { origin: found.origin, host: found.host, token: reply.token, name: String(label || reply.name || found.host).slice(0, 80) };
      this.listen();
      this.onChange();
      return this.status();
    }
    // Only a server that knows the sign-in route says bad_credentials. An older Bothive answers 401 "Sign in again." to a route it does not have.
    if (response.status === 401 && reply?.code !== 'bad_credentials') throw new Error(`${found.host} answered, but it does not accept sign-in from the apps. It is running an older Bothive. Update it to 10.1.1 or later, then try again.`);
    if (response.status === 401 || response.status === 429) throw new Error(reply?.error || 'That username and password don’t match.');
    if (response.status === 404) throw new Error(`${found.host} answered, but Web access is not turned on there, or it is not Bothive 10.1.1 or later.`);
    throw new Error(reply?.error || `${found.host} answered with an error (${response.status}).`);
  }

  disconnect(notify = true) {
    this.abort?.abort(); this.abort = null;
    const had = !!this.session; this.session = null;
    if (had && notify) this.onChange();
  }

  headers(extra = {}) { return { Authorization: 'Bearer ' + this.session.token, 'X-OGB-Request': '1', ...extra }; }

  /** Runs one of the window's calls on the server. Same answer shape as a local call: { ok, value } or { ok: false, error }. */
  async invoke(channel, args) {
    const session = this.session;
    if (!session) return { ok: false, error: 'Not connected to a server.' };
    try {
      const response = await this.fetch(session.origin + '/api/invoke', { method: 'POST', headers: this.headers({ 'Content-Type': 'application/json' }), body: JSON.stringify({ channel, args }), signal: AbortSignal.timeout(120000) });
      if (response.status === 401) { if (this.session === session) this.disconnect(); return { ok: false, error: `${session.name} no longer knows this sign-in. Sign in again under Settings → Servers.` }; }
      return await response.json();
    } catch { return { ok: false, error: `${session.name} could not be reached.` }; }
  }

  /** Reads the server's event stream, and reconnects if it drops, until disconnected. */
  listen() {
    const session = this.session; const abort = new AbortController(); this.abort = abort;
    (async () => {
      let delay = 1000;
      while (this.session === session && !abort.signal.aborted) {
        try {
          const response = await this.fetch(session.origin + '/api/events', { headers: this.headers(), signal: abort.signal });
          if (response.status === 401) { if (this.session === session) this.disconnect(); return; }
          if (!response.ok || !response.body) throw new Error('no stream');
          delay = 1000;
          const reader = response.body.getReader(), decoder = new TextDecoder(); let buffer = '';
          for (;;) {
            const { done, value } = await reader.read(); if (done) break;
            buffer += decoder.decode(value, { stream: true });
            let at; while ((at = buffer.indexOf('\n\n')) >= 0) {
              const block = buffer.slice(0, at); buffer = buffer.slice(at + 2);
              const data = block.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
              if (!data) continue;
              try { const event = JSON.parse(data); if (typeof event?.channel === 'string') this.onEvent(event.channel, event.value); } catch { /* ignore a bad line */ }
            }
          }
        } catch { /* reconnect below */ }
        if (abort.signal.aborted || this.session !== session) return;
        await new Promise(resolve => setTimeout(resolve, delay)); delay = Math.min(delay * 2, 15000);
      }
    })();
  }
}

module.exports = { RemoteBackend };
