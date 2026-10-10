import { useEffect, useRef, useState } from '../../vendor/preact-htm.js';
import { request, send, useSlice } from '../bridge.js';
import { html, cls, Icon, Button, Spinner, Alert, Popover, Menu, MenuButton } from '../ui.js';

/** The code itself, in the colour of its list. */
function Badge({ code, tint }) {
  return html`<span class=${cls('codes-badge', tint)}>${code}</span>`;
}

function HelpList({ title, icon, items, numbered }) {
  return html`<div class="codes-help-list">
    <div class="codes-help-title"><${Icon} name=${icon} />${title}</div>
    ${items.map((item, index) => html`<div key=${index} class="codes-help-item">
      <span class="codes-help-mark digits secondary">${numbered ? index + 1 + '.' : '•'}</span>
      <span>${item}</span>
    </div>`)}
  </div>`;
}

/** What a code means, what usually causes it and how to fix it. */
function CodeHelp({ list, code, disclaimer }) {
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);
  const copy = () => {
    send('codes.copyCode', { list: list.id, id: code.id, help: true });
    setCopied(true);
  };
  return html`<div class="codes-help selectable">
    <div class="codes-help-head">
      <${Badge} code=${code.code} tint=${list.tint} />
      <span class="headline grow">${code.title}</span>
      <${Button} kind="plain" icon=${copied ? 'check' : 'copy'} title="Copy this explanation" onClick=${copy}>${copied ? 'Copied' : 'Copy'}<//>
    </div>
    ${code.meaning ? html`
      <div>${code.meaning}</div>
      <${HelpList} title="Possible causes" icon="search" items=${code.causes} />
      <${HelpList} title="How to fix" icon="wrench" items=${code.fixes} numbered />
      <div class="caption secondary">${disclaimer}</div>
    ` : html`<div class="secondary">No extra information for this code yet.</div>`}
  </div>`;
}

/** A trouble code in the list. A click shows what it means and how to fix it. */
function CodeRow({ list, code, disclaimer }) {
  const [help, setHelp] = useState(false);
  const [menu, setMenu] = useState(null);
  const info = useRef(null);
  const copy = withHelp => send('codes.copyCode', { list: list.id, id: code.id, help: withHelp });
  return html`
    <div class=${cls('codes-row codes-code', { open: help })} tabindex="0" title="Show causes and fixes"
        onClick=${() => setHelp(true)}
        onKeyDown=${event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); setHelp(true); } }}
        onContextMenu=${event => { event.preventDefault(); setMenu({ x: event.clientX, y: event.clientY }); }}>
      <${Badge} code=${code.code} tint=${list.tint} />
      <span class="grow">${code.title}</span>
      <span ref=${info} class=${cls('codes-info', help ? list.tint : 'secondary')}><${Icon} name="info" /></span>
    </div>
    ${help && html`<${Popover} anchor=${info.current} side="left" align="center" onClose=${() => setHelp(false)}>
      <${CodeHelp} list=${list} code=${code} disclaimer=${disclaimer} />
    <//>`}
    ${menu && html`<${Menu} anchor=${menu} onClose=${() => setMenu(null)} items=${[
      { label: 'Copy Code', onClick: () => copy(false) },
      { label: 'Copy Code with Causes and Fixes', onClick: () => copy(true) },
    ]} />`}`;
}

/** The "Trouble Codes" part of the app. */
export function Codes() {
  const codes = useSlice('codes');
  const [confirming, setConfirming] = useState(false);
  const [saveError, setSaveError] = useState(null);

  // Ctrl+Shift+R reads the codes. It is caught before the window's own Ctrl+R (record) sees it.
  useEffect(() => {
    const key = event => {
      if ((event.ctrlKey || event.metaKey) && event.shiftKey && event.key.toLowerCase() === 'r') {
        event.preventDefault();
        event.stopPropagation();
        send('codes.read');
      }
    };
    window.addEventListener('keydown', key, true);
    return () => window.removeEventListener('keydown', key, true);
  }, []);
  // Escape answers the question with Cancel.
  useEffect(() => {
    if (!confirming) return;
    const key = event => { if (event.key === 'Escape') setConfirming(false); };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [confirming]);

  if (!codes) return html`<div class="content"></div>`;

  // `format`: 'text', or 'page' for a page to print (the Mac app makes a PDF there).
  const save = async format => {
    const result = await request('codes.save', { format });
    if (result && result.error) setSaveError(result.error);
  };

  return html`<div class="content fixed codes">
    <div class="codes-header">
      <div class="column grow" style="gap: 3px">
        <div class="headline">${codes.headline}</div>
        ${codes.chips.length > 0 && html`<div class="row" style="gap: 10px">
          ${codes.chips.map(chip => html`<span key=${chip.label} class=${cls('codes-chip', chip.on ? 'orange' : 'secondary')}>${chip.label}</span>`)}
        </div>`}
      </div>
      ${codes.reading && html`<${Spinner} />`}
      <${MenuButton} icon="share" align="end" disabled=${!codes.canExport}
        title="Copy or save every code with its causes and fixes, e.g. for your mechanic or a forum"
        items=${[
          { label: 'Copy Codes', onClick: () => send('codes.copy', { help: false }) },
          { label: 'Copy Codes with Causes and Fixes', onClick: () => send('codes.copy', { help: true }) },
          { divider: true },
          { label: 'Save as Web Page…', onClick: () => save('page') },
          { label: 'Save as Text…', onClick: () => save('text') },
        ]}>Export<${Icon} name="chevron-down" class="codes-chevron" /><//>
      <${Button} disabled=${!codes.canClear} onClick=${() => setConfirming(true)}>${codes.clear.button}<//>
      <${Button} kind="prominent" disabled=${!codes.canRead} title="Read the trouble codes from the car (Ctrl+Shift+R)"
        onClick=${() => send('codes.read')}>Read Codes<//>
    </div>
    <div class="divider"></div>
    <div class="codes-list">
      ${codes.error && html`<div class="codes-row codes-message orange"><${Icon} name="triangle-alert" /><span class="selectable">${codes.error}</span></div>`}
      ${codes.notice && html`<div class="codes-row codes-message secondary"><${Icon} name="info" /><span class="selectable">${codes.notice}</span></div>`}
      ${codes.lists.map(list => html`<section key=${list.id}>
        <div class="codes-section">
          <div class="headline">${list.title}</div>
          <div class="caption secondary">${list.subtitle}</div>
        </div>
        ${list.codes.length === 0 && html`<div class="codes-row secondary">${list.emptyText}</div>`}
        ${list.codes.map(code => html`<${CodeRow} key=${code.id} list=${list} code=${code} disclaimer=${codes.disclaimer} />`)}
      </section>`)}
    </div>
    ${confirming && html`<${Alert} title=${codes.clear.title} buttons=${[
      { label: codes.clear.confirm, kind: 'destructive', onClick: () => { setConfirming(false); send('codes.clear'); } },
      { label: 'Cancel', onClick: () => setConfirming(false) },
    ]}><span class="codes-question">${codes.clear.message}</span><//>`}
    ${saveError && html`<${Alert} title="Couldn't save the codes" buttons=${[{ label: 'OK', onClick: () => setSaveError(null) }]}>${saveError}<//>`}
  </div>`;
}
