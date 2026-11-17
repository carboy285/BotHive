// Settings → Servers (10.1.1): use a Bothive that runs somewhere else by its address (Tailscale, home network or https).
// Sign in here once and this window shows that server's Bots; you chat with them here. Every string goes in through textContent.
const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const pill = (text, action, className = 'pill') => { const b = el('button', className, text); b.type = 'button'; b.addEventListener('click', action); return b; };

export async function renderServers({ bridge, result, toast, page }) {
  if (!bridge.serversList) { page.append(el('p', 'muted', 'Servers are available in the installed app.')); return; }
  const root = el('div', 'servers-page'); page.append(root);

  const draw = async () => {
    let list, status = { active: false };
    try { list = await result(bridge.serversList()); status = await result(bridge.serversStatus()); } catch (error) { root.replaceChildren(el('p', 'muted', error.message)); return; }
    root.replaceChildren();
    root.append(el('p', 'muted', 'Use a Bothive that runs on another computer, a home server or a Docker container, instead of this one. Type its address, sign in with the username and password from its Web access settings, and its Bots show up here. You chat and talk to them in this app. Chats and Bots stay on that server.'));

    const saved = el('section', 'settings-card'); saved.append(el('h2', '', 'Your servers'));
    if (status.active) {
      const bar = el('div', 'skill-bar'); bar.append(el('strong', '', `Using ${status.name}`), pill('Back to this computer', async () => { try { await result(bridge.serversDisconnect()); } catch (error) { toast(error.message); } }, 'pill primary'));
      saved.append(bar);
    }
    if (!list.length) saved.append(el('p', 'muted', 'No servers yet. Add one below.'));
    for (const server of list) {
      const row = el('div', 'skill-row'); const text = el('div', 'skill-text');
      const connected = status.active && status.url === server.url;
      text.append(el('strong', '', server.name), el('span', 'muted', server.url), ...(connected ? [el('small', 'muted', 'Connected')] : []));
      const actions = el('div', 'skill-actions'); const form = el('form', 'server-signin'); form.hidden = true;
      const user = el('input'); user.placeholder = 'Username'; user.value = 'admin'; user.autocomplete = 'username'; user.setAttribute('aria-label', 'Server username');
      const password = el('input'); password.type = 'password'; password.placeholder = 'Password'; password.autocomplete = 'current-password'; password.setAttribute('aria-label', 'Server password');
      const submit = el('button', 'pill primary', 'Sign in'); submit.type = 'submit'; const note = el('small', 'muted');
      form.append(user, password, submit, note);
      form.addEventListener('submit', async event => {
        event.preventDefault(); submit.disabled = true; note.textContent = 'Signing in…';
        const secret = password.value; password.value = '';
        try { await result(bridge.serversConnect(server.id, user.value, secret)); } catch (error) { note.textContent = error.message; submit.disabled = false; }
      });
      actions.append(
        ...(connected ? [] : [pill('Connect', () => { form.hidden = !form.hidden; if (!form.hidden) password.focus(); }, 'pill primary')]),
        pill('Remove', async () => { if (!confirm(`Remove “${server.name}”?`)) return; try { await result(bridge.serversRemove(server.id)); toast('Server removed.'); draw(); } catch (error) { toast(error.message); } }, 'pill danger'));
      row.append(text, actions, form); saved.append(row);
    }

    const add = el('section', 'settings-card'); add.append(el('h2', '', 'Add a server'));
    const field = (label, control) => { const wrap = el('label', 'voice-row'); wrap.append(el('span', '', label), control); add.append(wrap); return control; };
    const address = field('Address', el('input')); address.placeholder = 'https://my-box.tailnet-name.ts.net  ·  http://100.101.102.103:8765'; address.autocomplete = 'off'; address.spellcheck = false; address.maxLength = 300;
    const name = field('Name', el('input')); name.placeholder = 'Home server (optional)'; name.maxLength = 60;
    const note = el('p', 'muted'); const bar = el('div', 'skill-bar');
    const test = pill('Test', async () => { note.textContent = 'Looking…'; try { const found = await result(bridge.serversTest(address.value)); note.textContent = found.message; } catch (error) { note.textContent = error.message; } });
    const save = pill('Add server', async () => { try { const entry = await result(bridge.serversAdd(name.value, address.value)); toast(`Added “${entry.name}”.`); draw(); } catch (error) { note.textContent = error.message; } }, 'pill primary');
    address.addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); save.click(); } });
    bar.append(test, save); add.append(bar, note);
    add.append(el('p', 'muted', 'With Tailscale, turn it on here and on the server, then use the server’s Tailscale address. Plain http:// is only for private addresses (Tailscale 100.x, home Wi-Fi). Anything else needs https://.'));
    root.append(saved, add);
  };
  await draw();
}

/** A thin bar at the top of the sidebar while this window is using a server, with a way back. */
export async function installServerBanner({ bridge, result, toast }) {
  if (!bridge.serversStatus) return;
  let status; try { status = await result(bridge.serversStatus()); } catch { return; }
  if (!status.active) return;
  const sidebar = document.querySelector('.sidebar'); if (!sidebar) return;
  const banner = el('div', 'server-banner'); banner.id = 'server-banner';
  banner.append(el('span', '', `Using ${status.name}`), pill('Back', async () => { try { await result(bridge.serversDisconnect()); } catch (error) { toast(error.message); } }, 'pill'));
  (sidebar.querySelector('.sidebar-header') || sidebar.firstChild).after(banner);
}
