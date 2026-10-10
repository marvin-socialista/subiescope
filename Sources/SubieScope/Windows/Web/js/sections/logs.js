import { useEffect, useState } from '../../vendor/preact-htm.js';
import { send, useSlice } from '../bridge.js';
import { registerIcons } from '../icons.js';
import { html, cls, Icon, Button, Empty, Alert, Menu, MenuButton, TextField } from '../ui.js';
import { ChartStack, OverviewStrip, useLogData } from './logs-chart.js';

registerIcons({
  'file-plus': '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z" /> <path d="M14 2v4a2 2 0 0 0 2 2h4" /> <path d="M9 15h6" /> <path d="M12 18v-6" />',
});

/** True while a sheet, an alert or a menu is over the window: keys are theirs then. */
function somethingIsOver() {
  return document.querySelector('.backdrop, .popover-layer') !== null;
}

// Ctrl+O opens a log from any part of the app, as "Open Log…" in the Mac's File menu does.
window.addEventListener('keydown', event => {
  if (!(event.ctrlKey || event.metaKey) || event.shiftKey || event.altKey || event.key.toLowerCase() !== 'o') return;
  event.preventDefault();
  if (!somethingIsOver()) send('logs.open');
});

// Whether the focus was last moved with the Tab key, and not by a click. A button that was clicked
// keeps the focus in a browser, but should not take the space bar from the playback for it.
let tabbed = false;
window.addEventListener('keydown', event => { if (event.key === 'Tab') tabbed = true; }, true);
window.addEventListener('pointerdown', () => { tabbed = false; }, true);

/** The playhead's time, by itself so that a playing log does not draw the whole bar again. */
function PlayheadTime() {
  const cursor = useSlice('logs.cursor');
  return html`<span class="logs-time digits">${cursor ? cursor.time : ''}</span>`;
}

