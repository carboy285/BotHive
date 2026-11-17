// Settings → Channels (10.1.2): one Bot you choose answers messages from Telegram, Discord, Slack, iMessage (through Inkbox) and SMS, and can
// phone you. Tokens go to the computer that runs the Bot and are never shown again; a person is answered only after you approve them.
// Every string goes in through textContent.
const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const pill = (text, action, className = 'pill') => { const b = el('button', className, text); b.type = 'button'; b.addEventListener('click', action); return b; };

const CHANNELS = [
  { id: 'telegram', title: 'Telegram', steps: ['In Telegram, message @BotFather and send /newbot.', 'Follow the steps, then paste the token it gives you.', 'Message your new bot. It answers direct messages only.'], fields: [{ key: 'token', label: 'Bot token', secret: true }] },
  { id: 'discord', title: 'Discord', steps: ['At discord.com/developers/applications make an application, then add a Bot.', 'Under Bot, turn on Message Content Intent, then copy the token.', 'Add it to a server with OAuth2 → URL Generator (scope bot). It answers direct messages, and in a server when you @mention it.'], fields: [{ key: 'token', label: 'Bot token', secret: true }] },
  { id: 'slack', title: 'Slack', steps: ['At api.slack.com/apps make an app from scratch and turn on Socket Mode.', 'Make an App-Level Token with connections:write (starts xapp-).', 'Under OAuth & Permissions add chat:write, im:history, im:read and app_mentions:read, install to your workspace and copy the Bot token (starts xoxb-).', 'Under Event Subscriptions turn on message.im and app_mention.'], fields: [{ key: 'botToken', label: 'Bot token (xoxb-)', secret: true }, { key: 'appToken', label: 'App-level token (xapp-)', secret: true }] },
  { id: 'imessage', title: 'iMessage (through Inkbox)', steps: ['Sign up at inkbox.ai and create an agent with iMessage turned on.', 'Make an API key for that agent in the Inkbox console and paste it here.', 'From your phone, text “connect @your-agent-handle” to Inkbox’s router number (the console shows it). After that, your messages reach the Bot.', 'Inkbox limits an agent to about 100 iMessages a day on the base plan.'], fields: [{ key: 'apiKey', label: 'Inkbox API key', secret: true }],
    calls: [{ key: 'ownerNumber', label: 'Your phone number for calls (+15551234567)' }] },
  { id: 'sms', title: 'SMS and phone calls (Twilio)', steps: ['Make a Twilio account and buy a phone number.', 'Paste its Account SID, Auth Token and number. Texts to that number reach the Bot.', 'For calls, add your own number, a PIN, and a public https address. On a server run “tailscale funnel --bg 8766” and paste the address it prints. Only the phone port is public.', 'The Bot calls you, or you call the number and enter the PIN. Say “call me” in any channel to get a call.'],
    fields: [{ key: 'accountSid', label: 'Account SID' }, { key: 'authToken', label: 'Auth Token', secret: true }, { key: 'number', label: 'Twilio number (+15551234567)' }],
    calls: [{ key: 'ownerNumber', label: 'Your own number (+15551234567)' }, { key: 'pin', label: 'Call PIN (4 to 8 digits)', secret: true }, { key: 'publicUrl', label: 'Public https address' }, { key: 'language', label: 'Call language (en-US)' }] },
];

