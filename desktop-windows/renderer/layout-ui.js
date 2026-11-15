// Layout controls (10.1): drag the edge of the sidebar to resize it, and choose how wide the conversation is.
// The drag follows the pointer 1:1 (pointer capture, offset from where you grabbed it), pushes back softly past its limits and settles
// when you let go, and never animates while you drag. Double-click the edge, or press Home on it, to reset.
const KEY = 'sidebarWidth', CHAT_KEY = 'chatWidth';
const MIN = 240, STEP = 16, SOFT = 44;
export const chatWidths = [['comfortable', 'Comfortable', '780px'], ['wide', 'Wide', '1000px'], ['extra', 'Extra wide', '1280px'], ['fill', 'Fill the window', '10000px']];

const el = (tag, className = '', text = '') => { const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node; };
const read = key => { try { return localStorage.getItem(key); } catch { return null; } };
const write = (key, value) => { try { if (value == null) localStorage.removeItem(key); else localStorage.setItem(key, String(value)); } catch { /* private mode */ } };
/** The further past a limit, the less the edge follows: real things slow before they stop. */
export const rubberband = (over, constant = 0.55) => (over * SOFT * constant) / (SOFT + constant * Math.abs(over));

export function installSidebarResize({ workspace = document.querySelector('#workspace'), sidebar = document.querySelector('.sidebar'), motion = () => !matchMedia('(prefers-reduced-motion: reduce)').matches } = {}) {
  if (!workspace || !sidebar) return null;
  const widest = () => Math.max(MIN + 40, Math.min(560, window.innerWidth * 0.45));
  const clamp = value => Math.min(Math.max(value, MIN), widest());
  const apply = width => { if (width == null) workspace.style.removeProperty('--sidebar-w'); else workspace.style.setProperty('--sidebar-w', width + 'px'); };
  const saved = Number(read(KEY)); if (saved > 0) apply(clamp(saved));

  const handle = el('div', 'sidebar-handle'); handle.setAttribute('role', 'separator'); handle.setAttribute('aria-orientation', 'vertical'); handle.setAttribute('aria-label', 'Sidebar width'); handle.tabIndex = 0; handle.title = 'Drag to resize the sidebar. Double-click to reset.';
  sidebar.append(handle);
  const current = () => sidebar.getBoundingClientRect().width;
  const settle = () => { if (!motion()) return; workspace.classList.add('settling'); setTimeout(() => workspace.classList.remove('settling'), 260); };
  let start = null;
  handle.addEventListener('pointerdown', event => {
    if (event.button !== 0) return; event.preventDefault();
    handle.setPointerCapture(event.pointerId); start = { x: event.clientX, width: current() }; workspace.classList.add('resizing'); workspace.classList.remove('settling');
  });
  handle.addEventListener('pointermove', event => {
    if (!start) return;
    const raw = start.width + (event.clientX - start.x), low = MIN, high = widest();
    apply(raw < low ? low - rubberband(low - raw) : raw > high ? high + rubberband(raw - high) : raw);
  });
  const finish = event => {
    if (!start) return; const raw = start.width + (event.clientX - start.x); start = null; workspace.classList.remove('resizing');
    try { handle.releasePointerCapture(event.pointerId); } catch { /* already released */ }
    const final = clamp(raw); settle(); apply(final); write(KEY, Math.round(final));
  };
  handle.addEventListener('pointerup', finish); handle.addEventListener('pointercancel', finish);
  handle.addEventListener('dblclick', () => { settle(); apply(null); write(KEY, null); });
  handle.addEventListener('keydown', event => {
    if (event.key === 'Home') { event.preventDefault(); apply(null); write(KEY, null); return; }
    if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return; event.preventDefault();
    const next = clamp(current() + (event.key === 'ArrowRight' ? STEP : -STEP)); apply(next); write(KEY, Math.round(next));
  });
  window.addEventListener('resize', () => { const value = Number(read(KEY)); if (value > 0) apply(clamp(value)); });
  return { reset: () => { apply(null); write(KEY, null); } };
}

