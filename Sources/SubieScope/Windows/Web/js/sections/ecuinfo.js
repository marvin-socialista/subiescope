import { send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Toggle, Spinner, ToolbarButton, useToolbar } from '../ui.js';

/** One line of a section: a name with its value, or a sentence (see ECUInfoState.Item in the app). */
function Item({ item }) {
  if (item.kind === 'row') {
    return html`<div class="group-row">
      <span class="ecuinfo-label">${item.label}</span>
      <span class=${cls('ecuinfo-value selectable', { mono: item.mono })}>${item.value}</span>
    </div>`;
  }
  if (item.kind === 'warning') {
    return html`<div class="group-row callout orange"><${Icon} name="triangle-alert" /><span class="selectable">${item.value}</span></div>`;
  }
  return html`<div class=${cls('group-row', item.kind === 'error' ? 'red' : 'secondary', { callout: item.kind === 'callout' })}><span class="selectable">${item.value}</span></div>`;
}

function Section({ title, children }) {
  return html`<section>
    <div class="ecuinfo-title">${title}</div>
    <div class="group">${children}</div>
  </section>`;
}

/** OBD-II only: the switch for the search for extended values, and how the search went. */
function Extended({ extended }) {
  return html`<${Section} title=${extended.title}>
    <div class="group-row">
      <span class="grow">${extended.toggle}</span>
      <${Toggle} checked=${extended.on} onChange=${on => send('ecuinfo.extendedValues', { on })} />
    </div>
    ${extended.state ? html`
      <div class="group-row callout secondary">${extended.searching && html`<${Spinner} />`}<span class="selectable">${extended.state}</span></div>
      ${extended.canLookAgain && html`<div class="group-row"><${Button} onClick=${() => send('ecuinfo.lookAgain')}>Look Again<//></div>`}
    ` : html`<div class="group-row callout secondary">${extended.help}</div>`}
  <//>`;
}

/** The "ECU Info" part of the app. */
export function ECUInfo() {
  const info = useSlice('ecuinfo');
  const live = useSlice('ecuinfo.live');
  const copy = info && info.copy;
  useToolbar(copy ? html`<${ToolbarButton} icon="copy" title=${copy.help} disabled=${!copy.enabled} onClick=${() => send('ecuinfo.copy')} />` : null,
    [copy && copy.help, copy && copy.enabled]);
  if (!info) return html`<div class="content"></div>`;
  const liveRows = (live && live.rows) || [];

  return html`<div class="content">
    <div class="ecuinfo">
      ${info.sections.map(section => html`<${Section} key=${section.title} title=${section.title}>
        ${[...section.items, ...(section.endsWithLiveRows ? liveRows : [])].map(item => html`<${Item} key=${item.kind + item.label} item=${item} />`)}
      <//>`)}
      ${info.extended && html`<${Extended} extended=${info.extended} />`}
      ${info.about && html`<${Section} title=${info.about.title}>
        <div class="group-row callout secondary">${info.about.text}</div>
        <div class="group-row">
          <${Button} disabled=${!info.about.canChangeConnectionType} onClick=${() => send('setup.showModeChooser')}>Connection Type…<//>
        </div>
      <//>`}
    </div>
  </div>`;
}
