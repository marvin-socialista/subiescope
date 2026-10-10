// The dyno's charts: one measure against engine speed, a line for every pull that is shown.
// They are drawn the way Swift Charts draws them in the Mac app (DynoChart in DynoView.swift):
// the value axis on the left with solid lines across, dashed lines up from the rpm axis with the
// number to the right of each, smooth lines through the points, and a dashed rule at the pointer.
import { useLayoutEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { html } from '../ui.js';

// Sizes in pixels, measured from the Mac's charts. The frame is 220 high: the plot takes the top
// 180, the numbers of the rpm axis and the word "rpm" come under it.
const frameHeight = 220;
const plotHeight = 180;
const tickBottom = 194.5;
const rpmNumbersBaseline = 195;
const axisNameBaseline = 216.5;
const labelGap = 4.5;
const labelSize = 11;

/**
 * Round numbers to put marks at: steps of 1, 2, 2.5 or 5 times a power of ten. Of those, the one
 * that gives the count of marks closest to four wins (five rather than three, and the smaller step
 * when two give the same count). This is what Swift Charts chooses by itself.
 * `count(step)` says how many marks a step would give.
 */
function roundStep(size, count) {
  let best = null;
  const power = Math.floor(Math.log10(size)) - 2;
  for (let k = power; k <= power + 3; k++) {
    for (const digits of [1, 2, 2.5, 5]) {
      const step = digits * 10 ** k;
      const marks = count(step);
      const off = Math.abs(marks - 4) - (marks > 4 ? 0.5 : 0);
      if (!best || off < best.off) best = { step, off };
    }
  }
  return best.step;
}

/** The marks of the value axis: from zero in round steps to the first one past the highest value. */
function valueMarks(lowest, highest) {
  if (!(highest > lowest) && !(highest > 0)) return [];
  const top = Math.max(highest, 0), bottom = Math.min(lowest, 0);
  const steps = step => Math.ceil(top / step - 1e-9) - Math.floor(bottom / step + 1e-9);
  const step = roundStep(top - bottom, step => steps(step) + 1);
  const marks = [];
  for (let i = Math.floor(bottom / step + 1e-9); i <= Math.ceil(top / step - 1e-9); i++) marks.push(i * step);
  return marks;
}

/** The marks of the rpm axis: the round numbers between its two ends. */
function rpmMarks(low, high) {
  const inside = step => Math.floor(high / step + 1e-9) - Math.ceil(low / step - 1e-9) + 1;
  const step = roundStep(high - low, inside);
  const marks = [];
  for (let i = Math.ceil(low / step - 1e-9); i * step <= high + 1e-6; i++) marks.push(i * step);
  return marks;
}

/** 3000 as "3,000", with the separators this computer uses. */
function numberText(value, format) {
  const [whole, fraction] = String(Math.abs(Number(value.toFixed(6)))).split('.');
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, format.group);
  return (value < 0 ? '-' : '') + grouped + (fraction ? format.decimal + fraction : '');
}

let ruler = null;

/** How wide a number of an axis is, in pixels. */
function textWidth(text) {
  if (!ruler) ruler = document.createElement('canvas').getContext('2d');
  ruler.font = `${labelSize}px ${getComputedStyle(document.body).fontFamily}`;
  return ruler.measureText(text).width;
}

/**
 * A smooth line through the points ([[x, y], …]): a centripetal Catmull-Rom curve, which is what
 * the Mac's charts use. It passes through every point and does not swing out between them.
 */
function smoothPath(points) {
  if (points.length === 0) return '';
  const number = value => value.toFixed(2);
  let path = `M${number(points[0][0])} ${number(points[0][1])}`;
  for (let i = 0; i < points.length - 1; i++) {
    const before = points[i - 1] || points[i], from = points[i], to = points[i + 1], after = points[i + 2] || to;
    const d01 = Math.hypot(from[0] - before[0], from[1] - before[1]);
    const d12 = Math.hypot(to[0] - from[0], to[1] - from[1]);
    const d23 = Math.hypot(after[0] - to[0], after[1] - to[1]);
    const r01 = Math.sqrt(d01), r12 = Math.sqrt(d12), r23 = Math.sqrt(d23);
    let c1 = from, c2 = to;
    if (r01 > 1e-6) {
      const a = 2 * d01 + 3 * r01 * r12 + d12, n = 3 * r01 * (r01 + r12);
      c1 = [(from[0] * a - before[0] * d12 + to[0] * d01) / n, (from[1] * a - before[1] * d12 + to[1] * d01) / n];
    }
    if (r23 > 1e-6) {
      const b = 2 * d23 + 3 * r23 * r12 + d12, m = 3 * r23 * (r23 + r12);
      c2 = [(to[0] * b + from[0] * d12 - after[0] * d23) / m, (to[1] * b + from[1] * d12 - after[1] * d23) / m];
    }
    path += `C${number(c1[0])} ${number(c1[1])} ${number(c2[0])} ${number(c2[1])} ${number(to[0])} ${number(to[1])}`;
  }
  return path;
}

/**
 * What the pointer is on, as the Mac writes it: "5123 rpm · Pull 1: 181 · Pull 2: 176". A pull
 * says its nearest point, when that is within 150 rpm.
 */
