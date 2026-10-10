// Settings, and what comes with it: the About tab, the "new version" sheet and the question after a
// crash. The Mac app has Settings as a window of its own with the same four tabs (SettingsView.swift);
// what the Mac keeps in its menu bar about the app itself is on the About tab here, because a
// Windows app has no menu bar. The state comes from Bridge+Settings.swift.
import { useEffect, useState } from '../../vendor/preact-htm.js';
import { peek, send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Select, Segmented, Sheet, Alert, Link, Spinner } from '../ui.js';

// The app's icon

// Drawn the way scripts/make-icon.swift draws it: a dark blue tile with a gauge that is open at the
// bottom, a red zone at its end and a gold needle. On a 1024 grid, as the icon itself.
const iconDrawing = (() => {
  const body = 824, radius = body * 0.34, cx = 512, cy = 512 + radius * 0.07;
  const start = 225, end = -45;   // degrees from 3 o'clock, against the clock
  const round = number => Math.round(number * 10) / 10;
  const at = (degrees, distance) => {
    const angle = degrees * Math.PI / 180;
    return round(cx + Math.cos(angle) * distance) + ' ' + round(cy - Math.sin(angle) * distance);
  };
  const arc = (from, to) => `M${at(from, radius)}A${round(radius)} ${round(radius)} 0 ${from - to > 180 ? 1 : 0} 1 ${at(to, radius)}`;
  const part = share => start - (start - end) * share;
  const needle = part(0.74), width = body * 0.028, stroke = round(body * 0.055);
  let ticks = '';
  for (let i = 0; i <= 8; i++) ticks += `M${at(part(i / 8), radius * 0.7)}L${at(part(i / 8), radius * 0.8)}`;
  return `<defs><linearGradient id="settings-icon-tile" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1a3b85"/><stop offset="1" stop-color="#081438"/></linearGradient></defs>
    <rect x="100" y="100" width="${body}" height="${body}" rx="${round(body * 0.2237)}" fill="url(#settings-icon-tile)"/>
    <g fill="none" stroke-linecap="round">
      <path d="${arc(start, end)}" stroke="#fff" stroke-opacity="0.14" stroke-width="${stroke}"/>
      <path d="${arc(start, needle)}" stroke="#6bb3ff" stroke-width="${stroke}"/>
      <path d="${arc(part(0.86), end)}" stroke="#ed4540" stroke-width="${stroke}"/>
      <path d="${ticks}" stroke="#fff" stroke-opacity="0.8" stroke-width="${round(body * 0.012)}"/>
    </g>
    <path d="M${at(needle, radius * 0.92)}L${at(needle + 90, width)}L${at(needle + 180, radius * 0.14)}L${at(needle - 90, width)}Z" fill="#edba40"/>
    <circle cx="${cx}" cy="${round(cy)}" r="${round(width * 1.9)}" fill="#edba40"/>
    <circle cx="${cx}" cy="${round(cy)}" r="${round(width * 0.8)}" fill="#081438"/>`;
})();

/** SubieScope's own icon. `size` in pixels. */
export function AppIcon({ size }) {
  return html`<svg class="settings-app-icon" style=${{ width: size + 'px', height: size + 'px' }} viewBox="0 0 1024 1024" aria-hidden="true"
    dangerouslySetInnerHTML=${{ __html: iconDrawing }}></svg>`;
}

// The rows of a tab

/** A setting with its name on the left and what it is, or what changes it, on the right. */
function Row({ label, children }) {
  return html`<div class="group-row settings-row">
    <span class="settings-label">${label}</span>
    <div class="settings-value">${children}</div>
  </div>`;
}

/** The small print under a setting. */
function Note({ children }) {
  return html`<div class="group-row settings-note">${children}</div>`;
}

/**
 * A setting that is on or off. The switch shows what the app says, not what was clicked: it moves
 * when the app has changed the setting, which is what matters for one the app may refuse or ask about first.
 */
