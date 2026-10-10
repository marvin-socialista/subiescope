// The ROM editor, behind Advanced mode: a ROM that is opened from a file or read from the car, what
// it is, its checksums, its maps as tables to edit, its raw bytes, and saving it as a new file.
// What it shows comes from the app (Bridge+ROM.swift). Nothing here writes to a car.
import { useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { request, send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Select, Spinner, Progress, Sheet, ToolbarButton, useToolbar } from '../ui.js';
import { registerIcons } from '../icons.js';

registerIcons({
  'arrow-down-to-line': '<path d="M12 17V3" /> <path d="m6 11 6 6 6-6" /> <path d="M19 21H5" />',
  'badge-x': '<path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z" /> <line x1="15" x2="9" y1="9" y2="15" /> <line x1="9" x2="15" y1="9" y2="15" />',
  'circle-arrow-down': '<circle cx="12" cy="12" r="10" /> <path d="M12 8v8" /> <path d="m8 12 4 4 4-4" />',
  'circle-arrow-right': '<circle cx="12" cy="12" r="10" /> <path d="M8 12h8" /> <path d="m12 16 4-4-4-4" />',
  'file-cog': '<path d="M14 2v4a2 2 0 0 0 2 2h4" /> <path d="m3.2 12.9-.9-.4" /> <path d="m3.2 15.1-.9.4" /> <path d="M4.677 21.5a2 2 0 0 0 1.313.5H18a2 2 0 0 0 2-2V7l-5-5H6a2 2 0 0 0-2 2v2.5" /> <path d="m4.9 11.2-.4-.9" /> <path d="m4.9 16.8-.4.9" /> <path d="m7.5 10.3-.4.9" /> <path d="m7.5 17.7-.4-.9" /> <path d="m9.7 12.5-.9.4" /> <path d="m9.7 15.5-.9-.4" /> <circle cx="6" cy="14" r="3" />',
  // Lucide has no shield with a lock in it: this is its shield, with a small lock in the same hand.
  'shield-lock': '<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z" /> <rect x="9" y="11.5" width="6" height="4.5" rx="1" /> <path d="M10.25 11.5V10a1.75 1.75 0 0 1 3.5 0v1.5" />',
});

/** An icon with a sentence next to it, which may run over several lines. */
function Label({ icon, class: extra, children }) {
  return html`<div class=${cls('rom-label', extra)}><${Icon} name=${icon} /><span>${children}</span></div>`;
}

function Card({ title, children }) {
  return html`<section class="card flat rom-card">
    <div class="title3">${title}</div>
    ${children}
  </section>`;
}

/** A line to type in that does something on Enter only, not when it is left. */
function Field({ value, onChange, onSubmit, placeholder, style }) {
  return html`<input class="field" type="text" style=${style} value=${value} placeholder=${placeholder} spellcheck=${false}
    onInput=${event => onChange(event.target.value)}
    onKeyDown=${event => { if (event.key === 'Enter' && onSubmit) onSubmit(); }} />`;
}

/** What stands in the ROM editor's place while Advanced mode is off. */
function Locked({ advanced }) {
  return html`<div class="content">
    <div class="empty rom-locked">
      <${Icon} name="shield-lock" />
      <div class="title3">ROM reading and editing is in Advanced mode</div>
      <div class="empty-text">This is for reading a ROM (an ECU tune) from the car and editing it on your ${advanced.computer}. It is risky and separate from the normal logging and diagnostics, so it is off until you turn it on.</div>
      <${Button} kind="prominent" tint="orange" icon="shield-alert" onClick=${() => send('rom.showDisclaimer')}>Turn On Advanced Mode…<//>
    </div>
  </div>`;
}

function DisclaimerCard({ advanced }) {
  const [open, setOpen] = useState(false);
  return html`<section class="rom-warning">
    <${Label} icon="triangle-alert" class="headline orange">${advanced.short}<//>
    <div class="rom-subheadline">${advanced.noWriteToCar}</div>
    <button class="rom-disclosure" aria-expanded=${open} onClick=${() => setOpen(!open)}>
      <${Icon} name=${open ? 'chevron-down' : 'chevron-right'} /><span>What you should know before editing a ROM</span>
    </button>
    ${open && html`<div class="callout secondary rom-paragraphs">${advanced.full}</div>`}
  </section>`;
}

function ReadCard() {
  const read = useSlice('rom.read');
  if (!read) return null;
  return html`<${Card} title="Read from car">
    <div class="callout secondary">Read the ROM straight off the car's engine ECU, then edit it here. It needs an OBDLink (or other STN-based) adapter in OBD-II mode, or a Tactrix OpenPort 2.0. This loads a small helper program into the ECU and copies the flash out. It reads only, and never writes anything back to the car. For the 2008 and later Subarus with a Denso SH7058 ECU, such as the 2008+ STI. This is new and has not been tested on a real car yet.</div>
    ${read.inProgress ? html`
      <${Progress} value=${read.progress} />
      <div class="row">
        <span class="callout secondary grow">${read.status}</span>
        <${Button} onClick=${() => send('rom.stopRead')}>Stop<//>
      </div>
      <div class="caption secondary">This takes several minutes. Keep the ignition ON, leave the engine off, and do not touch the car or unplug the adapter until it finishes.</div>
    ` : html`
      <${Label} icon="triangle-alert" class="callout orange">Before you start: ignition ON, engine OFF, a healthy battery, and do not disturb the car until the read finishes.<//>
      <div class="row" style="gap: 10px">
        <${Button} kind="prominent" icon="arrow-down-to-line" disabled=${!read.canRead} onClick=${() => send('rom.readFromCar')}>Read ROM from car<//>
        ${read.checkingAdapter && html`<${Spinner} />`}
      </div>
      <div class="callout secondary">${read.availability}</div>
      ${read.status && html`<div class=${cls('callout', read.failed ? 'red' : 'secondary')}>${read.status}</div>`}
    `}
  <//>`;
}

function EmptyState({ status }) {
  return html`<div class="rom-empty">
    <${Icon} name="microchip" />
    <div class="secondary">Open a ROM file to inspect and edit it.</div>
    <div class="callout secondary">A ROM is a .bin file, for example one read with FastECU or EcuFlash. You can also read it from the car with the card above.</div>
    <${Button} kind="prominent" icon="folder" onClick=${() => send('rom.open')}>Open ROM…<//>
    ${status && html`<div class="callout secondary">${status}</div>`}
  </div>`;
}

function FileCard({ rom }) {
  return html`<${Card} title="File">
    ${rom.file.map(row => html`<div key=${row.label} class="rom-row callout">
      <span class="secondary">${row.label}</span><span class="selectable">${row.value}</span>
    </div>`)}
  <//>`;
}

const checksumLooks = {
  unknown: { icon: 'circle-help', look: 'callout secondary' },
  disabled: { icon: 'circle-minus', look: 'secondary' },
  ok: { icon: 'badge-check', look: 'green' },
  mismatch: { icon: 'badge-x', look: 'orange' },
};

function ChecksumCard({ rom }) {
  const sums = rom.checksums;
  return html`<${Card} title="Checksums">
    ${sums && html`<${Label} icon=${checksumLooks[sums.state].icon} class=${checksumLooks[sums.state].look}>${sums.text}<//>`}
    ${sums && sums.state === 'mismatch' && html`
      <div class="callout secondary">After editing a map, the checksums no longer add up. Correct them before a ROM is of any use.</div>
      <div><${Button} kind="prominent" icon="wand-sparkles" onClick=${() => send('rom.correctChecksums')}>Correct Checksums<//></div>
    `}
    ${rom.status && html`<div class="callout secondary">${rom.status}</div>`}
  <//>`;
}

/** One cell of a map. It keeps what is typed until Enter or until it is left, and then shows what the ROM holds. */
function Cell({ text, editable, onCommit }) {
  const [draft, setDraft] = useState(text);
  const focused = useRef(false);
  useEffect(() => { if (!focused.current) setDraft(text); }, [text]);
  const commit = async typed => {
    // Nothing typed: nothing to ask the app.
    if (typed === text) return;
    setDraft(await onCommit(typed));
  };
  return html`<input class="rom-cell" type="text" value=${draft} disabled=${!editable} spellcheck=${false}
    onInput=${event => setDraft(event.target.value)}
    onFocus=${() => { focused.current = true; }}
    onBlur=${event => { focused.current = false; commit(event.target.value); }}
    onKeyDown=${event => { if (event.key === 'Enter') commit(event.target.value); }} />`;
}

/**
 * The map that is chosen, as a table with its axes. Its numbers come once, when `version` says they
 * are new (see ROMMap in the app); after an edit only the cell that changed comes back.
 */
function MapGrid({ version }) {
  const [map, setMap] = useState(null);
  const shown = useRef(version);
  shown.current = version;
  useEffect(() => {
    let wanted = true;
    request('rom.map').then(reply => { if (wanted) setMap(reply); });
    return () => { wanted = false; };
  }, [version]);
  if (!map) return null;

  const commit = async (row, column, text) => {
    const reply = await request('rom.editCell', { map: map.name, row, column, text });
    const now = reply ? reply.text : map.cells[row][column];
    // Another map may have been chosen in the meantime.
    if (shown.current === version) {
      setMap(old => old && old.name === map.name
        ? { ...old, cells: old.cells.map((line, r) => r !== row ? line : line.map((cell, c) => c !== column ? cell : now)) }
        : old);
    }
    return now;
  };

  const columnCount = map.cells.length ? map.cells[0].length : 0;
  // A label for every column, also where the axis is shorter than the table is wide.
  const labels = map.columns && Array.from({ length: columnCount }, (_, c) => map.columns[c] || '');
  // Every column is as wide as the longest number in it.
  const widths = Array.from({ length: columnCount }, (_, c) => Math.max(labels ? labels[c].length : 0, ...map.cells.map(line => line[c].length)));
  const columns = 'minmax(54px, max-content) ' + widths.map(length => `max(52px, calc(${length}ch + 10px))`).join(' ');
  return html`<div class="rom-map">
    <div class="row">
      <span class="headline">${map.name}</span>
      ${map.units && html`<span class="secondary">(${map.units})</span>`}
      ${map.readOnly && html`<span class="rom-readonly caption secondary"><${Icon} name="lock" />read-only</span>`}
    </div>
    ${map.description && html`<div class="caption secondary">${map.description}</div>`}
    <div class="rom-grid-scroll">
      <div class="rom-grid" style=${{ gridTemplateColumns: columns }}>
        ${labels && html`<span></span>${labels.map((label, c) => html`<span key=${'x' + c} class="rom-axis">${label}</span>`)}`}
        ${map.cells.map((line, r) => html`
          <span key=${'y' + r} class="rom-axis">${map.rows[r]}</span>
          ${line.map((text, c) => html`<${Cell} key=${r + ':' + c} text=${text} editable=${!map.readOnly} onCommit=${typed => commit(r, c, typed)} />`)}
        `)}
      </div>
    </div>
  </div>`;
}

function MapPicker({ rom }) {
  const categories = useSlice('rom.maps') || [];
  const options = [{ value: '', label: 'Choose a map…' }];
  for (const category of categories) {
    options.push({ heading: category.name });
    for (const name of category.maps) options.push({ value: name, label: name });
  }
  return html`<div class="row">
    <span>Map</span>
    <${Select} class="rom-map-picker" options=${options} value=${rom.selectedMap} onChange=${name => send('rom.selectMap', { name })} />
  </div>`;
}

function MapsCard({ rom }) {
  const definitions = rom.definitions;
  return html`<${Card} title="Maps">
    <div class="row" style="gap: 10px">
      ${definitions.loading && html`<${Spinner} />`}
      <${Button} icon="circle-arrow-down" disabled=${definitions.loading} onClick=${() => send('rom.getDefinitions')}>Get Definitions<//>
      <${Button} icon="file-cog" onClick=${() => send('rom.openDefinitions')}>Open Definitions…<//>
      ${definitions.source && html`<span class="caption secondary">${definitions.source}</span>`}
    </div>
    <div class="callout secondary">The definitions let SubieScope show this ROM's maps by name. It downloads RomRaider's ecu_defs.xml from the SubieScope repository (credited to RomRaider), or you can choose your own copy.</div>
    ${rom.mapError && html`<${Label} icon="triangle-alert" class="callout orange">${rom.mapError}<//>`}
    ${definitions.state === 'matched' && html`
      <div class="callout green">${definitions.matchedText}</div>
      <${MapPicker} rom=${rom} />
      <${MapGrid} version=${rom.mapVersion} />
    `}
    ${definitions.state === 'suggestions' && html`
      <div class="callout secondary">No exact match for this ROM's internal ID. Closest definitions, pick one only if you are sure it is right:</div>
      ${definitions.suggestions.map(suggestion => html`<${Button} key=${suggestion.id} kind="link" class="rom-suggestion" icon="circle-arrow-right"
        onClick=${() => send('rom.useDefinition', { id: suggestion.id })}>${suggestion.label}<//>`)}
    `}
    ${definitions.state === 'unknown' && html`<${Label} icon="circle-help" class="callout secondary">These definitions have no entry matching this ROM's internal ID.<//>`}
  <//>`;
}

function BytesCard({ rom }) {
  const lines = useSlice('rom.bytes') || [];
  const [place, setPlace] = useState('0');
  const [offset, setOffset] = useState('');
  const [bytes, setBytes] = useState('');
  // Another ROM starts at its first byte again.
  useEffect(() => setPlace('0'), [rom.session]);
  const show = () => send('rom.showOffset', { offset: place });
  return html`<${Card} title="Bytes">
    <div class="callout secondary">Edit raw bytes directly. Named map editing (fuel, boost, timing by name) needs the ROM definitions and is the next step.</div>
    <div class="row">
      <span>Go to offset (hex)</span>
      <${Field} value=${place} onChange=${setPlace} onSubmit=${show} placeholder="0" style="width: 100px" />
      <${Button} onClick=${show}>Show<//>
    </div>
    <div class="rom-hex">
      ${lines.map(line => html`<div key=${line.offset}><span class="secondary">${line.offset}</span><span>${line.hex}</span><span class="secondary">${line.text}</span></div>`)}
    </div>
    <div class="divider" style="margin: 4px 0"></div>
    <div class="column" style="gap: 6px">
      <div class="rom-subheadline">Write bytes</div>
      <div class="row wrap">
        <span>Offset (hex)</span>
        <${Field} value=${offset} onChange=${setOffset} placeholder="2004" style="width: 90px" />
        <span>Bytes (hex)</span>
        <${Field} value=${bytes} onChange=${setBytes} placeholder="e.g. 41 42 43" style="width: 220px" />
        <${Button} onClick=${() => send('rom.writeBytes', { offset, bytes })}>Apply<//>
      </div>
      ${rom.bytesError && html`<div class="caption red">${rom.bytesError}</div>`}
    </div>
  <//>`;
}

function Editor({ advanced }) {
  const rom = useSlice('rom');
  const app = useSlice('app');
  const isOpen = !!(rom && rom.isOpen);
  useToolbar(html`
    <${ToolbarButton} icon="folder" title="Open ROM…" onClick=${() => send('rom.open')} />
    <${ToolbarButton} icon="save" title="Save As… Save the edited ROM to a NEW file; keep the original." disabled=${!isOpen} onClick=${() => send('rom.saveAs')} />
  `, [isOpen]);
  // Whether the adapter can read a ROM is found out when this part comes up, and again when the connection changes.
  const connection = app && app.connection;
  useEffect(() => { send('rom.checkAdapter'); }, [connection]);
  if (!rom) return html`<div class="content"></div>`;
  return html`<div class="content">
    <div class="rom">
      <${DisclaimerCard} advanced=${advanced} />
      <${ReadCard} />
      ${isOpen ? html`
        <${FileCard} rom=${rom} />
        <${ChecksumCard} rom=${rom} />
        <${MapsCard} rom=${rom} />
        <${BytesCard} rom=${rom} />
      ` : html`<${EmptyState} status=${rom.status} />`}
    </div>
  </div>`;
}

/** The "ROM Editor" part of the app. */
export function ROM() {
  const advanced = useSlice('rom.advanced');
  if (!advanced) return html`<div class="content"></div>`;
  return advanced.on ? html`<${Editor} advanced=${advanced} />` : html`<${Locked} advanced=${advanced} />`;
}

/** The sheet that asks before Advanced mode (the ROM editor) is turned on. Shown when the app asks for it. */
export function ROMSheets() {
  const advanced = useSlice('rom.advanced');
  const showing = !!(advanced && advanced.showDisclaimer);
  // Escape answers this sheet alone, also when it lies over Settings, where it is asked for.
  useEffect(() => {
    if (!showing) return;
    const key = event => { if (event.key === 'Escape') { event.stopPropagation(); send('rom.dismissDisclaimer'); } };
    window.addEventListener('keydown', key, true);
    return () => window.removeEventListener('keydown', key, true);
  }, [showing]);
  if (!showing) return null;
  return html`<div class="rom-sheet-layer">
    <${Sheet} width=${560}>
      <div class="rom-disclaimer">
        <${Label} icon="triangle-alert" class="title2 orange">Turn on Advanced mode?<//>
        <div class="headline">Advanced mode unlocks the ROM Editor: reading a ROM (an ECU tune) from a file or from the car, and editing it on your ${advanced.computer}.</div>
        <div class="rom-disclaimer-text secondary rom-paragraphs">${advanced.full}</div>
        <div class="sheet-buttons" style="margin-top: 0">
          <${Button} onClick=${() => send('rom.dismissDisclaimer')}>Cancel<//>
          <${Button} kind="prominent" tint="orange" icon="shield-check" onClick=${() => send('rom.acceptDisclaimer')}>I Understand, Turn It On<//>
        </div>
      </div>
    <//>
  </div>`;
}
