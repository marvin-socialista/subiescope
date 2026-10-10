// The window: the sidebar, the toolbar, and the part of the app that is chosen.
import { render, useEffect, useRef, useState } from '../vendor/preact-htm.js';
import { connect, peek, send, useSlice } from './bridge.js';
import { html, cls, Icon, Button, Select, Segmented, Spinner, Popover, ToolbarSlot, useElapsed, clock } from './ui.js';
import { Dashboard } from './sections/dashboard.js';
import { Logger } from './sections/logger.js';
import { Codes } from './sections/codes.js';
import { Recipes } from './sections/recipes.js';
import { ECUInfo } from './sections/ecuinfo.js';
import { Logs } from './sections/logs.js';
import { Dyno } from './sections/dyno.js';
import { ROM, ROMSheets } from './sections/rom.js';
import { Console } from './sections/console.js';
import { Settings, SettingsSheets } from './sections/settings.js';
import { ConnectionPanel, SetupSheets } from './sections/setup.js';

const sections = {
  dashboard: { title: 'Dashboard', icon: 'gauge', view: Dashboard },
  logger: { title: 'Logger', icon: 'activity', view: Logger },
  diagnostics: { title: 'Trouble Codes', icon: 'triangle-alert', view: Codes },
  recipes: { title: 'Troubleshooting', icon: 'stethoscope', view: Recipes },
  ecuInfo: { title: 'ECU Info', icon: 'cpu', view: ECUInfo },
  logs: { title: 'Recorded Logs', icon: 'file-search', view: Logs },
  dyno: { title: 'Virtual Dyno', icon: 'trending-up', view: Dyno },
  rom: { title: 'ROM Editor', icon: 'microchip', view: ROM },
  console: { title: 'Console', icon: 'terminal', view: Console },
};

function Sidebar({ app, onSettings }) {
  const item = id => html`<div key=${id} class=${cls('sidebar-item', { selected: app.section === id })} tabindex="0"
      onClick=${() => send('app.section', { section: id })}
      onKeyDown=${event => { if (event.key === 'Enter' || event.key === ' ') send('app.section', { section: id }); }}>
    <${Icon} name=${sections[id].icon} />
    <span class="truncate">${sections[id].title}</span>
    ${id === 'diagnostics' && app.codeCount > 0 && html`<span class="sidebar-badge">${app.codeCount}</span>`}
  </div>`;
  return html`<aside class="sidebar">
    <div class="sidebar-list">
      <div class="sidebar-heading">Car</div>
      ${['dashboard', 'logger', 'diagnostics', 'recipes', 'ecuInfo'].map(item)}
      <div class="sidebar-heading">Files</div>
      ${['logs', 'dyno', ...(app.advancedMode ? ['rom'] : [])].map(item)}
      <div class="sidebar-heading">Tools</div>
      ${item('console')}
      <div class="sidebar-item" tabindex="0" onClick=${onSettings} onKeyDown=${event => { if (event.key === 'Enter') onSettings(); }}>
        <${Icon} name="settings" /><span>Settings</span>
      </div>
    </div>
    <div class="sidebar-footer"><${ConnectionCard} app=${app} /></div>
  </aside>`;
}

/** The cable list in SSM mode, the adapter list in OBD-II mode, each with its demo car. */
export function DevicePicker({ app, wide, style }) {
  const options = [
    ...app.devices.map(device => ({ value: device.id, label: device.label })),
    ...(app.experimentalDevices.length ? [{ heading: 'USB and Wi-Fi (experimental)' }, ...app.experimentalDevices.map(device => ({ value: device.id, label: device.label }))] : []),
    { divider: true },
    { value: app.demoDevice.id, label: app.demoDevice.label },
  ];
  const busy = app.connection === 'connecting' || app.connection === 'connected';
  return html`<${Select} options=${options} value=${app.selectedDevice} wide=${wide} style=${style} disabled=${busy}
    placeholder=${app.emptyDevicesText || (app.mode === 'obd' ? 'Choose an adapter' : 'Choose a cable')}
    title=${app.mode === 'obd'
      ? 'The adapter to use. A Bluetooth adapter that is paired in Windows shows up as a COM port. USB and Wi-Fi adapters are experimental.'
      : 'The USB cable to use. FTDI cables show up as "FT232R USB UART".'}
    onChange=${id => send('app.selectDevice', { id })} />`;
}

