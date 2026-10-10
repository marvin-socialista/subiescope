// The "Logger" part of the app. On the left every value the car can report, with a tick for the
// ones that are logged. On the right the last minute of each logged value as a small graph, under
// the bar that says whether a log is being recorded.
import { h, useEffect, useLayoutEffect, useMemo, useRef, useState } from '../../vendor/preact-htm.js';
import { onSlice, peek, request, send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Checkbox, Segmented, TextField, Menu, MenuButton, Empty } from '../ui.js';
import { Sparkline } from '../gauges.js';
import { registerIcons } from '../icons.js';

// Lucide's gauge, made smaller, with a badge at its corner that says what the button does: a plus
// to put the value on the dashboard, a minus to take it off. The badge is cut out of the gauge in
// the colour of the window, as on the Mac.
function gaugeWithBadge(sign) {
  return '<g transform="translate(4.8 0) scale(.8)" stroke-width="2.2"><path d="m12 14 4-4" /> <path d="M3.34 19a10 10 0 1 1 17.32 0" /></g>'
    + ' <circle cx="5.5" cy="18.5" r="6.4" stroke="none" style="fill: var(--window)" />'
    + ' <circle cx="5.5" cy="18.5" r="4.8" stroke="none" fill="currentColor" />'
    + ` <g stroke-width="1.7" style="stroke: var(--window)">${sign}</g>`;
}

registerIcons({
  'circle-ellipsis': '<circle cx="12" cy="12" r="10" /> <path d="M17 12h.01" /> <path d="M12 12h.01" /> <path d="M7 12h.01" />',
  'logger-gauge-plus': gaugeWithBadge('<path d="M5.5 16.3v4.4" /> <path d="M3.3 18.5h4.4" />'),
  'logger-gauge-minus': gaugeWithBadge('<path d="M3.3 18.5h4.4" />'),
  // A ring with a dot in it, as on a recorder.
  'logger-record': '<circle cx="12" cy="12" r="10" /> <circle cx="12" cy="12" r="4.5" fill="currentColor" stroke="none" />',
});

/** A component that is drawn again only when something it is given has changed. */
function memo(view) {
  return function Memo(props) {
    this.shouldComponentUpdate = next => {
      for (const name in next) if (next[name] !== this.props[name]) return true;
      for (const name in this.props) if (!(name in next)) return true;
      return false;
    };
    return h(view, props);
  };
}

/** What a scrolling element shows right now: { top, height, width }. For lists that draw only the rows in sight. */
function useViewport(scroller) {
  const [view, setView] = useState({ top: 0, height: 0, width: 0 });
  useLayoutEffect(() => {
    const element = scroller.current;
    if (!element) return;
    const measure = () => setView(old => old.top === element.scrollTop && old.height === element.clientHeight && old.width === element.clientWidth
      ? old : { top: element.scrollTop, height: element.clientHeight, width: element.clientWidth });
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    element.addEventListener('scroll', measure, { passive: true });
    return () => { observer.disconnect(); element.removeEventListener('scroll', measure); };
  }, []);
  return view;
}

// MARK: The list of values

// The heights of the list, as in css/sections/logger.css. The list draws only the rows in sight
// (without a car it holds every value of the definitions, some five hundred), so it has to
// know where each one is. A row with a second line is taller; a heading has some air under it.
const rowHeight = 24, tallRowHeight = 37, headingHeight = 28, headingGap = 10;

/** One value: its tick, name, newest number, units and the button that puts it on the dashboard. */
const ParameterRow = memo(function ParameterRow({ row, value, logged, onDashboard, top, onUnits }) {
  const id = row.id;
  return html`<div class=${cls('logger-row', { tall: row.detail })} style=${{ top: top + 'px' }}>
    <${Checkbox} checked=${logged} title="Log this parameter" onChange=${on => send('logger.log', { id, on })} />
    <div class="logger-row-name" title=${row.help}>
      <div class="truncate">${row.name}</div>
      ${row.detail && html`<div class="logger-row-detail truncate">${row.detail}</div>`}
    </div>
    ${value !== undefined && html`<span class="logger-row-value digits">${value}</span>`}
    ${!row.isSwitch && (row.unitChoices.length
      ? html`<button class="logger-units-button" onClick=${event => onUnits(row, event.currentTarget)}>${row.units}<${Icon} name="chevron-down" /></button>`
      : html`<span class="logger-row-units">${row.units}</span>`)}
    <button class=${cls('logger-gauge-button', { on: onDashboard })} title=${onDashboard ? 'Remove from Dashboard' : 'Add to Dashboard'}
        onClick=${() => send('logger.dashboard', { id, on: !onDashboard })}>
      <${Icon} name=${onDashboard ? 'logger-gauge-minus' : 'logger-gauge-plus'} />
    </button>
  </div>`;
});

