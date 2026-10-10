// The 3D view of a map: every cell a tile in its heat colour, floating at the height of its value,
// so the shape of the map shows. It is the Mac's drawing (Views/ROMSurfaceView.swift) with the same
// numbers: the map lies on a plane, as a table does, with the columns along x, the rows along y and
// the labels along its top and left. The plane is turned about its middle and tilted away from the
// viewer, and looked at from far away, so a tile stays a parallelogram and its number lies flat on it.
import { useEffect, useLayoutEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { send } from '../bridge.js';
import { html } from '../ui.js';
import { RomButton, CellNumbers, focusWorkspace } from './rom-ui.js';

const tileWidth = 44;
const tileHeight = 24;
const gap = 2;
// The room the row labels and the column labels take on the plane.
const labelColumn = 40;
const labelRow = 16;
// How far the highest value is lifted for each step of the Height slider.
const liftPerStep = 24;
// Where the names of the axes lie on the plane: the columns' above it, the rows' to its left.
const columnTitleY = -50;
const rowTitleX = -70;
// About how wide one letter of an axis name is, for making room for it.
const titleCharacterWidth = 8.4;
const canvasHeight = 560;

// The colours of a cell's ring and of the selection, which are the same in the light and the dark look.
const cellText = '#0d0e10';
const selectionRing = '#5499ff';
const rings = { raised: '#b3001b', lowered: '#0b3fc4', different: '#6b21a8' };

function planeSize(table) {
  return { width: labelColumn + table.columns * (tileWidth + gap) - gap, height: labelRow + table.rows * (tileHeight + gap) - gap };
}

function tileRect(row, column) {
  return { x: labelColumn + column * (tileWidth + gap), y: labelRow + row * (tileHeight + gap), width: tileWidth, height: tileHeight };
}

function inset(rect, by) {
  return { x: rect.x + by, y: rect.y + by, width: rect.width - 2 * by, height: rect.height - 2 * by };
}

/** From a point on the plane, `height` above it, to the screen: x' = a x + c y + tx, y' = b x + d y + ty. */
function transformOf(scene, height) {
  const middleX = scene.plane.width / 2, middleY = scene.plane.height / 2;
  const cosTurn = Math.cos(scene.turn), sinTurn = Math.sin(scene.turn), cosTilt = Math.cos(scene.tilt), sinTilt = Math.sin(scene.tilt);
  const scale = scene.scale;
  return {
    a: scale * cosTurn, b: scale * sinTurn * cosTilt,
    c: -scale * sinTurn, d: scale * cosTurn * cosTilt,
    tx: scene.originX - scale * (middleX * cosTurn - middleY * sinTurn),
    ty: scene.originY - scale * ((middleX * sinTurn + middleY * cosTurn) * cosTilt + height * sinTilt),
  };
}

function heightOf(scene, row, column) {
  return (scene.table.cells[row][column].place || 0) * scene.lift;
}

/** Fits the whole scene, with its axis titles and its highest tile, into a canvas of `width` by `height`. */
function makeScene(table, angles, width, height) {
  const plane = planeSize(table);
  const scene = {
    table, plane, turn: angles.turn * Math.PI / 180, tilt: angles.tilt * Math.PI / 180, lift: angles.height * liftPerStep,
    scale: 1, originX: 0, originY: 0,
    // The plane with a margin around it, which is drawn as the floor under the tiles.
    floor: { x: -44, y: -30, width: plane.width + 58, height: plane.height + 44 },
  };
  // The room on the screen that is drawn in: the floor, the names of the axes on it, and each tile
  // where it floats. The scene is made as large as fits.
  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
  const add = (rect, lifted) => {
    const m = transformOf(scene, lifted);
    for (const [x, y] of [[rect.x, rect.y], [rect.x + rect.width, rect.y], [rect.x, rect.y + rect.height], [rect.x + rect.width, rect.y + rect.height]]) {
      const screenX = m.a * x + m.c * y + m.tx, screenY = m.b * x + m.d * y + m.ty;
      left = Math.min(left, screenX); right = Math.max(right, screenX);
      top = Math.min(top, screenY); bottom = Math.max(bottom, screenY);
    }
  };
  add(scene.floor, 0);
  if (table.columnTitle) {
    const length = table.columnTitle.length * titleCharacterWidth;
    add({ x: plane.width / 2 - length / 2, y: columnTitleY - 11, width: length, height: 22 }, 0);
  }
  if (table.rowTitle) {
    const length = table.rowTitle.length * titleCharacterWidth;
    add({ x: rowTitleX - 11, y: plane.height / 2 - length / 2, width: 22, height: length }, 0);
  }
  for (let row = 0; row < table.rows; row++) {
    for (let column = 0; column < table.columns; column++) add(inset(tileRect(row, column), -4), heightOf(scene, row, column));
  }
  const fit = Math.min((width - 28) / Math.max(right - left, 1), (height - 28) / Math.max(bottom - top, 1));
  scene.scale = Math.max(Math.min(fit, 1.7), 0.05);
  scene.originX = width / 2 - (left + right) / 2 * scene.scale;
  scene.originY = height / 2 - (top + bottom) / 2 * scene.scale;
  return scene;
}

/** The tiles from the back to the front, so a tile that is nearer is drawn over one behind it. */
function tilesBackToFront(scene) {
  const tiles = [];
  const middleX = scene.plane.width / 2, middleY = scene.plane.height / 2;
  for (let row = 0; row < scene.table.rows; row++) {
    for (let column = 0; column < scene.table.columns; column++) {
      const rect = tileRect(row, column);
      // How far down the turned plane the tile is: the bottom of the plane is the near side.
      const depth = (rect.x + rect.width / 2 - middleX) * Math.sin(scene.turn) + (rect.y + rect.height / 2 - middleY) * Math.cos(scene.turn);
      tiles.push({ row, column, depth, height: heightOf(scene, row, column) });
    }
  }
  return tiles.sort((one, other) => one.depth - other.depth || one.height - other.height);
}

/** The tile under a point of the canvas: the nearest one, when tiles overlap there. */
function tileAt(scene, x, y) {
  const tiles = tilesBackToFront(scene);
  for (let i = tiles.length - 1; i >= 0; i--) {
    const tile = tiles[i];
    const m = transformOf(scene, tile.height);
    const size = m.a * m.d - m.b * m.c;
    const planeX = (m.d * (x - m.tx) - m.c * (y - m.ty)) / size, planeY = (m.a * (y - m.ty) - m.b * (x - m.tx)) / size;
    const rect = tileRect(tile.row, tile.column);
    if (planeX >= rect.x && planeX < rect.x + rect.width && planeY >= rect.y && planeY < rect.y + rect.height) return tile;
  }
  return null;
}

function strokeRect(context, rect, colour, lineWidth) {
  context.strokeStyle = colour;
  context.lineWidth = lineWidth;
  context.strokeRect(rect.x, rect.y, rect.width, rect.height);
}

/**
 * The ring of a marked cell, as the table draws it: two pixels in its colour just inside the tile,
 * two of white just outside it, and a triangle in the corner that points up for raised and down for lowered.
 */
function drawMark(context, mark, rect) {
  strokeRect(context, inset(rect, -1), '#fff', 2);
  strokeRect(context, inset(rect, 1), rings[mark], 2);
  if (mark !== 'raised' && mark !== 'lowered') return;
  const right = rect.x + rect.width - 3;
  context.beginPath();
  if (mark === 'raised') {
    context.moveTo(right - 8, rect.y + 8);
    context.lineTo(right, rect.y + 8);
    context.lineTo(right - 4, rect.y + 2);
  } else {
    const bottom = rect.y + rect.height;
    context.moveTo(right - 8, bottom - 8);
    context.lineTo(right, bottom - 8);
    context.lineTo(right - 4, bottom - 2);
  }
  context.closePath();
  context.fillStyle = rings[mark];
  context.fill();
}

/** Draws the scene. `look`: { numbers, selected (a Set of row * columns + column), dark, ratio, titleColour, mono, sans }. */
function draw(context, scene, look) {
  const table = scene.table, plane = scene.plane;
  const ink = look.dark ? '255, 255, 255' : '0, 0, 0';
  const on = (height, body) => {
    const m = transformOf(scene, height);
    context.save();
    context.transform(m.a, m.b, m.c, m.d, m.tx, m.ty);
    body();
    context.restore();
  };
  context.textBaseline = 'middle';

  // The floor, with the labels and the names of the axes lying on it.
  on(0, () => {
    context.fillStyle = `rgba(${ink}, ${look.dark ? 0.05 : 0.04})`;
    context.fillRect(scene.floor.x, scene.floor.y, scene.floor.width, scene.floor.height);
    strokeRect(context, scene.floor, `rgba(${ink}, 0.25)`, 1);
    context.font = `700 10px ${look.mono}`;
    context.fillStyle = `rgba(${ink}, 0.8)`;
    context.textAlign = 'center';
    (table.columnLabels || []).forEach((label, column) => context.fillText(label, tileRect(0, column).x + tileWidth / 2, labelRow / 2));
    context.textAlign = 'right';
    (table.rowLabels || []).forEach((label, row) => context.fillText(label, labelColumn - 6, tileRect(row, 0).y + tileHeight / 2));
    context.font = `700 15px ${look.sans}`;
    context.fillStyle = look.titleColour;
    context.textAlign = 'center';
    if (table.columnTitle) context.fillText(table.columnTitle, plane.width / 2, columnTitleY);
    if (table.rowTitle) {
      context.save();
      context.translate(rowTitleX, plane.height / 2);
      // Along the rows, and the way round that reads from the left on the screen: turned to the
      // left the plane's own left side faces down, and the name would stand on its head.
      context.rotate((scene.turn < 0 ? 90 : -90) * Math.PI / 180);
      context.fillText(table.rowTitle, 0, 0);
      context.restore();
    }
  });

  // The tiles, the far ones first.
  context.textAlign = 'center';
  for (const tile of tilesBackToFront(scene)) {
    const cell = table.cells[tile.row][tile.column];
    const rect = tileRect(tile.row, tile.column);
    on(tile.height, () => {
      if (cell.color) {
        context.fillStyle = cell.color;
        context.fillRect(rect.x, rect.y, rect.width, rect.height);
      }
      strokeRect(context, rect, 'rgba(0, 0, 0, 0.3)', 0.6);
      if (cell.mark) drawMark(context, cell.mark, rect);
      if (look.selected.has(tile.row * table.columns + tile.column)) {
        strokeRect(context, inset(rect, -1), '#fff', 2);
        strokeRect(context, inset(rect, -3), selectionRing, 2);
      }
      if (look.numbers) {
        context.font = `700 10px ${look.mono}`;
        context.fillStyle = cellText;
        context.fillText(cell.text, rect.x + rect.width / 2, rect.y + rect.height / 2);
      }
    });
  }
}

/** True while the window is in its dark look. */
function useDark() {
  const query = window.matchMedia('(prefers-color-scheme: dark)');
  const [dark, setDark] = useState(query.matches);
  useEffect(() => {
    const changed = () => setDark(query.matches);
    query.addEventListener('change', changed);
    return () => query.removeEventListener('change', changed);
  }, []);
  return dark;
}

function clamp(value, [low, high]) {
  return Math.min(Math.max(value, low), high);
}

/**
 * The 3D view of one open map, with its sliders above it and the selected cell under it. It turns
 * and tilts with the sliders and by dragging, and a click on a tile selects that cell.
 *
 * `map` is the app's `ROMMapWindow`, `angles` its `ROMAngles`, `rom` the slice `rom`. `selection`
 * is the selected cells of this map ([row, column, …], empty for a map that is not the selected
 * one) and `detail` what the app says of the cell the selection ends on.
 *
 * While it is being turned the view follows the pointer by itself, and the app hears where it ended.
 */
export function Surface({ map, rom, angles, selection, detail, onCell }) {
  const table = map.table;
  const canvas = useRef(null);
  const drag = useRef(null);
  const scene = useRef(null);
  const [width, setWidth] = useState(0);
  // The angles while they are being changed here, until the app says the same.
  const [live, setLive] = useState(null);
  const dark = useDark();
  const shown = live || angles;
  const ranges = rom.surface;

  useLayoutEffect(() => {
    const element = canvas.current;
    setWidth(Math.floor(element.clientWidth));
    const observer = new ResizeObserver(() => setWidth(Math.floor(element.clientWidth)));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => setLive(null), [angles && angles.turn, angles && angles.tilt, angles && angles.height]);

  useLayoutEffect(() => {
    const element = canvas.current;
    if (!element || !shown || width <= 0) return;
    const ratio = window.devicePixelRatio || 1;
    element.width = Math.round(width * ratio);
    element.height = Math.round(canvasHeight * ratio);
    const context = element.getContext('2d');
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, canvasHeight);
    scene.current = makeScene(table, shown, width, canvasHeight);
    const selected = new Set();
    for (let i = 0; i < selection.length; i += 2) selected.add(selection[i] * table.columns + selection[i + 1]);
    const style = getComputedStyle(element);
    draw(context, scene.current, {
      numbers: map.numbers, selected, dark,
      titleColour: style.getPropertyValue('--rom-axis-title-3d').trim(),
      mono: style.getPropertyValue('--font-mono').trim() || 'monospace',
      sans: style.fontFamily,
    });
  }, [table, shown && shown.turn, shown && shown.tilt, shown && shown.height, width, map.numbers, selection, dark]);

  const down = event => {
    if (event.button !== 0 || !shown) return;
    canvas.current.setPointerCapture(event.pointerId);
    drag.current = { x: event.clientX, y: event.clientY, turn: shown.turn, tilt: shown.tilt, height: shown.height, turning: false, now: null };
  };
  const move = event => {
    const start = drag.current;
    if (!start) return;
    const across = event.clientX - start.x, along = event.clientY - start.y;
    // A few pixels of movement are still a click.
    if (!start.turning && Math.abs(across) <= 3 && Math.abs(along) <= 3) return;
    start.turning = true;
    start.now = { turn: clamp(start.turn + across * 0.35, ranges.turn), tilt: clamp(start.tilt - along * 0.25, ranges.tilt), height: start.height };
    setLive(start.now);
  };
  const up = event => {
    const start = drag.current;
    drag.current = null;
    if (!start) return;
    if (start.turning) {
      if (start.now) send('rom.angles', { map: map.id, turn: start.now.turn, tilt: start.now.tilt });
    } else if (scene.current && event.type === 'pointerup') {
      const box = canvas.current.getBoundingClientRect();
      const tile = tileAt(scene.current, event.clientX - box.left, event.clientY - box.top);
      if (tile) onCell(tile.row, tile.column, false);
    }
  };

  const slider = (title, name) => html`<label class="rom-slider">
    <span class="secondary">${title}</span>
    <input type="range" min=${ranges[name][0]} max=${ranges[name][1]} step="any" value=${shown ? shown[name] : ranges[name][0]} aria-label=${title}
      onInput=${event => shown && setLive({ ...shown, [name]: clamp(Number(event.target.value), ranges[name]) })}
      onChange=${event => { send('rom.angles', { map: map.id, [name]: clamp(Number(event.target.value), ranges[name]) }); focusWorkspace(); }} />
  </label>`;

  return html`<div class="rom-surface">
    <div class="rom-surface-controls">
      ${slider('Turn', 'turn')}
      ${slider('Tilt', 'tilt')}
      ${slider('Height', 'height')}
      <label class="checkbox">
        <input type="checkbox" checked=${map.numbers} onChange=${event => { send('rom.numbers', { map: map.id, on: event.target.checked }); focusWorkspace(); }} />
        <span>Numbers on the tiles</span>
      </label>
      <span class="secondary">Drag to turn it. Click a tile to select that cell.</span>
      <${RomButton} kind="quiet" height=${24} onClick=${() => { setLive(null); send('rom.resetView', { map: map.id }); }}>Reset View<//>
    </div>
    <canvas ref=${canvas} class="rom-surface-canvas" style=${{ height: canvasHeight + 'px' }} role="img"
      aria-label=${`${map.title} drawn in 3D, from ${table.lowText} to ${table.highText}`}
      onPointerDown=${down} onPointerMove=${move} onPointerUp=${up} onPointerCancel=${up}></canvas>
    <div class="rom-surface-foot">
      ${selection.length > 0 && detail ? html`<span class="rom-bold">${detail.place}</span><${CellNumbers} detail=${detail} />`
        : html`<span class="secondary">No cell selected</span>`}
      <span class="spacer"></span>
      <span class="rom-scale">
        <span>${table.lowText}</span>
        <span class="rom-heat-bar" style=${{ background: `linear-gradient(to right, ${rom.heatScale.join(', ')})` }}></span>
        <span>${table.highText}</span>
      </span>
    </div>
  </div>`;
}
