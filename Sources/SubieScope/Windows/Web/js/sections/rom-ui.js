// The ROM editor's own small controls, in the look of the Mac's (Views/ROMStyle.swift): a flat
// button, a switch between a few views of the same thing, a count in a badge. Used by rom.js and
// the files next to it.
import { html, cls, Icon } from '../ui.js';
import { registerIcons } from '../icons.js';

registerIcons({
  'arrow-left-right': '<path d="M8 3 4 7l4 4" /> <path d="M4 7h16" /> <path d="m16 21 4-4-4-4" /> <path d="M20 17H4" />',
  'arrow-down-to-line': '<path d="M12 17V3" /> <path d="m6 11 6 6 6-6" /> <path d="M19 21H5" />',
  'chevrons-down': '<path d="m7 6 5 5 5-5" /> <path d="m7 13 5 5 5-5" />',
  'chevrons-up': '<path d="m17 11-5-5-5 5" /> <path d="m17 18-5-5-5 5" />',
  'circle-arrow-right': '<circle cx="12" cy="12" r="10" /> <path d="M8 12h8" /> <path d="m12 16 4-4-4-4" />',
  'move-horizontal': '<path d="m18 8 4 4-4 4" /> <path d="M2 12h20" /> <path d="m6 8-4 4 4 4" />',
  // Lucide has no shield with a lock in it: this is its shield, with a small lock in the same hand.
  'shield-lock': '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" /> <rect x="9" y="11.5" width="6" height="4.5" rx="1" /> <path d="M10.25 11.5V10a1.75 1.75 0 0 1 3.5 0v1.5" />',
});

/** True while a sheet, an alert or a menu is over the window: keys are theirs then. */
export function somethingIsOver() {
  return document.querySelector('.backdrop, .popover-layer') !== null;
}

/**
 * Gives the keyboard to the workspace: the arrow keys move the selected cell there, and digits type
 * into it. Called when a cell is clicked, and after a control in a map that would keep the keys.
 */
export function focusWorkspace() {
  const workspace = document.querySelector('.rom-workspace');
  if (workspace) workspace.focus({ preventScroll: true });
}

/** An icon with a sentence next to it, which may run over several lines. */
export function Label({ icon, class: extra, style, title, children }) {
  return html`<div class=${cls('rom-label', extra)} style=${style} title=${title}><${Icon} name=${icon} /><span>${children}</span></div>`;
}

/**
 * The editor's own button: a flat, rounded tile. `kind`: nothing for a button of the toolbar,
 * 'quiet' for one inside a card, 'filled' for one in a colour of its own (`tint`: 'fine', 'coarse',
 * 'primary' or 'purple'). `height` and `pad` in pixels. `label` says what a button without words does.
 */
export function RomButton({ kind, tint, height = 30, pad = 10, icon, pressed, disabled, title, label, onClick, children }) {
  const style = { height: height + 'px', padding: `0 ${pad}px`, borderRadius: height > 26 ? '7px' : '6px' };
  return html`<button class=${cls('rom-btn', kind, kind === 'filled' && tint)} style=${style} disabled=${disabled} title=${title}
      aria-label=${label} aria-pressed=${pressed} onClick=${onClick}>
    ${icon && html`<${Icon} name=${icon} />`}${children}
  </button>`;
}

/**
 * A small switch between a few views of the same thing: Now, As opened, Difference.
 * `options`: [{ value, label, dot }], where `dot` is the colour of a dot in front of the label.
 * With `fills`, each option takes an equal share of the width.
 */
export function Segments({ options, value, onChange, fills, height = 20, title }) {
  return html`<div class=${cls('rom-segments', { fills })} role="tablist" title=${title}>
    ${options.map(option => html`<button key=${String(option.value)} role="tab" aria-selected=${option.value === value}
        class=${cls({ selected: option.value === value })} style=${{ height: height + 'px' }} onClick=${() => onChange(option.value)}>
      ${option.dot && html`<span class="rom-dot" style=${{ background: option.dot }}></span>`}${option.label}
    </button>`)}
  </div>`;
}

/** A count in a rounded badge: the changed cells of a map in orange, the different ones in purple. */
export function Badge({ text, compare }) {
  return html`<span class=${cls('rom-badge', { compare })}>${text}</span>`;
}

/**
 * What the selected cell holds, in the words of the strip under a map: now, as opened with the
 * difference, and what the other ROM holds while one is compared. `detail` is the app's
 * `ROMSelection.Detail`.
 */
export function CellNumbers({ detail }) {
  const units = detail.units ? ' ' + detail.units : '';
  return html`<span class="rom-numbers">
    <span>Now <b>${detail.now}</b>${units}</span>
    ${detail.other !== undefined ? html`<span class="other">Other ROM <b>${detail.other}</b>${units}</span>`
      : detail.comparing ? html`<span class="secondary">The same in the other ROM</span>`
      : detail.opened !== undefined ? html`<span class="opened">As opened <b>${detail.opened}</b>${units} (${detail.difference || ''})</span>`
      : html`<span class="secondary">Same as opened</span>`}
  </span>`;
}
