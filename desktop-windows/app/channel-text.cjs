'use strict';
// Small text helpers shared by the chat channels (10.1.1).

/** Splits text into pieces of at most `max` characters, breaking at a blank line, a new line or a space where it can. */
function chunk(text, max) {
  const out = []; let rest = String(text ?? '').trim();
  while (rest.length > max) {
    let cut = rest.lastIndexOf('\n\n', max);
    if (cut < max * 0.4) cut = rest.lastIndexOf('\n', max);
    if (cut < max * 0.4) cut = rest.lastIndexOf(' ', max);
    if (cut < max * 0.4) cut = max;
    out.push(rest.slice(0, cut).trim()); rest = rest.slice(cut).trim();
  }
  if (rest) out.push(rest);
  return out;
}

/** Turns a Bot's markdown reply into something that reads out loud: no symbols, links or code, and short. */
function spoken(text, limit = 600) {
  let value = String(text ?? '')
    .replace(/```[\s\S]*?```/g, ' (code omitted) ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/https?:\/\/[^\s)]*[^\s).,;!?]/g, 'a link')
    .replace(/^[#>\-*+\d.)\s]+(?=\S)/gm, '')
    .replace(/[*_~|]/g, '')
    .replace(/\s+/g, ' ').trim();
  if (value.length > limit) { value = value.slice(0, limit); const stop = Math.max(value.lastIndexOf('. '), value.lastIndexOf('? '), value.lastIndexOf('! ')); value = (stop > limit * 0.5 ? value.slice(0, stop + 1) : value.replace(/\s+\S*$/, '')) + ' The rest is in your chat.'; }
  return value;
}

/** Escapes text for TwiML (XML) element content. */
function xml(text) {
  return String(text ?? '').replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[c])).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '');
}

module.exports = { chunk, spoken, xml };
