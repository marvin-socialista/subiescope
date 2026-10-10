// The controls every part of the app is made of, in the Mac app's look (css/app.css).
import { html, useEffect, useLayoutEffect, useRef, useState } from '../vendor/preact-htm.js';
import { icons } from './icons.js';
import { send } from './bridge.js';

export { html };

/** Class names from what is true: cls('btn', { large: true, prominent: isMain }). */
export function cls(...parts) {
  const names = [];
  for (const part of parts) {
    if (!part) continue;
    if (typeof part === 'string') names.push(part);
    else for (const [name, on] of Object.entries(part)) if (on) names.push(name);
  }
  return names.join(' ');
}

/** An icon by its Lucide name (js/icons.js). `size` in pixels; the colour is the text colour. */
export function Icon({ name, size, class: extra, style }) {
  const drawing = icons[name] || icons['circle-help'];
  const box = size ? { width: size + 'px', height: size + 'px', ...style } : style;
  return html`<svg class=${cls('icon', extra)} style=${box} viewBox="0 0 24 24" aria-hidden="true" dangerouslySetInnerHTML=${{ __html: drawing }}></svg>`;
}

/**
 * A button. `kind`: 'prominent' (the main thing to do), 'link', 'plain', 'destructive' or nothing.
 * `size`: 'small' or 'large'. `tint`: 'orange', 'red' or 'green' with a prominent button.
 */
export function Button({ kind, size, tint, icon, wide, disabled, title, onClick, children, class: extra }) {
  return html`<button class=${cls('btn', kind, size, tint, { wide }, extra)} disabled=${disabled} title=${title} onClick=${onClick}>
    ${icon && html`<${Icon} name=${icon} />`}${children}
  </button>`;
}

/** A row of choices of which one is on. `options`: [{ value, label }]. */
export function Segmented({ options, value, onChange, wide, disabled }) {
  return html`<div class=${cls('segmented', { wide })} role="tablist">
    ${options.map(option => html`<button key=${option.value} role="tab" disabled=${disabled || option.disabled} title=${option.title}
      class=${cls({ selected: option.value === value })} onClick=${() => option.value !== value && onChange(option.value)}>${option.label}</button>`)}
  </div>`;
}

/**
 * A pop-up list. `options`: [{ value, label, disabled }], with { heading: 'USB' } to start a group
 * and { divider: true } for a line. `placeholder` shows while nothing is chosen.
 */
export function Select({ options, value, onChange, placeholder, wide, disabled, title, class: extra, style }) {
  const groups = [{ heading: null, items: [] }];
  for (const option of options) {
    if (option.heading !== undefined) groups.push({ heading: option.heading, items: [] });
    else if (option.divider) groups.push({ heading: '', items: [] });
    else groups[groups.length - 1].items.push(option);
  }
  const render = option => html`<option key=${option.value} value=${option.value} disabled=${option.disabled}>${option.label}</option>`;
  const known = options.some(option => option.value !== undefined && option.value === value);
  return html`<div class=${cls('select', { wide }, extra)} style=${style} title=${title}>
    <select value=${known ? value : ''} disabled=${disabled} onChange=${event => onChange(event.target.value)}>
      ${!known && html`<option value="" disabled>${placeholder || ''}</option>`}
      ${groups.map((group, index) => group.heading === null
        ? group.items.map(render)
        : group.items.length > 0 && html`<optgroup key=${index} label=${group.heading || '──────────'}>${group.items.map(render)}</optgroup>`)}
    </select>
    <${Icon} name="chevrons-up-down" />
  </div>`;
}

/** An on/off switch with its label. */
export function Toggle({ checked, onChange, disabled, children, title }) {
  return html`<label class="toggle" title=${title}>
    <input type="checkbox" checked=${checked} disabled=${disabled} onChange=${event => onChange(event.target.checked)} />
    ${children && html`<span>${children}</span>`}
  </label>`;
}

export function Checkbox({ checked, onChange, disabled, children, title }) {
  return html`<label class="checkbox" title=${title}>
    <input type="checkbox" checked=${checked} disabled=${disabled} onChange=${event => onChange(event.target.checked)} />
    ${children && html`<span>${children}</span>`}
  </label>`;
}

/** A line of text to type in. `onChange` gets the text with every key; `onCommit` on Enter or when leaving. */
export function TextField({ value, onChange, onCommit, placeholder, wide, disabled, class: extra, style, type }) {
  return html`<input class=${cls('field', { wide }, extra)} style=${style} type=${type || 'text'} value=${value} placeholder=${placeholder} disabled=${disabled}
    spellcheck=${false} onInput=${event => onChange && onChange(event.target.value)}
    onKeyDown=${event => { if (event.key === 'Enter' && onCommit) onCommit(event.target.value); }}
    onBlur=${event => onCommit && onCommit(event.target.value)} />`;
}

export function SearchField({ value, onChange, placeholder, style }) {
  return html`<div class="search" style=${style}>
    <${Icon} name="search" />
    <input class="field" type="text" value=${value} placeholder=${placeholder || 'Search'} spellcheck=${false} onInput=${event => onChange(event.target.value)} />
  </div>`;
}