function SwitchRow({ label, checked, disabled, onChange }) {
  return html`<div class="group-row settings-row">
    <span class="settings-label">${label}</span>
    <label class="toggle"><input type="checkbox" role="switch" aria-label=${label} checked=${checked} disabled=${disabled}
      onChange=${event => { const wanted = event.target.checked; event.target.checked = checked; onChange(wanted); }} /></label>
  </div>`;
}

/** A path on one line, shortened in the middle when it does not fit: the folder's own name stays in view. */
function Path({ path }) {
  const cut = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  const split = cut > 0 && path.length - cut <= 32 ? cut : Math.max(0, path.length - 20);
  return html`<span class="settings-path secondary" title=${path}>
    <span class="truncate">${path.slice(0, split)}</span><span>${path.slice(split)}</span>
  </span>`;
}

const set = (name, value) => send('settings.set', { name, ...value });
const flip = name => on => set(name, { on });

// The four tabs: General

function General({ settings, computer }) {
  const obd = settings.mode === 'obd';
  return html`<div class="group settings-form">
    <${Row} label="Connection type">
      <span class="secondary">${settings.connectionType}</span>
      <${Button} disabled=${settings.connected} onClick=${() => send('setup.showModeChooser')}>Change…<//>
    <//>
    <${Row} label="Help with connecting">
      <${Button} disabled=${settings.connecting} title="A short setup that helps you pick the right cable or adapter and checks that it works"
        onClick=${() => send('setup.showWizard')}>Setup Wizard…<//>
      ${!obd && html`<${Button} title="Three quick steps to connect to your Subaru with the cable" onClick=${() => send('setup.showCableSetup')}>Cable Setup…<//>`}
    <//>
    <${Row} label="Units">
      <${Select} value=${settings.unitSystem} onChange=${value => set('unitSystem', { value })}
        options=${[{ value: 'metric', label: 'Metric (°C, kPa, km/h)' }, { value: 'imperial', label: 'Imperial (°F, psi, mph)' }]} />
    <//>
    <${Row} label="Pressure">
      <${Select} value=${settings.pressureUnit} options=${settings.pressureUnits} onChange=${value => set('pressureUnit', { value })} />
    <//>
    <${Note}>Boost and other pressures in kPa, bar or psi. You can still pick other units per parameter in the Logger.<//>

    <${Row} label="Logs folder">
      <${Path} path=${settings.logsFolder} />
      <${Button} onClick=${() => send('settings.chooseLogsFolder')}>Change…<//>
    <//>

    <${SwitchRow} label="Connect automatically when SubieScope opens" checked=${settings.autoConnect} onChange=${flip('autoConnect')} />

    <${SwitchRow} label="Check for updates automatically" checked=${settings.autoUpdateCheck} onChange=${flip('autoUpdateCheck')} />
    <${Note}>Once a day when SubieScope opens, it asks GitHub for the newest version and tells you when there is one. Nothing about you or your car is sent. You can always look yourself with Check for Updates on the About tab.<//>

    ${obd && html`
      <${SwitchRow} label="Extended values (experimental)" checked=${settings.extendedValues} onChange=${flip('extendedValues')} />
      <${Note}>Asks the car for manufacturer specific values such as AVCS (VVT) angles, knock and boost control, using OBD-II Mode 22. It is meant for Subarus from about 2015, including cars with the FA20 or FA24 engine. It might work on yours, but it has not been tested on a real car yet. The values come from community data, so check them against what you expect. Nothing is shown when your car does not answer.<//>
    `}

    <${SwitchRow} label="Advanced mode (ROM reading and editing)" checked=${settings.advancedMode}
      onChange=${on => on ? send('rom.showDisclaimer') : set('advancedMode', { on: false })} />
    <${Note}>Unlocks the ROM Editor: opening and editing a ROM file (an ECU tune) on your ${computer}, and reading the ROM from the car with an OBDLink adapter or a Tactrix OpenPort. It never writes to the car. It is risky and for advanced users, so you have to accept a warning before it turns on.<//>

    <${SwitchRow} label="Let the command line tool control the app (developer)" checked=${settings.remoteControl} onChange=${flip('remoteControl')} />
    <${Note}>Lets programs you run on this ${computer} send read-only requests to the connected adapter through subiescope-cli. Off by default. Nothing that clears codes or writes to the car gets through.<//>

    ${!obd && html`
      ${settings.openPortIsSetting && html`
        <${SwitchRow} label="Tactrix OpenPort 2.0 cable (experimental)" checked=${settings.openPort} disabled=${settings.connected} onChange=${flip('openPort')} />
        <${Note}>${settings.openPortNote}<//>
      `}

      ${settings.openPort && html`
        <${Row} label="Tactrix OpenPort 2.0 talks over">
          <${Segmented} value=${settings.openPortCAN ? 'can' : 'kline'} disabled=${settings.connecting}
            options=${[{ value: 'kline', label: 'K-line' }, { value: 'can', label: 'CAN (experimental)' }]}
            onChange=${value => set('openPortCAN', { on: value === 'can' })} />
        <//>
        <${Note}>${settings.openPortCANNote}<//>
      `}

      <${SwitchRow} label="Fast poll (continuous mode)" checked=${settings.fastPoll} onChange=${flip('fastPoll')} />
      <${Note}>The ECU keeps sending values without being asked each time, roughly doubling the sample rate. Turn it off if logging stalls.<//>
    `}
  </div>`;
}

// Wideband

function Wideband() {
  const wideband = useSlice('settings.wideband');
  // A serial adapter that was plugged in a moment ago should be in the list.
  useEffect(() => { send('settings.refreshPorts'); }, []);
  if (!wideband) return null;
  return html`<div class="group settings-form">
    <${SwitchRow} label="Log an AEM wideband gauge (experimental)" checked=${wideband.on} onChange=${flip('wideband')} />
    <${Note}>Reads a separate AEM wideband air/fuel gauge through its serial output and adds it to the Dashboard, the Logger and your recorded logs, next to the values from the car. For the X-Series (30-0300) and the UEGO gauges (30-4100, 30-4110), set to AFR or lambda. Not tested with a real gauge yet.<//>
    ${wideband.on && html`
      <${Row} label="Gauge port">
        <${Select} value=${wideband.selectedPort || ''} disabled=${wideband.portLocked} onChange=${value => set('widebandPort', { value })}
          options=${[{ value: '', label: 'Choose a port' }, ...wideband.ports.map(port => ({ value: port.id, label: port.label }))]} />
      <//>
      <${Note}>The gauge needs a USB to RS-232 serial adapter of its own: the cable or adapter that goes to the car can't be shared. Connect the gauge's blue wire to pin 2 (receive) of the adapter's 9-pin plug, and pin 5 (ground) to the gauge's ground.<//>
      <${Row} label="Status">
        <span class=${wideband.hasProblem ? 'orange' : 'secondary'}>${wideband.status}</span>
      <//>
      <${Note}>The gauge is in the Logger as "AEM Wideband A/F", already ticked. Add it to the Dashboard from there with the gauge button.<//>
    `}
  </div>`;
}

// Definitions

function Definitions() {
  const definitions = useSlice('settings.definitions');
  if (!definitions) return null;
  const loaded = definitions.loaded;
  return html`<div class="group settings-form">
    ${loaded && html`
      <${Row} label="Loaded"><span class="secondary selectable">${loaded.file}</span><//>
      <${Row} label="Version"><span class="secondary selectable">${loaded.version}</span><//>
      <${Row} label="Contents"><span class="secondary">${loaded.contents}</span><//>
    `}
    ${definitions.error && html`<div class="group-row red selectable">${definitions.error}</div>`}
    <div class="group-row wrap">
      <${Button} onClick=${() => send('settings.chooseDefinitions')}>Choose Definition File…<//>
      <${Button} onClick=${() => send('settings.useDownloadedDefinitions')}>Use Downloaded<//>
      <${Button} disabled=${definitions.downloading} onClick=${() => send('settings.downloadDefinitions')}>
        ${definitions.downloading ? 'Downloading…' : 'Download Again'}
      <//>
    </div>
    <${Note}>SubieScope reads RomRaider logger definitions (logger_METRIC_EN_v370.xml or newer). Newer files add ECU IDs and parameters.<//>
    <div class="group-row"><${Link} href="https://www.romraider.com/forum/post66788.html">RomRaider logger definitions<//></div>
  </div>`;
}

// About, with what the Mac app has in its SubieScope and Help menus

function AboutTab() {
  const about = useSlice('settings.about');
  if (!about) return null;
  return html`<div class="settings-about">
    <${AppIcon} size=${80} />
    <div class="column center" style="gap: 3px">
      <div class="title2 settings-semibold">SubieScope</div>
      <div class="callout secondary selectable">${about.version}</div>
    </div>
    <div class="secondary settings-about-text">SSM logging, diagnostics and a virtual dyno for Subarus. SubieScope is free: if it saves you a trip to the dealer, you can buy me a coffee.</div>
    <${Button} kind="prominent" size="large" icon="coffee" title=${about.coffeeLink} onClick=${() => send('app.open', { url: about.coffeeLink })}>Buy Me a Coffee<//>

    <div class="group settings-form settings-about-more">
      <${Row} label="Updates">
        ${about.checkingForUpdates && html`<${Spinner} />`}
        <${Button} disabled=${about.checkingForUpdates} title="Asks GitHub for the newest version of SubieScope"
          onClick=${() => send('settings.checkForUpdates')}>Check for Updates…<//>
      <//>
      <${Row} label="Help">
        <${Link} href=${about.repositoryLink}>SubieScope on GitHub<//>
        <${Link} href=${about.issuesLink}>Report a Problem…<//>
      <//>
      <${Row} label="Diagnostic report">
        <${Button} title=${about.sendReportHelp} onClick=${() => send('settings.sendReport')}>Send…<//>
        <${Button} title="Saves the report as a file, where you choose" onClick=${() => send('settings.saveReport')}>Save…<//>
        <${Button} title="The log file SubieScope keeps of what it does" onClick=${() => send('settings.showLog')}>${about.showLogLabel}<//>
      <//>
    </div>

    <span class="spacer"></span>
    <div class="caption tertiary">Parameter definitions from the RomRaider project. Not affiliated with Subaru.</div>
  </div>`;
}

// The sheet with its tabs

const tabs = [
  { id: 'general', label: 'General', icon: 'settings' },
  { id: 'wideband', label: 'Wideband', icon: 'gauge' },
  { id: 'definitions', label: 'Definitions', icon: 'file-text' },
  { id: 'about', label: 'About', icon: 'info' },
];
// Opened again, Settings shows the tab it was closed on, as the Mac's Settings window does.
let lastTab = 'general';

/** The Settings window, as a sheet. `onClose` closes it. */
export function Settings({ onClose }) {
  const settings = useSlice('settings');
  const app = useSlice('app');
  const [tab, setTab] = useState(lastTab);
  const choose = id => { lastTab = id; setTab(id); };
  // Asked for (Ctrl+comma) while another sheet has to be answered first: not now, and not later by surprise.
  useEffect(() => { if ((peek('settings') || {}).steppedAside) onClose(); }, []);
  // While a sheet the app asks for is up (the connection type, the warning before Advanced mode,
  // a new version, …) Settings steps aside, and is back when that sheet is answered.
  if (!settings || !app || settings.steppedAside) return null;
  return html`<${Sheet} width=${560} onClose=${onClose} class="settings-sheet">
    <div class="settings-header">
      <div class="settings-tabs" role="tablist">
        ${tabs.map(item => html`<button key=${item.id} role="tab" aria-selected=${item.id === tab}
            class=${cls('settings-tab', { selected: item.id === tab })} onClick=${() => choose(item.id)}>
          <${Icon} name=${item.icon} /><span>${item.label}</span>
        </button>`)}
      </div>
      <${Button} class="settings-done" onClick=${onClose}>Done<//>
    </div>
    <div class="settings-body" key=${tab}>
      ${tab === 'general' ? html`<${General} settings=${settings} computer=${app.computer} />`
        : tab === 'wideband' ? html`<${Wideband} />`
        : tab === 'definitions' ? html`<${Definitions} />`
        : html`<${AboutTab} />`}
    </div>
  <//>`;
}

