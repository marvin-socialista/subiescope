import { useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { peek, send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Select, Spinner, Sheet, Link } from '../ui.js';

/**
 * Everything about getting connected that is not the main window: the "How to connect" panel of the
 * connection card, and the sheets of the first start (setup wizard, cable setup, which connection to choose).
 *
 * The app says what is shown (Bridge+Setup.swift): where the wizard is, which cables and adapters
 * there are, how a test went, and every text that is worded differently on a PC than on a Mac.
 * What is the same everywhere is written out here.
 */

const modeIcon = { ssm: 'cable', obd: 'radio' };

/** Enter does what the main button does, as with the default button of a sheet in the Mac app. */
function useEnter(action, enabled) {
  const latest = useRef(action);
  latest.current = action;
  useEffect(() => {
    if (!enabled) return;
    const key = event => {
      if (event.key !== 'Enter' || event.defaultPrevented || event.isComposing) return;
      // In a field to type in, Enter belongs to the field.
      const tag = event.target && event.target.tagName;
      if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA') return;
      // A button that was clicked before keeps the focus: Enter must not press it again.
      event.preventDefault();
      latest.current();
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [enabled]);
}

// MARK: Pieces the screens share

/** A warning in an orange box: Bluetooth is off, the connection failed. */
function Warning({ children }) {
  return html`<div class="setup-warning callout">
    <${Icon} name="triangle-alert" class="orange" /><div class="grow selectable">${children}</div>
  </div>`;
}

/** How a test went, in green or in orange. */
function Result({ result }) {
  return html`<div class=${cls('setup-result', result.ok ? 'ok' : 'failed')}>
    <${Icon} name=${result.ok ? 'circle-check' : 'triangle-alert'} class=${result.ok ? 'green' : 'orange'} />
    <div class="column grow" style="gap: 3px">
      <div class="headline">${result.title}</div>
      <div class="secondary selectable">${result.detail}</div>
    </div>
  </div>`;
}

/** One numbered step of the cable or adapter checks. The number becomes a green check when it is done. */
function SetupStep({ number, title, done, children }) {
  return html`<div class="setup-step">
    <div class=${cls('setup-step-number', { done })}>${done ? html`<${Icon} name="check" />` : number}</div>
    <div class="column grow" style="gap: 6px">
      <div class="headline">${title}</div>
      ${children}
    </div>
  </div>`;
}

/** A choice with a round mark in front, as in a list of adapters. */
function RadioRow({ selected, disabled, onClick, children, class: extra }) {
  return html`<div class=${cls('setup-radio', { disabled }, extra)} role="radio" aria-checked=${selected} onClick=${disabled ? undefined : onClick}>
    <${Icon} name=${selected ? 'circle-dot' : 'circle'} class=${selected ? 'accent' : 'secondary'} />
    ${children}
  </div>`;
}

/** The address of the Wi-Fi adapter. What is typed goes to the app with every key. */
function WifiField({ address, disabled }) {
  const [text, setText] = useState(address);
  const typing = useRef(false);
  // The app's version wins, except while this field is being typed in.
  useEffect(() => { if (!typing.current) setText(address); }, [address]);
  return html`<input class="field" style="width: 160px" type="text" spellcheck=${false} value=${text} disabled=${disabled}
    placeholder="192.168.0.10:35000" title="Address and port of the adapter. Nearly all Wi-Fi adapters use 192.168.0.10:35000."
    onFocus=${() => { typing.current = true; }} onBlur=${() => { typing.current = false; }}
    onInput=${event => { setText(event.target.value); send('setup.wifiAddress', { address: event.target.value }); }} />`;
}

/** USB adapters and the Wi-Fi adapter as choices. Both are experimental. */
function OtherAdapterRows({ adapters }) {
  const choose = id => send('app.selectDevice', { id });
  return html`
    ${adapters.ports.map(port => html`<${RadioRow} key=${port.id} selected=${port.selected} disabled=${adapters.locked} onClick=${() => choose(port.id)}>
      <span class="callout truncate grow" title=${port.name}>${port.name}</span>
    <//>`)}
    ${adapters.noPortsNote && html`<div class="caption secondary">${adapters.noPortsNote}</div>`}
    <div class="row">
      <${RadioRow} selected=${adapters.wifi.selected} disabled=${adapters.locked} onClick=${() => choose(adapters.wifi.id)} class="grow">
        <span class="callout truncate">${adapters.wifi.name}</span>
      <//>
      <${WifiField} address=${adapters.wifiAddress} disabled=${adapters.locked} />
    </div>
    <div class="caption secondary">${adapters.experimentalNote}</div>`;
}

/** The Bluetooth adapters that were found. `limit` is how many fit; `note` is what an OBD-II adapter is marked with. */
function BluetoothRows({ adapters, limit, note, large }) {
  return adapters.bluetoothAdapters.slice(0, limit).map(adapter => html`<${RadioRow} key=${adapter.id} selected=${adapter.selected}
      disabled=${adapters.locked} onClick=${() => send('app.selectDevice', { id: adapter.id })}>
    <span class=${cls('truncate grow', { callout: !large })} style=${{ fontWeight: adapter.looksLikeOBD ? 500 : 400 }}>${adapter.name}</span>
    ${adapter.looksLikeOBD && html`<span class="caption secondary">${note}</span>`}
  <//>`);
}

// MARK: The panel of the connection card

function PanelSection({ title, icon, children }) {
  return html`<div class="setup-section">
    <div class="setup-section-title"><${Icon} name=${icon} />${title}</div>
    ${children}
  </div>`;
}

function ChecklistRow({ check }) {
  return html`<div class="setup-check">
    <${Icon} name=${check.done ? 'circle-check' : 'circle'} class=${check.done ? 'green' : 'secondary'} />
    <div class="column grow" style="gap: 2px">
      <div class="callout">${check.text}</div>
      <div class="caption secondary">${check.detail}</div>
    </div>
  </div>`;
}

/** The adapters to choose from in OBD-II mode. */
function PanelAdapters({ adapters }) {
  // A PC cannot use Bluetooth LE: there the adapters that do work are one list.
  if (!adapters.bluetooth) {
    return html`<${PanelSection} title="USB, Wi-Fi or paired Bluetooth adapter (experimental)" icon="cable">
      <${OtherAdapterRows} adapters=${adapters} />
    <//>`;
  }
  return html`
    <${PanelSection} title="Bluetooth adapter" icon="radio">
      ${adapters.bluetoothProblem ? html`
        <div class="setup-label callout"><${Icon} name="triangle-alert" class="orange" /><div class="grow">${adapters.bluetoothProblem}</div></div>
      ` : adapters.bluetoothAdapters.length === 0 ? html`
        <div class="row"><${Spinner} /><span class="secondary">Looking for adapters nearby…</span></div>
        <div class="caption secondary">An adapter only shows up while it is plugged into a car with the ignition ON.</div>
      ` : html`<${BluetoothRows} adapters=${adapters} limit=${6} note="OBD-II" />`}
    <//>
    <${PanelSection} title="USB or Wi-Fi adapter (experimental)" icon="cable">
      <${OtherAdapterRows} adapters=${adapters} />
    <//>`;
}

/** The cables that were found in SSM mode, and which port to use when there is more than one. */
function PanelCables({ app, panel }) {
  return html`<${PanelSection} title="Cable" icon="cable">
    ${panel.noCable ? html`<div class="secondary">${panel.noCable}</div>` : html`
      ${(panel.cables || []).map(cable => html`<div key=${cable.id} class="column" style="gap: 2px">
        <div class="callout" style="font-weight: 500">${cable.title}</div>
        <div class=${cls('caption', cable.needsDriver ? 'orange' : 'secondary')}>${cable.text}</div>
        ${cable.offerOpenPort && html`<div><${Button} size="small" disabled=${app.connection === 'connected'}
          onClick=${() => send('setup.openPortOn')}>Turn On OpenPort Support<//></div>`}
      </div>`)}
      ${panel.portChoices.length > 0 && html`<div class="row">
        <span>Use</span>
        <${Select} class="grow" value=${app.selectedDevice} onChange=${id => send('app.selectDevice', { id })}
          options=${panel.portChoices.map(port => ({ value: port.id, label: port.label }))} />
      </div>`}
    `}
  <//>`;
}

/** The panel that opens from the connection card. `onClose` closes it. */
export function ConnectionPanel({ onClose }) {
  const app = useSlice('app');
  const panel = useSlice('setup.panel');
  const live = useSlice('setup.panel.live');
  const adapters = useSlice('setup.adapter');
  // A cable that was plugged in a moment ago is there when the panel opens.
  useEffect(() => { send('setup.panelOpened'); }, []);
  const connected = app && app.connection === 'connected';
  const connecting = app && app.connection === 'connecting';
  const canConnect = app && !connected && !connecting && app.canConnect;
  useEnter(() => send('app.connect'), canConnect);
  if (!app || !panel) return html`<div class="setup-panel"></div>`;
  const status = panel.status;
  const colour = status.color === 'gray' ? 'var(--text-2)' : `var(--${status.color})`;
  const obd = app.mode === 'obd';

  return html`<div class="setup-panel">
    <div class="row" style="gap: 10px">
      <span class=${cls('dot', { 'setup-dot-ring': connected })} style=${{ color: colour }}></span>
      <div class="column grow" style="gap: 2px">
        <div class="title3">${status.title}</div>
        <div class="callout secondary">${status.detail}</div>
      </div>
    </div>

    <div class="row">
      <${Icon} name=${modeIcon[app.mode]} />
      <span class="callout grow" style="font-weight: 500">${panel.modeLine}</span>
      <${Button} size="small" disabled=${!panel.canChangeMode} title="Switch between the Subaru SSM cable and an OBD-II adapter"
        onClick=${() => { onClose(); send('setup.showModeChooser'); }}>Change…<//>
    </div>

    ${obd && adapters && html`<${PanelAdapters} adapters=${adapters} />`}
    ${!obd && html`<${PanelCables} app=${app} panel=${panel} />`}

    <${PanelSection} title="Car" icon="car">
      ${panel.facts.length > 0 ? html`
        ${panel.facts.map(fact => html`<div key=${fact.label} class=${cls('setup-fact callout', { mono: fact.mono })}>
          <span>${fact.label}</span><span class="secondary selectable">${fact.value}</span>
        </div>`)}
        <div class="setup-fact callout"><span>Speed</span><span class="secondary digits">${live ? live.speed : ''}</span></div>
      ` : html`
        <div class="callout headline">How to connect</div>
        ${panel.checklist.map((check, index) => html`<${ChecklistRow} key=${index} check=${check} />`)}
      `}
    <//>

    ${panel.widebandOn && live && live.wideband && html`<${PanelSection} title="Wideband gauge" icon="gauge">
      <div class=${cls('callout', live.widebandProblem ? 'orange' : 'secondary')}>${live.wideband}</div>
    <//>`}

    ${app.connectionError && html`<${Warning}>${app.connectionError}<//>`}

    <div class="row">
      ${!obd && html`<${Button} onClick=${() => { onClose(); send('setup.showCableSetup'); }}>Cable Setup…<//>`}
      ${!connected && html`<${Button} disabled=${connecting} onClick=${() => { onClose(); send('setup.useDemoCar'); }}>Use Demo Car<//>`}
      <span class="spacer"></span>
      ${connected ? html`<${Button} onClick=${() => send('app.disconnect')}>Disconnect<//>`
        : html`<${Button} kind="prominent" disabled=${!canConnect} onClick=${() => send('app.connect')}>
            ${connecting ? html`<${Spinner} />` : 'Connect'}
          <//>`}
    </div>
  </div>`;
}

// MARK: The cable checks

function CableRow({ cable }) {
  return html`<div class="setup-cable">
    <div class="row" style="gap: 6px">
      <${Icon} name=${cable.hasPort ? 'circle-check' : 'circle-alert'} class=${cable.usable ? 'green' : 'orange'} />
      <span style="font-weight: 500">${cable.name}</span>
      <span class="secondary">· ${cable.chip}</span>
    </div>
    <div class="callout secondary">${cable.text}</div>
    ${cable.driverURL && html`<div class="row" style="gap: 12px">
      <${Link} href=${cable.driverURL}>Get the driver<//>
      ${cable.settingsButton && html`<${Button} kind="link" onClick=${() => send('setup.openDriverSettings')}>${cable.settingsButton}<//>`}
    </div>`}
    ${cable.tip && html`<div class="caption orange">${cable.tip}</div>`}
  </div>`;
}

/** Find the cable, plug it into the car, test the connection. In the Cable Setup sheet and in the wizard. */
function CableSteps() {
  const cable = useSlice('setup.cable');
  // Keeps looking for a cable that is plugged in while the steps are on the screen.
  useEffect(() => {
    send('setup.scanCables');
    const timer = setInterval(() => send('setup.scanCables'), 1500);
    return () => clearInterval(timer);
  }, []);
  if (!cable) return null;
  return html`<div class="column" style="gap: 18px">
    <${SetupStep} number=${1} title=${cable.plugTitle} done=${cable.cables.length > 0}>
      ${cable.cables.length === 0
        ? html`<div class="secondary">Waiting for a USB cable… Use a USB-C adapter if needed. SubieScope keeps looking.</div>`
        : cable.cables.map(item => html`<${CableRow} key=${item.id} cable=${item} />`)}
    <//>
    <${SetupStep} number=${2} title="Plug it into the car and turn the ignition ON" done=${cable.passed}>
      <div class="secondary">The OBD port is under the dashboard on the driver's side. The engine may be off or running. If your cable has a switch, set it to K-line on pin 7 (often labelled "VAG" or "1").</div>
    <//>
    <${SetupStep} number=${3} title="Test the connection" done=${cable.passed}>
      <div class="row">
        <${Button} kind="prominent" icon="zap" disabled=${!cable.canTest} onClick=${() => send('setup.testCable')}>${cable.testing ? 'Testing…' : 'Test Connection'}<//>
        ${cable.testing && html`<${Spinner} />`}
        ${cable.connected && html`<span class="secondary">Already connected.</span>`}
      </div>
      ${cable.result && html`<${Result} result=${cable.result} />`}
    <//>
  </div>`;
}

/** Cable Setup: the cable checks, on their own. */
function CableSetup() {
  const cable = useSlice('setup.cable');
  const passed = cable && cable.passed;
  const close = () => send('setup.closeCableSetup');
  const connect = () => send('setup.closeCableSetup', { connect: true });
  useEnter(connect, passed);
  return html`<${Sheet} width=${560} onClose=${close} class="setup-sheet setup-cable-sheet">
    <div class="row" style="gap: 12px">
      <${Icon} name="cable" size=${28} class="accent" />
      <div class="column" style="gap: 2px">
        <div class="title2">Cable Setup</div>
        <div class="secondary">Three quick steps to connect to your Subaru.</div>
      </div>
    </div>
    <div class="setup-scroll"><${CableSteps} /></div>
    <div class="row">
      <${Button} onClick=${() => send('setup.closeCableSetup', { demo: true })}>Use the Demo Car Instead<//>
      <span class="spacer"></span>
      <${Button} onClick=${close}>Close<//>
      ${passed && html`<${Button} kind="prominent" onClick=${connect}>Connect<//>`}
    </div>
  <//>`;
}

// MARK: The adapter checks

/** Plug in, find the adapter, test. The wizard's version of the cable checks for OBD-II. */
function AdapterSteps() {
  const adapters = useSlice('setup.adapter');
  const [others, setOthers] = useState(() => { const now = peek('setup.adapter'); return !!(now && now.othersOpen); });
  useEffect(() => { send('setup.adapterSteps'); }, []);
  if (!adapters) return null;

  let finding;
  if (!adapters.bluetooth) {
    // A PC cannot use Bluetooth LE: say what works there, and offer that.
    finding = html`
      <div class="secondary">${adapters.pcNote}</div>
      <${OtherAdapterRows} adapters=${adapters} />
      <div class="caption secondary">${adapters.wifiNote}</div>`;
  } else {
    finding = html`
      ${adapters.bluetoothNotAsked ? html`
        <div class="secondary">The first time, macOS asks whether SubieScope may use Bluetooth. Please say yes: it is only used to talk to your adapter.</div>
        <div><${Button} kind="prominent" onClick=${() => send('setup.lookForAdapters')}>Look for adapters<//></div>
      ` : adapters.bluetoothProblem ? html`
        <${Warning}>${adapters.bluetoothProblem}<//>
        <div><${Button} onClick=${() => send('setup.retryBluetooth')}>Try again<//></div>
      ` : adapters.bluetoothAdapters.length === 0 ? html`
        <div class="row"><${Spinner} /><span class="secondary">Looking for adapters nearby…</span></div>
        <div class="caption secondary">An adapter only shows up while it is plugged into a car with the ignition ON. Vgate iCar Pro adapters often appear as "IOS-Vlink" or "vLinker".</div>
      ` : html`<${BluetoothRows} adapters=${adapters} limit=${8} note="Looks like an OBD-II adapter" large />`}
      <div class="setup-disclosure callout" onClick=${() => setOthers(!others)}>
        <${Icon} name=${others ? 'chevron-down' : 'chevron-right'} />I have a USB or Wi-Fi adapter (experimental)
      </div>
      ${others && html`<div class="column setup-disclosed">
        <${OtherAdapterRows} adapters=${adapters} />
        <div class="caption secondary">${adapters.wifiNote}</div>
      </div>`}`;
  }

  return html`<div class="column" style="gap: 18px">
    <${SetupStep} number=${1} title="Plug the adapter into the car and turn the ignition ON" done=${adapters.pluggedIn}>
      <div class="secondary">The OBD port is under the dashboard on the driver's side. The engine may be off or running. The adapter's light comes on. Close other apps that use the adapter (also on your phone): it accepts one connection at a time.</div>
    <//>
    <${SetupStep} number=${2} title=${adapters.bluetooth ? 'Look for your adapter' : 'Choose your adapter'} done=${adapters.chosen}>
      ${finding}
    <//>
    <${SetupStep} number=${3} title="Test the connection" done=${adapters.connected}>
      <div class="row">
        <${Button} kind="prominent" icon="zap" disabled=${!adapters.canTest} onClick=${() => send('app.connect')}>${adapters.connecting ? 'Connecting…' : 'Test Connection'}<//>
        ${adapters.connecting && html`<${Spinner} />`}
      </div>
      ${adapters.result && html`<${Result} result=${adapters.result} />`}
    <//>
  </div>`;
}

// MARK: The two connection types side by side

function Bullets({ title, items, icon, colour }) {
  return html`<div class="column" style="gap: 5px">
    <div class="setup-card-heading">${title}</div>
    ${items.map(item => html`<div key=${item} class="setup-label callout"><${Icon} name=${icon} class=${colour} /><div class="grow">${item}</div></div>`)}
  </div>`;
}

function ModeCard({ card, onChoose }) {
  const obd = card.mode === 'obd';
  return html`<div class=${cls('setup-card', { current: card.isCurrent })}>
    <div class="row" style="gap: 10px">
      <${Icon} name=${modeIcon[card.mode]} size=${22} class="accent" style=${{ margin: '0 4px' }} />
      <div class="column grow" style="gap: 1px">
        <div class="row" style="gap: 6px">
          <span class="title3">${card.title}</span>
          ${card.isNew && html`<span class="setup-new">NEW</span>`}
        </div>
        <div class="caption secondary">${card.hardware}</div>
      </div>
    </div>
    <div class="column" style="gap: 12px">
      <div class="setup-card-heading">Best for</div>
      <div class="callout" style="font-weight: 500">${card.bestFor}</div>
    </div>
    <${Bullets} title="You get" items=${card.gets} icon="circle-check" colour="green" />
    ${card.missing.length > 0 && html`<${Bullets} title="What you don't get" items=${card.missing} icon="circle-minus" colour="orange" />`}
    <div class="column" style="gap: 3px">
      <div class="setup-card-heading">You need</div>
      <div class="callout">${card.needs}</div>
    </div>
    <div class="column" style="gap: 5px">
      <div class="setup-card-heading">Which cars</div>
      ${card.cars.map(car => html`<div key=${car.name}>
        <div class="caption" style="font-weight: 500">${car.name}</div>
        <div class="caption secondary">${car.note}</div>
      </div>`)}
    </div>
    ${obd && html`<div class="caption secondary">OBD-II mode is new and tested with a simulated car. Please tell me how it works on yours.</div>`}
    <span class="spacer" style="min-height: 4px"></span>
    <${Button} kind="prominent" size="large" wide onClick=${() => onChoose(card.mode)}>${card.button}<//>
  </div>`;
}

function ModeComparison({ setup, onChoose }) {
  return html`<div class="setup-cards">
    ${setup.cards.map(card => html`<${ModeCard} key=${card.mode} card=${card} onChoose=${onChoose} />`)}
  </div>`;
}

/** "How do you connect to your car?": what each type gives you, what it needs and which cars it fits. */
function ModeChooser({ setup }) {
  const close = setup.canCloseModeChooser ? () => send('setup.closeModeChooser') : undefined;
  return html`<${Sheet} width=${820} onClose=${close} class="setup-sheet setup-chooser">
    <div class="row" style="gap: 12px">
      <${Icon} name="car" size=${28} class="accent" />
      <div class="column grow" style="gap: 2px">
        <div class="title2">How do you connect to your car?</div>
        <div class="secondary">${setup.chooserSubtitle}</div>
      </div>
    </div>
    <div class="setup-scroll">
      <${ModeComparison} setup=${setup} onChoose=${mode => send('setup.chooseMode', { mode })} />
    </div>
    <div class="setup-tip callout"><${Icon} name="lightbulb" class="yellow" /><div class="grow">${setup.notSure}</div></div>
    <div class="row">
      <span class="spacer"></span>
      ${close && html`<${Button} onClick=${close}>Close<//>`}
    </div>
  <//>`;
}

// MARK: The wizard

const cars = [
  ['olderSubaru', 'A Subaru up to about 2014', 'Impreza, WRX, STI, Legacy, Outback, Forester, Baja, Tribeca'],
  ['newerSubaru', 'A newer Subaru (about 2015 and up)', 'WRX or STI (VA), Levorg, XV / Crosstrek, Forester (SJ and newer), BRZ / GR86 and others'],
  ['otherBrand', 'Another brand', 'Any car built since about 2008'],
  ['notSure', "I'm not sure", "We'll help you find out"],
];

function Welcome({ wizard }) {
  const point = (icon, title, detail) => html`<div class="setup-label">
    <${Icon} name=${icon} class="accent" style=${{ margin: '1px 4px 0' }} />
    <div class="grow"><span style="font-weight: 500">${title}</span><span class="secondary"> ${detail}</span></div>
  </div>`;
  return html`<div class="column" style="gap: 16px">
    <div class="title2">${wizard.welcomeTitle}</div>
    <div class="secondary">${wizard.welcomeText}</div>
    <div class="column" style="gap: 10px; padding-top: 4px">
      ${point('car', 'Tell us which car you have', 'so we can recommend the right connection.')}
      ${point('cable', 'Plug in and test', "with clear steps, and help if something doesn't work.")}
      ${point('circle-play', 'No hardware yet?', 'You can try everything with a simulated demo car.')}
    </div>
  </div>`;
}

function CarQuestion({ wizard }) {
  const advice = wizard.recommendation;
  return html`<div class="column" style="gap: 14px">
    <div class="secondary">This decides which connection you need. Both plug into the same port under the dashboard.</div>
    <div class="column" style="gap: 8px">
      ${cars.map(([choice, title, detail]) => html`<div key=${choice} class=${cls('setup-car', { selected: wizard.carChoice === choice })}
          role="radio" aria-checked=${wizard.carChoice === choice} onClick=${() => send('setup.wizardCar', { choice })}>
        <${Icon} name=${wizard.carChoice === choice ? 'circle-dot' : 'circle'} class=${wizard.carChoice === choice ? 'accent' : 'secondary'} />
        <div class="column grow" style="gap: 2px">
          <div style="font-weight: 500">${title}</div>
          <div class="caption secondary">${detail}</div>
        </div>
      </div>`)}
    </div>
    ${wizard.carChoice === 'notSure' && html`<div class="setup-tip callout" style="padding: 12px">
      <${Icon} name="lightbulb" class="yellow" />
      <div class="grow">Check the year on the registration papers, or the sticker in the driver's door frame. The older WRX and STI (hatchback or sedan with a 2.0 or 2.5 litre boxer, up to 2014) are in the first group. The sedan that came in 2015 (the VA) is in the second.</div>
    </div>`}
    ${advice && html`<div class="setup-recommendation">
      <div class="row"><${Icon} name=${modeIcon[advice.mode]} class="accent" /><span class="headline">${advice.title}</span></div>
      <div class="callout">${advice.text}</div>
      <${Button} kind="link" class="callout" onClick=${() => send('setup.wizardPrefer', { mode: advice.otherMode })}>${advice.otherLabel}<//>
    </div>`}
    <${Button} kind="link" onClick=${() => send('setup.wizardCompare', { on: true })}>Compare both options in detail<//>
  </div>`;
}

function Comparison({ setup }) {
  return html`<div class="column" style="gap: 12px">
    <${Button} kind="link" icon="chevron-left" onClick=${() => send('setup.wizardCompare', { on: false })}>Back to the question<//>
    <${ModeComparison} setup=${setup} onChoose=${mode => send('setup.wizardChoose', { mode })} />
  </div>`;
}

function ConnectStep({ wizard }) {
  return html`<div class="column" style="gap: 18px">
    ${wizard.connectMode === 'obd' ? html`<${AdapterSteps} />` : html`<${CableSteps} />`}
    <div class="divider"></div>
    <div class="row callout" style="gap: 10px">
      <${Icon} name="circle-play" class="secondary" />
      <span class="secondary">${wizard.demoQuestion}</span>
      <${Button} kind="link" onClick=${() => send('setup.wizardDemo')}>Try the demo car<//>
    </div>
  </div>`;
}

function DoneStep({ wizard, setup }) {
  const open = url => send('app.open', { url });
  return html`<div class="column" style="gap: 18px">
    <div class=${cls('setup-box', wizard.doneConnected ? 'setup-box-green' : 'setup-box-blue')}>
      <div class="setup-label">
        <${Icon} name=${wizard.doneConnected ? 'circle-check' : 'info'} size=${22} class=${wizard.doneConnected ? 'green' : 'accent'} />
        <div class="column grow" style="gap: 3px">
          <div class="headline">${wizard.doneTitle}</div>
          <div class="secondary">${wizard.doneDetail}</div>
        </div>
      </div>
    </div>
    <div class="setup-box setup-box-orange">
      <div class="row" style="gap: 10px"><${Icon} name="coffee" size=${22} class="orange" /><span class="headline">SubieScope is free</span></div>
      <div>I develop SubieScope for free, in my own time, and I'm happy to keep it that way. If it helps you understand your car, or saves you a trip to the garage, a coffee is always welcome and really appreciated. No pressure at all: the app works exactly the same either way.</div>
      <div class="row">
        <${Button} kind="prominent" tint="orange" icon="coffee" onClick=${() => open(setup.coffeeURL)}>Buy Me a Coffee<//>
        <span class="caption secondary">${wizard.coffeeNote}</span>
      </div>
    </div>
    <div class="setup-label callout setup-feedback" onClick=${() => open(setup.issuesURL)}>
      <${Icon} name="message-square" class="secondary" />
      <div class="grow">Something not working on your car? <span class="accent">Please tell me</span>. Reports of which cars work are very welcome.</div>
    </div>
  </div>`;
}

/** The wizard of the first start: what car do you have, which connection fits it, connect and test it. */
function Wizard({ setup }) {
  const wizard = useSlice('setup.wizard');
  const body = useRef(null);
  const step = wizard && wizard.step;
  // Every step starts at its top.
  useEffect(() => { if (body.current) body.current.scrollTop = 0; }, [step]);
  const next = wizard && wizard.next;
  useEnter(() => send('setup.wizardNext'), !!(next && next.enabled));
  if (!wizard) return null;
  const steps = Array.from({ length: wizard.count }, (unused, index) => index);
  return html`<${Sheet} width=${720} class="setup-sheet setup-wizard">
    <div class="setup-wizard-header">
      <${Icon} name="gauge" size=${26} class="accent" />
      <div class="column grow" style="gap: 2px">
        <div class="title3">${wizard.title}</div>
        <div class="caption secondary">Step ${wizard.index + 1} of ${wizard.count}</div>
      </div>
      <div class="setup-dots" aria-hidden="true">
        ${steps.map(index => html`<span key=${index} class=${cls({ reached: index <= wizard.index, now: index === wizard.index })}></span>`)}
      </div>
    </div>
    <div class="divider"></div>
    <div ref=${body} class="setup-wizard-body">
      ${step === 'welcome' ? html`<${Welcome} wizard=${wizard} />`
        : step === 'car' ? html`<${CarQuestion} wizard=${wizard} />`
        : step === 'compare' ? html`<${Comparison} setup=${setup} />`
        : step === 'connect' ? html`<${ConnectStep} wizard=${wizard} />`
        : html`<${DoneStep} wizard=${wizard} setup=${setup} />`}
    </div>
    <div class="divider"></div>
    <div class="setup-wizard-footer">
      ${wizard.canGoBack && html`<${Button} onClick=${() => send('setup.wizardBack')}>Back<//>`}
      ${wizard.canSkip && html`<${Button} kind="link" class="setup-skip" onClick=${() => send('setup.wizardSkip')}>Skip setup<//>`}
      <span class="spacer"></span>
      ${next && html`<${Button} kind=${next.prominent ? 'prominent' : undefined} disabled=${!next.enabled}
        onClick=${() => send('setup.wizardNext')}>${next.label}<//>`}
    </div>
  <//>`;
}

/** The sheets this part owns. It shows the ones the app asks for, and nothing otherwise. */
export function SetupSheets() {
  const setup = useSlice('setup');
  if (!setup) return null;
  if (setup.showWizard) return html`<${Wizard} setup=${setup} />`;
  if (setup.showModeChooser) return html`<${ModeChooser} setup=${setup} />`;
  if (setup.showCableSetup) return html`<${CableSetup} />`;
  return null;
}
