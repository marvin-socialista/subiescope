import { useState } from '../../vendor/preact-htm.js';
import { send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Spinner, Menu, MenuButton, PickerSheet, ToolbarButton, useToolbar } from '../ui.js';
import { ArcGauge, LinearGauge, Sparkline, SwitchPill, ValueText } from '../gauges.js';

const styles = [['dial', 'Dial', 'gauge'], ['digital', 'Digital', 'hash'], ['bar', 'Bar', 'chart-bar'], ['graph', 'Graph', 'chart-line']];
const sizes = [['small', 'Small'], ['wide', 'Wide'], ['large', 'Large']];
const nothing = { value: null, text: '–', min: '–', max: '–', lowText: '', highText: '', low: 0, high: 100, peakLow: null, peakHigh: null, tint: 'accent', history: null };

/** One gauge. `gauge` holds its live numbers (see DashboardLive in the app). */
function Tile({ tile, gauge }) {
  const large = tile.size === 'large';
  let body;
  if (tile.isSwitch) {
    body = html`<div class="tile-body"><${SwitchPill} value=${gauge.value} /></div>`;
  } else if (tile.style === 'digital') {
    body = html`<div class="tile-body digital">
      <${ValueText} text=${gauge.text} units=${tile.units} size=${large ? 96 : tile.size === 'wide' ? 64 : 52} />
      <${LinearGauge} gauge=${gauge} height=${6} />
    </div>`;
  } else if (tile.style === 'bar') {
    body = html`<div class="tile-body bar">
      <${ValueText} text=${gauge.text} units=${tile.units} size=${large ? 44 : 28} />
      <${LinearGauge} gauge=${gauge} height=${large ? 30 : 18} />
      <div class="tile-scale"><span>${gauge.lowText}</span><span>${gauge.highText}</span></div>
    </div>`;
  } else if (tile.style === 'graph') {
    body = html`<div class="tile-body graph">
      <${ValueText} text=${gauge.text} units=${tile.units} size=${large ? 40 : 26} />
      <${Sparkline} history=${gauge.history} tint=${gauge.tint} />
    </div>`;
  } else {
    body = html`<div class="tile-body"><${ArcGauge} gauge=${gauge} units=${tile.units} /></div>`;
  }
  return html`
    <div class="tile-name truncate" title=${tile.help}>${tile.name}</div>
    ${body}
    ${!tile.isSwitch && html`<div class="tile-peaks" title="Double-click to reset min/max"
        onDblClick=${() => send('dashboard.resetPeaks', { id: tile.id })}>
      <span>min ${gauge.min}</span><span>max ${gauge.max}</span>
    </div>`}`;
}

function tileMenu(tile, first) {
  const id = tile.id;
  return [
    ...(tile.isSwitch ? [] : [{ heading: 'Style' }, ...styles.map(([style, label, icon]) => (
      { label, icon, checked: tile.style === style, onClick: () => send('dashboard.style', { id, style }) })), { divider: true }]),
    { heading: 'Size' },
    ...sizes.map(([size, label]) => ({ label, checked: tile.size === size, onClick: () => send('dashboard.size', { id, size }) })),
    ...(tile.unitChoices.length ? [{ divider: true }, { heading: 'Units' }, ...tile.unitChoices.map(unit => (
      { label: unit.label, checked: unit.label === tile.units, onClick: () => send('dashboard.units', { id, units: unit.units }) }))] : []),
    { divider: true },
    ...(tile.isSwitch ? [] : [{ label: 'Reset Min/Max', checked: false, onClick: () => send('dashboard.resetPeaks', { id }) }]),
    { label: 'Move to Start', checked: false, disabled: id === first, onClick: () => send('dashboard.move', { id, before: first }) },
    { label: 'Remove from Dashboard', checked: false, destructive: true, onClick: () => send('dashboard.remove', { id }) },
  ];
}

