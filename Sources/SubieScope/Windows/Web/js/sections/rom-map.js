// One open map in the ROM editor's workspace, as a window of its own: a title bar with the map's
// menus and the switch for what its cells show, the table (or the 3D view) with its axes, what the
// rings mean, and, for the selected map, a strip that describes the selected cell.
// (The Mac's Views/ROMMapWindow.swift and ROMMapGrid.swift.) What it shows is the app's `ROMMapWindow`.
import { useLayoutEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { send } from '../bridge.js';
import { html, cls, Icon, MenuButton } from '../ui.js';
import { RomButton, Segments, Badge, Label, CellNumbers, focusWorkspace } from './rom-ui.js';
import { Surface } from './rom-surface.js';

const shows = [{ value: 'now', label: 'Now' }, { value: 'asOpened', label: 'As opened' }, { value: 'difference', label: 'Difference' }];
const compareShows = [{ value: 'both', label: 'Both' }, { value: 'thisROM', label: 'This ROM' }, { value: 'otherROM', label: 'Other ROM' }, { value: 'difference', label: 'Difference' }];
const none = [];

// Where everything of a map's table is, in pixels. The numbers are the Mac's (ROMGridMetrics).
// Around the cells there is room for the rings of a marked or a selected cell, which reach outside it.
const gridInset = 5;
const gridGap = 1;
const headerHeight = 23;
const maxCellWidth = 84;
// A table that scrolls sideways has a scroll bar under it, which takes room of its own in the page.
const scrollBarHeight = 12;

function cellHeightOf(table) {
  return table.twoNumbers ? 34 : 23;
}

/** How tall the table is. It does not depend on the width, so the window can make room for it first. */
function gridHeight(table) {
  const header = table.columnLabels ? headerHeight + gridGap : 0;
  return 2 * gridInset + header + table.rows * cellHeightOf(table) + gridGap * Math.max(table.rows - 1, 0);
}

/**
 * The cells share the width there is, up to a width that still reads as a table. When the numbers
 * do not fit at their own size, they get a pixel smaller before the table starts to scroll: a map
 * that is on screen whole shows every changed cell at once.
 */
function gridMetrics(table, available) {
  let longest = 4;
  for (const line of table.cells) for (const cell of line) longest = Math.max(longest, cell.text.length, cell.below ? cell.below.length : 0);
  for (const label of table.columnLabels || []) longest = Math.max(longest, label.length);
  const longestLabel = Math.max(0, ...(table.rowLabels || []).map(label => label.length));
  const labelWidth = table.rowLabels ? Math.min(Math.max(Math.ceil(longestLabel * 7.4 + 16), 44), 72) : 0;
  // What a number of the longest length needs at a font size: the digits and a little air, a pixel
  // less of it at the smaller size, where every pixel counts.
  const needed = size => Math.ceil(longest * size * 0.61 + (size < 12 ? 5 : 6));
  const labels = table.rowLabels ? labelWidth + gridGap : 0;
  const room = available - 2 * gridInset - labels - gridGap * Math.max(table.columns - 1, 0);
  const share = table.columns > 0 ? Math.floor(room / table.columns) : needed(12);
  const metrics = { labelWidth, cellHeight: cellHeightOf(table), fontSize: 12, cellWidth: needed(12), scrolls: true };
  if (share >= needed(12)) return { ...metrics, cellWidth: Math.min(share, Math.max(maxCellWidth, needed(12))), scrolls: false };
  if (share >= needed(11)) return { ...metrics, fontSize: 11, cellWidth: share, scrolls: false };
  return metrics;
}

/**
 * A map as a table of coloured cells, the way RomRaider shows one: each number on the colour of its
 * place between the map's lowest and highest value, with the axes along the top and the left. A cell
 * that is not what it was when the ROM was opened has a ring around it, red when it was raised and
 * blue when it was lowered, and a small triangle in its corner that points the same way.
 *
 * A table that is wider than the window scrolls sideways past the labels in front of its rows, and
 * keeps the selected cell in view. `width` is the room there is for the table. `selection` is the
 * selected cells ([row, column, …]) and `cursor` the one the selection ends on; `typed` is the
 * number being typed into them. `onCell(row, column, extending)` is called for a click on a cell,
 * and for each cell a drag reaches.
 */
function Grid({ table, metrics, width, selection, cursor, typed, onCell }) {
  const scroller = useRef(null);
  const cells = useRef(null);
  const dragged = useRef(null);
  const header = table.columnLabels ? 1 : 0;
  const pitchX = metrics.cellWidth + gridGap, pitchY = metrics.cellHeight + gridGap;

  // The cell under the pointer. With `nearest`, a point outside the cells gives the cell closest
  // to it: a drag that runs off the table keeps selecting along its edge.
  const cellAt = (event, nearest) => {
    const box = cells.current.getBoundingClientRect();
    const column = Math.floor((event.clientX - box.left) / pitchX);
    const row = Math.floor((event.clientY - box.top - header * (headerHeight + gridGap)) / pitchY);
    if (nearest) return { row: Math.min(Math.max(row, 0), table.rows - 1), column: Math.min(Math.max(column, 0), table.columns - 1) };
    return row >= 0 && row < table.rows && column >= 0 && column < table.columns ? { row, column } : null;
  };
  const down = event => {
    if (event.button !== 0) return;
    const cell = cellAt(event, false);
    if (!cell) return;
    dragged.current = cell;
    cells.current.setPointerCapture(event.pointerId);
    onCell(cell.row, cell.column, event.shiftKey);
  };
  const move = event => {
    const last = dragged.current;
    if (!last) return;
    // The drag reached another cell: the block from where it started to here.
    const cell = cellAt(event, true);
    if (cell.row === last.row && cell.column === last.column) return;
    dragged.current = cell;
    onCell(cell.row, cell.column, true);
  };
  const up = () => { dragged.current = null; };

  // A cell that the arrow keys moved to comes into view, when it was past the edge. So does the
  // selected one when the window gets narrower around it.
  const cursorColumn = cursor ? cursor[1] : -1;
  useLayoutEffect(() => {
    const view = scroller.current;
    if (!metrics.scrolls || !view || cursorColumn < 0) return;
    const left = cursorColumn * pitchX, right = left + metrics.cellWidth + 2 * gridInset;
    if (left < view.scrollLeft) view.scrollLeft = left;
    else if (right > view.scrollLeft + view.clientWidth) view.scrollLeft = right - view.clientWidth;
  }, [cursorColumn, metrics.scrolls, width]);

  const selected = new Set();
  let top = Infinity, left = Infinity, bottom = -1, right = -1;
  for (let i = 0; i < selection.length; i += 2) {
    const row = selection[i], column = selection[i + 1];
    if (row >= table.rows || column >= table.columns) continue;
    selected.add(row * table.columns + column);
    top = Math.min(top, row); bottom = Math.max(bottom, row);
    left = Math.min(left, column); right = Math.max(right, column);
  }
  const several = selected.size > 1;
  const typing = typed && cursor && cursor[0] < table.rows && cursor[1] < table.columns;
  const rows = { gridTemplateRows: header ? headerHeight + 'px' : undefined, gridAutoRows: metrics.cellHeight + 'px' };
  // Where something lies over a block of cells. It names both ends: what lies over the grid has
  // no place in it of its own, and an end that is not named would be the edge of the whole grid.
  const over = (firstRow, firstColumn, lastRow, lastColumn) => ({ gridRow: `${firstRow + 1 + header} / ${lastRow + 2 + header}`, gridColumn: `${firstColumn + 1} / ${lastColumn + 2}` });

  return html`<div class=${cls('rom-grid', { scrolls: metrics.scrolls })} style=${{ fontSize: metrics.fontSize + 'px' }}>
    ${table.rowLabels && html`<div class="rom-grid-labels" style=${{ ...rows, width: metrics.labelWidth + 'px' }} aria-hidden="true">
      ${header ? html`<span></span>` : null}
      ${table.rowLabels.map((label, row) => html`<span key=${row} class="rom-axis-cell">${label}</span>`)}
    </div>`}
    <div ref=${scroller} class="rom-grid-scroll">
      <div ref=${cells} class="rom-grid-cells" style=${{ ...rows, gridTemplateColumns: `repeat(${table.columns}, ${metrics.cellWidth}px)` }}
          role="img" aria-label=${`${table.rows} by ${table.columns} cells`}
          onPointerDown=${down} onPointerMove=${move} onPointerUp=${up} onPointerCancel=${up}>
        ${(table.columnLabels || []).map((label, column) => html`<span key=${'x' + column} class="rom-axis-cell">${label}</span>`)}
        ${table.cells.map((line, row) => line.map((cell, column) => html`<span key=${row + ':' + column}
            class=${cls('rom-cell', cell.fill && 'fill-' + cell.fill, cell.mark && 'marked mark-' + cell.mark,
                        { two: cell.below !== undefined, selected: several && selected.has(row * table.columns + column) })}
            style=${cell.color ? { background: cell.color } : null} title=${cell.note}>
          ${cell.text}${cell.below !== undefined && html`<small>${cell.below}</small>`}
        </span>`))}
        ${typing && html`<span class="rom-typed" style=${over(cursor[0], cursor[1], cursor[0], cursor[1])}>${typed}<i></i></span>`}
        ${bottom >= 0 && html`<span class="rom-selection" style=${over(top, left, bottom, right)}></span>`}
      </div>
    </div>
  </div>`;
}

/** The small cell in a legend that shows what a ring means. `fill`: 'raised', 'lowered' or 'plain' as in a Difference view. */
function Sample({ mark, fill }) {
  return html`<span class=${cls('rom-sample', fill && 'fill-' + fill, mark && 'marked mark-' + mark)} aria-hidden="true"></span>`;
}

function Legend({ legend }) {
  const item = (sample, text) => html`<span>${sample}${text}</span>`;
  return html`<span class="rom-legend">
    ${legend === 'changes' && html`
      ${item(html`<${Sample} mark="raised" />`, 'raised')}
      ${item(html`<${Sample} mark="lowered" />`, 'lowered since this ROM was opened')}`}
    ${legend === 'difference' && html`
      ${item(html`<${Sample} mark="raised" fill="raised" />`, 'raised')}
      ${item(html`<${Sample} mark="lowered" fill="lowered" />`, 'lowered')}
      ${item(html`<${Sample} fill="plain" />`, 'as opened')}`}
    ${legend === 'compare' && item(html`<${Sample} mark="different" />`, 'A cell that is different: this ROM on top, the other ROM below it')}
    ${legend === 'compareDifference' && html`
      ${item(html`<${Sample} mark="raised" fill="raised" />`, 'higher in this ROM')}
      ${item(html`<${Sample} mark="lowered" fill="lowered" />`, 'lower in this ROM')}
      ${item(html`<${Sample} fill="plain" />`, 'the same')}`}
  </span>`;
}

/**
 * The strip under the selected map: where the selected cell is, what it holds now and held when the
 * ROM was opened, where the ROM keeps it, and the way back. It takes a second line where one is not enough.
 */
function Strip({ detail, rom, indent }) {
  return html`<div class="rom-strip" style=${{ marginLeft: indent + 'px' }}>
    <span class="rom-bold">${detail.place}</span>
    <${CellNumbers} detail=${detail} />
    ${detail.stored && html`<span class="secondary">${detail.stored}</span>`}
    ${detail.count > 1 && html`<span class="secondary">${detail.count} cells selected</span>`}
    ${rom.editingNote && html`<span class="secondary">${rom.editingNote}</span>`}
    ${!rom.compare && html`<${RomButton} kind="quiet" height=${22} pad=${9} disabled=${!detail.canPutBack}
      title="Give the selected cells the numbers they had when this ROM was opened"
      onClick=${() => send('rom.putBack')}>${detail.count > 1 ? `Put back as opened (${detail.count})` : 'Put back as opened'}<//>`}
  </div>`;
}

function Table({ map, rom, isSelected, selection, typed, onCell }) {
  const table = map.table;
  const area = useRef(null);
  const [available, setAvailable] = useState(0);
  useLayoutEffect(() => {
    const element = area.current;
    setAvailable(Math.floor(element.clientWidth));
    // A new width can change the table's height (a scroll bar comes or goes), which is this
    // element's own: that is for the next frame, not for the middle of this one's layout.
    const observer = new ResizeObserver(() => requestAnimationFrame(() => setAvailable(Math.floor(element.clientWidth))));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  const metrics = gridMetrics(table, available);
  const height = gridHeight(table);
  // The axis name beside the rows takes room on the left. The rest is kept clear of it.
  const indent = table.rowTitle ? 22 : 0;
  const detail = isSelected && selection ? selection.detail : undefined;
  return html`<div class="rom-map-body">
    ${isSelected && table.description && html`<div class="rom-map-description">${table.description}</div>`}
    ${table.columnTitle && html`<div class="rom-axis-title" style=${{ marginLeft: indent + 'px' }}>${table.columnTitle}</div>`}
    <div class="rom-map-table">
      ${table.rowTitle && html`<div class="rom-row-title" style=${{ height: height + 'px' }}><span style=${{ width: height + 'px' }}>${table.rowTitle}</span></div>`}
      <div ref=${area} class="rom-grid-area" style=${{ height: height + (metrics.scrolls && available > 0 ? scrollBarHeight : 0) + 'px' }}>
        ${available > 0 && html`<${Grid} table=${table} metrics=${metrics} width=${available} selection=${isSelected && selection ? selection.cells : none}
          cursor=${isSelected && selection ? selection.cursor : undefined} typed=${isSelected ? typed : ''} onCell=${onCell} />`}
      </div>
    </div>
    ${metrics.scrolls && available > 0 && html`<${Label} icon="move-horizontal" class="rom-scroll-note" style=${{ marginLeft: indent + 'px' }}>
      This map is wider than the window. Scroll sideways to see the rest of it.
    <//>`}
    <div class="rom-map-foot" style=${{ marginLeft: indent + 'px' }}>
      <span class="rom-value-title truncate">${table.valueTitle}</span>
      <${Legend} legend=${table.legend} />
    </div>
    ${detail && html`<${Strip} detail=${detail} rom=${rom} indent=${indent} />`}
  </div>`;
}

/**
 * A RomRaider switch is no table: the ROM is in one of its positions. The window says which, and
 * that it cannot be changed here.
 */
function Switch({ toggle }) {
  return html`<div class="rom-switch">
    <div class="row" style="gap: 10px">
      <span class="rom-switch-tag" style=${toggle.color ? { background: toggle.color } : null}>${(toggle.state || 'neither').toUpperCase()}</span>
      <span>${toggle.state ? `This switch is ${toggle.state} in this ROM.`
        : "This ROM is in neither of this switch's positions: the bytes it holds here are something else."}</span>
    </div>
    ${toggle.openedState && html`<div class="rom-orange-text">It was ${toggle.openedState} when this ROM was opened.</div>`}
    ${toggle.otherState && html`<div class="rom-purple-text">In the other ROM it is ${toggle.otherState}.</div>`}
    ${toggle.description && html`<div class="secondary">${toggle.description}</div>`}
    <div class="secondary">A switch is not a table of numbers: the ROM holds one of a few fixed sets of bytes for it. SubieScope shows which one, and cannot change a switch yet.</div>
  </div>`;
}

function Menus({ map, rom, isSelected, selection }) {
  const id = map.id;
  const count = isSelected && selection ? selection.cells.length / 2 : 0;
  // The Edit menu works on the selected cells, which are in the selected map: in another map's
  // window there is nothing for it to work on until a cell there is clicked.
  const ready = isSelected && rom.canEditCells && count > 0;
  const canPutBack = isSelected && !!selection && !!selection.detail && selection.detail.canPutBack;
  const step = (size, up) => () => send('rom.step', { size, up });
  const table = [
    { label: 'Show as a Table', disabled: !map.surface, onClick: () => send('rom.surface', { map: id, on: false }) },
    { label: 'Show in 3D', disabled: map.surface || !map.canShowSurface, onClick: () => send('rom.surface', { map: id, on: true }) },
    { divider: true },
    { label: 'Put This Map Back as Opened', disabled: !!rom.compare || !map.isChanged, onClick: () => send('rom.putBackMap', { map: id }) },
    { divider: true },
    { label: 'Close', onClick: () => send('rom.closeMap', { map: id }) },
  ];
  const edit = [
    { label: rom.undo.label ? `Undo ${rom.undo.label}` : 'Undo', disabled: !rom.undo.can, onClick: () => send('rom.undo') },
    { label: rom.redo.label ? `Redo ${rom.redo.label}` : 'Redo', disabled: !rom.redo.can, onClick: () => send('rom.redo') },
    { divider: true },
    { label: 'Select All Cells', onClick: () => { send('rom.selectAll', { map: id }); focusWorkspace(); } },
    { label: 'Copy the Selected Cells', disabled: count === 0, onClick: () => send('rom.copy') },
    { divider: true },
    { label: 'Raise by the Fine Step', disabled: !ready, onClick: step('fine', true) },
    { label: 'Lower by the Fine Step', disabled: !ready, onClick: step('fine', false) },
    { label: 'Raise by the Coarse Step', disabled: !ready, onClick: step('coarse', true) },
    { label: 'Lower by the Coarse Step', disabled: !ready, onClick: step('coarse', false) },
    { label: 'Set to the Value', disabled: !ready, onClick: () => send('rom.set') },
    { label: 'Multiply by the Value', disabled: !ready, onClick: () => send('rom.multiply') },
    { divider: true },
    { label: 'Put the Selected Cells Back as Opened', disabled: !canPutBack, onClick: () => send('rom.putBack') },
  ];
  const view = rom.compare
    ? compareShows.map(option => ({ label: option.label, checked: map.compareShows === option.value, onClick: () => send('rom.showCompared', { map: id, shows: option.value }) }))
    : [...shows.map(option => ({ label: option.label, checked: map.shows === option.value, onClick: () => send('rom.show', { map: id, shows: option.value }) })),
       { divider: true },
       { label: rom.showsChanges ? 'Hide the Changes Panel' : 'Show the Changes Panel', onClick: () => send('rom.showChanges', { on: !rom.showsChanges }) }];
  return html`<span class="rom-menus">
    <${MenuButton} kind="plain" class="rom-menu" items=${table}>Table<//>
    <${MenuButton} kind="plain" class="rom-menu" items=${edit}>Edit<//>
    <${MenuButton} kind="plain" class="rom-menu" items=${view}>View<//>
  </span>`;
}

/**
 * The title bar is one row where there is room for it. Next to the Changes panel, or in a narrow
 * window, the switches go on a row of their own, so that nothing in it is cut short.
 */
function TitleBar({ map, rom, isSelected, selection }) {
  const bar = useRef(null);
  const items = useRef(null);
  const switches = useRef(null);
  const [stacked, setStacked] = useState(false);
  const measure = () => {
    if (!bar.current || !items.current) return;
    const style = getComputedStyle(bar.current);
    const room = bar.current.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    // What one row needs: the title and what stands next to it at their full width, the switches and the close button.
    let needed = 10 * (items.current.children.length - 1) + 10 + 22;
    for (const child of items.current.children) needed += child.scrollWidth;
    const wide = switches.current ? switches.current.offsetWidth : 0;
    setStacked(wide > 0 && needed + 8 + wide + 10 > room);
  };
  useLayoutEffect(measure);
  useLayoutEffect(() => {
    // A second row makes the bar taller: measured in the next frame, not in the middle of this one's layout.
    const observer = new ResizeObserver(() => requestAnimationFrame(measure));
    observer.observe(bar.current);
    return () => observer.disconnect();
  }, []);

  // Table or 3D, and what the cells of the table show.
  const choices = map.table && html`<span ref=${switches} class="rom-switches">
    ${map.canShowSurface && html`<${Segments} title="Show this map as a table or in 3D" value=${map.surface}
      options=${[{ value: false, label: 'Table' }, { value: true, label: '3D' }]} onChange=${on => send('rom.surface', { map: map.id, on })} />`}
    ${!map.surface && (rom.compare
      ? html`<${Segments} options=${compareShows} value=${map.compareShows} onChange=${value => send('rom.showCompared', { map: map.id, shows: value })} />`
      : html`<${Segments} options=${shows} value=${map.shows} onChange=${value => send('rom.show', { map: map.id, shows: value })} />`)}
  </span>`;
  const close = html`<button class="rom-close" title=${'Close ' + map.title} aria-label=${'Close ' + map.title}
    onClick=${() => send('rom.closeMap', { map: map.id })}><${Icon} name="x" /></button>`;
  // A click on the bar itself selects the map. One on a button or in a menu is that button's own.
  const select = event => { if (!event.target.closest('button, .popover-layer')) send('rom.selectMap', { map: map.id }); };
  return html`<div ref=${bar} class="rom-titlebar" onClick=${select}>
    <div class="rom-title-row">
      <div ref=${items} class="rom-title-items">
        <span class="rom-title" title=${map.table ? map.table.description : map.toggle ? map.toggle.description : undefined}>${map.title}</span>
        ${map.table && map.table.badge && html`<${Badge} text=${map.table.badge} compare=${!!rom.compare} />`}
        ${map.table && map.table.readOnly && html`<span class="rom-readonly"
          title="This map's definition has no way back from a value to bytes, so its cells cannot be changed."><${Icon} name="lock" />read-only</span>`}
        ${map.table && html`<${Menus} map=${map} rom=${rom} isSelected=${isSelected} selection=${selection} />`}
      </div>
      <span class="spacer"></span>
      ${!stacked && choices}
      ${close}
    </div>
    ${stacked && html`<div class="rom-title-row end">${choices}</div>`}
  </div>`;
}

/**
 * One open map. `map` is the app's `ROMMapWindow` and `rom` the slice `rom`; `selection` is the
 * slice `rom.selection` when this is the selected map, and `angles` this map's `ROMAngles`.
 * `typed` is the number being typed into the selected cells.
 */
export function MapWindow({ map, rom, isSelected, selection, angles, typed, onCell }) {
  return html`<section class=${cls('rom-window', { selected: isSelected })} data-map=${map.id} aria-label=${map.title}>
    <${TitleBar} map=${map} rom=${rom} isSelected=${isSelected} selection=${selection} />
    ${map.table ? (map.surface
        ? html`<${Surface} map=${map} rom=${rom} angles=${angles} selection=${isSelected && selection ? selection.cells : none}
            detail=${isSelected && selection ? selection.detail : undefined} onCell=${onCell} />`
        : html`<${Table} map=${map} rom=${rom} isSelected=${isSelected} selection=${selection} typed=${typed} onCell=${onCell} />`)
      : map.toggle ? html`<${Switch} toggle=${map.toggle} />`
      : html`<${Label} icon="triangle-alert" class="rom-map-error">${map.error}<//>`}
  </section>`;
}
