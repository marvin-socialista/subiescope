// The charts of the log viewer: one chart per value under each other on one time axis, the layer
// over them with the playhead and the pointer, and the small chart of the whole log underneath.
//
// The numbers of a log come from the app once (the event 'logs.data') and are drawn here on
// canvases, thinned out to the pixels there are, so a long log stays smooth. What the charts show
// (which values, which stretch of time, where the playhead is) is the app's, in the slices
// 'logs.view' and 'logs.cursor'.
import { useEffect, useMemo, useRef, useState } from '../../vendor/preact-htm.js';
import { onEvent, send, useSlice } from '../bridge.js';
import { html, Menu } from '../ui.js';

// The plot of every chart starts and ends at the same place, so one line marks one moment in all of them.
const inset = { left: 60, right: 14 };

/** Where a moment is across the charts, as a CSS length. `part` runs from 0 (left) to 1 (right). */
function across(part) {
  return `calc(${inset.left}px + (100% - ${inset.left + inset.right}px) * ${part})`;
}

// MARK: The numbers of the open log

let held = null;
const waiting = new Set();

function floats(numbers) {
  const out = new Float64Array(numbers.length);
  for (let i = 0; i < numbers.length; i++) out[i] = numbers[i] === null ? NaN : numbers[i];
  return out;
}

onEvent('logs.data', data => {
  held = { id: data.id, time: floats(data.time), values: data.values.map(floats) };
  waiting.forEach(listener => listener(held));
});

/**
 * The numbers of the log with this id: { time, values }, where `time` is the seconds of every row
 * and `values[column][row]` its values (NaN for an empty cell). Null until the app has sent them.
 */
export function useLogData(id) {
  const [data, setData] = useState(held && held.id === id ? held : null);
  useEffect(() => {
    if (id === undefined || id === null) return undefined;
    if (held && held.id === id) { setData(held); return undefined; }
    // Another log than the one in hand: that one can go.
    held = null;
    setData(null);
    const listener = fresh => { if (fresh.id === id) setData(fresh); };
    waiting.add(listener);
    send('logs.load', { id });
    return () => waiting.delete(listener);
  }, [id]);
  return data && data.id === id ? data : null;
}

/** The last row at or before `t` seconds. */
function rowAt(time, t) {
  let low = 0, high = time.length - 1;
  if (high < 0 || t <= time[0]) return 0;
  if (t >= time[high]) return high;
  while (low < high) {
    const middle = (low + high + 1) >> 1;
    if (time[middle] <= t) low = middle; else high = middle - 1;
  }
  return low;
}

/** The scale of a chart: what the value does between `from` and `to`, with some air above and below. */
function scaleOf(log, column, from, to) {
  const series = log && log.values[column];
  if (!series || log.time.length === 0) return [0, 1];
  const first = rowAt(log.time, from), last = Math.min(log.time.length - 1, rowAt(log.time, to) + 1);
  let low = Infinity, high = -Infinity;
  for (let i = first; i <= last; i++) {
    const value = series[i];
    if (value !== value) continue;
    if (value < low) low = value;
    if (value > high) high = value;
  }
  if (low === Infinity) return [0, 1];
  const air = high - low < 1e-9 ? Math.max(Math.abs(low) * 0.1, 1) : (high - low) * 0.08;
  return [low - air, high + air];
}

// MARK: Drawing

/**
 * A canvas that fills its box. `draw(context, width, height, style)` paints it, in CSS pixels;
 * `style` is the canvas's computed style, for the colours. It is painted again when its size, the
 * colour scheme or anything in `changes` changes.
 */
function Canvas({ draw, changes }) {
  const canvas = useRef(null);
  const latest = useRef(draw);
  const paint = useRef(null);
  latest.current = draw;
  useEffect(() => {
    const element = canvas.current;
    paint.current = () => {
      const scale = window.devicePixelRatio || 1;
      const width = element.clientWidth, height = element.clientHeight;
      const pixelsWide = Math.round(width * scale), pixelsHigh = Math.round(height * scale);
      if (element.width !== pixelsWide || element.height !== pixelsHigh) {
        element.width = pixelsWide;
        element.height = pixelsHigh;
      }
      const context = element.getContext('2d');
      context.setTransform(scale, 0, 0, scale, 0, 0);
      context.clearRect(0, 0, width, height);
      latest.current(context, width, height, getComputedStyle(element));
    };
    const repaint = () => paint.current();
    const observer = new ResizeObserver(repaint);
    observer.observe(element);
    const scheme = window.matchMedia('(prefers-color-scheme: dark)');
    scheme.addEventListener('change', repaint);
    return () => { observer.disconnect(); scheme.removeEventListener('change', repaint); };
  }, []);
  useEffect(() => { if (paint.current) paint.current(); }, changes);
  return html`<canvas ref=${canvas}></canvas>`;
}

