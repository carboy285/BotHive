// Group chats from inside a Bot's side panel (10.1.1). A Bot lists the group chats it is in and can start a new one with it already
// chosen; a group chat lists its members and lets you remove one or add another (2 to 8). Names go in through textContent only.
const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const pill = (text, action, className = 'pill') => { const b = el('button', className, text); b.type = 'button'; b.addEventListener('click', action); return b; };

export function renderBotGroups({ bridge, result, toast, workspace, bot, container, open, changed }) {
  if (!bridge.createGroup) return;
  const individuals = workspace.bots.filter(x => !x.memberIDs);
  const run = async (call) => { try { changed(await result(call)); } catch (error) { toast(error.message); } };

  if (bot.memberIDs) {
    container.append(el('h3', '', 'Group members'));
    const ids = bot.memberIDs;
    for (const member of ids.map(id => workspace.bots.find(x => x.id === id)).filter(Boolean)) {
      const row = el('div', 'group-row');
      row.append(pill(member.name, () => open(member.id), 'group-open'));
      const remove = pill('Remove', () => run(bridge.setGroupMembers(bot.id, ids.filter(id => id !== member.id))), 'pill group-remove');
      remove.disabled = ids.length <= 2; remove.title = ids.length <= 2 ? 'A group needs at least 2 Bots' : `Remove ${member.name} from the group`;
      remove.setAttribute('aria-label', `Remove ${member.name} from the group`);
      row.append(remove); container.append(row);
    }
    const others = individuals.filter(x => !ids.includes(x.id));
    if (ids.length < 8 && others.length) {
      const select = el('select', 'field'); select.setAttribute('aria-label', 'Add a Bot to this group');
      select.append(el('option', '', 'Add a Bot…')); select.firstChild.value = '';
      for (const other of others) { const option = el('option', '', other.name); option.value = other.id; select.append(option); }
      select.addEventListener('change', () => { if (select.value) run(bridge.setGroupMembers(bot.id, [...ids, select.value])); });
      container.append(select);
    }
    container.append(el('p', 'muted', 'Each member answers with its own provider and model. A group has 2 to 8 Bots.'));
    return;
  }

  container.append(el('h3', '', 'Group chats'));
  const mine = workspace.bots.filter(x => x.memberIDs?.includes(bot.id));
  for (const group of mine) container.append(pill(`${group.name} · ${group.memberIDs.length} Bots`, () => open(group.id), 'pill group-open'));
  if (!mine.length) container.append(el('p', 'muted', 'No group chats yet. A group chat puts several Bots in one conversation.'));

  const form = el('details', 'new-group');
  form.append(el('summary', '', `New group chat with ${bot.name}`));
  const name = el('input', 'field'); name.type = 'text'; name.maxLength = 200; name.placeholder = 'Group name'; name.setAttribute('aria-label', 'Title for the new group chat');
  const picks = new Map();
  const list = el('div', 'group-picks');
  for (const other of individuals) {
    const label = el('label', 'group-pick'); const box = el('input'); box.type = 'checkbox';
    box.checked = other.id === bot.id; box.disabled = other.id === bot.id; picks.set(other.id, box);
    label.append(box, el('span', '', other.name)); list.append(label);
  }
  const problem = el('p', 'muted');
  const create = pill('Create group', async () => {
    const members = [...picks].filter(([, box]) => box.checked).map(([id]) => id);
    if (!name.value.trim()) { problem.textContent = 'Give the group a name.'; return; }
    if (members.length < 2 || members.length > 8) { problem.textContent = 'Choose 2 to 8 Bots.'; return; }
    try { const next = await result(bridge.createGroup(name.value, members)); changed(next, next.bots.at(-1)?.id); } catch (error) { problem.textContent = error.message; }
  });
  form.append(name, list, create, problem);
  container.append(form);
}
