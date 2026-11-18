// One line-icon set for the whole Windows app (10.2), drawn on a 24-point grid with round 1.8 strokes so every glyph has the same
// weight. Built with createElementNS (no innerHTML). Icons are decorative: the button that holds one carries the accessible name.
const NS = 'http://www.w3.org/2000/svg';

/** Each icon is a list of [element, attributes]. `fill` marks shapes that are filled instead of stroked. */
const ICONS = {
  general: [['path', { d: 'M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1' }], ['circle', { cx: 15, cy: 6, r: 2 }], ['circle', { cx: 9, cy: 12, r: 2 }], ['circle', { cx: 17, cy: 18, r: 2 }]],
  headsUps: [['path', { d: 'M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15Z' }], ['path', { d: 'M10 20.5a2 2 0 0 0 4 0' }]],
  routines: [['path', { d: 'M4.5 12A7.5 7.5 0 0 1 17.3 6.7L19.5 9' }], ['path', { d: 'M19.5 4.5V9H15' }], ['path', { d: 'M19.5 12a7.5 7.5 0 0 1-12.8 5.3L4.5 15' }], ['path', { d: 'M4.5 19.5V15H9' }]],
  skills: [['path', { d: 'M5 5.5A2.5 2.5 0 0 1 7.5 3H19v15H7.5A2.5 2.5 0 0 0 5 20.5Z' }], ['path', { d: 'M5 20.5A.5.5 0 0 0 7.5 21H19M9 7.5h6' }]],
  channels: [['path', { d: 'M3.5 6.5a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v5.5a2 2 0 0 1-2 2H9.5L6 17v-3H5.5a2 2 0 0 1-2-2Z' }], ['path', { d: 'M19.5 9.5a1.5 1.5 0 0 1 1 1.5v5a2 2 0 0 1-2 2H18v2.5L15 18h-3' }]],
  servers: [['rect', { x: 3.5, y: 4, width: 17, height: 7, rx: 2 }], ['rect', { x: 3.5, y: 13, width: 17, height: 7, rx: 2 }], ['circle', { cx: 7.5, cy: 7.5, r: 1, fill: true }], ['circle', { cx: 7.5, cy: 16.5, r: 1, fill: true }]],
  computer: [['rect', { x: 3, y: 4, width: 18, height: 12, rx: 2 }], ['path', { d: 'M8.5 20h7M12 16v4' }]],
  web: [['circle', { cx: 12, cy: 12, r: 8.5 }], ['path', { d: 'M3.5 12h17M12 3.5c2.3 2.4 3.5 5.2 3.5 8.5s-1.2 6.1-3.5 8.5c-2.3-2.4-3.5-5.2-3.5-8.5s1.2-6.1 3.5-8.5Z' }]],
  permissions: [['path', { d: 'M12 3.5 5 6.2v4.9c0 4.3 2.9 7.9 7 9.4 4.1-1.5 7-5.1 7-9.4V6.2Z' }], ['path', { d: 'm9 12 2 2 4-4' }]],
  key: [['circle', { cx: 8, cy: 15.5, r: 3.8 }], ['path', { d: 'm10.8 12.8 8.7-8.8M16.5 7l2.5 2.5M14.3 9.2l1.8 1.8' }]],
  lock: [['rect', { x: 5, y: 10.5, width: 14, height: 10, rx: 2.5 }], ['path', { d: 'M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5M12 14.5v2' }]],
  vault: [['rect', { x: 3.5, y: 4, width: 17, height: 5, rx: 1.5 }], ['path', { d: 'M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4' }]],
  voice: [['path', { d: 'M4 10v4M8 7v10M12 4v16M16 7.5v9M20 10v4' }]],
  models: [['rect', { x: 6, y: 6, width: 12, height: 12, rx: 2.5 }], ['rect', { x: 9.5, y: 9.5, width: 5, height: 5, rx: 1 }], ['path', { d: 'M9.5 3v3M14.5 3v3M9.5 18v3M14.5 18v3M3 9.5h3M3 14.5h3M18 9.5h3M18 14.5h3' }]],
  backup: [['ellipse', { cx: 12, cy: 6, rx: 7, ry: 2.8 }], ['path', { d: 'M5 6v12c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8V6M5 12c0 1.5 3.1 2.8 7 2.8s7-1.3 7-2.8' }]],
  usage: [['path', { d: 'M4 20h16M7.5 16v-5M12 16V6.5M16.5 16v-8' }]],
  updates: [['path', { d: 'M12 4v11M7.5 10.5 12 15l4.5-4.5M5 20h14' }]],
  search: [['circle', { cx: 11, cy: 11, r: 6.5 }], ['path', { d: 'm20 20-4.2-4.2' }]],
  plus: [['path', { d: 'M12 5v14M5 12h14' }]],
  send: [['path', { d: 'M12 19V5.5M6 11l6-6 6 6' }]],
  stop: [['rect', { x: 7, y: 7, width: 10, height: 10, rx: 2, fill: true }]],
  mic: [['rect', { x: 9, y: 3, width: 6, height: 11, rx: 3 }], ['path', { d: 'M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21' }]],
  close: [['path', { d: 'M6.5 6.5l11 11M17.5 6.5l-11 11' }]],
  share: [['path', { d: 'M12 3.5V15M7.5 8 12 3.5 16.5 8M5 13v5.5A2 2 0 0 0 7 20.5h10a2 2 0 0 0 2-2V13' }]],
  chevronDown: [['path', { d: 'm6.5 9.5 5.5 5.5 5.5-5.5' }]],
  apps: [['rect', { x: 4, y: 4, width: 7, height: 7, rx: 2 }], ['rect', { x: 13, y: 4, width: 7, height: 7, rx: 2 }], ['rect', { x: 4, y: 13, width: 7, height: 7, rx: 2 }], ['path', { d: 'M16.5 13v7M13 16.5h7' }]],
  check: [['path', { d: 'm5 12.5 4.5 4.5L19 7.5' }]],
};

/** @param {keyof typeof ICONS} name @param {{size?: number, className?: string}} [options] */
export function icon(name, { size = 18, className = '' } = {}) {
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('width', String(size)); svg.setAttribute('height', String(size));
  svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor'); svg.setAttribute('stroke-width', '1.8');
  svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true'); svg.setAttribute('focusable', 'false');
  svg.classList.add('icon'); if (className) svg.classList.add(...className.split(' ').filter(Boolean));
  for (const [tag, attributes] of ICONS[name] || []) {
    const shape = document.createElementNS(NS, tag);
    for (const [key, value] of Object.entries(attributes)) {
      if (key === 'fill') { shape.setAttribute('fill', 'currentColor'); shape.setAttribute('stroke', 'none'); } else shape.setAttribute(key, String(value));
    }
    svg.append(shape);
  }
  return svg;
}

/** Replaces a button's text glyph with an icon, keeping its accessible name. */
export function setIcon(button, name, size) {
  if (!button) return;
  button.replaceChildren(icon(name, { size }));
}

export const iconNames = Object.keys(ICONS);