export function Spinner({ large }) {
  return html`<div class=${cls('spinner', { large })} role="progressbar"></div>`;
}

/** A bar that fills up. `value` from 0 to 1. */
export function Progress({ value, tint }) {
  return html`<div class="progress"><div style=${{ width: Math.max(0, Math.min(1, value || 0)) * 100 + '%', background: tint }}></div></div>`;
}

/** What a part of the app shows when there is nothing to show yet: an icon, a title, a sentence, a button. */
export function Empty({ icon, title, children, action }) {
  return html`<div class="empty">
    ${icon && html`<${Icon} name=${icon} />`}
    <div class="empty-title">${title}</div>
    ${children && html`<div class="empty-text">${children}</div>`}
    ${action}
  </div>`;
}

/** A link that opens in the person's own browser. */
export function Link({ href, children }) {
  return html`<a onClick=${() => send('app.open', { url: href })} title=${href}>${children}</a>`;
}

/**
 * A panel over the window that has to be answered first. `width` in pixels. `onClose`, when given,
 * is called for Escape and for a click next to the panel.
 */
export function Sheet({ width, onClose, children, class: extra }) {
  useEffect(() => {
    const key = event => { if (event.key === 'Escape' && onClose) { event.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [onClose]);
  return html`<div class="backdrop" onMouseDown=${event => { if (event.target === event.currentTarget && onClose) onClose(); }}>
    <div class=${cls('sheet', extra)} style=${{ width: width ? width + 'px' : undefined }} role="dialog">${children}</div>
  </div>`;
}

/** A short question in the middle of the window. `buttons`: [{ label, kind, onClick }], the main one first. */
export function Alert({ title, children, buttons }) {
  return html`<${Sheet}>
    <div class="alert">
      <div class="headline">${title}</div>
      ${children && html`<div class="callout secondary">${children}</div>`}
      <div class="column" style="gap: 6px; margin-top: 6px">
        ${buttons.map(button => html`<${Button} kind=${button.kind} onClick=${button.onClick}>${button.label}<//>`)}
      </div>
    </div>
  <//>`;
}

/**
 * A panel that hangs on something on the page, such as a menu on its button. `anchor` is that element
 * (or a { left, top, right, bottom } rectangle, or { x, y } for a right click); `side` is 'bottom',
 * 'top', 'right' or 'left' of it. It closes on Escape and on a click anywhere else.
 */
export function Popover({ anchor, side = 'bottom', align = 'start', onClose, children, class: extra }) {
  const panel = useRef(null);
  const [place, setPlace] = useState({ left: -9999, top: -9999 });
  const [resized, setResized] = useState(0);
  // What is inside can grow or shrink by itself while the panel is open: it is placed again then.
  useEffect(() => {
    if (!panel.current || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(() => setResized(count => count + 1));
    observer.observe(panel.current);
    return () => observer.disconnect();
  }, []);
  useLayoutEffect(() => {
    if (!panel.current || !anchor) return;
    const rect = anchor.getBoundingClientRect ? anchor.getBoundingClientRect()
      : anchor.x !== undefined ? { left: anchor.x, right: anchor.x, top: anchor.y, bottom: anchor.y } : anchor;
    const size = panel.current.getBoundingClientRect();
    const gap = 6;
    let left, top;
    if (side === 'right' || side === 'left') {
      left = side === 'right' ? rect.right + gap : rect.left - gap - size.width;
      top = align === 'end' ? rect.bottom - size.height : align === 'center' ? (rect.top + rect.bottom - size.height) / 2 : rect.top;
    } else {
      top = side === 'bottom' ? rect.bottom + gap : rect.top - gap - size.height;
      left = align === 'end' ? rect.right - size.width : align === 'center' ? (rect.left + rect.right - size.width) / 2 : rect.left;
    }
    // Kept inside the window, whatever side was asked for.
    left = Math.max(8, Math.min(left, window.innerWidth - size.width - 8));
    top = Math.max(8, Math.min(top, window.innerHeight - size.height - 8));
    setPlace({ left, top });
  }, [anchor, side, align, children, resized]);
  useEffect(() => {
    const key = event => { if (event.key === 'Escape') { event.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', key, true);
    return () => window.removeEventListener('keydown', key, true);
  }, [onClose]);
  return html`<div class="popover-layer" onMouseDown=${event => { if (event.target === event.currentTarget) onClose(); }}
      onContextMenu=${event => { event.preventDefault(); onClose(); }}>
    <div ref=${panel} class=${cls('popover', extra)} style=${{ left: place.left + 'px', top: place.top + 'px' }}>${children}</div>
  </div>`;
}

/**
 * A menu. `items`: [{ label, icon, checked, disabled, destructive, onClick }], with { heading } and
 * { divider: true } between them. A `checked` that is true or false leaves room for a check mark.
 */
export function Menu({ anchor, side, align, items, onClose }) {
  const checks = items.some(item => item.checked !== undefined);
  return html`<${Popover} anchor=${anchor} side=${side} align=${align} onClose=${onClose} class="menu">
    ${items.filter(Boolean).map((item, index) => item.divider ? html`<div key=${index} class="menu-divider"></div>`
      : item.heading ? html`<div key=${index} class="menu-heading">${item.heading}</div>`
      : html`<div key=${index} class=${cls('menu-item', { disabled: item.disabled, destructive: item.destructive })}
            onClick=${() => { onClose(); item.onClick && item.onClick(); }}>
          ${checks && html`<span class="menu-check">${item.checked ? html`<${Icon} name="check" />` : null}</span>`}
          ${item.icon && html`<${Icon} name=${item.icon} />`}
          <span>${item.label}</span>
        </div>`)}
  <//>`;
}

/** A button that opens a menu. `items` as for Menu; the button takes Button's own properties. */
export function MenuButton({ items, children, side, align, ...button }) {
  const [anchor, setAnchor] = useState(null);
  return html`<${Button} ...${button} onClick=${event => setAnchor(event.currentTarget)}>${children}<//>
    ${anchor && html`<${Menu} anchor=${anchor} side=${side} align=${align} items=${items} onClose=${() => setAnchor(null)} />`}`;
}

/** Keeps a number of seconds since `since` (seconds since 1970) up to date, once a second. */
export function useElapsed(since) {
  const [, tick] = useState(0);
  useEffect(() => {
    if (!since) return;
    const timer = setInterval(() => tick(n => n + 1), 500);
    return () => clearInterval(timer);
  }, [since]);
  return since ? Math.max(0, Date.now() / 1000 - since) : 0;
}

/** 75 seconds as "1:15". */
export function clock(seconds) {
  const whole = Math.floor(seconds);
  return Math.floor(whole / 60) + ':' + String(whole % 60).padStart(2, '0');
}

/** A number with a fixed count of decimals, or a dash when there is none. */
export function fixed(value, decimals = 0) {
  return value === null || value === undefined || !Number.isFinite(value) ? '–' : value.toFixed(decimals);
}

// A part of the app can put buttons of its own in the window's toolbar, next to Connect and Record.
const toolbar = { items: null, listeners: new Set() };

/**
 * Shows `items` (buttons made with ToolbarButton) in the toolbar for as long as the component is
 * on the page. `changes` lists what the items depend on, as for useEffect.
 */
export function useToolbar(items, changes = []) {
  useEffect(() => {
    toolbar.items = items;
    toolbar.listeners.forEach(listener => listener());
    return () => {
      if (toolbar.items === items) toolbar.items = null;
      toolbar.listeners.forEach(listener => listener());
    };
  }, changes);
}

/** Where the toolbar shows those buttons. Used by the window's frame only. */
export function ToolbarSlot() {
  const [, redraw] = useState(0);
  useEffect(() => {
    const listener = () => redraw(n => n + 1);
    toolbar.listeners.add(listener);
    return () => toolbar.listeners.delete(listener);
  }, []);
  return toolbar.items ? html`<div class="toolbar-group">${toolbar.items}</div>` : null;
}

/** A button for the toolbar: an icon, with words next to it when `children` are given. */
export function ToolbarButton({ icon, title, disabled, onClick, children }) {
  return html`<button class="toolbar-button" title=${title} disabled=${disabled} onClick=${onClick}>
    ${icon && html`<${Icon} name=${icon} />`}${children}
  </button>`;
}

/**
 * A sheet with a list to search and pick one thing from. `items`: [{ id, name, detail }];
 * `onPick` gets the id. Used for adding a gauge and for anything else chosen from a long list.
 */
export function PickerSheet({ title, items, placeholder, onPick, onClose }) {
  const [query, setQuery] = useState('');
  const field = useRef(null);
  useEffect(() => { if (field.current) field.current.querySelector('input').focus(); }, []);
  const wanted = query.trim().toLowerCase();
  const shown = wanted ? items.filter(item => item.name.toLowerCase().includes(wanted)) : items;
  return html`<${Sheet} width=${440} onClose=${onClose}>
    <div class="row" style="padding: 14px 16px 10px">
      <div class="headline grow">${title}</div>
      <${Button} onClick=${onClose}>Done<//>
    </div>
    <div ref=${field} style="padding: 0 16px 10px"><${SearchField} value=${query} onChange=${setQuery} placeholder=${placeholder} /></div>
    <div class="picker-list">
      ${shown.map(item => html`<div key=${item.id} class="picker-row" onClick=${() => { onPick(item.id); onClose(); }}>
        <div class="grow"><div class="truncate">${item.name}</div>${item.detail && html`<div class="caption secondary">${item.detail}</div>`}</div>
        <${Icon} name="circle-plus" class="accent" />
      </div>`)}
      ${shown.length === 0 && html`<div class="secondary center" style="padding: 30px">Nothing found.</div>`}
    </div>
  <//>`;
}
