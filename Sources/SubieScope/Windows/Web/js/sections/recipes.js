// Troubleshooting: guided tests that tell a car owner what is wrong with the car. The list of tests,
// a test's description, the test while it runs, and what it found. (The Mac's RecipesView.swift;
// the app's side is Bridge+Recipes.swift, which calls a test a "recipe".)
import { useEffect, useLayoutEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Select, Checkbox, Sheet, Empty, Spinner, Progress } from '../ui.js';
import { registerIcons } from '../icons.js';

registerIcons({
  // From Lucide 0.468.0, like the icons in icons.js.
  'arrow-left-right': '<path d="M8 3 4 7l4 4" /> <path d="M4 7h16" /> <path d="m16 21 4-4-4-4" /> <path d="M20 17H4" />',
  'audio-lines': '<path d="M2 10v3" /> <path d="M6 6v11" /> <path d="M10 3v18" /> <path d="M14 8v7" /> <path d="M18 5v13" /> <path d="M22 10v3" />',
  'cog': '<path d="M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16Z" /> <path d="M12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4Z" /> <path d="M12 2v2" /> <path d="M12 22v-2" /> <path d="m17 20.66-1-1.73" /> <path d="M11 10.27 7 3.34" /> <path d="m20.66 17-1.73-1" /> <path d="m3.34 7 1.73 1" /> <path d="M14 12h8" /> <path d="M2 12h2" /> <path d="m20.66 7-1.73 1" /> <path d="m3.34 17 1.73-1" /> <path d="m17 3.34-1 1.73" /> <path d="m11 13.73-4 6.93" />',
  'fan': '<path d="M10.827 16.379a6.082 6.082 0 0 1-8.618-7.002l5.412 1.45a6.082 6.082 0 0 1 7.002-8.618l-1.45 5.412a6.082 6.082 0 0 1 8.618 7.002l-5.412-1.45a6.082 6.082 0 0 1-7.002 8.618l1.45-5.412Z" /> <path d="M12 12v.01" />',
  'file-question': '<path d="M12 17h.01" /> <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z" /> <path d="M9.1 9a3 3 0 0 1 5.82 1c0 2-3 3-3 3" />',
  'footprints': '<path d="M4 16v-2.38C4 11.5 2.97 10.5 3 8c.03-2.72 1.49-6 4.5-6C9.37 2 10 3.8 10 5.5c0 3.11-2 5.66-2 8.68V16a2 2 0 1 1-4 0Z" /> <path d="M20 20v-2.38c0-2.12 1.03-3.12 1-5.62-.03-2.72-1.49-6-4.5-6C14.63 6 14 7.8 14 9.5c0 3.11 2 5.66 2 8.68V20a2 2 0 1 0 4 0Z" /> <path d="M16 17h4" /> <path d="M4 13h4" />',
  'grip': '<circle cx="12" cy="5" r="1" /> <circle cx="19" cy="5" r="1" /> <circle cx="5" cy="5" r="1" /> <circle cx="12" cy="12" r="1" /> <circle cx="19" cy="12" r="1" /> <circle cx="5" cy="12" r="1" /> <circle cx="12" cy="19" r="1" /> <circle cx="19" cy="19" r="1" /> <circle cx="5" cy="19" r="1" />',
  'heater': '<path d="M11 8c2-3-2-3 0-6" /> <path d="M15.5 8c2-3-2-3 0-6" /> <path d="M6 10h.01" /> <path d="M6 14h.01" /> <path d="M10 16v-4" /> <path d="M14 16v-4" /> <path d="M18 16v-4" /> <path d="M20 6a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h3" /> <path d="M5 20v2" /> <path d="M19 20v2" />',
  'leaf': '<path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10Z" /> <path d="M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12" />',
  'nfc': '<path d="M6 8.32a7.43 7.43 0 0 1 0 7.36" /> <path d="M9.46 6.21a11.76 11.76 0 0 1 0 11.58" /> <path d="M12.91 4.1a15.91 15.91 0 0 1 .01 15.8" /> <path d="M16.37 2a20.16 20.16 0 0 1 0 20" />',
  'octagon-x': '<path d="m15 9-6 6" /> <path d="M2.586 16.726A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2h6.624a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586z" /> <path d="m9 9 6 6" />',
  'thermometer-sun': '<path d="M12 9a4 4 0 0 0-2 7.5" /> <path d="M12 3v2" /> <path d="m6.6 18.4-1.4 1.4" /> <path d="M20 4v10.54a4 4 0 1 1-4 0V4a2 2 0 0 1 4 0Z" /> <path d="M4 13H2" /> <path d="M6.34 7.34 4.93 5.93" />',
  // Not in Lucide: a bare exclamation mark and a bare "i" for a finding, and the dot that says "recording".
  'recipes-exclamation': '<path d="M12 4v10" /> <path d="M12 19.5h.01" />',
  'recipes-info': '<path d="M12 10.5v9" /> <path d="M12 5h.01" />',
  'recipes-recording': '<circle cx="12" cy="12" r="9.5" /> <circle cx="12" cy="12" r="5.5" fill="currentColor" stroke="none" />',
});

