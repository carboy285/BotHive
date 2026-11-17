'use strict';
// The one public door (10.1.1): a separate little web server that only Twilio talks to. Put a tunnel or Tailscale Funnel in front of
// THIS port and nothing else, so Bothive's own pages and settings are never exposed. Every request must carry Twilio's signature for
// the public address you set; anything else gets a bare 404.
const http = require('node:http');
const { validSignature } = require('./channel-twilio.cjs');

function createVoiceServer({ voice, log = () => {} }) {
  return http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    const end = (status, body = '', type = 'text/plain') => { res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' }); res.end(body); };
    if (req.method !== 'POST' || !(url.pathname === '/twilio/voice' || url.pathname.startsWith('/twilio/voice/'))) return end(404);
    let size = 0; const chunks = [];
    req.on('data', chunk => { size += chunk.length; if (size > 65536) { req.destroy(); } else chunks.push(chunk); });
    req.on('error', () => {});
    req.on('end', async () => {
      try {
        const params = Object.fromEntries(new URLSearchParams(Buffer.concat(chunks).toString('utf8')));
        const c = voice.config;
        const full = `${String(c.publicUrl || '').replace(/\/$/, '')}${url.pathname}${url.search}`;
        if (!voice.ready() || !validSignature(c.authToken, full, params, req.headers['x-twilio-signature'])) return end(403);
        const query = Object.fromEntries(url.searchParams);
        end(200, await voice.handle(url.pathname, params, query), 'text/xml');
      } catch (error) { log(error); end(500); }
    });
  });
}

module.exports = { createVoiceServer };