/**
 * One value as a line between `from` and `to` seconds, on a quiet grid: three lines with their
 * numbers, and a line at every mark of the time axis. `scale` is [lowest, highest] of the plot.
 */
function drawSeries(context, width, height, style, { log, column, from, to, scale, colour, alpha = 1, decimals, ticks }) {
  const plot = { x: inset.left, y: 4, width: width - inset.left - inset.right, height: height - 10 };
  const series = log && log.values[column];
  if (!(plot.width > 10 && plot.height > 10) || !series || log.time.length === 0 || !(to > from)) return;
  const time = log.time;
  const span = to - from, reach = scale[1] - scale[0];
  const x = t => plot.x + (t - from) / span * plot.width;
  const y = value => plot.y + plot.height - (value - scale[0]) / reach * plot.height;

  const secondary = style.getPropertyValue('--text-2').trim();
  context.lineWidth = 1;
  context.strokeStyle = secondary;
  context.fillStyle = secondary;
  context.font = `9px ${style.fontFamily}`;
  context.textAlign = 'right';
  context.textBaseline = 'middle';
  for (let i = 0; i <= 2; i++) {
    const value = scale[0] + reach * (0.1 + 0.4 * i);
    const at = Math.round(y(value)) + 0.5;
    context.globalAlpha = 0.15;
    context.beginPath();
    context.moveTo(plot.x, at);
    context.lineTo(plot.x + plot.width, at);
    context.stroke();
    context.globalAlpha = 1;
    context.fillText(value.toFixed(Math.min(decimals, 3)), plot.x - 6, at);
  }
  context.globalAlpha = 0.09;
  for (const tick of ticks) {
    if (tick < from - 1e-9 || tick > to + 1e-9) continue;
    const at = Math.round(x(tick)) + 0.5;
    context.beginPath();
    context.moveTo(at, plot.y);
    context.lineTo(at, plot.y + plot.height);
    context.stroke();
  }
  context.globalAlpha = 1;

  // The line. With more rows than pixels, every pixel column gets its lowest and its highest value,
  // in the order they came: a long log stays fast, and a spike stays in sight.
  const first = Math.max(0, rowAt(time, from) - 1);
  const last = Math.min(time.length - 1, rowAt(time, to) + 1);
  if (first > last) return;
  const columns = Math.max(1, Math.floor(plot.width));
  context.save();
  context.beginPath();
  context.rect(plot.x, plot.y - 2, plot.width, plot.height + 4);
  context.clip();
  context.beginPath();
  let penDown = false;
  const point = (t, value) => {
    if (value !== value) { penDown = false; return; }
    if (penDown) context.lineTo(x(t), y(value)); else { context.moveTo(x(t), y(value)); penDown = true; }
  };
  if (last - first + 1 <= columns * 2) {
    for (let i = first; i <= last; i++) point(time[i], series[i]);
  } else {
    let bucket = -1, has = false, lowest = 0, highest = 0, lowestAt = 0, highestAt = 0;
    const flush = () => {
      if (!has) return;
      if (lowestAt <= highestAt) { point(lowestAt, lowest); point(highestAt, highest); } else { point(highestAt, highest); point(lowestAt, lowest); }
    };
    for (let i = first; i <= last; i++) {
      const t = time[i], value = series[i];
      const here = Math.trunc((t - from) / span * columns);
      if (here !== bucket) { flush(); bucket = here; has = false; }
      if (value !== value) continue;
      if (!has) { lowest = value; highest = value; lowestAt = t; highestAt = t; has = true; }
      if (value < lowest) { lowest = value; lowestAt = t; }
      if (value > highest) { highest = value; highestAt = t; }
    }
    flush();
  }
  context.lineWidth = 2;
  context.lineCap = 'round';
  context.lineJoin = 'round';
  context.strokeStyle = colour;
  context.globalAlpha = alpha;
  context.stroke();
  context.restore();
}

// MARK: The charts

/** One value: its name and the value at the pointer above, its line below. */
function SeriesChart({ chart, info, data, view, ticks, moment, value }) {
  const { from, to } = view;
  const scale = useMemo(() => scaleOf(data, chart.column, from, to), [data, chart.column, from, to]);
  const colour = `var(--series-${chart.color % 8})`;
  const draw = (context, width, height, style) => drawSeries(context, width, height, style, {
    log: data, column: chart.column, from, to, scale, ticks, decimals: info.decimals,
    colour: style.getPropertyValue(`--series-${chart.color % 8}`).trim(),
  });
  // The dot on the line at the moment the values are of.
  let dot = null;
  const series = data && data.values[chart.column];
  if (series && data.time.length > 0 && moment >= from && moment <= to && to > from) {
    const now = series[rowAt(data.time, moment)];
    if (now === now) dot = { left: across((moment - from) / (to - from)), top: `calc(4px + (100% - 10px) * ${1 - (now - scale[0]) / (scale[1] - scale[0])})` };
  }
  return html`<div class="logs-chart">
    <div class="logs-chart-head">
      <span class="logs-swatch" style=${{ background: colour }}></span>
      <span class="logs-chart-name truncate">${info.name}</span>
      <span class="caption secondary truncate">${info.units}</span>
      <span class="spacer"></span>
      <span class="logs-chart-value digits">${value}</span>
    </div>
    <div class="logs-plot">
      <${Canvas} draw=${draw} changes=${[data, chart.column, chart.color, from, to, scale, ticks, info.decimals]} />
      ${dot && html`<div class="logs-dot-on-line" style=${{ left: dot.left, top: dot.top, background: colour }}></div>`}
    </div>
  </div>`;
}