export function readout(chart, rpm) {
  const parts = [];
  for (const series of chart.series) {
    let nearest = -1;
    for (let i = 0; i < series.points.length; i += 2) {
      if (nearest < 0 || Math.abs(series.points[i] - rpm) < Math.abs(series.points[nearest] - rpm)) nearest = i;
    }
    if (nearest >= 0 && Math.abs(series.points[nearest] - rpm) <= 150) parts.push(`${series.name}: ${series.points[nearest + 1].toFixed(0)}`);
  }
  return `${Math.trunc(rpm)} rpm · ` + parts.join(' · ');
}

/**
 * One chart. `chart` is one of the app's `DynoResult.charts`; `format` holds the separators for
 * numbers ({ group, decimal }). `hover` is the engine speed under the pointer, or null, and is
 * shared by the charts: `onHover` is called with a new one.
 */
export function DynoChart({ chart, format, hover, onHover }) {
  const frame = useRef(null);
  const [width, setWidth] = useState(0);
  useLayoutEffect(() => {
    const element = frame.current;
    if (!element) return;
    setWidth(Math.floor(element.clientWidth));
    const observer = new ResizeObserver(() => setWidth(Math.floor(element.clientWidth)));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  let lowest = Infinity, highest = -Infinity;
  for (const series of chart.series) {
    for (let i = 1; i < series.points.length; i += 2) {
      lowest = Math.min(lowest, series.points[i]);
      highest = Math.max(highest, series.points[i]);
    }
  }
  const values = valueMarks(lowest, highest);
  const valueTexts = values.map(value => numberText(value, format));
  // The plot starts to the right of the widest number of the value axis.
  const plotLeft = values.length ? Math.round(Math.max(...valueTexts.map(textWidth)) + labelGap) : 0;
  const plotWidth = Math.max(1, width - plotLeft);
  const bottomValue = values.length ? values[0] : 0, topValue = values.length ? values[values.length - 1] : 1;
  const x = rpm => plotLeft + (rpm - chart.low) / (chart.high - chart.low) * plotWidth;
  // Half a pixel down, so that a line of one pixel at a whole value lands on one row of pixels.
  const y = value => 0.5 + plotHeight - (value - bottomValue) / (topValue - bottomValue) * plotHeight;
  const row = value => Math.round(y(value) - 0.5) + 0.5;
  const rpms = rpmMarks(chart.low, chart.high);

  const move = event => {
    const box = frame.current.getBoundingClientRect();
    onHover(chart.low + (event.clientX - box.left - plotLeft) / plotWidth * (chart.high - chart.low));
  };
  const ruleAt = hover !== null && hover >= chart.low && hover <= chart.high ? x(hover) : null;

  return html`<div class="dyno-chart">
    <div class="row dyno-chart-title">
      <span class="headline">${chart.title}</span>
      <span class="secondary">${chart.unit}</span>
      <span class="spacer"></span>
      ${hover !== null && html`<span class="callout digits dyno-readout">${readout(chart, hover)}</span>`}
    </div>
    <div ref=${frame} class="dyno-chart-frame" style=${{ height: frameHeight + 'px' }} onMouseMove=${move} onMouseLeave=${() => onHover(null)}>
      ${width > 0 && html`<svg width=${width} height=${frameHeight} viewBox=${`0 0 ${width} ${frameHeight}`}>
        <g class="dyno-chart-grid">
          ${values.map(value => html`<line key=${value} x1=${plotLeft} x2=${width} y1=${row(value)} y2=${row(value)} />`)}
        </g>
        <g class="dyno-chart-grid dashed" transform="translate(-0.5 0)">
          ${rpms.map(rpm => html`<line key=${rpm} x1=${Math.max(1, Math.round(x(rpm)))} x2=${Math.max(1, Math.round(x(rpm)))} y1="0" y2=${tickBottom} />`)}
        </g>
        <g class="dyno-chart-numbers">
          ${values.map((value, index) => html`<text key=${value} x=${plotLeft - labelGap} y=${row(value)} text-anchor="end" dominant-baseline="central">${valueTexts[index]}</text>`)}
          ${rpms.map(rpm => {
            const text = numberText(rpm, format);
            // A number that would run past the right edge is left out, as on the Mac.
            return x(rpm) + labelGap + textWidth(text) <= width && html`<text key=${'r' + rpm} x=${x(rpm) + labelGap} y=${rpmNumbersBaseline}>${text}</text>`;
          })}
          <text x=${plotLeft} y=${axisNameBaseline}>rpm</text>
        </g>
        ${chart.series.map(series => {
          const points = [];
          for (let i = 0; i < series.points.length; i += 2) points.push([x(series.points[i]), y(series.points[i + 1])]);
          return html`<path key=${series.id} class="dyno-chart-line" d=${smoothPath(points)} stroke=${`var(--series-${series.color})`} />`;
        })}
        ${ruleAt !== null && html`<line class="dyno-chart-rule" x1=${ruleAt} x2=${ruleAt} y1="0" y2=${plotHeight + 0.5} />`}
      </svg>`}
    </div>
  </div>`;
}

/** The charts under each other, with one pointer for all of them. */
export function DynoCharts({ charts, format }) {
  const [hover, setHover] = useState(null);
  return charts.map(chart => html`<${DynoChart} key=${chart.title} chart=${chart} format=${format} hover=${hover} onHover=${setHover} />`);
}
