'use strict';
// Share a Bot with a friend (10.1): a short text code, "bothive-bot:" followed by base64url JSON. It carries only what makes the Bot
// itself: name, description, look, and (if you choose) the skills it follows. Never chats, memory, files, routines, keys or accounts.
// A code from someone else is untrusted: reading it rebuilds every field with limits, and nothing is created until the person agrees.
const skills = require('./skills.cjs');

const PREFIX = 'bothive-bot:';
const MAX_CODE = 150_000, MAX_SKILLS = 5;
const COLORS = ['white', 'black', 'purple', 'pink', 'ochre', 'red', 'orange', 'amber', 'green', 'teal', 'blue', 'gray'];
const SHAPES = ['circle', 'cloud', 'square', 'sparkle', 'flower', 'heart', 'clover', 'droplet', 'capsule', 'triangle', 'pebble', 'star', 'hexagon', 'fruit'];
const line = (value, max) => String(value ?? '').replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, max);

/** Makes the code for a Bot. `chosen` is the list of stored skills to include (already filtered by the caller). */
function make(bot, chosen = []) {
  if (!bot || bot.memberIDs) throw new Error('Choose an individual Bot to share.');
  const body = {
    v: 1, name: line(bot.name, 60), purpose: String(bot.purpose || '').slice(0, 2000),
    color: COLORS.includes(bot.appearance?.color || bot.color) ? (bot.appearance?.color || bot.color) : 'purple',
    shape: SHAPES.includes(bot.appearance?.shape) ? bot.appearance.shape : 'hexagon',
    skills: chosen.slice(0, MAX_SKILLS).map(x => ({ name: x.name, description: x.description, text: x.text })),
  };
  const code = PREFIX + Buffer.from(JSON.stringify(body), 'utf8').toString('base64url');
  if (code.length > MAX_CODE) throw new Error('That Bot and its skills are too large for a share code. Share fewer skills.');
  return code;
}

/** Reads a code (or a message that contains one) into { name, purpose, color, shape, skills[] }. Throws a user-readable Error. */
function read(input) {
  const text = String(input ?? '').trim();
  const at = text.indexOf(PREFIX);
  if (at < 0) throw new Error('That is not a Bothive Bot code. It starts with “bothive-bot:”.');
  const match = /^[A-Za-z0-9_-]+/.exec(text.slice(at + PREFIX.length));
  if (!match || at + PREFIX.length + match[0].length > MAX_CODE + PREFIX.length) throw new Error('That Bot code is incomplete or too large.');
  let raw;
  try { raw = JSON.parse(Buffer.from(match[0], 'base64url').toString('utf8')); } catch { throw new Error('That Bot code is damaged. Ask for it again.'); }
  if (!raw || typeof raw !== 'object' || raw.v !== 1) throw new Error('That Bot code is from a newer version. Update Bothive.');
  const name = line(raw.name, 60);
  if (!name) throw new Error('That Bot has no name.');
  const found = [];
  for (const item of (Array.isArray(raw.skills) ? raw.skills : []).slice(0, MAX_SKILLS)) {
    try { const s = skills.make({ name: item?.name, description: item?.description, text: item?.text, source: 'shared Bot code' }); found.push({ name: s.name, description: s.description, text: s.text }); } catch { /* skip a skill that does not pass */ }
  }
  return {
    name, purpose: String(raw.purpose ?? '').slice(0, 2000).replace(/\r\n?/g, '\n'),
    color: COLORS.includes(raw.color) ? raw.color : 'purple', shape: SHAPES.includes(raw.shape) ? raw.shape : 'hexagon', skills: found,
  };
}

module.exports = { PREFIX, MAX_CODE, MAX_SKILLS, make, read };
