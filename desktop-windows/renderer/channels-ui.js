// Settings → Channels (10.2): one Bot you choose answers on Telegram, Discord, Slack, iMessage (through Inkbox) and SMS, and can
// take or place phone calls. Nobody is answered until you approve them with the code the Bot gave them. Every string goes in through
// textContent; tokens are never shown again once saved, only whether they are set.
import { connectorIcon } from './connector-icon.js';

const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const pill = (text, action, className = 'pill') => { const b = el('button', className, text); b.type = 'button'; b.addEventListener('click', action); return b; };
const NS = 'http://www.w3.org/2000/svg';

/** What each channel needs, in the order the fields are asked for. `secret` fields are never echoed back. */
export const CHANNEL_SETUP = {
  telegram: {
    blurb: 'Direct messages to a Telegram bot you make in a minute with @BotFather.',
    steps: ['In Telegram, message @BotFather and send /newbot.', 'Pick a name, then copy the token it gives you.', 'Paste it below and turn the channel on.'],
    guide: 'https://core.telegram.org/bots/features#botfather',
    fields: [{ key: 'token', label: 'Bot token', secret: true, placeholder: '123456789:AA…' }],
  },
  discord: {
    blurb: 'Direct messages, and mentions in servers you invite it to.',
    steps: ['Create an application at discord.com/developers and add a Bot.', 'Turn on Message Content Intent, then copy the bot token.', 'Invite the bot to your server with the OAuth2 URL generator.'],
    guide: 'https://discord.com/developers/applications',
    fields: [{ key: 'token', label: 'Bot token', secret: true, placeholder: 'MTA…' }],
  },
  slack: {
    blurb: 'Direct messages, and mentions in channels it is added to. Uses Socket Mode, so nothing has to be reachable from outside.',
    steps: ['Create a Slack app and turn on Socket Mode.', 'Add the bot scopes chat:write, im:history and app_mentions:read, and subscribe to message.im and app_mention.', 'Install it, then copy the Bot token (xoxb-) and an App-level token (xapp-).'],
    guide: 'https://api.slack.com/apps',
    fields: [{ key: 'botToken', label: 'Bot token', secret: true, placeholder: 'xoxb-…' }, { key: 'appToken', label: 'App token', secret: true, placeholder: 'xapp-…' }],
  },
  imessage: {
    blurb: 'Your Bot gets its own iMessage identity through Inkbox. Works on Windows and on a server; nothing has to be reachable from outside.',
    steps: ['Sign up at inkbox.ai and create an agent with iMessage turned on.', 'Make an API key for that agent and paste it below.', 'From your phone, text “connect @your-agent-handle” to the router number Inkbox shows you.'],
    guide: 'https://inkbox.ai',
    fields: [{ key: 'apiKey', label: 'Inkbox API key', secret: true, placeholder: 'ik_…' }],
  },
  sms: {
    blurb: 'Texts to a Twilio number, and phone calls when you add your own number and a public https address.',
    steps: ['Buy a number in Twilio and copy the Account SID and Auth token.', 'For calls, add your own number, a PIN callers must say or type, and the public https address that reaches this computer (for example a Tailscale Funnel).'],
    guide: 'https://console.twilio.com',
    fields: [
      { key: 'accountSid', label: 'Account SID', placeholder: 'AC…' }, { key: 'authToken', label: 'Auth token', secret: true, placeholder: '••••' },
      { key: 'number', label: 'Twilio number', placeholder: '+15551234567' }, { key: 'ownerNumber', label: 'Your number (calls)', placeholder: '+15557654321' },
      { key: 'pin', label: 'Call PIN', secret: true, placeholder: '4 to 8 digits' }, { key: 'publicUrl', label: 'Public address (calls)', placeholder: 'https://my-pc.tailnet.ts.net' },
      { key: 'language', label: 'Call language', placeholder: 'en-US' },
    ],
  },
};
const ORDER = ['telegram', 'imessage', 'discord', 'slack', 'sms'];
const GLYPHS = {
  telegram: { color: '#2AABEE', d: 'M3.4 11.2 19.6 4.9c.8-.3 1.5.2 1.2 1.4l-2.8 13c-.2.9-.8 1.1-1.5.7l-4.2-3.1-2 1.9c-.2.2-.4.4-.9.4l.3-4.3 7.9-7.1c.3-.3-.1-.5-.5-.2l-9.8 6.2-4.2-1.3c-.9-.3-.9-.9.3-1.3Z' },
  imessage: { color: '#34C759', d: 'M12 3.5c-5 0-9 3.3-9 7.5 0 2.3 1.2 4.4 3.2 5.8-.1 1.2-.7 2.5-1.7 3.4 2 0 3.7-.8 4.9-1.9.8.2 1.7.3 2.6.3 5 0 9-3.4 9-7.6s-4-7.5-9-7.5Z' },
  sms: { color: '#F22F46', d: 'M5 4h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H9l-4 3.5V17a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Zm3 6.5a1.2 1.2 0 1 0 0 .01Zm4 0a1.2 1.2 0 1 0 0 .01Zm4 0a1.2 1.2 0 1 0 0 .01Z' },
};

