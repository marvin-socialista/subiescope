// How a value is drawn: a dial, a bar, a small graph, an ON/OFF pill. Used by the dashboard, and
// by any other part of the app that shows a live value.
import { useEffect, useRef } from '../vendor/preact-htm.js';
import { html, cls } from './ui.js';

/** 'accent', 'orange', 'red' or 'green' as a CSS colour. */
export function tintColor(tint) {
  return `var(--${tint || 'accent'})`;
}

function fraction(value, low, high) {
  if (value === null || value === undefined || !Number.isFinite(value) || !(high > low)) return 0;
  return Math.min(1, Math.max(0, (value - low) / (high - low)));
}

// The dial is 240 degrees of a circle, open at the bottom. Angles run clockwise from three o'clock.
const dial = { centerX: 50, centerY: 50, radius: 44, start: 150, sweep: 240, width: 5.5 };

function point(degrees, radius = dial.radius) {
  const angle = degrees * Math.PI / 180;
  return [dial.centerX + Math.cos(angle) * radius, dial.centerY + Math.sin(angle) * radius];
}

function arc(from, to) {
  const [x1, y1] = point(dial.start + dial.sweep * from);
  const [x2, y2] = point(dial.start + dial.sweep * to);
  const large = (to - from) * dial.sweep > 180 ? 1 : 0;
  return `M${x1.toFixed(2)} ${y1.toFixed(2)}A${dial.radius} ${dial.radius} 0 ${large} 1 ${x2.toFixed(2)} ${y2.toFixed(2)}`;
}

function tick(at, length) {
  const [x1, y1] = point(dial.start + dial.sweep * at, dial.radius - length / 2);
  const [x2, y2] = point(dial.start + dial.sweep * at, dial.radius + length / 2);
  return `M${x1.toFixed(2)} ${y1.toFixed(2)}L${x2.toFixed(2)} ${y2.toFixed(2)}`;
}

/**
 * A 240 degree dial with the value in its middle and marks at the lowest and highest seen.
 * `gauge` is one entry of the app's live gauges: { value, text, low, high, peakLow, peakHigh, tint }.
 */
export function ArcGauge({ gauge, units }) {
  const { low, high } = gauge;
  // A scale that crosses zero fills from zero, to either side.
  const origin = low < 0 && high > 0 ? fraction(0, low, high) : 0;
  const end = fraction(gauge.value, low, high);
  const from = Math.min(origin, end), to = Math.max(origin, end);
  const text = gauge.text;
  // The number shrinks to stay inside the dial: about 0.6 of its size per character.
  const size = Math.min(19, 96 / Math.max(text.length, 1));
  return html`<svg class="arc-gauge" viewBox="0 0 100 79" preserveAspectRatio="xMidYMin meet">
    <path d=${arc(0, 1)} class="arc-track" stroke-width=${dial.width} />
    ${gauge.value !== null && to - from > 0.0005 && html`<path d=${arc(from, to)} stroke=${tintColor(gauge.tint)} stroke-width=${dial.width} class="arc-value" />`}
    ${gauge.value !== null && to - from <= 0.0005 && html`<circle cx=${point(dial.start + dial.sweep * end)[0]} cy=${point(dial.start + dial.sweep * end)[1]} r=${dial.width / 2} fill=${tintColor(gauge.tint)} />`}
    ${origin > 0 && html`<path d=${tick(origin, dial.width * 1.2)} class="arc-origin" />`}
    ${gauge.peakHigh !== null && html`<path d=${tick(fraction(gauge.peakHigh, low, high), dial.width * 1.6)} class="arc-peak high" />`}
    ${gauge.peakLow !== null && html`<path d=${tick(fraction(gauge.peakLow, low, high), dial.width * 1.6)} class="arc-peak low" />`}
    <text x="50" y="58" class="arc-number" font-size=${size}>${text}</text>
    <text x="50" y="68.5" class="arc-units">${units}</text>
  </svg>`;
}