// The page's drawing for each of the Mac's icon names (SF Symbols) that the tests use.
const symbols = {
  'sensor.tag.radiowaves.forward': 'nfc',
  'aqi.medium': 'grip',
  'wind': 'wind',
  'waveform.path': 'audio-waveform',
  'minus.plus.batteryblock': 'battery-charging',
  'pedal.accelerator': 'footprints',
  'thermometer.medium': 'thermometer',
  'thermometer.sun': 'thermometer-sun',
  'fan': 'fan',
  'flag.checkered': 'flag',
  'waveform.badge.exclamationmark': 'audio-lines',
  'gearshape.2': 'cog',
  'fuelpump': 'fuel',
  'leaf': 'leaf',
  'thermometer.and.liquid.waves': 'heater',
  'speedometer': 'circle-gauge',
  'bolt.trianglebadge.exclamationmark': 'zap',
};
const symbol = name => symbols[name] || 'stethoscope';

// How a finding's severity looks: a check mark, an exclamation mark, a cross or an "i".
const severityIcons = { pass: 'check', warning: 'recipes-exclamation', fail: 'x', info: 'recipes-info' };

// The sentence about what the car reports, by its kind (see Availability in the app).
const availabilityLooks = {
  offline: { icon: 'cable', tint: 'secondary' },
  cannot: { icon: 'octagon-x', tint: 'red' },
  partly: { icon: 'info', tint: 'secondary callout' },
  complete: { icon: 'badge-check', tint: 'green' },
};

/** A line of text with an icon in front of it. */
function Label({ icon, class: extra, children }) {
  return html`<div class=${cls('recipes-label', extra)}><${Icon} name=${icon} /><span>${children}</span></div>`;
}

function Section({ title, children }) {
  return html`<div class="column"><div class="headline">${title}</div>${children}</div>`;
}