/** The bar above the charts: play, step, speed, and which log this is. */
function PlaybackControls({ viewer, view }) {
  return html`<div class="logs-transport">
    <${Button} class="logs-solid" icon="skip-back" title="Back to the start" onClick=${() => send('playback.seek', { time: 0 })} />
    <${Button} class="logs-solid" icon="step-back" title="Previous sample (←)" onClick=${() => send('logs.step', { rows: -1 })} />
    <${Button} class="logs-solid" kind="prominent" icon=${view.playing ? 'pause' : 'play'} title=${view.playing ? 'Pause (space)' : 'Play (space)'}
      onClick=${() => send('playback.toggle')} />
    <${Button} class="logs-solid" icon="step-forward" title="Next sample (→)" onClick=${() => send('logs.step', { rows: 1 })} />
    <${PlayheadTime} />
    <${MenuButton} title="Playback speed" class="logs-speed"
      items=${view.speeds.map(speed => ({ label: speed + '×', checked: speed === view.speed, onClick: () => send('playback.speed', { speed }) }))}>
      ${view.speed}×<${Icon} name="chevron-down" />
    <//>
    ${view.zoomed && html`<${Button} title="Show the whole log (or double-click a chart)" onClick=${() => send('logs.resetZoom')}>Zoom Out<//>`}
    <div class="logs-which">
      <div class="callout truncate">${viewer.file}</div>
      <div class="caption secondary truncate">${viewer.info}</div>
    </div>
    <${Button} class="logs-gauges" icon="gauge" title=${view.gaugesHelp} disabled=${!view.gaugesEnabled} onClick=${() => send('app.section', { section: 'dashboard' })}>Gauges<//>
    <${Button} kind="link" icon="x" title="Close this log" onClick=${() => send('playback.close')} />
  </div>`;
}

/** Every value of the log at the pointer, or at the playhead. A click on one adds or removes its chart. */
function SnapshotPanel({ viewer, view }) {
  const cursor = useSlice('logs.cursor');
  const [query, setQuery] = useState('');
  const colours = new Map(view.charts.map(chart => [chart.column, chart.color]));
  const wanted = query.toLowerCase();
  return html`<div class="logs-snapshot">
    <div class="logs-snapshot-head">
      <div class="row" style="align-items: baseline">
        <span class="headline grow">Snapshot</span>
        <span class="logs-snapshot-time digits">${cursor ? cursor.snapshotTime : ''}</span>
      </div>
      <div class="caption secondary">${cursor && cursor.hovering ? 'Values under the pointer' : 'Values at the playhead · hover a chart to inspect'}</div>
      <${TextField} value=${query} onChange=${setQuery} placeholder="Filter" wide />
    </div>
    <div class="divider"></div>
    <div class="logs-snapshot-list">
      ${viewer.columns.map((column, index) => {
        if (wanted && !column.logName.toLowerCase().includes(wanted)) return null;
        const colour = colours.get(index);
        return html`<div key=${index} class="logs-snapshot-row" onClick=${() => send('logs.toggleChart', { column: index })}>
          <span class=${cls('logs-mark', { off: colour === undefined })} style=${colour === undefined ? null : { background: `var(--series-${colour % 8})` }}></span>
          <span class="grow truncate" title=${column.header}>${column.name}</span>
          <span class="logs-snapshot-value digits">${(cursor && cursor.values[index]) || '–'}</span>
          <span class="logs-snapshot-units caption secondary truncate">${column.units}</span>
        </div>`;
      })}
    </div>
    <div class="logs-snapshot-foot caption secondary">Click a value to add or remove its chart.</div>
  </div>`;
}

/** The open log: its charts, the playback, and the values at the pointer. */
function LogViewer() {
  const viewer = useSlice('logs.viewer');
  const view = useSlice('logs.view');
  const data = useLogData(viewer ? viewer.id : null);
  // Space plays and pauses, the arrows go from sample to sample. Not while typing in a field, and
  // space stays what it is for someone who went to a button with the Tab key.
  useEffect(() => {
    const key = event => {
      if (event.ctrlKey || event.metaKey || event.altKey || somethingIsOver()) return;
      const target = event.target;
      if (target && target.matches && target.matches('input, textarea, select, [contenteditable]')) return;
      if (event.key === ' ') {
        if (tabbed && target && target.matches && target.matches('button, a, [tabindex]')) return;
        send('playback.toggle');
      } else if (event.key === 'ArrowLeft') send('logs.step', { rows: -1 });
      else if (event.key === 'ArrowRight') send('logs.step', { rows: 1 });
      else return;
      event.preventDefault();
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, []);
  if (!viewer || !view) return null;
  return html`<div class="logs-viewer">
    <${PlaybackControls} viewer=${viewer} view=${view} />
    <div class="divider"></div>
    <div class="logs-body">
      <div class="logs-charts">
        ${view.charts.length === 0
          ? html`<${Empty} icon="chart-line" title="No charts">Click values in the snapshot list to chart them.<//>`
          : html`<${ChartStack} key=${viewer.id} viewer=${viewer} view=${view} data=${data} />`}
        <div class="divider"></div>
        <${OverviewStrip} viewer=${viewer} view=${view} data=${data} />
      </div>
      <div class="logs-rule"></div>
      <${SnapshotPanel} key=${viewer.id} viewer=${viewer} view=${view} />
    </div>
  </div>`;
}

/** The "Recorded Logs" part of the app: the recordings on the left, the one that is open on the right. */
export function Logs() {
  const logs = useSlice('logs');
  const [menu, setMenu] = useState(null);
  const [deleting, setDeleting] = useState(null);
  // The files are on disk: the list is read again every time this part is opened.
  useEffect(() => { send('logs.reload'); }, []);
  // Escape takes the question about deleting back.
  useEffect(() => {
    if (!deleting) return undefined;
    const key = event => { if (event.key === 'Escape') setDeleting(null); };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [deleting]);
  if (!logs) return html`<div class="content fixed logs"></div>`;

  // With the list in focus, the up and down arrows go to the log above and below, as in the Mac's list.
  const listKey = event => {
    if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
    event.preventDefault();
    const at = logs.files.findIndex(file => file.name === logs.selected);
    const next = logs.files[at < 0 ? 0 : at + (event.key === 'ArrowDown' ? 1 : -1)];
    if (next) send('logs.select', { name: next.name });
  };
  const fileMenu = file => [
    { label: logs.revealLabel, onClick: () => send('logs.reveal', { name: file.name }) },
    { label: 'Open With Default App', onClick: () => send('logs.openExternally', { name: file.name }) },
    { divider: true },
    { label: logs.deleteLabel, destructive: true, onClick: () => setDeleting(file) },
  ];
  return html`<div class="content fixed logs">
    <div class="logs-list">
      <div class="logs-files" tabindex="0" onKeyDown=${listKey}>
        ${logs.files.map(file => html`<div key=${file.name} class=${cls('logs-file', { selected: file.name === logs.selected })}
            onClick=${() => send('logs.select', { name: file.name })}
            onContextMenu=${event => { event.preventDefault(); setMenu({ file, at: { x: event.clientX, y: event.clientY } }); }}>
          <div class="truncate">${file.name}</div>
          <div class="caption secondary truncate">${file.detail}</div>
        </div>`)}
        ${logs.files.length === 0 && html`<${Empty} icon="file-text" title="No logs yet">
          Recordings are saved to<br /><span class="selectable logs-folder">${logs.folder}</span>
        <//>`}
      </div>
      <div class="divider"></div>
      <div class="logs-list-bar">
        <${Button} kind="link" icon="folder" onClick=${() => send('logs.openFolder')}>Open Folder<//>
        <${Button} kind="link" icon="file-plus" title="Open any RomRaider CSV log (Ctrl+O)" onClick=${() => send('logs.open')}>Open…<//>
        <span class="spacer"></span>
        <${Button} kind="link" icon="rotate-cw" title="Reload" onClick=${() => send('logs.reload')} />
      </div>
    </div>
    <div class="logs-rule"></div>
    <div class="logs-main">
      ${logs.isOpen ? html`<${LogViewer} />`
        : logs.error ? html`<${Empty} icon="triangle-alert" title="Could not open the log">${logs.error}<//>`
        : html`<${Empty} icon="chart-line" title="Select a log">Pick a recording to replay it. You can also open RomRaider logs from elsewhere (Ctrl+O). The files are standard RomRaider CSV, so Datazap, DataLog Lab and Virtual Dyno open them too.<//>`}
    </div>
    ${menu && html`<${Menu} anchor=${menu.at} items=${fileMenu(menu.file)} onClose=${() => setMenu(null)} />`}
    ${deleting && html`<${Alert} title=${deleting.deleteQuestion} buttons=${[
      { label: logs.deleteLabel, kind: 'destructive', onClick: () => { send('logs.delete', { name: deleting.name }); setDeleting(null); } },
      { label: 'Cancel', onClick: () => setDeleting(null) },
    ]}>${logs.deleteDetail}<//>`}
  </div>`;
}