function channelIcon(id, name) {
  if (!GLYPHS[id]) return connectorIcon(id, name, { size: 36 });
  const tile = el('span', 'connector-icon channel-glyph'); tile.style.setProperty('--size', '36px'); tile.style.setProperty('--glyph', GLYPHS[id].color); tile.setAttribute('aria-hidden', 'true');
  const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('focusable', 'false');
  const path = document.createElementNS(NS, 'path'); path.setAttribute('d', GLYPHS[id].d); path.setAttribute('fill', '#fff'); svg.append(path); tile.append(svg);
  return tile;
}

/** The short state shown next to a channel's name. */
export function channelState(info) {
  if (!info.configured) return { tone: 'idle', text: 'Not set up' };
  if (!info.enabled) return { tone: 'idle', text: 'Off' };
  const state = info.state?.state || 'starting', detail = info.state?.detail || '';
  if (state === 'on') return { tone: 'on', text: detail ? `On · ${detail}` : 'On' };
  if (state === 'error') return { tone: 'error', text: detail ? `Not working · ${detail}` : 'Not working' };
  return { tone: 'busy', text: 'Connecting…' };
}

const ago = time => { const minutes = Math.max(0, Math.round((Date.now() - time) / 60000)); return minutes < 1 ? 'just now' : minutes < 60 ? `${minutes} min ago` : minutes < 1440 ? `${Math.round(minutes / 60)} h ago` : `${Math.round(minutes / 1440)} d ago`; };