// A new version

// Bold, code, links and italics inside a line of release notes, as GitHub shows them.
const marks = /\*\*(.+?)\*\*|`([^`]+)`|\[([^\]]+)\]\((https?:[^)\s]+)\)|\*([^*\s][^*]*)\*/g;

function inline(text) {
  const parts = [];
  let last = 0;
  for (const found of text.matchAll(marks)) {
    if (found.index > last) parts.push(text.slice(last, found.index));
    if (found[1] !== undefined) parts.push(html`<strong>${inline(found[1])}</strong>`);
    else if (found[2] !== undefined) parts.push(html`<code>${found[2]}</code>`);
    else if (found[3] !== undefined) parts.push(html`<${Link} href=${found[4]}>${inline(found[3])}<//>`);
    else parts.push(html`<em>${inline(found[5])}</em>`);
    last = found.index + found[0].length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return parts;
}

/** Release notes close to how GitHub shows them: paragraphs, "- " lists and headings. */
function ReleaseNotes({ markdown }) {
  const lines = markdown.split('\n').map(line => line.trim()).filter(line => line);
  return html`<div class="settings-notes-text">
    ${lines.map(line => line.startsWith('- ') || line.startsWith('* ')
      ? html`<div class="settings-bullet"><span class="secondary">•</span><span>${inline(line.slice(2))}</span></div>`
      : line.startsWith('#') ? html`<div class="headline">${inline(line.replace(/^[# ]+/, ''))}</div>`
      : html`<div>${inline(line)}</div>`)}
  </div>`;
}

/** Calls `onEnter` for the Enter key, unless it is pressed on a button or a link, which it presses itself. */
function useEnter(onEnter) {
  useEffect(() => {
    const key = event => {
      if (event.key !== 'Enter' || event.repeat || (event.target.closest && event.target.closest('button, a, input, select, textarea'))) return;
      event.preventDefault();
      onEnter();
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, []);
}

/** "A new version is available": what changed and how to get it. */
function UpdateSheet({ update }) {
  const later = () => send('settings.postponeUpdate');
  const download = () => send('settings.downloadUpdate');
  useEnter(download);
  return html`<${Sheet} width=${580} onClose=${later}>
    <div class="settings-update">
      <div class="row" style="gap: 14px">
        <${AppIcon} size=${56} />
        <div class="column" style="gap: 2px">
          <div class="title2 settings-semibold">SubieScope ${update.version} is available</div>
          <div class="secondary">${update.current}</div>
        </div>
      </div>
      ${update.whatsNew && html`<div class="column" style="gap: 6px; min-height: 0">
        <div class="headline">What's new</div>
        <div class="settings-notes selectable"><${ReleaseNotes} markdown=${update.whatsNew} /></div>
      </div>`}
      <div class="callout secondary">${update.instructions}</div>
      <div class="row">
        <${Button} onClick=${() => send('settings.skipUpdate')}>Skip This Version<//>
        <span class="spacer"></span>
        <${Button} onClick=${later}>Later<//>
        <${Button} kind="prominent" onClick=${download}>${update.downloadLabel}<//>
      </div>
    </div>
  <//>`;
}

// After a crash

/** The last run ended badly: the offer to send a report. */
function CrashQuestion({ crash }) {
  const answer = report => send('settings.answerCrash', { send: report });
  useEnter(() => answer(true));
  useEffect(() => {
    const key = event => { if (event.key === 'Escape') answer(false); };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, []);
  return html`<${Alert} title=${crash.title} buttons=${[
    { label: 'Send Report…', kind: 'prominent', onClick: () => answer(true) },
    { label: 'Not Now', onClick: () => answer(false) },
  ]}>${crash.message}<//>`;
}

/** Sheets that come up by themselves: a new version to install, the question after a crash. */
export function SettingsSheets() {
  const update = useSlice('settings.update');
  const crash = useSlice('settings.crash');
  return html`
    ${update && html`<${UpdateSheet} update=${update} />`}
    ${crash && html`<${CrashQuestion} crash=${crash} />`}`;
}