/** K-line or CAN for a Tactrix OpenPort, right where the connection is. The same choice as in Settings. */
function OpenPortLine({ app }) {
  return html`<${Segmented} wide value=${app.openPortLine} onChange=${line => send('settings.set', { name: 'openPortCAN', on: line === 'can' })}
    options=${[{ value: 'kline', label: 'K-line', title: 'The Tactrix OpenPort talks to the ECU over the K-line: every value.' },
               { value: 'can', label: 'CAN', title: 'Over CAN (experimental): two to three times as fast, but without the ECU specific values.' }]} />`;
}

/** The connection status at the bottom of the sidebar: a clear badge, a Connect button, and a panel with details. */
function ConnectionCard({ app }) {
  const [panel, setPanel] = useState(null);
  const card = useRef(null);
  const connected = app.connection === 'connected';
  const status = app.status;
  const colour = status.color === 'gray' ? 'var(--text-2)' : `var(--${status.color})`;
  const openPanel = () => setPanel(card.current);
  // Notices a cable being plugged in or out while not connected.
  useEffect(() => {
    if (connected || app.connection === 'connecting') return;
    const timer = setInterval(() => send('app.refresh', { quiet: true }), 3000);
    return () => clearInterval(timer);
  }, [connected, app.connection]);

  return html`<div ref=${card} class="connection-card" style=${{ borderColor: `color-mix(in srgb, ${colour} 45%, transparent)`, borderWidth: connected ? '1.5px' : '1px' }}>
    <div class="column" style="gap: 6px" onClick=${openPanel} title="Connection details and instructions">
      <div class="row" style="gap: 6px">
        <span class=${cls('badge', { 'solid green': connected })} style=${{ color: connected ? undefined : colour }}><span class="dot"></span>${status.badge}</span>
        <span class="spacer"></span>
        <${Icon} name="info" class="secondary" />
      </div>
      <div class="callout headline">${status.title}</div>
      <div class="caption secondary connection-detail">${status.detail}</div>
    </div>
    ${app.isPlayingBack ? html`
      <${Button} kind="prominent" size="large" wide icon="zap" title="Stop the playback and show live data from the car"
        onClick=${() => send('app.stopPlayback', { connect: true })}>Connect to Car<//>
      <${Button} kind="link" class="callout" onClick=${() => send('app.stopPlayback')}>Stop playback<//>
    ` : connected ? html`
      ${app.openPortLine && html`<${OpenPortLine} app=${app} />`}
      <div class="row">
        <${Button} kind="link" onClick=${openPanel}>Details<//>
        <span class="spacer"></span>
        <${Button} size="small" onClick=${() => send('app.disconnect')}>Disconnect<//>
      </div>
    ` : app.connection === 'connecting' ? html`
      <div class="row"><${Spinner} /><span class="callout">Connecting…</span></div>
    ` : html`
      <${Segmented} wide value=${app.mode} onChange=${mode => send('app.mode', { mode })}
        options=${[{ value: 'ssm', label: 'SSM cable', title: "SSM: Subaru's own protocol over a USB cable, for cars up to about 2014." },
                   { value: 'obd', label: 'OBD-II', title: 'OBD-II: standard protocol over an ELM327 adapter, for newer cars.' }]} />
      <${DevicePicker} app=${app} wide />
      ${app.openPortLine && html`<${OpenPortLine} app=${app} />`}
      <${Button} kind="link" class="caption" onClick=${() => send('setup.showModeChooser')}>Which one do I need?<//>
      <${Button} kind="prominent" size="large" wide icon="zap" disabled=${!app.canConnect}
        title=${app.canConnect ? 'Connect to the car (Ctrl+K)' : `Pick ${app.mode === 'obd' ? 'an adapter' : 'a cable'} first, or try the demo car`}
        onClick=${() => send('app.connect')}>Connect<//>
      <${Button} kind="link" class="callout" icon="circle-help" onClick=${openPanel}>How to connect<//>
    `}
    ${panel && html`<${Popover} anchor=${panel} side="right" align="end" onClose=${() => setPanel(null)}>
      <${ConnectionPanel} onClose=${() => setPanel(null)} />
    <//>`}
  </div>`;
}

function RecordButton({ app }) {
  const elapsed = useElapsed(app.isRecording ? app.recordingStart : null);
  return html`<button class="toolbar-button" disabled=${!app.canRecord && !app.isRecording}
      title=${app.isRecording ? 'Stop recording (Ctrl+R)' : 'Record the logged parameters to a CSV file (Ctrl+R)'}
      onClick=${() => send('app.toggleRecording')}>
    ${app.isRecording
      ? html`<${Icon} name="circle-stop" class="red" /><span class="digits">${clock(elapsed)}</span>`
      : html`<${Icon} name="circle-dot" />`}
  </button>`;
}

function Toolbar({ app }) {
  const connected = app.connection === 'connected';
  return html`<header class="toolbar">
    <${DevicePicker} app=${app} style="width: 240px" />
    <div class="toolbar-group">
      <button class="toolbar-button" disabled=${connected} title=${app.mode === 'obd' ? 'Look for adapters again' : 'Look for cables again'}
        onClick=${() => send('app.refresh')}><${Icon} name="refresh-cw" /></button>
    </div>
    <div class="toolbar-title">${app.title}</div>
    <span class="spacer"></span>
    ${app.connection === 'connecting' && html`<${Spinner} />`}
    <${ToolbarSlot} />
    <div class="toolbar-group">
      <button class="toolbar-button" disabled=${app.connection === 'connecting'}
        title=${connected ? 'Disconnect from the car (Ctrl+K)' : 'Connect to the car (Ctrl+K)'}
        onClick=${() => send('app.toggleConnection')}><${Icon} name=${connected ? 'zap-off' : 'zap'} /></button>
      <${RecordButton} app=${app} />
    </div>
  </header>`;
}

function App() {
  const app = useSlice('app');
  const [settings, setSettings] = useState(false);
  useEffect(() => {
    const key = event => {
      const command = event.ctrlKey || event.metaKey;
      if (command && event.key.toLowerCase() === 'k') { event.preventDefault(); send('app.toggleConnection'); }
      // Ctrl+R records. It would otherwise load the page again, as F5 does.
      if (command && event.key.toLowerCase() === 'r') { event.preventDefault(); if (!event.shiftKey) send('app.toggleRecording'); }
      if (command && event.key === ',') { event.preventDefault(); setSettings(true); }
      // Ctrl+1 to Ctrl+9 go to the parts of the app, with the numbers the Mac app's View menu gives them.
      if (command && !event.shiftKey && !event.altKey && /^[1-9]$/.test(event.key)) {
        const order = ['dashboard', 'logger', 'recipes', 'diagnostics', 'ecuInfo', 'logs', 'dyno', 'rom', 'console'];
        const section = order[Number(event.key) - 1];
        const current = peek('app');
        if (section && (section !== 'rom' || (current && current.advancedMode))) { event.preventDefault(); send('app.section', { section }); }
      }
      if (event.key === 'F5') event.preventDefault();
    };
    // A file dropped on the window must not replace the page.
    const refuse = event => event.preventDefault();
    window.addEventListener('keydown', key);
    window.addEventListener('dragover', refuse);
    window.addEventListener('drop', refuse);
    return () => { window.removeEventListener('keydown', key); window.removeEventListener('dragover', refuse); window.removeEventListener('drop', refuse); };
  }, []);
  if (!app) return null;
  const section = sections[app.section] || sections.dashboard;
  return html`<div class="window">
    <${Sidebar} app=${app} onSettings=${() => setSettings(true)} />
    <main class="detail">
      <${Toolbar} app=${app} />
      <${section.view} key=${app.section} />
    </main>
    <${SetupSheets} />
    <${SettingsSheets} />
    <${ROMSheets} />
    ${settings && html`<${Settings} onClose=${() => setSettings(false)} />`}
  </div>`;
}

render(html`<${App} />`, document.getElementById('app'));
connect();