/** The values in their groups. `values` holds the newest number of each as text. */
function ParameterList({ parameters, logger, values, query, onlyLogged }) {
  const scroller = useRef(null);
  const stack = useRef(null);
  const view = useViewport(scroller);
  const [menu, setMenu] = useState(null);
  // One function for every row, so a row is not drawn again for it. The menu hangs on the place
  // of the button, not on the button itself: a row can leave the page while its menu is open.
  const openUnits = useRef((row, button) => {
    const { left, top, right, bottom } = button.getBoundingClientRect();
    setMenu({ row, anchor: { left, top, right, bottom } });
  }).current;
  const logged = useMemo(() => new Set(logger.logged), [logger.logged]);
  const onDashboard = useMemo(() => new Set(logger.onDashboard), [logger.onDashboard]);

  // Where everything is: each group's heading, then the rows of it that are asked for.
  const layout = useMemo(() => {
    const wanted = query.toLowerCase();
    const groups = [];
    let top = 0;
    for (const group of parameters.groups) {
      const rows = group.rows.filter(row => (!onlyLogged || logged.has(row.id))
        && (!wanted || row.name.toLowerCase().includes(wanted) || row.id.toLowerCase().includes(wanted)));
      if (!rows.length) continue;
      if (groups.length) top += headingGap;
      const start = top;
      let height = headingHeight + headingGap;
      // Each row's place, counted from the top of its group.
      const tops = rows.map(row => { const at = height; height += row.detail ? tallRowHeight : rowHeight; return at; });
      top += height;
      groups.push({ name: group.title, title: `${group.title} · ${rows.length}`, rows, tops, start, height });
    }
    return { groups, height: top + headingGap };
  }, [parameters, query, onlyLogged, onlyLogged && logged]);

  // The groups in sight, and of each the rows in sight with a few around them. The note above the
  // list scrolls with it, so the list itself starts a little lower.
  const offset = stack.current ? stack.current.offsetTop : 0;
  const from = view.top - offset - 200, to = view.top - offset + view.height + 200;
  const shown = layout.groups.filter(group => group.start + group.height >= from && group.start <= to).map(group => {
    const rows = [];
    for (let index = 0; index < group.rows.length; index++) {
      const top = group.tops[index];
      if (group.start + top > to) break;
      if (group.start + top + tallRowHeight < from) continue;
      const row = group.rows[index];
      rows.push(html`<${ParameterRow} key=${row.id} row=${row} value=${values[row.id]} logged=${logged.has(row.id)}
        onDashboard=${onDashboard.has(row.id)} top=${top} onUnits=${openUnits} />`);
    }
    // The heading stays in sight while its group runs off the top, until the next one pushes it out.
    return html`<div key=${group.name} class="logger-group" style=${{ top: group.start + 'px', height: group.height + 'px' }}>
      <div class="logger-heading">${group.title}</div>
      ${rows}
    </div>`;
  });

  return html`<div ref=${scroller} class="logger-list">
    ${logger.offlineNote && html`<div class="logger-note">${logger.offlineNote}</div>`}
    <div ref=${stack} class="logger-stack" style=${{ height: layout.height + 'px' }}>${shown}</div>
  </div>
  ${menu && html`<${Menu} anchor=${menu.anchor} align="end" onClose=${() => setMenu(null)}
    items=${menu.row.unitChoices.map(unit => ({ label: unit.label, onClick: () => send('logger.units', { id: menu.row.id, units: unit.units }) }))} />`}`;
}