/**
 * The charts under each other, the time axis, and over all of it the layer with the playhead and
 * the pointer: hover to inspect, click to move the playhead, drag to zoom in, double-click to zoom out.
 */
export function ChartStack({ viewer, view, data }) {
  const cursor = useSlice('logs.cursor');
  const layer = useRef(null);
  const dragging = useRef(null);
  const told = useRef({ frame: 0, time: null, last: null });
  const now = useRef(view);
  now.current = view;
  const [hover, setHover] = useState(null);
  const [selection, setSelection] = useState(null);
  const [menu, setMenu] = useState(null);
  const ticks = useMemo(() => view.ticks.map(tick => tick.time), [view.ticks]);
  // A chart of a column this log does not have: the pieces of a newly opened log come one by one.
  const charts = view.charts.filter(chart => viewer.columns[chart.column]);
  const span = view.to - view.from;

  /** The moment at `x` pixels from the left of the layer. */
  const momentAt = x => {
    const range = now.current;
    const width = layer.current.clientWidth - inset.left - inset.right;
    return range.from + Math.min(Math.max(0, (x - inset.left) / Math.max(width, 1)), 1) * (range.to - range.from);
  };
  // The app shows the values at the pointer, so it hears where the pointer is: once per frame at most.
  const point = time => {
    setHover(time);
    told.current.time = time;
    if (told.current.frame) return;
    told.current.frame = requestAnimationFrame(() => {
      told.current.frame = 0;
      if (told.current.time === told.current.last) return;
      told.current.last = told.current.time;
      send('logs.hover', { time: told.current.time });
    });
  };
  // The pointer is over no chart before these charts are there, and after they are gone.
  useEffect(() => {
    send('logs.hover', { time: null });
    return () => {
      cancelAnimationFrame(told.current.frame);
      if (told.current.last !== null) send('logs.hover', { time: null });
    };
  }, []);

  // Ctrl with the wheel, which is also what a pinch on a touchpad is, zooms around the pointer.
  useEffect(() => {
    const element = layer.current;
    let factor = 1, anchor = 0, frame = 0;
    const wheel = event => {
      if (!event.ctrlKey) return;
      event.preventDefault();
      factor *= Math.exp(event.deltaY * 0.01);
      anchor = momentAt(event.clientX - element.getBoundingClientRect().left);
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        send('logs.zoomBy', { factor, anchor });
        factor = 1;
      });
    };
    element.addEventListener('wheel', wheel, { passive: false });
    return () => { element.removeEventListener('wheel', wheel); cancelAnimationFrame(frame); };
  }, []);

  const place = event => event.clientX - layer.current.getBoundingClientRect().left;
  const down = event => {
    if (event.button !== 0) return;
    layer.current.setPointerCapture(event.pointerId);
    dragging.current = { from: place(event) };
  };
  const move = event => {
    const x = place(event);
    if (dragging.current) {
      setSelection({ from: dragging.current.from, to: x });
      point(momentAt(x));
    } else {
      point(x >= inset.left && x <= layer.current.clientWidth - inset.right ? momentAt(x) : null);
    }
  };
  const up = event => {
    const drag = dragging.current;
    if (!drag) return;
    dragging.current = null;
    setSelection(null);
    const x = place(event);
    if (Math.abs(x - drag.from) <= 3) send('playback.seek', { time: momentAt(x) });
    else send('logs.zoom', { from: momentAt(Math.min(drag.from, x)), to: momentAt(Math.max(drag.from, x)) });
  };
  const leave = () => { if (!dragging.current) point(null); };
  const cancel = () => { dragging.current = null; setSelection(null); };
  // A right click is about the chart under it.
  const context = event => {
    event.preventDefault();
    const box = layer.current.getBoundingClientRect();
    const index = Math.floor((event.clientY - box.top) / ((box.height - 22) / Math.max(charts.length, 1)));
    if (charts[index]) setMenu({ column: charts[index].column, at: { x: event.clientX, y: event.clientY } });
  };

  const playhead = cursor ? cursor.playhead : 0;
  const moment = hover !== null ? hover : playhead;
  const part = time => (time - view.from) / span;
  return html`<div class="logs-stack-scroll">
    <div class="logs-stack">
      ${charts.map(chart => html`<${SeriesChart} key=${chart.column} chart=${chart} info=${viewer.columns[chart.column]} data=${data}
        view=${view} ticks=${ticks} moment=${moment} value=${(cursor && cursor.values[chart.column]) || '–'} />`)}
      <div class="logs-axis">
        ${span > 0 && view.ticks.map(tick => html`<span key=${tick.time} style=${{ left: across(part(tick.time)) }}>${tick.label}</span>`)}
      </div>
      <div ref=${layer} class="logs-cursor-layer" title="Hover to inspect · click to move the playhead · drag to zoom in · double-click to zoom out"
          onPointerDown=${down} onPointerMove=${move} onPointerUp=${up} onPointerLeave=${leave} onPointerCancel=${cancel}
          onDblClick=${() => send('logs.resetZoom')} onContextMenu=${context}>
        ${selection && Math.abs(selection.to - selection.from) > 3 && html`<div class="logs-selection"
          style=${{ left: Math.min(selection.from, selection.to) + 'px', width: Math.abs(selection.to - selection.from) + 'px' }}></div>`}
        ${span > 0 && playhead >= view.from && playhead <= view.to && html`<div class="logs-playhead" style=${{ left: across(part(playhead)) }}></div>`}
        ${hover !== null && span > 0 && html`<div class="logs-hover-line" style=${{ left: across(part(hover)) }}></div>`}
        ${hover !== null && span > 0 && cursor && cursor.hovering && html`<div class="logs-hover-time digits"
          style=${{ left: `min(calc(${across(part(hover))} + 6px), calc(100% - 70px))` }}>${cursor.snapshotTime}</div>`}
      </div>
    </div>
    ${menu && html`<${Menu} anchor=${menu.at} onClose=${() => setMenu(null)} items=${[
      { label: 'Move Up', onClick: () => send('logs.moveChart', { column: menu.column, up: true }) },
      { label: 'Move Down', onClick: () => send('logs.moveChart', { column: menu.column, up: false }) },
      { label: 'Remove Chart', onClick: () => send('logs.toggleChart', { column: menu.column }) },
    ]} />`}
  </div>`;
}

