'use strict';
// Servers (10.1.1): use a Bothive that runs somewhere else (a home server, a Docker container, another computer) by its address,
// for example https://my-box.tailnet-name.ts.net or http://100.101.102.103:8765. The app opens that address in its own window and
// you sign in with the web-access username and password set on the computer that runs it. Nothing is trusted from the address:
// it is checked here, and the window that opens it has no access to this computer.
const { localHost } = require('./remote-host.cjs');

const MAX_SERVERS = 20;

/** Plain http is only for networks that are private by nature: home Wi-Fi, Tailscale and local names. */
function privateHost(host) {
  const h = String(host).toLowerCase().replace(/^\[|\]$/g, '');
  return localHost(h) || h.endsWith('.ts.net') || (!h.includes('.') && !h.includes(':') && /^[a-z0-9-]+$/.test(h));
}

/** Turns what a person typed into { origin, host, https }, or throws an Error that says what to fix. */
function normalize(input) {
  let text = String(input ?? '').trim();
  if (!text) throw new Error('Type the server’s address, for example https://my-box.tailnet-name.ts.net.');
  if (text.length > 300) throw new Error('That address is too long.');
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) {
    const host = text.split(/[/:?#]/)[0];
    text = (privateHost(host) ? 'http://' : 'https://') + text;
  }
  let url;
  try { url = new URL(text); } catch { throw new Error('That address is not valid.'); }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('Use an address that starts with https:// or http://.');
  if (url.username || url.password) throw new Error('Leave the username and password out of the address. You sign in on the server’s own page.');
  if ((url.pathname !== '/' && url.pathname !== '') || url.search || url.hash) throw new Error('Use just the address, with no page after it.');
  if (!url.hostname) throw new Error('That address has no server name.');
  if (url.protocol === 'http:' && !privateHost(url.hostname)) throw new Error('Plain http is only for private addresses (Tailscale, home Wi-Fi). For anything else use https://.');
  return { origin: url.origin, host: url.host, https: url.protocol === 'https:' };
}

function valid(entry) {
  if (!entry || typeof entry !== 'object' || typeof entry.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(entry.id)) return false;
  if (typeof entry.name !== 'string' || !entry.name.trim() || entry.name.length > 60) return false;
  try { return normalize(entry.url).origin === entry.url; } catch { return false; }
}
function load(value) {
  return { version: 1, servers: (Array.isArray(value?.servers) ? value.servers : []).filter(valid).slice(0, MAX_SERVERS) };
}
const cleanName = (name, fallback) => String(name ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60) || fallback;

module.exports = { MAX_SERVERS, privateHost, normalize, valid, load, cleanName };
