// The logo for a connector (10.1): the service's real logo, in its own colour, on a white tile like a store listing.
// Built with createElementNS, never innerHTML. An app with no logo gets its first letter instead.
import { logos } from './connector-logos.js';

const NS = 'http://www.w3.org/2000/svg';

/** @param {string} slug @param {string} name @param {{size?: number}} [options] */
export function connectorIcon(slug, name, { size = 40 } = {}) {
  const tile = document.createElement('span');
  tile.className = 'connector-icon'; tile.style.setProperty('--size', size + 'px'); tile.setAttribute('aria-hidden', 'true');
  const logo = logos[slug];
  if (logo) {
    const svg = document.createElementNS(NS, 'svg'); svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('focusable', 'false');
    const path = document.createElementNS(NS, 'path'); path.setAttribute('d', logo.path); path.setAttribute('fill', '#' + logo.hex);
    svg.append(path); tile.append(svg);
  } else { tile.classList.add('fallback'); tile.textContent = (name || slug || '?')[0].toUpperCase(); }
  return tile;
}