export const chatWidthKey = () => (chatWidths.some(x => x[0] === read(CHAT_KEY)) ? read(CHAT_KEY) : 'wide');
export function applyChatWidth(key = chatWidthKey()) {
  const found = chatWidths.find(x => x[0] === key) || chatWidths[1];
  document.documentElement.style.setProperty('--chat-w', found[2]); write(CHAT_KEY, found[0]);
}

/** A small menu under a button in the top corner of the chat. Returns nothing; closes on choice, Escape or an outside press. */
function openMenu(anchor, rows, { label }) {
  document.querySelector('.chat-menu')?.remove();
  const menu = el('div', 'account-menu chat-menu'); menu.setAttribute('role', 'menu'); menu.setAttribute('aria-label', label);
  const close = () => { menu.remove(); document.removeEventListener('pointerdown', outside, true); document.removeEventListener('keydown', keys, true); anchor.setAttribute('aria-expanded', 'false'); anchor.focus?.(); };
  const outside = event => { if (!menu.contains(event.target) && !anchor.contains(event.target)) close(); };
  const buttons = [];
  const keys = event => {
    if (event.key === 'Escape') { event.preventDefault(); close(); return; }
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return; event.preventDefault();
    const at = buttons.indexOf(document.activeElement); buttons[(at + (event.key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length].focus();
  };
  for (const row of rows) {
    const button = el('button', 'account-item'); button.type = 'button'; button.setAttribute('role', row.checked != null ? 'menuitemradio' : 'menuitem');
    if (row.checked != null) button.setAttribute('aria-checked', String(row.checked));
    const mark = el('span', 'account-glyph', row.checked ? '✓' : (row.glyph || '')); mark.setAttribute('aria-hidden', 'true');
    button.append(mark, el('span', 'account-label', row.label));
    button.addEventListener('click', () => { close(); row.run(); }); menu.append(button); buttons.push(button);
  }
  document.body.append(menu);
  const rect = anchor.getBoundingClientRect();
  menu.style.top = rect.bottom + 8 + 'px'; menu.style.right = Math.max(8, window.innerWidth - rect.right) + 'px'; menu.style.left = 'auto'; menu.style.bottom = 'auto'; menu.style.transformOrigin = 'top right';
  anchor.setAttribute('aria-expanded', 'true'); anchor.setAttribute('aria-haspopup', 'menu');
  document.addEventListener('pointerdown', outside, true); document.addEventListener('keydown', keys, true); buttons[0]?.focus();
}

/** A liquid-glass Share button in the top corner of the chat. Its menu copies or exports the conversation and sets the chat width. */
export function installChatTools({ host = document.querySelector('main.conversation'), copyText, exportAs, toast }) {
  if (!host) return;
  applyChatWidth();
  const tools = el('div', 'chat-tools');
  const share = el('button', 'circle glass chat-tool share-glass'); share.type = 'button'; share.id = 'share-button'; share.setAttribute('aria-label', 'Share conversation'); share.title = 'Share, export and chat width';
  const NS = 'http://www.w3.org/2000/svg';
  const icon = document.createElementNS(NS, 'svg'); icon.setAttribute('viewBox', '0 0 24 24'); icon.setAttribute('aria-hidden', 'true');
  const path = document.createElementNS(NS, 'path'); path.setAttribute('d', 'M12 3v12M12 3l-4 4M12 3l4 4M5 12v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6'); path.setAttribute('fill', 'none'); path.setAttribute('stroke', 'currentColor'); path.setAttribute('stroke-width', '1.8'); path.setAttribute('stroke-linecap', 'round'); path.setAttribute('stroke-linejoin', 'round');
  icon.append(path); share.append(icon);
  share.addEventListener('click', () => openMenu(share, [
    { label: 'Copy conversation', glyph: '\u29C9', run: async () => { try { await navigator.clipboard.writeText(copyText()); toast('Conversation copied.'); } catch { toast('The conversation could not be copied.'); } } },
    { label: 'Export as Markdown\u2026', glyph: '\u21E9', run: () => exportAs('md') },
    { label: 'Export as PDF\u2026', glyph: '\u21E9', run: () => exportAs('pdf') },
    ...chatWidths.map(([key, title]) => ({ label: 'Chat width: ' + title, checked: key === chatWidthKey(), run: () => applyChatWidth(key) })),
  ], { label: 'Share' }));
  tools.append(share);
  host.append(tools);
}