function OfflineBanner({ dashboard }) {
  const obd = dashboard.mode === 'obd';
  return html`<div class="banner">
    <${Icon} name=${obd ? 'radio' : 'cable'} />
    <div class="column grow" style="gap: 4px">
      <div class="headline">Not connected</div>
      <div class="callout secondary">${obd
        ? 'Plug the adapter into the OBD port under the dashboard, turn the ignition ON (engine running or not), pick the adapter in the toolbar, then press Connect. No adapter handy? Pick "Demo OBD-II car" in the adapter menu.'
        : 'Plug the cable into the OBD port under the dashboard, turn the ignition ON (engine running or not), then press Connect. No cable handy? Pick "Demo ECU" in the cable menu.'}</div>
    </div>
    ${obd ? html`<${Button} onClick=${() => send('setup.showModeChooser')}>Connection Type…<//>`
          : html`<${Button} onClick=${() => send('setup.showCableSetup')}>Cable Setup…<//>`}
    <${Button} kind="prominent" disabled=${dashboard.connecting} onClick=${() => send('app.connect')}>Connect<//>
  </div>`;
}

/** Shown until RomRaider's parameter definitions are available. */
function DefinitionsBanner({ dashboard }) {
  return html`<div class="banner orange center callout">
    ${dashboard.downloadingDefinitions ? html`
      <${Spinner} /><span>Downloading the parameter definitions (one time only)…</span>
    ` : html`
      <${Icon} name="download" />
      <span class="grow">${dashboard.definitionsError || 'The parameter definitions are missing.'}</span>
      <${Button} onClick=${() => send('dashboard.downloadDefinitions')}>Try Again<//>
    `}
  </div>`;
}

/** The transport shown above the gauges while a log plays back. */
function PlaybackBar() {
  const playback = useSlice('playback');
  if (!playback) return null;
  const time = seconds => Math.floor(seconds / 60) + ':' + (seconds % 60).toFixed(1).padStart(4, '0');
  return html`<div class="playback-bar">
    <${Icon} name="circle-play" size=${20} class="secondary" />
    <div class="column grow" style="gap: 1px">
      <div class="callout truncate" style="font-weight: 500">Playing back ${playback.file}</div>
      <div class="caption secondary">Gauges show the log, min/max are for the whole log.</div>
    </div>
    <${Button} kind="prominent" icon=${playback.isPlaying ? 'pause' : 'play'} onClick=${() => send('playback.toggle')} />
    <input type="range" min="0" max=${Math.max(playback.duration, 0.001)} step="0.05" value=${playback.playhead}
      onInput=${event => send('playback.seek', { time: Number(event.target.value) })} />
    <span class="callout digits">${time(playback.playhead)} / ${time(playback.duration)}</span>
    <${MenuButton} align="end" items=${playback.speeds.map(speed => ({ label: speed + '×', checked: speed === playback.speed, onClick: () => send('playback.speed', { speed }) }))}>${playback.speed}×<//>
    <${Button} onClick=${() => send('app.section', { section: 'logs' })}>Charts<//>
    <${Button} icon="zap" title="Stop the playback and show live data from the car" onClick=${() => send('app.stopPlayback', { connect: true })}>Connect to Car<//>
    <${Button} kind="plain" icon="x" title="Close the log" onClick=${() => send('playback.close')} />
  </div>`;
}

/** The "Dashboard" part of the app: the gauges. */
export function Dashboard() {
  const dashboard = useSlice('dashboard');
  const live = useSlice('dashboard.live');
  const parameters = useSlice('parameters');
  const [picking, setPicking] = useState(false);
  const [menu, setMenu] = useState(null);
  const [dragging, setDragging] = useState(null);
  const [target, setTarget] = useState(null);
  useToolbar(html`<${ToolbarButton} icon="rotate-ccw" title="Reset the min/max markers" onClick=${() => send('dashboard.resetPeaks')} />`);
  if (!dashboard) return html`<div class="content"></div>`;
  const gauges = (live && live.gauges) || {};
  const shown = new Set(dashboard.tiles.map(tile => tile.id));
  const first = dashboard.tiles.length ? dashboard.tiles[0].id : null;

  return html`<div class="content" onDragEnd=${() => { setDragging(null); setTarget(null); }}>
    <div class="dashboard">
      ${dashboard.definitionsMissing && html`<${DefinitionsBanner} dashboard=${dashboard} />`}
      ${dashboard.playingBack ? html`<${PlaybackBar} />` : !dashboard.connected && html`<${OfflineBanner} dashboard=${dashboard} />`}
      ${dashboard.pollError && html`<div class="inline-note orange"><${Icon} name="triangle-alert" />${dashboard.pollError}</div>`}
      ${dashboard.notice && html`<div class="inline-note"><${Icon} name="info" />${dashboard.notice}</div>`}
      ${dashboard.hiddenNotice && html`<div class="inline-note"><${Icon} name="eye-off" />${dashboard.hiddenNotice}</div>`}
      <div class="dashboard-grid">
        ${dashboard.tiles.map(tile => html`<div key=${tile.id} draggable="true"
            class=${cls('tile', tile.size, { dragging: dragging === tile.id, target: target === tile.id && dragging && dragging !== tile.id })}
            onContextMenu=${event => { event.preventDefault(); setMenu({ tile, at: { x: event.clientX, y: event.clientY } }); }}
            onDragStart=${event => { setDragging(tile.id); event.dataTransfer.effectAllowed = 'move'; event.dataTransfer.setData('text/plain', tile.id); }}
            onDragOver=${event => { if (dragging) { event.preventDefault(); if (target !== tile.id) setTarget(tile.id); } }}
            onDrop=${event => { event.preventDefault(); if (dragging && dragging !== tile.id) send('dashboard.move', { id: dragging, before: tile.id }); setDragging(null); setTarget(null); }}>
          <${Tile} tile=${tile} gauge=${gauges[tile.id] || nothing} />
        </div>`)}
        <div class="tile tile-add" onClick=${() => setPicking(true)}>
          <${Icon} name="circle-plus" /><span>Add Gauge</span>
        </div>
      </div>
      <div class="caption tertiary">Right-click a gauge to change its style or size. Drag gauges to reorder them.</div>
    </div>
    ${menu && html`<${Menu} anchor=${menu.at} items=${tileMenu(menu.tile, first)} onClose=${() => setMenu(null)} />`}
    ${picking && html`<${PickerSheet} title="Add Gauge" placeholder="Search parameters"
      items=${(parameters || []).filter(parameter => !shown.has(parameter.id)).map(parameter => ({ id: parameter.id, name: parameter.name, detail: parameter.kind }))}
      onPick=${id => send('dashboard.add', { id })} onClose=${() => setPicking(false)} />`}
  </div>`;
}
