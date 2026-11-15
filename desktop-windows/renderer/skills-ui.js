// Settings → Skills (10.1): instruction packs a Bot can follow. Write your own, load one from a file, or add one from GitHub or
// skills.sh. Skills are plain text: nothing here runs code. Anything fetched is shown first, and every string goes in through
// textContent, so a skill's text can never add markup to this page.
const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const pill = (text, action, className = 'pill') => { const b = el('button', className, text); b.type = 'button'; b.addEventListener('click', action); return b; };

export async function renderSkills({ bridge, result, toast, page }) {
  if (!bridge.skillsList) { page.append(el('p', 'muted', 'Skills are available in the installed app.')); return; }
  const root = el('div', 'skills-page');
  page.append(root);

  const refresh = async () => {
    let skills;
    try { skills = await result(bridge.skillsList()); } catch (error) { root.replaceChildren(el('p', 'muted', error.message)); return; }
    root.replaceChildren();
    root.append(el('p', 'muted', 'A skill is a set of instructions a Bot follows, like “always list sources” or “write in my voice”. Turn skills on for each Bot in its side panel. Skills are text only: they cannot run anything or approve anything.'));

    const own = el('section', 'settings-card');
    own.append(el('h2', '', 'Your skills'));
    if (!skills.length) own.append(el('p', 'muted', 'No skills yet. Write one, load one from a file, or add one from GitHub below.'));
    for (const skill of skills) {
      const row = el('div', 'skill-row');
      const text = el('div', 'skill-text');
      text.append(el('strong', '', skill.name), el('span', 'muted', skill.description || 'No description'), el('small', 'muted', `${skill.source} · ${skill.chars.toLocaleString('en-US')} characters`));
      const actions = el('div', 'skill-actions');
      actions.append(
        pill('Edit', () => edit(skill.id)),
        pill('Delete', async () => {
          if (!confirm(`Delete the skill “${skill.name}”? Bots that use it stop following it.`)) return;
          try { await result(bridge.skillsDelete(skill.id)); toast('Skill deleted.'); refresh(); } catch (error) { toast(error.message); }
        }, 'pill danger'));
      row.append(text, actions); own.append(row);
    }
    const bar = el('div', 'skill-bar');
    bar.append(pill('New skill', () => edit(null), 'pill primary'), pill('Add from a file…', fromFile));
    own.append(bar);
    root.append(own, remote());
  };

  // ---- Write or edit ----
  async function edit(id) {
    let skill = { id: null, name: '', description: '', text: '' };
    if (id) { try { skill = await result(bridge.skillsGet(id)); } catch (error) { toast(error.message); return; } }
    const form = el('section', 'settings-card');
    form.append(el('h2', '', id ? 'Edit skill' : 'New skill'));
    const field = (label, control) => { const row = el('label', 'voice-row'); row.append(el('span', '', label), control); form.append(row); return control; };
    const name = field('Name', el('input')); name.value = skill.name; name.maxLength = 60; name.placeholder = 'For example Cite sources';
    const description = field('What it is for', el('input')); description.value = skill.description; description.maxLength = 300; description.placeholder = 'One line the Bot sees first';
    const text = field('Instructions', el('textarea')); text.value = skill.text; text.rows = 12; text.maxLength = 20000; text.placeholder = 'Write what the Bot should do, in plain language. Markdown is fine.';
    const bar = el('div', 'skill-bar');
    bar.append(pill('Save skill', async () => {
      try { await result(bridge.skillsSave({ id: skill.id, name: name.value, description: description.value, text: text.value })); toast('Skill saved.'); refresh(); }
      catch (error) { toast(error.message); }
    }, 'pill primary'), pill('Cancel', refresh));
    form.append(bar); root.replaceChildren(form); name.focus();
  }

  // ---- A file on this PC ----
  async function fromFile() {
    try { const found = await result(bridge.skillsImportFile()); if (found) preview([found], root); }
    catch (error) { toast(error.message); }
  }

  // ---- GitHub and skills.sh ----
  function remote() {
    const card = el('section', 'settings-card');
    card.append(el('h2', '', 'Add from GitHub or skills.sh'),
      el('p', 'muted', 'Paste an address, like github.com/owner/repo, a skills.sh page, or an “npx skills add owner/repo” command. Bothive looks for SKILL.md files in that public repository and shows you the text before anything is saved. Only the text is kept; scripts in the repository are ignored.'));
    const input = el('input'); input.placeholder = 'github.com/owner/repo  ·  skills.sh/owner/repo/skill  ·  owner/repo'; input.setAttribute('aria-label', 'GitHub or skills.sh address'); input.autocomplete = 'off'; input.spellcheck = false;
    const found = el('div', 'skill-found');
    const go = pill('Find skills', async () => {
      go.disabled = true; found.replaceChildren(el('p', 'muted', 'Looking…'));
      try { list(await result(bridge.skillsFind(input.value)), found); } catch (error) { found.replaceChildren(el('p', 'warn', error.message)); }
      go.disabled = false;
    }, 'pill primary');
    input.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); go.click(); } });
    const row = el('div', 'skill-bar'); row.append(input, go);
    card.append(row, found);
    return card;
  }

  function list(info, into) {
    into.replaceChildren(el('p', 'muted', `${info.items.length} skill${info.items.length === 1 ? '' : 's'} in ${info.owner}/${info.repo}. Choose up to 5 to read.`));
    const boxes = [];
    for (const item of info.items) {
      const label = el('label', 'skill-pick'); const box = document.createElement('input'); box.type = 'checkbox';
      label.append(box, el('span', '', item.folder), el('small', 'muted', item.path)); into.append(label); boxes.push([box, item]);
    }
    if (info.items.length === 1) boxes[0][0].checked = true;
    const read = pill('Read the selected skills', async () => {
      const chosen = boxes.filter(([box]) => box.checked).map(([, item]) => item).slice(0, 5);
      if (!chosen.length) { toast('Choose at least one skill.'); return; }
      read.disabled = true;
      try {
        const previews = [];
        for (const item of chosen) previews.push(await result(bridge.skillsFetch({ owner: info.owner, repo: info.repo, ref: info.ref, path: item.path })));
        preview(previews, into);
      } catch (error) { toast(error.message); }
      read.disabled = false;
    }, 'pill primary');
    into.append(read);
  }

  // ---- Read before adding ----
  function preview(items, into) {
    const box = el('div', 'skill-previews');
    box.append(el('p', 'warn', 'Read this first. A skill is instructions written by someone else. Only add ones you trust: a Bot will follow it where it fits.'));
    for (const item of items) {
      const card = el('article', 'skill-preview');
      const text = el('pre', 'skill-source'); text.textContent = item.text.length > 1500 ? item.text.slice(0, 1500) + '\n…' : item.text;
      const add = pill('Add this skill', async () => {
        add.disabled = true;
        try { await result(bridge.skillsSave({ name: item.name, description: item.description, text: item.text, source: item.source })); toast(`Added “${item.name}”. Turn it on for a Bot in its side panel.`); refresh(); }
        catch (error) { toast(error.message); add.disabled = false; }
      }, 'pill primary');
      card.append(el('strong', '', item.name), el('span', 'muted', item.description || 'No description'), el('small', 'muted', `${item.source} · ${item.text.length.toLocaleString('en-US')} characters`), text, add);
      box.append(card);
    }
    into.append(box); box.scrollIntoView({ block: 'nearest' });
  }

  await refresh();
}

/** The checklist in a Bot's side panel: which skills this Bot follows. */
export async function renderBotSkills({ bridge, result, toast, bot, container, manage }) {
  container.replaceChildren();
  if (!bridge.skillsList) return;
  let skills;
  try { skills = await result(bridge.skillsList()); } catch { return; }
  container.append(el('h3', '', 'Skills'), el('p', 'muted', 'Instructions this Bot follows, written by you or added from GitHub.'));
  if (!skills.length) container.append(el('p', 'muted', 'No skills yet.'));
  const on = new Set(bot.skills || []);
  for (const skill of skills) {
    const label = el('label', 'skill-pick'); const box = document.createElement('input'); box.type = 'checkbox'; box.checked = on.has(skill.id);
    box.addEventListener('change', async () => {
      if (box.checked) on.add(skill.id); else on.delete(skill.id);
      try { bot.skills = await result(bridge.skillsSetBot(bot.id, [...on])); } catch (error) { toast(error.message); box.checked = !box.checked; if (box.checked) on.add(skill.id); else on.delete(skill.id); }
    });
    label.append(box, el('span', '', skill.name), el('small', 'muted', skill.description)); container.append(label);
  }
  container.append(pill('Manage skills…', manage));
}