/** The whole log in small, with the stretch that is zoomed in on and the playhead. Drag to move through it. */
export function OverviewStrip({ viewer, view, data }) {
  const cursor = useSlice('logs.cursor');
  const strip = useRef(null);
  const dragging = useRef(false);
  const told = useRef({ frame: 0, time: 0 });
  const duration = Math.max(viewer.duration, 0.001);
  const first = view.charts.find(chart => viewer.columns[chart.column]);
  const column = first ? first.column : null;
  const scale = useMemo(() => (column === null ? [0, 1] : scaleOf(data, column, 0, duration)), [data, column, duration]);
  const draw = (context, width, height, style) => {
    if (column === null) return;
    drawSeries(context, width, height, style, {
      log: data, column, from: 0, to: duration, scale, ticks: viewer.overviewTicks, decimals: 0,
      colour: style.getPropertyValue('--text-2').trim(), alpha: 0.7,
    });
  };
  useEffect(() => () => cancelAnimationFrame(told.current.frame), []);

  const scrub = event => {
    const box = strip.current.getBoundingClientRect();
    const width = box.width - inset.left - inset.right;
    told.current.time = Math.min(Math.max(0, (event.clientX - box.left - inset.left) / Math.max(width, 1)), 1) * duration;
    if (told.current.frame) return;
    told.current.frame = requestAnimationFrame(() => {
      told.current.frame = 0;
      send('logs.scrub', { time: told.current.time });
    });
  };
  const down = event => {
    if (event.button !== 0) return;
    strip.current.setPointerCapture(event.pointerId);
    dragging.current = true;
    scrub(event);
  };
  const part = time => time / duration;
  return html`<div ref=${strip} class="logs-overview" title="Whole log. Drag to move through it."
      onPointerDown=${down} onPointerMove=${event => { if (dragging.current) scrub(event); }}
      onPointerUp=${() => { dragging.current = false; }} onPointerCancel=${() => { dragging.current = false; }}>
    <${Canvas} draw=${draw} changes=${[data, column, duration, scale, viewer.overviewTicks]} />
    ${view.zoomed && html`<div class="logs-window" style=${{ left: across(part(view.from)), width: `max(2px, calc((100% - ${inset.left + inset.right}px) * ${part(view.to - view.from)}))` }}></div>`}
    <div class="logs-playhead" style=${{ left: across(part(cursor ? cursor.playhead : 0)) }}></div>
  </div>`;
}