export async function renderChannels({ bridge, result, toast, page }) {
  if (!bridge.channelsStatus) { page.append(el('p', 'muted', 'Channels are available in the installed app, or in an app connected to a Bothive server.')); return; }
  const root = el('div', 'channels-page'); page.append(root);
  let draft = {};

  const draw = async () => {
    let status;
    try { status = await result(bridge.channelsStatus()); } catch (error) { root.replaceChildren(el('p', 'muted', error.message)); return; }
    if (!root.isConnected) return;
    const keep = Object.fromEntries([...root.querySelectorAll('input[data-key]')].filter(x => x.value).map(x => [x.dataset.key, x.value]));
    draft = { ...draft, ...keep };
    root.replaceChildren();
    root.append(el('p', 'muted', 'One Bot you choose answers messages that arrive on your chat channels and can message or phone you. Nobody is answered until you approve them: a stranger gets a short code and nothing else.'));

    const who = el('section', 'settings-card'); who.append(el('h2', '', 'Which Bot answers'));
    const select = el('select', 'field'); select.setAttribute('aria-label', 'Bot that answers on channels');
    const none = el('option', '', 'Choose a Bot…'); none.value = ''; select.append(none);
    for (const bot of status.bots || []) { const option = el('option', '', bot.name); option.value = bot.id; select.append(option); }
    select.value = status.bot || '';
    select.addEventListener('change', async () => { try { await result(bridge.channelsSetBot(select.value)); toast(select.value ? 'That Bot now answers on your channels.' : 'No Bot answers on channels.'); draw(); } catch (error) { toast(error.message); } });
    who.append(select, el('p', 'muted', 'This Bot is told which channels are connected and gets tools to message approved people and to phone you.'));
    const fast = el('label', 'channel-field channel-check'); const fastBox = el('input'); fastBox.type = 'checkbox'; fastBox.checked = status.settings?.fast !== false; fastBox.setAttribute('aria-label', 'Fast replies on channels');
    fastBox.addEventListener('change', async () => { try { await result(bridge.channelsSetSettings({ fast: fastBox.checked })); draw(); } catch (error) { toast(error.message); } });
    fast.append(fastBox, el('span', '', 'Fast replies on channels (a quicker model, short answers)'));
    const busy = el('label', 'channel-field'); busy.append(el('span', '', 'When I send another message while the Bot is working'));
    const busySelect = el('select', 'field'); busySelect.setAttribute('aria-label', 'When I send while it is working');
    for (const [value, label] of [['steer', 'Steer it: stop and carry on with my new message'], ['queue', 'Queue it: answer after the current one']]) { const option = el('option', '', label); option.value = value; busySelect.append(option); }
    busySelect.value = status.settings?.whenBusy || 'steer';
    busySelect.addEventListener('change', async () => { try { await result(bridge.channelsSetSettings({ whenBusy: busySelect.value })); draw(); } catch (error) { toast(error.message); } });
    busy.append(busySelect);
    const reach = el('label', 'channel-field'); reach.append(el('span', '', 'When the Bot needs you and you have not messaged it, reach me on'));
    const reachSelect = el('select', 'field'); reachSelect.setAttribute('aria-label', 'Reach me on');
    const anyOption = el('option', '', 'Any channel where I am marked Me'); anyOption.value = ''; reachSelect.append(anyOption);
    for (const spec of CHANNELS) { const option = el('option', '', spec.title); option.value = spec.id; reachSelect.append(option); }
    reachSelect.value = status.settings?.reachOn || '';
    reachSelect.addEventListener('change', async () => { try { await result(bridge.channelsSetSettings({ reachOn: reachSelect.value })); draw(); } catch (error) { toast(error.message); } });
    reach.append(reachSelect);
    const escalate = el('label', 'channel-field'); escalate.append(el('span', '', 'If an urgent question gets no answer'));
    const escalateSelect = el('select', 'field'); escalateSelect.setAttribute('aria-label', 'If I do not answer');
    for (const [value, label] of [['call', 'Call me (outside quiet hours)'], ['text', 'Text me again'], ['none', 'Do nothing']]) { const option = el('option', '', label); option.value = value; escalateSelect.append(option); }
    escalateSelect.value = status.settings?.escalate || 'call';
    escalateSelect.addEventListener('change', async () => { try { await result(bridge.channelsSetSettings({ escalate: escalateSelect.value })); draw(); } catch (error) { toast(error.message); } });
    escalate.append(escalateSelect);
    who.append(fast, busy, reach, escalate, el('p', 'muted', 'Messages sent a second apart are read together, so a photo and “add these to my reminders” arrive as one request. Texting “stop” only stops the Bot.'));
    root.append(who);

    for (const spec of CHANNELS) root.append(card(status, spec));
  };

  const card = (status, spec) => {
    const info = status.channels[spec.id]; const box = el('section', 'settings-card channel-card');
    const head = el('div', 'channel-head'); head.append(el('h2', '', spec.title));
    const state = info.enabled ? (info.state?.state === 'on' ? 'Connected' : info.state?.state === 'error' ? 'Not working' : 'Starting…') : 'Off';
    head.append(el('span', `channel-state ${info.enabled ? info.state?.state : 'off'}`, state)); box.append(head);
    if (info.enabled && info.state?.detail) box.append(el('p', 'muted', info.state.detail));
    const steps = el('ol', 'channel-steps'); for (const text of spec.steps) steps.append(el('li', '', text)); box.append(steps);

    const inputs = [];
    const field = (item) => {
      const row = el('label', 'channel-field'); row.append(el('span', '', item.label));
      const input = el('input', 'field'); input.type = item.secret ? 'password' : 'text'; input.dataset.key = item.key; if (item.secret) input.dataset.secret = '1'; input.autocomplete = 'off'; input.spellcheck = false; input.maxLength = 500;
      const saved = info.fields?.[item.key];
      input.placeholder = item.secret ? (saved ? 'Saved — type to replace' : '') : '';
      if (!item.secret && saved && saved !== true) input.value = saved;
      if (draft[item.key] && !item.secret) input.value = draft[item.key];
      row.append(input); inputs.push(input); return row;
    };
    for (const item of spec.fields) box.append(field(item));
    if (spec.calls) { box.append(el('h3', '', 'Phone calls')); for (const item of spec.calls) box.append(field(item)); }

    const actions = el('div', 'channel-actions');
    actions.append(pill('Save', async () => {
      const values = {}; for (const input of inputs) if (input.value || !input.dataset.secret) values[input.dataset.key] = input.value;
      try { await result(bridge.channelsConfigure(spec.id, values)); for (const input of inputs) if (input.type === 'password') input.value = ''; draft = {}; toast('Saved.'); draw(); } catch (error) { toast(error.message); }
    }));
    actions.append(pill(info.enabled ? 'Turn off' : 'Turn on', async () => { try { await result(bridge.channelsEnable(spec.id, !info.enabled)); draw(); } catch (error) { toast(error.message); } }, info.enabled ? 'pill' : 'pill primary'));
    if (spec.id === 'sms' || spec.id === 'imessage') actions.append(pill('Call me now', async () => { try { toast(await result(bridge.channelsTestCall())); } catch (error) { toast(error.message); } }));
    box.append(actions);
    if (spec.id === 'imessage' && info.enabled) {
      const inkbox = status.inkbox || {};
      const row = el('label', 'channel-field'); row.append(el('span', '', 'Phone voice'));
      const select = el('select', 'field'); select.setAttribute('aria-label', 'Phone voice');
      const none = el('option', '', 'Default voice'); none.value = ''; select.append(none);
      for (const voice of inkbox.voices || []) { const option = el('option', '', voice.name + (voice.available ? '' : ' (unavailable)')); option.value = voice.id; option.disabled = !voice.available; select.append(option); }
      select.value = info.fields?.voice || '';
      select.addEventListener('change', async () => { try { await result(bridge.channelsConfigure('imessage', { voice: select.value })); toast('Voice saved.'); draw(); } catch (error) { toast(error.message); } });
      row.append(select); box.append(row);
      box.append(el('p', 'muted', 'Calls are answered by Inkbox\u2019s voice assistant, which is told your Bot\u2019s name, style and notes. It cannot run the Bot\u2019s tools during a call; the transcript comes back into the Bot\u2019s chat and anything left to do is handed to the Bot. Tip: in the Inkbox console set the agent to contact-scoped access and allow only your own number to call it.'));
      if (inkbox.pendingAsk) box.append(el('p', 'muted', `The Bot is waiting for your answer to: ${inkbox.pendingAsk.question}`));
    }
    if (spec.id === 'sms') box.append(el('p', 'muted', status.calls?.ready ? (status.calls.listening ? 'Calls are ready. Twilio reaches the phone port at your public address.' : 'Calls are set up and starting.') : 'Calls need your Twilio number, your own number and an https address.'));

    if (info.pending?.length) {
      box.append(el('h3', '', 'Waiting for your OK'));
      for (const person of info.pending) {
        const row = el('div', 'channel-person'); row.append(el('span', '', `${person.name} · code ${person.code}`));
        const mine = el('label', 'channel-check'); const mineBox = el('input'); mineBox.type = 'checkbox'; mineBox.setAttribute('aria-label', `This is me: ${person.name}`); mine.append(mineBox, el('span', '', 'This is me'));
        row.append(mine);
        row.append(pill('Approve', async () => { try { await result(bridge.channelsApprove(spec.id, person.code, { me: mineBox.checked })); toast(`${person.name} can now message the Bot.`); draw(); } catch (error) { toast(error.message); } }, 'pill primary'));
        box.append(row);
      }
    }
    if (info.approved?.length) {
      box.append(el('h3', '', 'Approved'));
      for (const person of info.approved) {
        const row = el('div', 'channel-person'); row.append(el('span', '', person.name === person.id ? person.id : `${person.name} · ${person.id}`));
        const mine = el('label', 'channel-check'); const mineBox = el('input'); mineBox.type = 'checkbox'; mineBox.checked = !!person.me; mineBox.setAttribute('aria-label', `This is me: ${person.name}`); mine.append(mineBox, el('span', '', 'Me'));
        mineBox.addEventListener('change', async () => { try { await result(bridge.channelsSetPerson(spec.id, person.id, { me: mineBox.checked })); toast(mineBox.checked ? 'The Bot can now reach out to this person first.' : 'Saved.'); draw(); } catch (error) { toast(error.message); } });
        row.append(mine);
        row.append(pill('Rename', async () => { const next = window.prompt('Name for this person (the same name on two channels is one person to the Bot):', person.name); if (next === null) return; try { await result(bridge.channelsSetPerson(spec.id, person.id, { name: next })); draw(); } catch (error) { toast(error.message); } }));
        row.append(pill('Remove', async () => { try { await result(bridge.channelsRemove(spec.id, person.id)); draw(); } catch (error) { toast(error.message); } }));
        box.append(row);
      }
    }
    return box;
  };

  await draw();
  const timer = setInterval(() => { if (!root.isConnected) { clearInterval(timer); return; } if (!root.contains(document.activeElement) || document.activeElement.tagName !== 'INPUT') draw(); }, 5000);
}