function Bullets({ items, icon }) {
  return html`<div class="column" style="gap: 6px">
    ${items.map(item => html`<${Label} key=${item} icon=${icon} class="recipes-bullet">${item}<//>`)}
  </div>`;
}

/** Short texts as pills: next to each other when they all fit on one line, otherwise under each other. */
function Chips({ items }) {
  const box = useRef(null);
  const [stacked, setStacked] = useState(false);
  useLayoutEffect(() => {
    const element = box.current;
    if (!element) return;
    const measure = () => setStacked(element.firstElementChild.firstElementChild.offsetWidth > element.clientWidth + 0.5);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [items.join('|')]);
  const chips = items.map(item => html`<span key=${item} class="recipes-chip">${item}</span>`);
  return html`<div ref=${box} class="recipes-chips">
    <div class="recipes-chips-measure" aria-hidden="true"><div>${chips}</div></div>
    <div class=${cls('recipes-chips-shown', { stacked })}>${chips}</div>
  </div>`;
}

/** The tests to choose from, under "In the garage" and "On the road". */
function TestList({ state, selected, onSelect }) {
  const list = useRef(null);
  const ids = state.groups.flatMap(group => group.tests.map(test => test.id));
  const move = by => {
    const next = ids[Math.max(0, Math.min(ids.length - 1, ids.indexOf(selected) + by))];
    if (next) onSelect(next);
  };
  useEffect(() => {
    const row = list.current && list.current.querySelector('.recipes-row.selected');
    if (row) row.scrollIntoView({ block: 'nearest' });
  }, [selected]);
  return html`<div ref=${list} class="recipes-list" tabindex="0" role="listbox" onKeyDown=${event => {
      if (event.key === 'ArrowDown') { event.preventDefault(); move(1); }
      if (event.key === 'ArrowUp') { event.preventDefault(); move(-1); }
    }}>
    ${state.groups.map(group => html`
      <div key=${group.label} class="recipes-heading">${group.label}</div>
      ${group.tests.map(test => html`<div key=${test.id} role="option" aria-selected=${test.id === selected}
          class=${cls('recipes-row', { selected: test.id === selected })} onClick=${() => onSelect(test.id)}>
        <${Icon} name=${symbol(test.symbol)} class="recipes-row-icon" />
        <div class="grow">
          <div class="truncate">${test.title}</div>
          <div class="caption secondary truncate">${test.caption}</div>
        </div>
        ${state.running && state.run === test.id && html`<${Icon} name="recipes-recording" class="recipes-recording" />`}
      </div>`)}
    `)}
  </div>`;
}

/** What a test is for and what it asks of the person, with the button that starts it. */
function Detail({ test, state }) {
  const wideband = test.wideband;
  const availability = availabilityLooks[test.availability.kind] || availabilityLooks.offline;
  return html`<div class="recipes-pane">
    <div class="recipes-scroll">
      <div class="recipes-page recipes-detail">
        <div class="recipes-title-row">
          <div class="recipes-symbol"><${Icon} name=${symbol(test.symbol)} /></div>
          <div class="column" style="gap: 4px">
            <div class="recipes-title">${test.title}</div>
            <div class="secondary">${test.facts}</div>
          </div>
        </div>
        <div>${test.summary}</div>
        ${test.symptoms.length > 0 && html`<${Section} title="Helps with"><${Chips} items=${test.symptoms} /><//>`}
        ${test.conditions.length > 0 && html`<${Section} title="Before you start"><${Bullets} items=${test.conditions} icon="circle-check" /><//>`}
        ${test.safety && html`<${Label} icon="triangle-alert" class="recipes-safety">${test.safety}<//>`}
        ${wideband && html`<${Section} title="Wideband gauge">
          <${Checkbox} checked=${state.useWideband} disabled=${state.running} onChange=${on => send('recipes.useWideband', { on })}>${wideband.label}<//>
          <div class="callout secondary">${wideband.explanation}</div>
          ${state.useWideband && wideband.problem && html`<${Label} icon="triangle-alert" class="callout orange">${wideband.problem}<//>`}
        <//>`}
        <${Section} title="What you'll do">
          <div class="column">
            ${test.steps.map((step, index) => html`<div key=${index} class="recipes-step">
              <span class="recipes-step-number">${index + 1}</span>
              <div class="column" style="gap: 2px">
                <div class="callout recipes-step-name">${step.title}</div>
                <div class="callout secondary">${step.instruction}</div>
              </div>
            </div>`)}
          </div>
        <//>
        <${Section} title="What SubieScope looks at"><${Bullets} items=${test.lookFor} icon="search" /><//>
        <${Label} icon=${availability.icon} class=${availability.tint}>${test.availability.text}<//>
      </div>
    </div>
    <div class="recipes-bar filled">
      <${Button} title="Run this test's analysis on a log you recorded earlier" onClick=${() => send('recipes.analyzeLog', { id: test.id })}>Analyze a Log…<//>
      ${state.demoFault && html`<label class="row recipes-fault" title="Make the demo car misbehave to see how the test reacts">
        <span>Demo fault</span>
        <${Select} options=${state.demoFaults.map(fault => ({ value: fault.id, label: fault.label }))} value=${state.demoFault}
          onChange=${fault => send('recipes.demoFault', { fault })} />
      </label>`}
      <span class="spacer"></span>
      <${Button} kind="prominent" size="large" icon="play" class="recipes-start" disabled=${!test.canStart}
        onClick=${() => send('recipes.start', { id: test.id })}>Start<//>
    </div>
  </div>`;
}

/** One capsule for each step: the ones done, the one being done (wider), the ones to come. */
function StepDots({ count, current }) {
  return html`<div class="recipes-dots" role="img" aria-label=${`Step ${current + 1} of ${count}`}>
    ${Array.from({ length: count }, (_, index) => html`<span key=${index} class=${cls({ done: index < current, current: index === current })}></span>`)}
  </div>`;
}

/** How far the step is: a sentence, a bar that fills up, or a wait for something to happen. */
function Goal({ goal }) {
  const note = goal.note && html`<div class=${cls('caption', goal.noteIsWarning ? 'orange' : 'secondary')}>${goal.note}</div>`;
  if (goal.kind === 'manual') return html`<div class="recipes-goal"><div class="secondary">${goal.text}</div></div>`;
  if (goal.kind === 'waiting') return html`<div class="recipes-goal"><div class="row"><${Spinner} /><span>${goal.text}</span></div>${note}</div>`;
  return html`<div class="recipes-goal"><div class="digits">${goal.text}</div><${Progress} value=${goal.progress} />${note}</div>`;
}

/** A live value to keep an eye on, with whether it is where it should be. */
function WatchTile({ tile }) {
  const within = tile.state === 'in';
  return html`<div class="recipes-tile">
    <div class="caption secondary truncate">${tile.label}</div>
    <div class="recipes-tile-reading">
      <span class="recipes-tile-value">${tile.value}</span>
      <span class="caption secondary">${tile.units}</span>
    </div>
    ${tile.expected && html`<${Label} icon=${within ? 'circle-check' : 'arrow-left-right'}
      class=${cls('caption recipes-tile-range', within ? 'green' : tile.state === 'out' ? 'orange' : 'secondary')}>${tile.expected}<//>`}
  </div>`;
}

/** A test while it runs: the step to do, tips, progress and the live values that matter for it. */
function Run() {
  const run = useSlice('recipes.run');
  const live = useSlice('recipes.live');
  const [confirming, setConfirming] = useState(false);
  const manual = run ? run.manual : false;
  // Enter is Continue on a step that waits for it, wherever the keyboard happens to be, as on the Mac.
  useEffect(() => {
    if (!manual || confirming) return;
    const key = event => {
      if (event.key !== 'Enter' || event.repeat || event.ctrlKey || event.metaKey || event.altKey) return;
      if (/^(INPUT|TEXTAREA|SELECT)$/.test(event.target.tagName) || document.querySelector('.backdrop, .popover-layer')) return;
      event.preventDefault();
      event.stopPropagation();
      send('recipes.continue');
    };
    window.addEventListener('keydown', key, true);
    return () => window.removeEventListener('keydown', key, true);
  }, [manual, confirming]);
  if (!run) return html`<div class="recipes-pane"></div>`;
  // Live values of the step before are not shown with this step's texts.
  const now = live && live.step === run.step ? live : null;
  const stop = analyze => { setConfirming(false); send('recipes.stop', { analyze }); };

  return html`<div class="recipes-pane">
    <div class="recipes-run-header">
      <${Icon} name=${symbol(run.symbol)} />
      <div class="column grow" style="gap: 2px">
        <div class="headline">${run.title}</div>
        <div class="row" style="gap: 6px">
          <${Icon} name="recipes-recording" class="recipes-recording" />
          <span class="caption secondary truncate">${run.recording}</span>
        </div>
      </div>
      <${StepDots} count=${run.stepCount} current=${run.step} />
    </div>
    <div class="recipes-scroll">
      <div class="recipes-page recipes-run">
        <div class="column">
          <div class="recipes-step-label">${run.stepLabel}</div>
          <div class="recipes-step-title">${run.stepTitle}</div>
          <div class="recipes-instruction">${run.instruction}</div>
        </div>
        ${now && now.tips.length > 0 && html`<div class="column">
          ${now.tips.map((tip, index) => html`<${Label} key=${index} icon=${tip.urgent ? 'octagon-alert' : 'lightbulb'}
            class=${cls('recipes-tip', { urgent: tip.urgent })}>${tip.message}<//>`)}
        </div>`}
        ${now && html`<${Goal} goal=${now.goal} />`}
        ${now && html`<div class="recipes-watch">${now.tiles.map(tile => html`<${WatchTile} key=${tile.key} tile=${tile} />`)}</div>`}
      </div>
    </div>
    <div class="recipes-bar">
      <${Button} onClick=${() => setConfirming(true)}>Stop…<//>
      <span class="spacer"></span>
      ${run.manual
        ? html`<${Button} kind="prominent" onClick=${() => send('recipes.continue')}>Continue<//>`
        : html`<${Button} title="Move on without finishing this step. The result may be less complete." onClick=${() => send('recipes.skip')}>Skip Step<//>`}
    </div>
    ${confirming && html`<${Sheet} onClose=${() => setConfirming(false)}>
      <div class="alert">
        <div class="headline">Stop ${run.title}?</div>
        <div class="column" style="gap: 6px; margin-top: 6px">
          <${Button} kind="prominent" onClick=${() => stop(true)}>Stop and Analyse What's Recorded<//>
          <${Button} kind="destructive" onClick=${() => stop(false)}>Stop Without Results<//>
          <${Button} onClick=${() => setConfirming(false)}>Keep Going<//>
        </div>
      </div>
    <//>`}
  </div>`;
}

/** What a test found, after a run or in a recorded log (`analysis`). */
function Result({ result, state, revealLabel, analysis }) {
  if (result.unusable) {
    return html`<div class="recipes-pane">
      <${Empty} icon="file-question" title=${result.unusable.title}
        action=${html`<${Button} onClick=${() => send('recipes.done', { analysis })}>Back<//>`}>${result.unusable.text}<//>
    </div>`;
  }
  return html`<div class="recipes-pane">
    <div class="recipes-scroll">
      <div class="recipes-page recipes-result">
        <div class="row" style="gap: 16px">
          <div class=${cls('recipes-verdict', result.verdict)} role="img" aria-label=${result.verdictLabel}>
            <${Icon} name=${severityIcons[result.verdict]} />
          </div>
          <div class="column" style="gap: 4px">
            <div class="callout secondary">${result.caption}</div>
            <div class="recipes-headline">${result.headline}</div>
          </div>
        </div>
        <div class="column" style="gap: 10px">
          ${result.findings.map((finding, index) => html`<div key=${index} class=${cls('recipes-finding', finding.severity)}>
            <span role="img" aria-label=${finding.label} title=${finding.label}><${Icon} name=${severityIcons[finding.severity]} /></span>
            <div class="column grow" style="gap: 4px">
              <div class="recipes-finding-top">
                <span class="headline grow">${finding.title}</span>
                ${finding.measured && html`<span class="recipes-measured">${finding.measured}</span>`}
              </div>
              ${finding.detail && html`<div class="callout secondary">${finding.detail}</div>`}
            </div>
          </div>`)}
        </div>
        <div class="caption secondary">These results are rules of thumb from the logged data, not a replacement for a proper diagnosis. When in doubt, ask a Subaru specialist and bring the log.</div>
      </div>
    </div>
    <div class="recipes-bar">
      ${result.hasLog && html`
        <${Button} onClick=${() => send('recipes.replayLog')}>Replay Log<//>
        <${Button} onClick=${() => send('recipes.revealLog')}>${revealLabel}<//>
      `}
      <span class="spacer"></span>
      <${Button} disabled=${!state.connected} onClick=${() => send('recipes.runAgain', { id: result.test, analysis })}>Run Again<//>
      <${Button} kind="prominent" onClick=${() => send('recipes.done', { analysis })}>Done<//>
    </div>
  </div>`;
}

/** The "Troubleshooting" part of the app. */
export function Recipes() {
  const state = useSlice('recipes');
  const results = useSlice('recipes.results');
  const [selected, setSelected] = useState(null);
  // The list follows a test that starts, from wherever it is started. A result that was already
  // there when this part was opened does not move the selection, as on the Mac.
  const followed = useRef(undefined);
  const runID = state ? state.run || null : undefined;
  useEffect(() => {
    if (runID === undefined) return;
    const first = followed.current === undefined;
    if (runID && (first ? state.running : runID !== followed.current)) setSelected(runID);
    followed.current = runID;
  }, [runID]);
  if (!state) return html`<div class="content fixed recipes"></div>`;

  const tests = state.groups.flatMap(group => group.tests);
  const current = selected || (tests.length ? tests[0].id : null);
  const test = tests.find(candidate => candidate.id === current);
  const waiting = html`<div class="recipes-pane"></div>`;
  let pane;
  if (state.run && (state.run === current || state.running)) {
    // A test that runs stays in sight, whatever is chosen in the list.
    if (state.running) pane = html`<${Run} />`;
    else pane = results && results.run ? html`<${Result} result=${results.run} state=${state} revealLabel=${results.revealLabel} analysis=${false} />` : waiting;
  } else if (state.analysis && state.analysis === current) {
    pane = results && results.analysis ? html`<${Result} result=${results.analysis} state=${state} revealLabel=${results.revealLabel} analysis=${true} />` : waiting;
  } else if (test) {
    pane = html`<${Detail} key=${test.id} test=${test} state=${state} />`;
  } else {
    pane = html`<div class="recipes-pane"><${Empty} icon="stethoscope" title="Pick a test" /></div>`;
  }
  return html`<div class="content fixed recipes">
    <${TestList} state=${state} selected=${current} onSelect=${setSelected} />
    ${pane}
  </div>`;
}