/** The left side: the search field, All or Logged, the list, and how fast the car answers. */
function ParameterBrowser({ parameters, logger, live }) {
  const [query, setQuery] = useState('');
  const [onlyLogged, setOnlyLogged] = useState(false);
  return html`<div class="logger-browser">
    <div class="logger-filter">
      <${TextField} wide value=${query} onChange=${setQuery} placeholder=${`Search ${parameters.count} parameters`} />
      <div class="row">
        <${Segmented} value=${onlyLogged ? 'logged' : 'all'} onChange=${value => setOnlyLogged(value === 'logged')}
          options=${[{ value: 'all', label: 'All' }, { value: 'logged', label: `Logged (${logger.loggedCount})` }]} />
        <span class="spacer"></span>
        <${MenuButton} kind="plain" class="logger-more" align="end" items=${[
          { label: 'Log Nothing', onClick: () => send('logger.logNothing') },
          { label: 'Log Dashboard Gauges', onClick: () => send('logger.logDashboard') },
        ]}><${Icon} name="circle-ellipsis" /><${Icon} name="chevron-down" class="logger-chevron" /><//>
      </div>
    </div>
    <div class="divider"></div>
    <${ParameterList} parameters=${parameters} logger=${logger} values=${live.values} query=${query} onlyLogged=${onlyLogged} />
    <div class="divider"></div>
    <div class="logger-hint">${live.speedHint}</div>
  </div>`;
}

// MARK: The graphs

// The last minute of every graph, kept here and not sent whole with every sample: the page asks
// the app only for the points it does not have yet (`logger.points`). It stays when another part
// of the app is shown, so coming back costs no more than what happened in between.
const points = { source: null, newest: -1, series: new Map(), asking: false, again: false, listeners: new Set() };

/** Asks the app for the points since the last answer and adds them. One question at a time. */
async function fetchPoints() {
  if (points.asking) { points.again = true; return; }
  points.asking = true;
  try {
    do {
      points.again = false;
      addPoints(await request('logger.points', { after: points.newest, source: points.source, known: [...points.series.keys()] }));
    } while (points.again);
  } finally {
    points.asking = false;
  }
}

/** Adds an answer of `logger.points` to what the page has. */
function addPoints(answer) {
  if (!answer) return;
  const seconds = (peek('logger') || {}).window || 60;
  for (const [id, sent] of Object.entries(answer.series)) {
    let line = sent.keep && points.series.get(id);
    // `drawn` counts the changes to a line, so a graph knows when to draw itself again.
    if (!line) { line = { time: [], value: [], drawn: 0 }; points.series.set(id, line); }
    if (!sent.points) continue;
    const numbers = sent.points.split(',');
    for (let i = 0; i + 1 < numbers.length; i += 2) {
      line.time.push(numbers[i] / 1000);
      line.value.push(Number(numbers[i + 1]));
    }
    // What is older than the width of the graph goes, as it does in the app.
    const newest = line.time[line.time.length - 1];
    let old = 0;
    while (newest - line.time[old] > seconds) old++;
    if (old) { line.time.splice(0, old); line.value.splice(0, old); }
    line.drawn++;
  }
  for (const id of [...points.series.keys()]) if (!(id in answer.series)) points.series.delete(id);
  points.source = answer.source;
  points.newest = answer.newest;
  points.listeners.forEach(listener => listener());
}

/** Keeps the graphs' points up to date for as long as the component is on the page, and draws it again with every new one. */
function usePoints() {
  const [, redraw] = useState(0);
  useEffect(() => {
    const listener = () => redraw(n => n + 1);
    points.listeners.add(listener);
    // Every sample from the car changes this slice: the sign that there is something new to ask for.
    const stop = onSlice('logger.live', fetchPoints);
    fetchPoints();
    return () => { points.listeners.delete(listener); stop(); };
  }, []);
}

// A graph is 54 high in a card with 10 around it; 10 between two cards and 12 around all of them.
const trendPitch = 84, trendPadding = 12, trendHeight = 74;

