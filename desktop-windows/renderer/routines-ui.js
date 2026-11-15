// Settings → Routines (10.1): every Bot's scheduled tasks in one place. See what runs and when, pause or resume, run one now,
// edit it, add one, or delete it. Routines run only while the app is open; a missed run catches up once.
const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const pill = (text, action, className = 'pill') => { const b = el('button', className, text); b.type = 'button'; b.addEventListener('click', action); return b; };

const REPEAT = { none: 'Once', hourly: 'Every hour', daily: 'Every day', weekly: 'Every week' };
const when = date => new Date(date).toLocaleString(undefined, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
/** The value a datetime-local box wants (local time, no zone) for an ISO date. */
const toLocalInput = iso => { const d = new Date(iso); const p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; };
/** Turns a datetime-local value (the person's own clock) into an ISO time with a zone. */
const fromLocalInput = value => { const date = new Date(value); return Number.isNaN(date.getTime()) ? '' : date.toISOString(); };

/** One-line summary of when a routine runs. */
export function routineWhen(task) {
  if (!task.enabled) return task.nextRun != null && task.recurrence === 'none' && task.lastRun ? 'Finished' : 'Paused';
  if (task.nextRun == null) return task.source === 'mail' ? 'When new mail arrives' : task.source === 'calendar' ? 'Before an event starts' : 'When a Bot messages it';
  return `${when(task.nextRun)} · ${REPEAT[task.recurrence] || task.recurrence}`;
}

export async function renderRoutines({ bridge, result, toast, page, refresh }) {
  if (!bridge.pauseTask || !bridge.load) { page.append(el('p', 'muted', 'Routines are available in the installed app.')); return; }
  const root = el('div', 'routines-page'); page.append(root);

  const draw = async () => {
    let workspace;
    try { workspace = await result(bridge.load()); } catch (error) { root.replaceChildren(el('p', 'muted', error.message)); return; }
    const bots = (workspace.bots || []).filter(bot => !bot.memberIDs);
    const rows = bots.flatMap(bot => (bot.schedules || []).map(task => ({ bot, task })));
    root.replaceChildren();
    const active = rows.filter(row => row.task.enabled).length;
    root.append(el('p', 'muted', `${rows.length ? `${rows.length} routine${rows.length === 1 ? '' : 's'}, ${active} on.` : 'No routines yet.'} A routine is a task a Bot does on its own, once, on a repeat, or when another Bot messages it. They run only while Bothive is open; a missed run happens once when you come back.`));

    const card = el('section', 'settings-card');
    if (!rows.length) card.append(el('p', 'muted', 'Add one below, or ask a Bot in chat: “every morning at 8, summarize my open tasks”.'));
    const ordered = rows.sort((a, b) => (a.task.enabled === b.task.enabled ? 0 : a.task.enabled ? -1 : 1) || String(a.task.nextRun || '9').localeCompare(String(b.task.nextRun || '9')));
    for (const { bot, task } of ordered) card.append(row(bot, task));
    root.append(card, creator(bots));
  };

  function row(bot, task) {
    const item = el('div', 'routine-row');
    const text = el('div', 'routine-text');
    const state = el('span', `routine-state${task.enabled ? '' : ' paused'}`, routineWhen(task));
    text.append(el('strong', '', task.name), el('span', 'muted', bot.name), state);
    if (task.lastRun) text.append(el('small', 'muted', `Last ran ${when(task.lastRun)}${task.lastResult ? ' · ' + task.lastResult : ''}`));
    const actions = el('div', 'routine-actions');
    const run = async action => { try { await result(action()); await draw(); } catch (error) { toast(error.message); } };
    actions.append(
      pill(task.enabled ? 'Pause' : 'Resume', () => run(() => bridge.pauseTask(bot.id, task.id, !task.enabled))),
      pill('Run now', async () => { await run(() => bridge.runTask(bot.id, task.id)); toast(`Running “${task.name}”.`); }),
      pill('Edit', () => edit(bot, task)),
      pill('Delete', async () => { if (confirm(`Delete the routine “${task.name}”?`)) run(() => bridge.cancelTask(bot.id, task.id)); }, 'pill danger'));
    item.append(text, actions);
    if (task.history?.length) {
      const details = el('details', 'routine-history'); details.append(el('summary', '', 'Run history'));
      for (const entry of [...task.history].reverse().slice(0, 10)) details.append(el('p', 'muted', `${when(entry.date)} · ${entry.status}`));
      text.append(details);
    }
    return item;
  }

  // ---- Edit ----
  function edit(bot, task) {
    const form = el('section', 'settings-card');
    form.append(el('h2', '', `Edit routine · ${bot.name}`));
    const field = (label, control) => { const wrap = el('label', 'voice-row'); wrap.append(el('span', '', label), control); form.append(wrap); return control; };
    const name = field('Name', el('input')); name.value = task.name; name.maxLength = 200;
    const text = field('What to do', el('textarea')); text.value = task.text; text.rows = 6; text.maxLength = 8000;
    let at, repeat;
    if (task.nextRun != null) {
      at = field('Next run', el('input')); at.type = 'datetime-local'; at.value = toLocalInput(task.nextRun);
      repeat = field('Repeat', el('select')); for (const [value, label] of Object.entries(REPEAT)) { const option = el('option', '', label); option.value = value; repeat.append(option); } repeat.value = task.recurrence;
    } else form.append(el('p', 'muted', task.source === 'mail' ? 'This routine starts when new mail arrives.' : task.source === 'calendar' ? 'This routine starts shortly before an event.' : 'This routine starts when another Bot messages this one.'));
    const bar = el('div', 'skill-bar');
    bar.append(pill('Save', async () => {
      const input = { name: name.value, text: text.value };
      if (at) { if (at.value && at.value !== toLocalInput(task.nextRun)) input.at = fromLocalInput(at.value); input.recurrence = repeat.value; }
      try { await result(bridge.editTask(bot.id, task.id, input)); toast('Routine saved.'); draw(); } catch (error) { toast(error.message); }
    }, 'pill primary'), pill('Cancel', draw));
    form.append(bar); root.replaceChildren(form); name.focus();
  }

  // ---- Add ----
  function creator(bots) {
    const card = el('section', 'settings-card');
    card.append(el('h2', '', 'Add a routine'));
    if (!bots.length) { card.append(el('p', 'muted', 'Create a Bot first.')); return card; }
    const field = (label, control) => { const wrap = el('label', 'voice-row'); wrap.append(el('span', '', label), control); card.append(wrap); return control; };
    const botPick = field('Bot', el('select')); for (const bot of bots) { const option = el('option', '', bot.name); option.value = bot.id; botPick.append(option); }
    const name = field('Name', el('input')); name.maxLength = 200; name.placeholder = 'Morning summary';
    const text = field('What to do', el('textarea')); text.rows = 4; text.maxLength = 8000; text.placeholder = 'Look at my open tasks and give me a short plan for the day.';
    const at = field('First run', el('input')); at.type = 'datetime-local'; const soon = new Date(Date.now() + 3600000); soon.setMinutes(0, 0, 0); at.value = toLocalInput(soon.toISOString());
    const repeat = field('Repeat', el('select')); for (const [value, label] of Object.entries(REPEAT)) { const option = el('option', '', label); option.value = value; repeat.append(option); } repeat.value = 'daily';
    const bar = el('div', 'skill-bar');
    bar.append(pill('Add routine', async () => {
      try { await result(bridge.createTask(botPick.value, { name: name.value, text: text.value, at: fromLocalInput(at.value), recurrence: repeat.value })); toast('Routine added.'); draw(); }
      catch (error) { toast(error.message); }
    }, 'pill primary'));
    card.append(bar);
    return card;
  }

  await draw();
}
