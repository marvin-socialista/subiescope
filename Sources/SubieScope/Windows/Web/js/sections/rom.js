// The ROM editor, behind Advanced mode, laid out the way RomRaider is: a tree of the ROM's maps on
// the left, a toolbar over it, and a workspace of the maps that are open, each a table of coloured
// cells. A cell that is not what it was when the ROM was opened is ringed, so a change is never out
// of sight.
//
// The page only draws and passes on what a person does. What is open, selected and changed is all
// in the app's ROM editor (ROMEditor.swift, sent by Bridge+ROM.swift), which the Mac app shows too:
// this is the same screen as the Mac's Views/ROMView.swift and the files next to it. Everything
// here is work on a file. Nothing here writes to a car.
import { useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { peek, send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Spinner, Progress, Sheet } from '../ui.js';
import { RomButton, Segments, Badge, Label, focusWorkspace, somethingIsOver } from './rom-ui.js';
import { MapWindow } from './rom-map.js';

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

/**
 * A field whose text is the editor's own: the tree's filter, and the toolbar's steps and value.
 * What is typed goes to the app with every key. What the app holds shows while nobody is typing
 * here: it fills the Value field from the cell that is selected, and a map brings its own steps.
 * With `clear`, a button that empties the field stands behind it while there is something in it.
 */
function EditorField({ field, value, session, class: extra, style, placeholder, label, disabled, clear, onSubmit }) {
  const input = useRef(null);
  const [text, setText] = useState(value);
  useEffect(() => { if (document.activeElement !== input.current) setText(value); }, [value]);
  // Another ROM starts every field again, also the one that is being typed in.
  useEffect(() => setText(value), [session]);
  const type = typed => {
    setText(typed);
    send('rom.type', { field, text: typed });
  };
  return html`<input ref=${input} class=${extra} style=${style} type="text" value=${text} placeholder=${placeholder} aria-label=${label}
      disabled=${disabled} spellcheck=${false} onInput=${event => type(event.target.value)} onBlur=${() => setText(value)}
      onKeyDown=${event => { if (event.key === 'Enter' && onSubmit) onSubmit(); }} />
    ${clear && text && html`<button title=${clear} aria-label=${clear} onClick=${() => type('')}><${Icon} name="circle-x" /></button>`}`;
}

/** A card of the overview, and of the screen without a ROM. */
function Card({ title, children }) {
  return html`<section class="rom-card">
    <div class="rom-card-title">${title}</div>
    ${children}
  </section>`;
}

/**
 * The warning that stands over everything to do with a ROM: it is at your own risk, and nothing
 * here writes to the car. The whole text is behind "What you should know".
 */
function Notice({ advanced }) {
  const [open, setOpen] = useState(false);
  return html`<section class="rom-notice">
    <${Icon} name="triangle-alert" />
    <div class="column grow" style="gap: 4px">
      <div class="rom-notice-title">${advanced.short}</div>
      <div class="callout">${advanced.noWriteToCar}</div>
      <button class="rom-disclosure callout" aria-expanded=${open} onClick=${() => setOpen(!open)}>
        <${Icon} name=${open ? 'chevron-down' : 'chevron-right'} /><span>What you should know before editing a ROM</span>
      </button>
      ${open && html`<div class="callout secondary rom-paragraphs" style="padding-top: 6px">${advanced.full}</div>`}
    </div>
  </section>`;
}

/**
 * Reading the ROM out of the car's engine ECU. This is the one thing in the editor that talks to
 * the car, and it only reads.
 */
function ReadCard() {
  const read = useSlice('rom.read');
  if (!read) return null;
  return html`<${Card} title="Read from car">
    <div class="callout secondary">Copies the ROM out of the engine ECU and opens it here. It needs a Tactrix OpenPort 2.0, or an OBDLink (or other STN-based) adapter in OBD-II mode. It loads a small helper program into the ECU and copies the flash out. It reads only, and never writes anything back to the car. For the 2008 and later Subarus with a Denso SH7058 ECU, such as the 2008+ STI. This is new: it has worked on one car so far, a 2009 WRX STI through a Tactrix OpenPort.</div>
    ${read.inProgress ? html`
      <div class="rom-wide"><${Progress} value=${read.progress} /></div>
      <div class="row rom-wide">
        <span class="callout secondary grow">${read.status}</span>
        <${RomButton} kind="quiet" height=${26} onClick=${() => send('rom.stopRead')}>Stop<//>
      </div>
      <div class="callout secondary">This takes several minutes. Keep the ignition ON, leave the engine off, and do not touch the car or unplug the adapter until it finishes.</div>
    ` : html`
      <${Label} icon="triangle-alert" class="callout rom-orange-text">Ignition ON, engine OFF, a healthy battery, and leave the car alone until it finishes.<//>
      <div class="row" style="gap: 12px">
        <${RomButton} kind="filled" tint="primary" height=${28} pad=${12} icon="arrow-down-to-line" disabled=${!read.canRead}
          onClick=${() => send('rom.readFromCar')}>Read ROM from Car<//>
        ${read.checkingAdapter && html`<${Spinner} />`}
        <span class="callout secondary">${read.availability}</span>
      </div>
      ${read.status && html`<div class=${cls('callout', read.failed ? 'red' : 'secondary')}>${read.status}</div>`}
    `}
  <//>`;
}

/** The ROM editor without a ROM in it: the risk notice, reading one from the car, and opening a file. */
function Start({ rom, advanced }) {
  return html`<div class="rom-start">
    <div class="rom-start-column">
      <${Notice} advanced=${advanced} />
      <${ReadCard} />
      <div class="rom-empty">
        <${Icon} name="microchip" />
        <div class="secondary">Open a ROM file to inspect and edit it.</div>
        <div class="callout secondary">A ROM is a .bin file, for example one read with FastECU or EcuFlash. You can also read it from the car with the card above.</div>
        <${Button} kind="prominent" icon="folder" onClick=${() => send('rom.open')}>Open ROM…<//>
        ${rom.status && html`<div class=${cls('callout', rom.statusIsProblem ? 'rom-orange-text' : 'secondary')}>${rom.status}</div>`}
      </div>
    </div>
  </div>`;
}

// MARK: The toolbar and the bars

const checksumLooks = {
  unknown: { icon: 'circle-help', look: 'secondary' },
  disabled: { icon: 'circle-minus', look: 'secondary' },
  ok: { icon: 'badge-check', look: 'rom-ok' },
  mismatch: { icon: 'triangle-alert', look: 'rom-orange-text' },
};

/** A fine or a coarse step: the buttons that lower and raise the selected cells by it, and how large it is. */
function StepGroup({ rom, title, size, width, enabled, note }) {
  const word = title.toLowerCase();
  const double = size === 'coarse';
  return html`<div class="rom-tool-group steps">
    <span class="rom-tool-label">${title}</span>
    <${RomButton} kind="filled" tint=${size} height=${28} pad=${8} icon=${double ? 'chevrons-down' : 'chevron-down'} disabled=${!enabled}
      title=${enabled ? `Lower the selected cells by the ${word} step` : note} label=${`Lower the selected cells by the ${word} step`}
      onClick=${() => send('rom.step', { size, up: false })} />
    <${RomButton} kind="filled" tint=${size} height=${28} pad=${8} icon=${double ? 'chevrons-up' : 'chevron-up'} disabled=${!enabled}
      title=${enabled ? `Raise the selected cells by the ${word} step` : note} label=${`Raise the selected cells by the ${word} step`}
      onClick=${() => send('rom.step', { size, up: true })} />
    <${EditorField} class="rom-field" style=${{ width: width + 'px' }} field=${size + 'Step'} value=${double ? rom.coarseStep : rom.fineStep}
      session=${rom.session} label=${title + ' step'} disabled=${!enabled} />
  </div>`;
}

/**
 * The editor's toolbar: the file, Undo and Redo, RomRaider's ways to change the selected cells (a
 * fine and a coarse step down or up, set to a value, multiply by one), the 3D view, comparing with
 * another ROM, and how the checksums stand.
 */
function Toolbar({ rom }) {
  const read = useSlice('rom.read');
  const maps = useSlice('rom.maps') || [];
  const selection = useSlice('rom.selection');
  const comparing = !!rom.compare;
  const selected = rom.selectedMap === undefined ? undefined : maps.find(map => map.id === rom.selectedMap);
  // The tools that change cells are there while the selected map shows the ROM as it is now. They
  // have nothing to work on in a view of the past, a view of differences, or another ROM. A switch
  // is selected like a map, and has no cells.
  const showsEditTools = !!selected && !!selected.table && !comparing && (selected.surface || selected.shows === 'now');
  const canChangeCells = rom.canEditCells && !!selection && selection.cells.length > 0;
  const note = rom.editingNote || 'Select the cells to change first.';
  const sums = checksumLooks[rom.checksums.state] || checksumLooks.unknown;
  const separator = html`<span class="rom-tool-separator"></span>`;
  return html`<div class="rom-toolbar">
    <div class="rom-toolbar-flow">
      <div class="rom-tool-group">
        <${RomButton} icon="folder" title="Open a ROM file (.bin)" onClick=${() => send('rom.open')}>Open<//>
        ${rom.isOpen && html`<${RomButton} icon="download" title="Save this ROM as a new file. Keep the original." onClick=${() => send('rom.saveAs')}>Save As<//>`}
        <${RomButton} icon="cpu" title=${read ? read.availability : undefined} disabled=${!!read && read.inProgress}
          onClick=${() => send('rom.askToRead')}>Read from Car<//>
      </div>
      ${rom.isOpen && html`
        ${!comparing && html`
          ${separator}
          <div class="rom-tool-group undo">
            <${RomButton} icon="undo" disabled=${!rom.undo.can} title=${rom.undo.label ? `Undo ${rom.undo.label} (Ctrl+Z)` : 'Nothing to undo'}
              label=${rom.undo.label ? `Undo ${rom.undo.label}` : 'Undo'} onClick=${() => send('rom.undo')} />
            <${RomButton} icon="redo" disabled=${!rom.redo.can} title=${rom.redo.label ? `Redo ${rom.redo.label} (Ctrl+Y)` : 'Nothing to redo'}
              label=${rom.redo.label ? `Redo ${rom.redo.label}` : 'Redo'} onClick=${() => send('rom.redo')} />
          </div>`}
        ${showsEditTools && html`
          ${separator}
          <${StepGroup} rom=${rom} title="Fine" size="fine" width=${52} enabled=${canChangeCells} note=${note} />
          <${StepGroup} rom=${rom} title="Coarse" size="coarse" width=${46} enabled=${canChangeCells} note=${note} />
          <div class="rom-tool-group steps">
            <span class="rom-tool-label">Value</span>
            <${EditorField} class="rom-field" style="width: 64px" field="value" value=${rom.value} session=${rom.session} label="Value"
              disabled=${!canChangeCells} onSubmit=${() => send('rom.set')} />
            <${RomButton} kind="quiet" height=${28} disabled=${!canChangeCells} title="Give the selected cells this value" onClick=${() => send('rom.set')}>Set<//>
            <${RomButton} kind="quiet" height=${28} disabled=${!canChangeCells} title="Multiply the selected cells by this value" onClick=${() => send('rom.multiply')}>Mul<//>
          </div>`}
        ${separator}
        <div class="rom-tool-group">
          ${rom.selectedMap !== undefined && html`<${RomButton} icon="box" kind=${selected && selected.surface ? 'filled' : undefined} tint="primary"
            pressed=${!!selected && selected.surface} disabled=${!selected || !selected.canShowSurface}
            title=${selected && selected.canShowSurface ? 'Show the selected map in 3D, or as a table again' : 'Only a map with rows and columns has a 3D view'}
            onClick=${() => send('rom.toggleSurface')}>3D<//>`}
          <${RomButton} icon="arrow-left-right" kind=${comparing ? 'filled' : undefined} tint="purple" pressed=${comparing}
            title=${comparing ? 'Stop comparing' : 'Compare this ROM with another ROM file. Comparing changes neither file.'}
            onClick=${() => send('rom.toggleCompare')}>Compare<//>
        </div>`}
    </div>
    ${rom.isOpen && html`<div class="rom-checksums">
      <${Label} icon=${sums.icon} class=${sums.look} title=${rom.checksums.text}>${rom.checksums.short}<//>
      ${rom.checksums.state === 'mismatch' && !comparing && html`<${RomButton} kind="filled" tint="primary" pad=${12}
        title="Correct the checksums. An ECU rejects a ROM whose checksums are wrong." onClick=${() => send('rom.correctChecksums')}>Correct<//>`}
    </div>`}
  </div>`;
}

/** The bar that says which two files are being compared, with the ways out of it. */
function CompareBar({ rom }) {
  return html`<div class="rom-compare-bar">
    <div class="row" style="gap: 14px">
      <span class="rom-compare-names"><b>Comparing</b>${'  this ROM, '}<b>${rom.fileName}</b><span class="secondary">${'  with  '}</span><b>${rom.compare.other}</b>${' · ' + rom.compare.calibration}</span>
      <${RomButton} kind="quiet" height=${24} onClick=${() => send('rom.compare')}>Choose Another File<//>
      <${RomButton} kind="quiet" height=${24} onClick=${() => send('rom.stopCompare')}>Stop Comparing<//>
    </div>
    ${rom.compare.warning && html`<${Label} icon="triangle-alert" class="rom-orange-text">${rom.compare.warning}<//>`}
  </div>`;
}

/**
 * The line along the bottom: how much changed since the ROM was opened (or differs from the other
 * ROM), what happened last, and which definitions and what kind of ROM this is.
 */
function StatusBar({ rom }) {
  const read = useSlice('rom.read');
  return html`<footer class="rom-status">
    ${rom.compare ? html`<span class="rom-summary compared"><span class="rom-dot"></span><span class="truncate">${rom.compare.summary}</span></span>`
      : rom.hasChanges ? html`
        <span class="rom-summary changed"><span class="rom-dot"></span><span class="truncate">${rom.changesSummary}</span></span>
        <${RomButton} kind="quiet" height=${20} pad=${8} title="List every change since this ROM was opened, with the old number first"
          onClick=${() => send('rom.showChanges', { on: !rom.showsChanges })}>${rom.showsChanges ? 'Hide changes' : 'Show changes'}<//>`
      : html`<span>${rom.changesSummary}</span>`}
    ${read && read.inProgress ? html`<span class="row" style="gap: 6px"><${Spinner} />${read.status}</span>`
      : rom.status && html`<span class=${cls('rom-last truncate', { problem: rom.statusIsProblem })} title=${rom.status}>${rom.status}</span>`}
    <span class="spacer"></span>
    <span>${rom.definitions.summary}</span>
    <span>${rom.size}</span>
  </footer>`;
}

// MARK: The tree

/**
 * The left side: the ROM itself as a card, and under it every map of the ROM by category, the way
 * RomRaider lists them. A map that changed since the ROM was opened carries the number of its
 * changed cells in orange, and the list can be cut down to only those.
 */
function Tree({ rom }) {
  const tree = useSlice('rom.tree');
  const comparing = !!rom.compare;
  if (!tree) return html`<aside class="rom-tree"></aside>`;
  // All, or only the maps that changed. While another ROM is compared, only the ones that differ from it.
  const narrowed = comparing ? { value: 'different', label: `Different ${tree.differentMapCount}`, dot: 'var(--rom-purple)' }
    : { value: 'changed', label: `Changed ${tree.changedMapCount}`, dot: 'var(--rom-orange)' };
  return html`<aside class="rom-tree">
    <button class=${cls('rom-file', { unsaved: rom.isEdited, selected: rom.overview })} aria-pressed=${rom.overview}
        title="Show what this ROM is: its file, definitions, checksums and bytes" onClick=${() => send('rom.showOverview')}>
      <span class="rom-bold">${rom.fileName}</span>
      <span class="callout secondary">${rom.identity}</span>
      <span class=${cls('rom-file-saved callout', { unsaved: rom.isEdited })}>${rom.isEdited && html`<span class="rom-dot"></span>`}${rom.saved}</span>
    </button>
    ${tree.mapCount > 0 ? html`
      <div class="rom-filter">
        <${Icon} name="search" />
        <${EditorField} field="filter" value=${tree.filter} session=${rom.session} placeholder="Filter maps" label="Filter maps" clear="Clear the filter" />
      </div>
      <${Segments} fills height=${24} value=${tree.listing} options=${[{ value: 'all', label: `All ${tree.mapCount}` }, narrowed]}
        onChange=${listing => send('rom.list', { listing })} />
      <div class="rom-tree-list">
        ${tree.categories.map(category => html`
          <button key=${category.name} class=${cls('rom-category', { expanded: category.isExpanded })} aria-expanded=${category.isExpanded}
              title=${category.name} onClick=${() => send('rom.toggleCategory', { name: category.name })}>
            <${Icon} name="chevron-right" class="rom-chevron" /><${Icon} name="folder" class="rom-folder" />
            <span class="truncate grow">${category.name}</span>
            ${category.hasChanges && tree.listing === 'all' && !comparing && html`<span class="rom-dot" aria-label="has changed maps"></span>`}
            <span class="rom-count">${category.countText}</span>
          </button>
          ${category.isExpanded && category.maps.map(map => html`
            <button key=${category.name + '/' + map.id} class=${cls('rom-tree-map', { open: map.isOpen, selected: map.isSelected })}
                aria-current=${map.isSelected ? 'true' : undefined} title=${map.title} onClick=${() => send('rom.openMap', { map: map.id })}>
              <span class="rom-chip">${map.dimension}</span>
              <span class="truncate grow">${map.title}</span>
              ${comparing ? map.different > 0 && html`<${Badge} text=${map.different} compare />` : map.changed > 0 && html`<${Badge} text=${map.changed} />`}
            </button>`)}`)}
        ${tree.categories.length === 0 && tree.listing === 'all' && html`<div class="callout secondary" style="padding: 6px">No map has "${tree.filter}" in its name.</div>`}
      </div>
      ${tree.note && html`<div class="rom-note">${tree.note}</div>`}
    ` : html`<div class="rom-note">${rom.definitions.state === 'matched' ? 'The definitions have no map for this ROM that can be shown.'
        : `${rom.definitions.text} The card above says more.`}</div>`}
  </aside>`;
}

/**
 * Everything that is different from the ROM as it was opened, map by map, with the old number
 * first. A click on a line goes to that cell. Under the list are the two things to do about it:
 * correct the checksums, or put everything back.
 */
function ChangesPanel({ rom }) {
  const changes = useSlice('rom.changes');
  // With checksums that no longer add up, the warning comes with the button that corrects them.
  const mismatch = rom.checksums.state === 'mismatch';
  const open = (group, line) => {
    send('rom.openMap', line.row === undefined ? { map: group.id } : { map: group.id, row: line.row, column: line.column });
    focusWorkspace();
  };
  return html`<aside class="rom-changes">
    <div class="row" style="align-items: flex-start">
      <div class="column grow" style="gap: 2px">
        <div class="rom-card-title">Changes</div>
        <div class="callout secondary">Everything that is different from this ROM as it was opened. The old number comes first.</div>
      </div>
      <button class="rom-close" title="Hide the changes" aria-label="Hide the changes" onClick=${() => send('rom.showChanges', { on: false })}><${Icon} name="x" /></button>
    </div>
    ${rom.hasChanges ? html`
      <div class="rom-changes-list">
        ${changes && changes.groups.map(group => html`<div key=${group.id} class="rom-change-group">
          <div class="row">
            <button class="rom-change-title truncate" title=${'Open ' + group.title} onClick=${() => send('rom.openMap', { map: group.id })}>${group.title}</button>
            <span class="spacer"></span>
            <span class="callout secondary">${group.units}</span>
          </div>
          <div class="rom-change-lines">
            ${group.lines.map((line, index) => html`<button key=${index} onClick=${() => open(group, line)}>
              <span class=${cls('rom-arrow', line.raised ? 'up' : 'down')} role="img" aria-label=${line.raised ? 'raised' : 'lowered'}></span>
              <span class="truncate grow">${line.place}</span>
              <span class="rom-change-numbers">${line.was} → <b>${line.now}</b></span>
            </button>`)}
          </div>
          ${group.more > 0 && html`<div class="callout secondary">and ${group.more} more</div>`}
        </div>`)}
        ${changes && changes.more > 0 && html`<div class="callout secondary">and ${changes.more} more map${changes.more === 1 ? '' : 's'}. Choose Changed above the map list to see them all.</div>`}
        ${changes && changes.otherBytes && html`<div class="callout secondary">${changes.otherBytes}</div>`}
      </div>
      <div class=${cls('rom-changes-actions', { mismatch })}>
        ${mismatch && html`<div>An ECU rejects a ROM whose checksums are wrong. Correct them before you use this file.</div>`}
        <div class="row wrap" style="gap: 6px">
          ${mismatch && html`<${RomButton} kind="filled" tint="primary" height=${26} onClick=${() => send('rom.correctChecksums')}>Correct Checksums<//>`}
          <${RomButton} kind="quiet" height=${26} title="Make the whole ROM what it was when it was opened. Undo brings your changes back."
            onClick=${() => send('rom.putEverythingBack')}>Put Everything Back<//>
        </div>
      </div>
    ` : html`<div class="callout secondary">Nothing has changed since this ROM was opened.</div>`}
  </aside>`;
}

// MARK: The overview

/**
 * The raw file, for what the definitions have no map for: sixteen lines of bytes from an offset,
 * and a way to write bytes at one.
 */
function BytesCard({ rom, overview }) {
  const [place, setPlace] = useState('0');
  const [offset, setOffset] = useState('');
  const [bytes, setBytes] = useState('');
  // Another ROM starts at its beginning again.
  useEffect(() => { setPlace('0'); setOffset(''); setBytes(''); }, [rom.session]);
  const show = () => send('rom.showOffset', { offset: place });
  const field = (value, change, placeholder, width, submit) => html`<input class="rom-field small" type="text" style=${{ width: width + 'px' }}
    value=${value} placeholder=${placeholder} spellcheck=${false} onInput=${event => change(event.target.value)}
    onKeyDown=${event => { if (event.key === 'Enter' && submit) submit(); }} />`;
  return html`<section class="rom-card">
    <div class="row wrap rom-wide" style="gap: 6px 14px">
      <span class="rom-card-title">Bytes</span>
      <span class="callout secondary">The raw file, for what the definitions have no map for.</span>
      <span class="spacer"></span>
      <span class="row callout" style="gap: 6px">
        <span>Go to offset (hex)</span>
        ${field(place, setPlace, '0', 84, show)}
        <${RomButton} kind="quiet" height=${26} onClick=${show}>Show<//>
      </span>
    </div>
    <div class="rom-hex selectable">
      ${overview.bytes.map(line => html`<div key=${line.offset}><span class="secondary">${line.offset}</span><span>${line.hex}</span><span class="secondary">${line.text}</span></div>`)}
    </div>
    <div class="row wrap callout">
      <span>Write at (hex)</span>
      ${field(offset, setOffset, 'offset', 84)}
      <span>Bytes</span>
      ${field(bytes, setBytes, '41 42 43', 260)}
      <${RomButton} kind="quiet" height=${26} disabled=${!!rom.compare} onClick=${() => send('rom.writeBytes', { offset, bytes })}>Apply<//>
      ${overview.bytesError && html`<span class="red">${overview.bytesError}</span>`}
    </div>
  </section>`;
}

/**
 * What the workspace shows while the ROM itself is selected in the tree: the risk notice, and a
 * card each for the file, the definitions, the checksums and reading from the car, with the raw
 * bytes under them.
 */
function Overview({ rom, advanced }) {
  const overview = useSlice('rom.overview');
  if (!overview) return null;
  const definitions = rom.definitions;
  const matched = definitions.state === 'matched';
  const sums = checksumLooks[rom.checksums.state] || checksumLooks.unknown;
  const mismatch = rom.checksums.state === 'mismatch';
  // Where the definitions in use came from: the repository, or a file the person chose.
  const source = !overview.definitionsSource ? "SubieScope downloads RomRaider's ecu_defs.xml from its repository, or you can choose your own copy."
    : overview.definitionsSource.startsWith('from ') ? `They are RomRaider's ecu_defs.xml, downloaded ${overview.definitionsSource}.`
    : `They are RomRaider's definitions, read from the file ${overview.definitionsSource}.`;
  return html`<div class="rom-overview">
    <${Notice} advanced=${advanced} />
    <div class="rom-cards">
      <${Card} title="File">
        <div class="rom-file-rows">
          ${overview.file.map(row => html`<span key=${row.label} class="secondary">${row.label}</span><span class=${cls('selectable', { mono: row.isCode })}>${row.value}</span>`)}
          <span class="secondary">Saved</span><span class=${cls({ 'rom-orange-text': rom.isEdited })}>${rom.saved}</span>
        </div>
      <//>
      <${Card} title="Definitions">
        <div class=${cls('rom-label', matched ? 'rom-ok' : 'rom-orange-text')}>
          ${definitions.loading ? html`<${Spinner} />` : html`<${Icon} name=${matched ? 'circle-check' : 'circle-help'} />`}<span>${definitions.text}</span>
        </div>
        ${definitions.state === 'suggestions' && html`<div class="column" style="gap: 4px; align-items: flex-start">
          ${overview.suggestions.map(suggestion => html`<${Button} key=${suggestion.id} kind="link" icon="circle-arrow-right"
            onClick=${() => send('rom.useDefinition', { id: suggestion.id })}>${suggestion.label}<//>`)}
        </div>`}
        ${overview.definitionsError && html`<${Label} icon="triangle-alert" class="callout rom-orange-text">${overview.definitionsError}<//>`}
        <div class="callout secondary">The definitions say where each map sits in this ROM and how its numbers are scaled. ${source}</div>
        <div class="row" style="gap: 6px">
          <${RomButton} kind="quiet" height=${26} disabled=${definitions.loading} onClick=${() => send('rom.getDefinitions')}>Get Definitions<//>
          <${RomButton} kind="quiet" height=${26} onClick=${() => send('rom.openDefinitions')}>Open Definitions…<//>
        </div>
      <//>
      <${Card} title="Checksums">
        <${Label} icon=${sums.icon} class=${sums.look}>${rom.checksums.text}<//>
        <div class="callout secondary">An ECU rejects a ROM whose checksums are wrong. After you edit a map they no longer add up, and SubieScope corrects them for you.</div>
        <${RomButton} kind=${mismatch ? 'filled' : 'quiet'} tint="primary" height=${26} disabled=${!mismatch || !!rom.compare}
          onClick=${() => send('rom.correctChecksums')}>Correct Checksums<//>
      <//>
      <${ReadCard} />
    </div>
    <${BytesCard} rom=${rom} overview=${overview} />
  </div>`;
}

// MARK: The workspace

/**
 * The workspace: the ROM itself, or the maps that are open, each a window, with the Changes panel
 * beside them. It has the keyboard: the arrow keys move the selected cell (with Shift they select a
 * block), digits type a number for the selected cells, Enter writes it and Escape drops it. Ctrl+A
 * selects the whole map and Ctrl+C copies the selected cells.
 */
function Workspace({ rom, advanced }) {
  const maps = useSlice('rom.maps') || [];
  const selection = useSlice('rom.selection');
  const angles = useSlice('rom.angles') || [];
  const windows = useRef(null);
  // The number being typed into the selected cells, until Enter writes it or Escape drops it.
  const typed = useRef('');
  const [, redraw] = useState(0);
  const setTyped = text => {
    if (typed.current === text) return;
    typed.current = text;
    redraw(count => count + 1);
  };
  // Another map is selected: what was being typed was for the one before. The keyboard goes to
  // the workspace when nothing else has it, so the arrow keys work on a map that was just opened.
  useEffect(() => {
    setTyped('');
    if (rom.selectedMap !== undefined && document.activeElement === document.body) focusWorkspace();
  }, [rom.selectedMap]);

  // Writes the number that was typed into the selected cells.
  const commitTyped = () => {
    if (!typed.current) return;
    const text = typed.current;
    setTyped('');
    send('rom.set', { text });
  };
  const onCell = map => (row, column, extending) => {
    commitTyped();
    focusWorkspace();
    send('rom.selectCell', { map, row, column, extending });
  };
  const key = event => {
    // The newest of what the app said: several keys can come before the page is drawn again.
    const now = peek('rom'), cells = peek('rom.selection');
    if (!now || now.selectedMap === undefined || event.altKey || somethingIsOver()) return;
    // A field or a slider in the workspace has keys of its own.
    if (event.target.closest('input, textarea, select')) return;
    if (event.ctrlKey || event.metaKey) {
      const letter = event.key.toLowerCase();
      if (letter === 'a') send('rom.selectAll');
      else if (letter === 'c') send('rom.copy');
      else return;
      event.preventDefault();
      return;
    }
    const move = (rows, columns) => {
      commitTyped();
      send('rom.move', { rows, columns, extending: event.shiftKey });
    };
    switch (event.key) {
      case 'ArrowUp': move(-1, 0); break;
      case 'ArrowDown': move(1, 0); break;
      case 'ArrowLeft': move(0, -1); break;
      case 'ArrowRight': move(0, 1); break;
      case 'Enter':
        if (!typed.current) return;
        commitTyped();
        break;
      case 'Escape':
        if (!typed.current) return;
        setTyped('');
        break;
      case 'Backspace':
        if (!typed.current) return;
        setTyped(typed.current.slice(0, -1));
        break;
      default:
        // A number is being typed. A comma is taken for the decimal point.
        if (event.key.length !== 1 || !'0123456789.,-'.includes(event.key) || !now.canEditCells
            || !cells || cells.cells.length === 0 || typed.current.length >= 12) return;
        setTyped(typed.current + event.key);
    }
    event.preventDefault();
  };

  // A map that was opened from the tree or the Changes panel comes into view, once its window is there.
  const revealed = useRef(rom.revealCount);
  useEffect(() => {
    if (revealed.current === rom.revealCount || !windows.current) return;
    const target = [...windows.current.children].find(child => child.dataset.map === rom.selectedMap);
    if (!target) return;
    revealed.current = rom.revealCount;
    windows.current.scrollTo({ top: target.offsetTop - 12, behavior: 'smooth' });
  }, [rom.revealCount, rom.selectedMap, maps]);

  const showsChanges = rom.showsChanges && !rom.compare;
  return html`<div class=${cls('rom-workspace', { 'beside-changes': showsChanges })} tabindex="0" onKeyDown=${key}>
    <div ref=${windows} class="rom-windows">
      ${rom.overview ? html`<${Overview} rom=${rom} advanced=${advanced} />` : maps.map(map => {
        const isSelected = map.id === rom.selectedMap;
        return html`<${MapWindow} key=${map.id} map=${map} rom=${rom} isSelected=${isSelected}
          selection=${isSelected && selection && selection.map === map.id ? selection : undefined}
          angles=${angles.find(one => one.id === map.id)} typed=${typed.current} onCell=${onCell(map.id)} />`;
      })}
    </div>
    ${showsChanges && html`<${ChangesPanel} rom=${rom} />`}
  </div>`;
}

function Editor({ advanced }) {
  const rom = useSlice('rom');
  const app = useSlice('app');
  // Ctrl+Z takes the last edit of the ROM back, and Ctrl+Y (or Ctrl+Shift+Z) puts it back. They are
  // only caught while there is an edit to take back or put back: without one they stay what they are
  // everywhere else, undo and redo for the text in a field.
  useEffect(() => {
    const key = event => {
      if (!(event.ctrlKey || event.metaKey) || event.altKey || somethingIsOver()) return;
      const letter = event.key.toLowerCase();
      const again = letter === 'y' || (letter === 'z' && event.shiftKey);
      if (!again && letter !== 'z') return;
      const now = peek('rom');
      if (!now || !(again ? now.redo.can : now.undo.can)) return;
      event.preventDefault();
      event.stopPropagation();
      send(again ? 'rom.redo' : 'rom.undo');
    };
    window.addEventListener('keydown', key, true);
    return () => window.removeEventListener('keydown', key, true);
  }, []);
  // Whether the adapter can read a ROM is found out when this part comes up, and again when the connection changes.
  const connection = app && app.connection;
  useEffect(() => { send('rom.checkAdapter'); }, [connection]);
  // A button that is clicked does not take the keyboard: it stays with the workspace, or with the
  // field that was being typed in, as it does in the Mac app.
  const keepFocus = event => { if (event.target.closest('button')) event.preventDefault(); };
  if (!rom) return html`<div class="rom-editor"></div>`;
  return html`<div class="rom-editor" onMouseDown=${keepFocus}>
    <${Toolbar} rom=${rom} />
    ${rom.isOpen ? html`
      ${rom.compare && html`<${CompareBar} rom=${rom} />`}
      <div class="rom-main">
        <${Tree} rom=${rom} />
        <${Workspace} rom=${rom} advanced=${advanced} />
      </div>
      <${StatusBar} rom=${rom} />
    ` : html`<${Start} rom=${rom} advanced=${advanced} />`}
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
