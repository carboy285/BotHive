// Share a Bot (10.1): copy a short code that a friend pastes into Bothive, and add a Bot from a code someone sent you.
// The code holds the Bot's name, description, look and (if you choose) its skills. It never holds chats, memory, files or keys.
// Everything from a code goes in through textContent, and nothing is created until the person presses Add.
const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const pill = (text, action, className = 'pill') => { const b = el('button', className, text); b.type = 'button'; b.addEventListener('click', action); return b; };

/** In the Bot's side panel: copy a share code. */
export function renderShareBot({ bridge, result, toast, bot, container }) {
  container.replaceChildren();
  if (!bridge.shareMake || bot.memberIDs) return;
  container.append(el('h3', '', 'Share this Bot'), el('p', 'muted', 'Copy a code a friend can paste into Bothive to get their own copy. It holds the name, description and look only. Your chats, memory and files stay here.'));
  const hasSkills = (bot.skills || []).length > 0;
  const label = el('label', 'skill-pick'); const box = document.createElement('input'); box.type = 'checkbox'; box.checked = hasSkills; box.disabled = !hasSkills;
  label.append(box, el('span', '', 'Include its skills'), el('small', 'muted', hasSkills ? `${bot.skills.length} turned on` : 'None turned on'));
  container.append(label, pill('Copy share code', async () => {
    try { const code = await result(bridge.shareMake(bot.id, box.checked)); await navigator.clipboard.writeText(code); toast('Share code copied. Send it to a friend.'); }
    catch (error) { toast(error.message); }
  }));
}

/** A box that takes a pasted code, shows what is in it, and adds it as a new Bot when asked. */
export function renderAddFromCode({ bridge, result, toast, container, onAdded }) {
  container.replaceChildren();
  if (!bridge.shareRead) return;
  const input = el('textarea'); input.rows = 3; input.placeholder = 'Paste a code that starts with bothive-bot:'; input.setAttribute('aria-label', 'Bot share code'); input.spellcheck = false;
  const shown = el('div', 'share-preview');
  const look = pill('Look at it', async () => {
    shown.replaceChildren();
    let info;
    try { info = await result(bridge.shareRead(input.value)); } catch (error) { shown.append(el('p', 'warn', error.message)); return; }
    const card = el('article', 'skill-preview');
    card.append(el('strong', '', info.name), el('span', 'muted', info.purpose || 'No description'));
    let skillBox = null;
    if (info.skills.length) {
      card.append(el('p', 'warn', `It brings ${info.skills.length} skill${info.skills.length === 1 ? '' : 's'}: ${info.skills.map(x => x.name).join(', ')}. Skills are instructions the Bot will follow, so only include them from someone you trust.`));
      const label = el('label', 'skill-pick'); skillBox = document.createElement('input'); skillBox.type = 'checkbox'; label.append(skillBox, el('span', '', 'Include the skills'));
      card.append(label);
      for (const skill of info.skills) { const text = el('pre', 'skill-source'); text.textContent = `${skill.name}\n\n${skill.text.length > 600 ? skill.text.slice(0, 600) + '\n…' : skill.text}`; card.append(text); }
    }
    const add = pill('Add this Bot', async () => {
      add.disabled = true;
      try { const added = await result(bridge.shareAdd(input.value, !!skillBox?.checked)); toast(`Added “${added.name}”.`); onAdded?.(added); }
      catch (error) { toast(error.message); add.disabled = false; }
    }, 'pill primary');
    card.append(add); shown.append(card);
  }, 'pill');
  container.append(input, look, shown);
}
