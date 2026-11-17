// The account menu (10.1): press the round account button at the bottom of the sidebar and a small menu opens above it.
// Who is signed in, get the iPhone app, support links, Settings, and signing out. Every string goes in through textContent.
const SITE = 'https://carboy285.github.io/BotHive/';
const LINKS = {
  phone: SITE + 'iphone.html',
  help: 'https://github.com/carboy285/BotHive/issues',
  privacy: SITE + 'privacy.html',
  terms: SITE + 'terms.html',
  licenses: SITE + 'licenses.html',
  site: SITE,
};

const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };

/** Opens the menu above `anchor`. Returns a function that closes it. */
export function openAccountMenu({ anchor, bridge, result, toast, openSettings }) {
  document.querySelector('.account-menu')?.remove();
  const menu = el('div', 'account-menu'); menu.setAttribute('role', 'menu'); menu.setAttribute('aria-label', 'Account');
  const items = [];
  let submenu = null;
  const close = () => { menu.remove(); submenu?.remove(); submenu = null; document.removeEventListener('pointerdown', outside, true); document.removeEventListener('keydown', keys, true); anchor.setAttribute('aria-expanded', 'false'); anchor.focus?.(); };
  const outside = event => { if (!menu.contains(event.target) && !submenu?.contains(event.target) && !anchor.contains(event.target)) close(); };
  const keys = event => {
    if (event.key === 'Escape') { event.preventDefault(); if (submenu?.isConnected) { submenu.remove(); submenu = null; return; } close(); return; }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    const live = items.filter(x => x.isConnected && !x.disabled); if (!live.length) return;
    event.preventDefault();
    const at = live.indexOf(document.activeElement);
    live[(at + (event.key === 'ArrowDown' ? 1 : -1) + live.length) % live.length].focus();
  };
  const row = (label, glyph, action, extra = '') => {
    const button = el('button', 'account-item ' + extra); button.type = 'button'; button.setAttribute('role', 'menuitem');
    const mark = el('span', 'account-glyph', glyph); mark.setAttribute('aria-hidden', 'true');
    button.append(mark, el('span', 'account-label', label));
    button.addEventListener('click', action); items.push(button); return button;
  };
  const open = url => async () => { close(); try { if (bridge.openLink) await result(bridge.openLink(url)); else window.open(url, '_blank', 'noopener,noreferrer'); } catch (error) { toast(error.message); } };

  const who = el('div', 'account-who'); const line = el('span', 'account-email', 'Checking account…'); who.append(line); menu.append(who);
  menu.append(el('hr'));
  menu.append(row('Get Bothive for iPhone', '▯', open(LINKS.phone)));

  const support = row('Support', '▢', () => {
    if (submenu?.isConnected) { submenu.remove(); submenu = null; return; }
    submenu = el('div', 'account-menu account-submenu'); submenu.setAttribute('role', 'menu');
    for (const [label, url] of [['Report a problem', LINKS.help], ['Privacy', LINKS.privacy], ['Terms', LINKS.terms], ['Licenses', LINKS.licenses], ['Website', LINKS.site]]) {
      const item = row(label, '', open(url)); submenu.append(item);
    }
    document.body.append(submenu);
    const rect = support.getBoundingClientRect();
    submenu.style.left = Math.min(rect.right + 6, window.innerWidth - 200) + 'px';
    submenu.style.bottom = Math.max(8, window.innerHeight - rect.bottom - 8) + 'px';
    submenu.querySelector('button')?.focus();
  });
  const more = el('span', 'account-more', '\u203A'); more.setAttribute('aria-hidden', 'true'); support.append(more); support.setAttribute('aria-haspopup', 'menu');
  menu.append(support);
  menu.append(row('Settings', '⚙', () => { close(); openSettings(); }));
  menu.append(el('hr'));
  let signAction = () => { close(); openSettings('Computer'); };
  const sign = row('Sign in', '\u21E5', () => signAction());
  menu.append(sign);

  document.body.append(menu);
  const rect = anchor.getBoundingClientRect();
  menu.style.left = Math.max(8, rect.left - 4) + 'px';
  menu.style.bottom = Math.max(8, window.innerHeight - rect.top + 10) + 'px';
  anchor.setAttribute('aria-expanded', 'true'); anchor.setAttribute('aria-haspopup', 'menu');
  document.addEventListener('pointerdown', outside, true); document.addEventListener('keydown', keys, true);
  menu.querySelector('button')?.focus();

  // Who is signed in (this is the Bothive account that links the phone).
  (async () => {
    if (!bridge.cloudStatus) { line.textContent = 'This computer'; sign.remove(); return; }
    try {
      const status = await result(bridge.cloudStatus());
      if (!menu.isConnected) return;
      if (status.signedIn) {
        line.textContent = status.email || 'Signed in';
        sign.querySelector('.account-label').textContent = 'Sign out'; sign.querySelector('.account-glyph').textContent = '\u21A9';
        signAction = async () => { close(); try { await result(bridge.cloudSignOut()); toast('Signed out.'); } catch (error) { toast(error.message); } };
      } else line.textContent = 'Not signed in';
    } catch { if (menu.isConnected) line.textContent = 'Account'; }
  })();
  return close;
}
