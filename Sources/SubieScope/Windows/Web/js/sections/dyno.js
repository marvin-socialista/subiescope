import { useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { request, send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Select, Toggle, Checkbox, TextField, SearchField, Sheet, Empty } from '../ui.js';
import { registerIcons } from '../icons.js';
import { DynoCharts } from './dyno-chart.js';

registerIcons({
  'corner-down-right': '<polyline points="15 10 20 15 15 20" /> <path d="M4 4v7a4 4 0 0 0 4 4h12" />',
});

// How a pull's quality looks: the colour, and the icon in front of the verdict.
const qualities = {
  good: { color: 'green', icon: 'circle-check' },
  usable: { color: 'orange', icon: 'circle-alert' },
  retry: { color: 'red', icon: 'rotate-ccw' },
};

const steps = [
  ['Prepare the car', 'Engine fully warm, good fuel, correct tyre pressures. Note how much fuel is in the tank and who is in the car: weight matters.'],
  ['Pick the place', 'A flat, straight, closed road or track without wind. Always use the same stretch so pulls can be compared.'],
  ['Log the right values', 'Press Record a Pull below: SubieScope ticks Engine Speed, Throttle, Speed, boost, knock and fueling for you. You can also tick at least Engine Speed and Throttle in the Logger and press Record.'],
  ['Do the pull', "In 3rd gear (4th is even smoother, but faster) roll along at about 2,500 rpm. Press the throttle smoothly to the floor and hold it until just before the rev limiter. Don't change gear during the pull."],
  ['Lift off and stop', 'Lift off, slow down calmly and stop the recording.'],
  ['Repeat the other way', 'Do a second pull in the opposite direction on the same road. Averaging both cancels out slope and wind.'],
  ['Check the settings', 'Enter the weight with driver and fuel, your tyre size and check the detected gear. The numbers are estimates: use them to compare changes, not to brag.'],
];

/** A heading with a box of rows under it, as in the Mac's forms. */
function Section({ title, children }) {
  return html`<section class="dyno-section">
    <div class="dyno-heading">${title}</div>
    <div class="group">${children}</div>
  </section>`;
}

/**
 * A field for one of the car's numbers. `text` is what the app says it holds; what is typed goes to
 * the app on Enter and when the field is left, and the app answers with what the fields show then
 * (for this one the old number, when what was typed is not a number).
 */
function NumberField({ field, text, width }) {
  const [draft, setDraft] = useState(null);
  const latest = useRef(null);
  latest.current = draft;
  // A new number from the app (after Reset, say) replaces whatever was being typed.
  useEffect(() => setDraft(null), [text]);
  const commit = () => {
    const typed = latest.current;
    if (typed === null) return;
    if (typed === text) { setDraft(null); return; }
    request('dyno.set', { field, text: typed }).then(car => {
      const shown = car ? car[field] : text;
      // Unless the person typed on in the meantime.
      if (latest.current === typed) setDraft(shown === text ? null : shown);
    });
  };
  return html`<${TextField} class="dyno-number" style=${{ width: width + 'px' }} value=${draft === null ? text : draft} onChange=${setDraft} onCommit=${commit} />`;
}

function NumberRow({ title, field, text, units }) {
  return html`<div class="group-row">
    <span class="grow">${title}</span>
    <${NumberField} field=${field} text=${text} width=${70} />
    ${units && html`<span class="secondary">${units}</span>`}
  </div>`;
}

const fillInHelp = "Takes the weight, gear ratios, final drive, tyre size and drag of a car from RomRaider's list. Check them against your own car afterwards.";

// The cars whose details can be filled in. The app has one list of them, which is asked for once.
let cars = null;

/**
 * The cars to choose one from, under their years, with a field to search them. (The Mac has a menu
 * here with a submenu for every year. A list that can be searched is easier with this many cars.)
 * Every word that is typed has to be in the car's name: "2009 sti" finds the 2009 STis.
 */
function CarSheet({ onPick, onClose }) {
  const [query, setQuery] = useState('');
  const field = useRef(null);
  useEffect(() => { if (field.current) field.current.querySelector('input').focus(); }, []);
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  const years = [];
  for (const car of cars) {
    const name = car.name.toLowerCase();
    if (!words.every(word => name.includes(word))) continue;
    if (years.length && years[years.length - 1].year === car.year) years[years.length - 1].cars.push(car);
    else years.push({ year: car.year, cars: [car] });
  }
  return html`<${Sheet} width=${440} onClose=${onClose}>
    <div class="row" style="padding: 14px 16px 6px">
      <div class="headline grow">Fill In From a Car</div>
      <${Button} onClick=${onClose}>Cancel<//>
    </div>
    <div class="caption secondary" style="padding: 0 16px 10px">${fillInHelp}</div>
    <div ref=${field} style="padding: 0 16px 10px"><${SearchField} value=${query} onChange=${setQuery} placeholder="Search cars" /></div>
    <div class="picker-list">
      ${years.map(group => html`<div key=${group.year}>
        <div class="dyno-car-year">${group.year}</div>
        ${group.cars.map(car => html`<div key=${car.id} class="picker-row" onClick=${() => { onPick(car.id); onClose(); }}><span class="truncate">${car.name}</span></div>`)}
      </div>`)}
      ${years.length === 0 && html`<div class="secondary center" style="padding: 30px">Nothing found.</div>`}
    </div>
  <//>`;
}

/** "Fill In From a Car": the car that is chosen gives its weight, gearing, tyres and drag to the fields. */
function FillInFromCar() {
  const [open, setOpen] = useState(false);
  const [, loaded] = useState(0);
  const show = () => {
    setOpen(true);
    if (!cars) request('dyno.cars').then(list => { cars = list || []; loaded(n => n + 1); });
  };
  return html`<${Button} class="dyno-form-button" title=${fillInHelp} onClick=${show}>Fill In From a Car<//>
    ${open && cars && html`<${CarSheet} onPick=${car => send('dyno.fillIn', { car })} onClose=${() => setOpen(false)} />`}`;
}

/** The left side: the log, the car and the unit. */
function Form({ dyno }) {
  const car = dyno.car;
  const logs = [{ value: '', label: 'Choose a log' }, ...dyno.logs.map(log => ({ value: log.path, label: log.name }))];
  const gears = Array.from({ length: dyno.gearCount }, (_, index) => ({ value: String(index + 1), label: String(index + 1) }));
  return html`<div class="dyno-form">
    <${Section} title="Log">
      <div class="group-row dyno-tall">
        <${Select} class="dyno-log" wide options=${logs} value=${dyno.selected || ''} onChange=${path => send('dyno.select', { path })} />
      </div>
      <div class="group-row dyno-tall">
        <${Button} class="dyno-form-button" onClick=${() => send('dyno.openOther')}>Open Other Log…<//>
      </div>
      <div class="group-row dyno-help caption secondary">Record a pull with Troubleshooting › Full-throttle pull, or log Engine Speed and Throttle (Vehicle Speed and Intake Air Temperature help).</div>
    <//>
    <${Section} title="Car">
      <div class="group-row dyno-tall"><${FillInFromCar} /></div>
      <${NumberRow} title="Weight with driver" field="massKg" text=${car.massKg} units="kg" />
      <div class="group-row">
        <span class="grow">Detect gear from speed</span>
        <${Toggle} checked=${dyno.detectGear} onChange=${on => send('dyno.detectGear', { on })} />
      </div>
      ${!dyno.detectGear && html`<div class="group-row">
        <span class="grow">Gear</span>
        <${Select} options=${gears} value=${String(dyno.gear)} onChange=${gear => send('dyno.gear', { gear: Number(gear) })} />
      </div>`}
      <div class="group-row">
        <span class="grow">Tyres</span>
        <div class="dyno-tyres">
          <${NumberField} field="tireWidthMM" text=${car.tireWidthMM} width=${44} />
          <span>/</span>
          <${NumberField} field="tireAspect" text=${car.tireAspect} width=${32} />
          <span>R</span>
          <${NumberField} field="rimInches" text=${car.rimInches} width=${32} />
        </div>
      </div>
      <${NumberRow} title="Final drive" field="finalDrive" text=${car.finalDrive} />
      <${NumberRow} title="Drag coefficient" field="dragCoefficient" text=${car.dragCoefficient} />
      <${NumberRow} title="Frontal area" field="frontalAreaM2" text=${car.frontalAreaM2} units="m²" />
      <${NumberRow} title="Drivetrain loss" field="drivetrainLoss" text=${car.drivetrainLoss} units="%" />
      <div class="group-row dyno-tall">
        <${Button} class="dyno-form-button" onClick=${() => send('dyno.reset')}>Reset to 2008 STI (GRB) values<//>
      </div>
    <//>
    <${Section} title="Display">
      <div class="group-row">
        <span class="grow">Power in</span>
        <${Select} options=${dyno.units} value=${dyno.unit} onChange=${unit => send('dyno.unit', { unit })} />
      </div>
    <//>
  </div>`;
}

/** How to record a pull that gives a trustworthy dyno curve. It folds away under its title. */
function PullGuide({ expanded, connected }) {
  const [open, setOpen] = useState(expanded);
  return html`<div class="dyno-guide">
    <div class="dyno-guide-title headline" role="button" tabindex="0" aria-expanded=${open} onClick=${() => setOpen(!open)}
        onKeyDown=${event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setOpen(!open); } }}>
      <${Icon} name=${open ? 'chevron-down' : 'chevron-right'} />How to do a dyno pull
    </div>
    ${open && html`<div class="dyno-guide-body">
      ${steps.map(([title, text], index) => html`<div key=${index} class="dyno-step">
        <span class="dyno-step-number">${index + 1}</span>
        <div class="callout">
          <div class="headline">${title}</div>
          <div class="secondary">${text}</div>
        </div>
      </div>`)}
      <div class="dyno-label callout orange"><${Icon} name="triangle-alert" />Only on a closed road, track or dyno. Keep your eyes on the road; SubieScope records everything.</div>
      <div class="row dyno-guide-record">
        <${Button} kind="prominent" icon="circle-dot" disabled=${!connected} onClick=${() => send('dyno.recordPull')}>Record a Pull<//>
        ${!connected && html`<span class="caption secondary">Connect to the car first.</span>`}
      </div>
    </div>`}
  </div>`;
}

/** Plain-language answer to "was that a good pull?" */
function Verdict({ verdict }) {
  const look = qualities[verdict.quality] || qualities.retry;
  return html`<div class=${cls('dyno-verdict', look.color)}>
    <div class="dyno-label title3"><${Icon} name=${look.icon} />${verdict.title}</div>
    ${verdict.issues.map(issue => html`<div key=${issue} class="dyno-label callout secondary"><${Icon} name="corner-down-right" />${issue}</div>`)}
  </div>`;
}

function StatTile({ tile }) {
  return html`<div class="card dyno-tile">
    <div class="caption secondary">${tile.title}</div>
    <div class="dyno-tile-value"><span class="value-number digits">${tile.value}</span><span class="secondary">${tile.unit}</span></div>
    <div class="caption secondary">${tile.detail}</div>
  </div>`;
}

/** The pulls of the log, each with a tick for whether its curves are drawn. */
function RunList({ runs }) {
  return html`<div class="dyno-runs">
    <div class="headline">Pulls in this log</div>
    ${runs.map(run => html`<${Checkbox} key=${run.id} checked=${run.shown} onChange=${shown => send('dyno.show', { id: run.id, shown })}>
      <span class="dyno-run">
        <span class="dyno-swatch" style=${{ background: `var(--series-${run.color})` }}></span>
        <span>${run.name}</span>
        <span class="secondary">${run.detail}</span>
        ${run.power && html`<span class="digits">${run.power}</span>`}
        <span class=${cls('dyno-badge', (qualities[run.quality] || qualities.retry).color)} title=${run.notes}>${run.badge}</span>
      </span>
    <//>`)}
  </div>`;
}

/** The right side: what the chosen log gave. */
function Results({ dyno }) {
  if (!dyno.selected) {
    return html`<div class="dyno-results"><${Empty} icon="trending-up" title="Choose a log">The virtual dyno turns a full-throttle pull into a power and torque curve.<//></div>`;
  }
  const result = dyno.result;
  if (!result) {
    // Nothing to say about a log that is still being read.
    if (dyno.loading) return html`<div class="dyno-results"></div>`;
    return html`<div class="dyno-results">
      <div class="dyno-nothing">
        <div class="dyno-label title3"><${Icon} name="flag" />No full-throttle pull found in this log</div>
        <div class="secondary">A pull needs full throttle with rising rpm for at least 1.5 seconds and 1,500 rpm, in one gear.</div>
        <${PullGuide} key="nothing" expanded=${true} connected=${dyno.connected} />
      </div>
    </div>`;
  }
  return html`<div class="dyno-results">
    <div class="dyno-found">
      <${PullGuide} key="found" expanded=${false} connected=${dyno.connected} />
      <${Verdict} verdict=${result.verdict} />
      <div class="dyno-tiles">${result.tiles.map(tile => html`<${StatTile} key=${tile.title} tile=${tile} />`)}</div>
      <${RunList} runs=${result.runs} />
      <${DynoCharts} charts=${result.charts} format=${{ group: dyno.groupingSeparator, decimal: dyno.decimalSeparator }} />
      <div class="caption secondary">An estimate from acceleration, weight and gearing. Road slope, wind, tyre slip and clutch slip all change the result: compare pulls made in the same gear on the same stretch of road.</div>
    </div>
  </div>`;
}

/** The "Virtual Dyno" part of the app. */
export function Dyno() {
  const dyno = useSlice('dyno');
  const [visit, setVisit] = useState(null);
  // Every visit starts fresh, with the newest log, as on the Mac. The app says which visit this is,
  // and until its state is about this one there is nothing to show.
  useEffect(() => {
    let gone = false;
    request('dyno.appear').then(number => { if (!gone) setVisit(number); });
    return () => { gone = true; send('dyno.disappear'); };
  }, []);
  if (!dyno || dyno.visit !== visit) return html`<div class="content fixed dyno"></div>`;
  return html`<div class="content fixed dyno">
    <${Form} dyno=${dyno} />
    <div class="dyno-divider"></div>
    <${Results} dyno=${dyno} />
  </div>`;
}