export async function renderChannels({ bridge, result, toast, page, workspace }) {
  if (!bridge.channelsStatus) { page.append(el('p', 'muted', 'Channels are available in the installed app.')); return; }
  const root = el('div', 'channels-page'); page.append(root);
  const open = new Set();
  let status;

  const run = async (operation, done) => {
    try { status = await result(operation); if (done) toast(done); } catch (error) { toast(error.message); }
    draw();
  };

  function draw() {
    if (!root.isConnected) return;
    root.replaceChildren();
    root.append(el('p', 'page-intro', 'Reach a Bot from the chat apps you already use. It answers people you approve, and it can message them for you when you ask.'));

    // Which Bot answers.
    const who = el('section', 'settings-card channel-who');
    const bots = (workspace()?.bots || []).filter(bot => !bot.memberIDs);
    const select = el('select'); select.setAttribute('aria-label', 'Bot that answers on channels');
    const none = el('option', '', 'Choose a Bot…'); none.value = ''; select.append(none);
    for (const bot of bots) { const option = el('option', '', bot.name); option.value = bot.id; select.append(option); }
    select.value = status.bot || '';
    select.addEventListener('change', () => run(bridge.channelsSetBot(select.value || null), select.value ? 'That Bot answers on your channels now.' : undefined));
    const label = el('div', 'setting-text'); label.append(el('strong', '', 'Answers on channels'), el('small', 'muted', 'One Bot speaks for you everywhere. It is told which channels are on and gets tools to message approved people.'));
    const row = el('div', 'setting-row'); row.append(label, select); who.append(row);
    root.append(who);

    const list = el('section', 'channel-list'); list.setAttribute('aria-label', 'Channels');
    for (const id of ORDER) {
      const info = status.channels[id]; if (!info) continue;
      list.append(channelCard(id, info));
    }
    root.append(list);
    root.append(el('p', 'panel-footnote', 'Strangers who message your Bot get a 6-digit code and nothing else. Ask them for it and enter it here to let them in. Approved people are limited to 30 messages every 10 minutes. Tokens are encrypted with Windows device storage.'));
  }

  function channelCard(id, info) {
    const setup = CHANNEL_SETUP[id], state = channelState(info);
    const card = el('article', 'channel-card'); card.dataset.channel = id; card.dataset.tone = state.tone;
    const head = el('div', 'channel-head');
    const text = el('div', 'channel-text');
    const badge = el('span', `status-badge ${state.tone}`, state.text);
    const title = el('div', 'channel-title'); title.append(el('strong', '', id === 'sms' ? 'SMS and calls' : info.name), badge);
    text.append(title, el('small', 'muted', setup.blurb));
    const toggle = el('input', 'switch'); toggle.type = 'checkbox'; toggle.setAttribute('role', 'switch'); toggle.checked = !!info.enabled; toggle.setAttribute('aria-label', `Turn ${info.name} on`);
    toggle.disabled = !info.configured || !status.bot;
    toggle.title = !info.configured ? 'Set it up first' : !status.bot ? 'Choose which Bot answers first' : '';
    toggle.addEventListener('change', () => run(bridge.channelsEnable(id, toggle.checked), toggle.checked ? `${info.name} is on.` : `${info.name} is off.`));
    const expand = pill(open.has(id) ? 'Done' : info.configured ? 'Manage' : 'Set up', () => { open.has(id) ? open.delete(id) : open.add(id); draw(); }, 'pill small');
    expand.setAttribute('aria-expanded', String(open.has(id)));
    head.append(channelIcon(id, info.name), text, expand, toggle);
    card.append(head);

    // Waiting people are worth seeing even when the card is closed.
    if (info.pending.length) card.append(pendingList(id, info));
    if (!open.has(id)) return card;

    const body = el('div', 'channel-body');
    const steps = el('ol', 'channel-steps'); for (const step of setup.steps) steps.append(el('li', '', step));
    body.append(steps);
    const form = el('form', 'channel-form');
    const inputs = {};
    for (const field of setup.fields) {
      const wrap = el('label', 'field-row'); const input = el('input', 'field');
      input.type = field.secret ? 'password' : 'text'; input.autocomplete = 'off'; input.spellcheck = false; input.maxLength = 500;
      const saved = info.fields?.[field.key];
      if (field.secret) input.placeholder = saved ? 'Saved · type to replace' : field.placeholder;
      else { input.placeholder = field.placeholder; input.value = typeof saved === 'string' ? saved : ''; }
      wrap.append(el('span', '', field.label), input); form.append(wrap); inputs[field.key] = input;
    }
    const save = el('button', 'pill primary', 'Save'); save.type = 'submit';
    const actions = el('div', 'channel-actions'); actions.append(save, pill('Open the guide ↗', () => bridge.openDocs(setup.guide), 'pill'));
    if (id === 'sms' && status.calls?.ready && bridge.channelsTestCall) actions.append(pill('Call my phone', async () => { try { toast(await result(bridge.channelsTestCall())); } catch (error) { toast(error.message); } }));
    form.append(actions);
    form.addEventListener('submit', event => {
      event.preventDefault();
      const fields = {}; for (const [key, input] of Object.entries(inputs)) { const secret = setup.fields.find(f => f.key === key).secret; if (!secret || input.value) fields[key] = input.value; input.type === 'password' && (input.value = ''); }
      run(bridge.channelsConfigure(id, fields), `${info.name} saved.`);
    });
    body.append(form);
    if (id === 'sms') body.append(el('p', 'muted small', status.calls?.ready ? (status.calls.listening ? 'Calls are ready. Text “call me” or ask the Bot to phone you.' : 'Calls are set up but the call listener is not running.') : 'Calls need your number, a PIN and a public https address.'));

    const people = el('div', 'channel-people'); people.append(el('h3', '', 'Approved people'));
    if (!info.approved.length) people.append(el('p', 'muted small', 'Nobody yet. Message the Bot from your own account to get a code, then enter it above.'));
    for (const person of info.approved) {
      const row = el('div', 'person-row'); const initial = el('span', 'person-initial', (person.name || '?')[0].toUpperCase());
      const details = el('div', 'person-text'); details.append(el('strong', '', person.name), el('small', 'muted', `Approved ${ago(person.at)}`));
      row.append(initial, details, pill('Remove', async () => { if (!confirm(`Stop answering ${person.name} on ${info.name}?`)) return; run(bridge.channelsRemove(id, person.id), `${person.name} removed.`); }, 'pill small danger'));
      people.append(row);
    }
    body.append(people);
    card.append(body);
    return card;
  }

  function pendingList(id, info) {
    const box = el('div', 'channel-pending');
    for (const person of info.pending) {
      const row = el('form', 'pending-row');
      const text = el('div', 'person-text'); text.append(el('strong', '', `${person.name} wants to talk`), el('small', 'muted', `Asked ${ago(person.at)} · ask them for the code the Bot sent`));
      const code = el('input', 'field code-field'); code.inputMode = 'numeric'; code.maxLength = 6; code.placeholder = '6-digit code'; code.autocomplete = 'off'; code.setAttribute('aria-label', `Code from ${person.name}`);
      const approve = el('button', 'pill small primary', 'Approve'); approve.type = 'submit';
      row.append(el('span', 'person-initial waiting', (person.name || '?')[0].toUpperCase()), text, code, approve);
      row.addEventListener('submit', event => { event.preventDefault(); run(bridge.channelsApprove(id, code.value), `${person.name} can talk to the Bot now.`); });
      box.append(row);
    }
    return box;
  }

  try { status = await result(bridge.channelsStatus()); } catch (error) { root.append(el('p', 'muted', error.message)); return; }
  draw();
  // Keep the states fresh while the page is open, without redrawing under the person's typing.
  const timer = setInterval(async () => {
    if (!root.isConnected) { clearInterval(timer); return; }
    if (root.contains(document.activeElement) && document.activeElement.matches('input,select')) return;
    try { status = await result(bridge.channelsStatus()); draw(); } catch { /* keep the last view */ }
  }, 5000);
}