/**
 * One logged value: its name, its newest number and its last minute. Drawn again only for a new
 * number, new points (`drawn`) or another width of the window.
 */
const TrendRow = memo(function TrendRow({ trend, text, line, seconds, top }) {
  // The graph wants pairs of (seconds ago, value).
  let history = null;
  if (line && line.time.length > 1) {
    const count = line.time.length, newest = line.time[count - 1];
    history = new Array(count * 2);
    for (let i = 0; i < count; i++) {
      history[i * 2] = newest - line.time[i];
      history[i * 2 + 1] = line.value[i];
    }
  }
  return html`<div class="logger-trend" style=${{ top: top + 'px' }}>
    <div class="logger-trend-label">
      <div class="logger-trend-name">${trend.name}</div>
      <div class="logger-trend-value"><span class="digits">${text}</span><span class="logger-trend-units">${trend.units}</span></div>
    </div>
    <div class="logger-trend-graph"><${Sparkline} history=${history} window=${seconds} /></div>
  </div>`;
});

/** The graphs under each other. Only the ones in sight are drawn. */
function TrendList({ trends, values, seconds }) {
  const scroller = useRef(null);
  const view = useViewport(scroller);
  usePoints();
  const first = Math.max(0, Math.floor((view.top - trendPadding) / trendPitch) - 1);
  const last = Math.min(trends.length, Math.ceil((view.top + view.height - trendPadding) / trendPitch) + 1);
  const height = trends.length * trendPitch - (trendPitch - trendHeight) + trendPadding * 2;
  return html`<div ref=${scroller} class="logger-trend-list">
    <div class="logger-stack" style=${{ height: height + 'px' }}>
      ${trends.slice(first, last).map((trend, index) => {
        const line = points.series.get(trend.id);
        return html`<${TrendRow} key=${trend.id} trend=${trend} seconds=${seconds}
          text=${values[trend.id] === undefined ? '–' : values[trend.id]} line=${line} drawn=${line ? line.drawn : 0}
          top=${trendPadding + (first + index) * trendPitch} width=${view.width} />`;
      })}
    </div>
  </div>`;
}

/** Whether a log is being written, and the button that starts and stops it. */
function RecordingBar({ logger, live }) {
  return html`<div class="logger-recording">
    ${logger.isRecording ? html`
      <${Icon} name="logger-record" class="red logger-pulse" />
      <div class="column grow" style="gap: 1px">
        <div class="callout truncate" style="font-weight: 500">${logger.recordingTitle}</div>
        <div class="caption secondary digits">${live.recordingDetail}</div>
      </div>
    ` : html`
      <${Icon} name="logger-record" class="secondary" />
      <div class="callout secondary grow">${logger.recordHint}</div>
    `}
    <${Button} kind="prominent" tint=${logger.isRecording ? 'red' : null} disabled=${!logger.canRecord}
      onClick=${() => send('app.toggleRecording')}>${logger.isRecording ? 'Stop' : 'Record'}<//>
  </div>`;
}

/** The right side: the recording bar, and the graphs of what is logged. */
function LiveTrends({ logger, live }) {
  return html`<div class="logger-trends">
    <${RecordingBar} logger=${logger} live=${live} />
    <div class="divider"></div>
    ${logger.trends.length === 0
      ? html`<div class="logger-nothing"><${Empty} icon="activity" title="Nothing to show yet">${logger.emptyText}<//></div>`
      : html`<${TrendList} trends=${logger.trends} values=${live.values} seconds=${logger.window} />`}
  </div>`;
}

const nothingLive = { values: {}, speedHint: '', recordingDetail: null, newest: null };

/** The "Logger" part of the app. */
export function Logger() {
  const parameters = useSlice('logger.parameters');
  const logger = useSlice('logger');
  const live = useSlice('logger.live') || nothingLive;
  if (!parameters || !logger) return html`<div class="content fixed logger"></div>`;
  return html`<div class="content fixed logger">
    <${ParameterBrowser} parameters=${parameters} logger=${logger} live=${live} />
    <div class="logger-divider"></div>
    <${LiveTrends} logger=${logger} live=${live} />
  </div>`;
}