/** A horizontal bar with marks at the lowest and highest seen. `height` in pixels. */
export function LinearGauge({ gauge, height = 6 }) {
  const { low, high } = gauge;
  const origin = low < 0 && high > 0 ? fraction(0, low, high) : 0;
  const end = fraction(gauge.value, low, high);
  const left = Math.min(origin, end), width = Math.abs(end - origin);
  return html`<div class="linear-gauge" style=${{ height: height + 'px', borderRadius: height / 2 + 'px' }}>
    ${gauge.value !== null && html`<div class="linear-fill" style=${{ left: left * 100 + '%', width: `max(${height}px, ${width * 100}%)`, background: tintColor(gauge.tint), borderRadius: height / 2 + 'px' }}></div>`}
    ${gauge.peakHigh !== null && html`<div class="linear-peak high" style=${{ left: `calc(${fraction(gauge.peakHigh, low, high) * 100}% - 1px)` }}></div>`}
    ${gauge.peakLow !== null && html`<div class="linear-peak low" style=${{ left: `calc(${fraction(gauge.peakLow, low, high) * 100}% - 1px)` }}></div>`}
  </div>`;
}

/** The big number with its units under it. `size` is the number's height in pixels. */
export function ValueText({ text, units, size, centered }) {
  return html`<div class=${cls('value-text', { centered })}>
    <div class="value-number digits" style=${{ fontSize: Math.max(14, size) + 'px' }}>${text}</div>
    <div class="value-units" style=${{ fontSize: Math.max(10, size * 0.32) + 'px' }}>${units}</div>
  </div>`;
}

/** ON, OFF, or a dash while the car has not said. */
export function SwitchPill({ value }) {
  const known = value !== null && value !== undefined;
  const on = known && value !== 0;
  return html`<div class=${cls('switch-pill', { on })}>${known ? (on ? 'ON' : 'OFF') : '–'}</div>`;
}

/**
 * The last minute of a value as a line. `history` is pairs of (seconds ago, value) in one flat list,
 * oldest first; `window` is how many seconds the width stands for.
 */
export function Sparkline({ history, window: seconds = 60, tint }) {
  const canvas = useRef(null);
  useEffect(() => {
    const element = canvas.current;
    if (!element) return;
    const scale = window.devicePixelRatio || 1;
    const width = element.clientWidth, height = element.clientHeight;
    if (element.width !== Math.round(width * scale) || element.height !== Math.round(height * scale)) {
      element.width = Math.round(width * scale);
      element.height = Math.round(height * scale);
    }
    const context = element.getContext('2d');
    context.setTransform(scale, 0, 0, scale, 0, 0);
    context.clearRect(0, 0, width, height);
    const count = history ? history.length / 2 : 0;
    if (count < 2) return;
    let low = Infinity, high = -Infinity;
    for (let i = 0; i < count; i++) {
      const value = history[i * 2 + 1];
      if (value < low) low = value;
      if (value > high) high = value;
    }
    const span = high - low === 0 ? 1 : high - low;
    const x = i => width * (1 - history[i * 2] / seconds);
    const y = i => height * (1 - (history[i * 2 + 1] - low) / span) * 0.9 + height * 0.05;
    const style = getComputedStyle(element);
    const colour = style.getPropertyValue(`--${tint || 'accent'}`).trim() || '#5499ff';
    context.beginPath();
    context.moveTo(x(0), y(0));
    for (let i = 1; i < count; i++) context.lineTo(x(i), y(i));
    context.lineWidth = 1.5;
    context.lineJoin = 'round';
    context.strokeStyle = colour;
    context.stroke();
    context.lineTo(x(count - 1), height);
    context.lineTo(x(0), height);
    context.closePath();
    const fill = context.createLinearGradient(0, 0, 0, height);
    fill.addColorStop(0, colour + '40');
    fill.addColorStop(1, colour + '05');
    context.fillStyle = fill;
    context.fill();
    context.font = '9px ' + style.fontFamily;
    context.fillStyle = style.getPropertyValue('--text-2');
    context.textBaseline = 'top';
    context.fillText(Number(high.toPrecision(4)).toString(), 2, 2);
    context.textBaseline = 'bottom';
    context.fillText(Number(low.toPrecision(4)).toString(), 2, height - 2);
  });
  return html`<canvas ref=${canvas} class="sparkline"></canvas>`;
}
