import { useEffect, useRef } from '../../vendor/preact-htm.js';
import { onEvent, request, send, useSlice } from '../bridge.js';
import { html, Button, Checkbox } from '../ui.js';

/** The "Console" part of the app: what the app did, and every message to and from the car. */
export function Console() {
  const state = useSlice('console');
  const list = useRef(null);

  // The lines are not drawn by Preact. There are thousands of them and new ones come in all the
  // time, so they are put on the page by hand: new ones at the end, old ones off the top.
  // The app sends the whole list once, and after that only what is new (see Bridge+Console.swift).
  useEffect(() => {
    const view = list.current;
    let newest = 0;
    // Events that came in before the answer with the whole list wait here.
    let early = [];

    // The console follows the newest line, until the person scrolls up to read. Scrolling back
    // down to the end makes it follow again.
    let following = true;
    const scrolled = () => { following = view.scrollHeight - view.scrollTop - view.clientHeight < 24; };
    view.addEventListener('scroll', scrolled);
    // A window that changes size wraps the lines differently, which moves the end.
    const resizes = new ResizeObserver(() => { if (following) view.scrollTop = view.scrollHeight; });
    resizes.observe(view);

    const show = batch => {
      if (batch.first == null) view.replaceChildren();
      else while (view.firstChild && view.firstChild.lineID < batch.first) view.firstChild.remove();
      const added = document.createDocumentFragment();
      for (const line of batch.lines) {
        if (line.id <= newest) continue;
        newest = line.id;
        const row = document.createElement('div');
        row.className = line.kind ? 'console-line ' + line.kind : 'console-line';
        row.textContent = line.text;
        row.lineID = line.id;
        added.appendChild(row);
      }
      view.appendChild(added);
      if (following) view.scrollTop = view.scrollHeight;
    };

    const stopListening = onEvent('console.lines', batch => { if (early) early.push(batch); else show(batch); });
    request('console.lines').then(all => {
      show(all || { lines: [] });
      early.forEach(show);
      early = null;
    });
    return () => {
      stopListening();
      view.removeEventListener('scroll', scrolled);
      resizes.disconnect();
      send('console.stop');
    };
  }, []);

  return html`<div class="content fixed console">
    <div class="console-bar">
      <${Checkbox} checked=${!!(state && state.capturesTraffic)} onChange=${on => send('console.captureTraffic', { on })}>Show raw traffic<//>
      <span class="caption secondary">→ sent · ↩ echo from the cable · ← ECU reply</span>
      <span class="spacer"></span>
      <${Button} onClick=${() => send('console.copyAll')}>Copy All<//>
      <${Button} onClick=${() => send('console.clear')}>Clear<//>
    </div>
    <div class="divider"></div>
    <div ref=${list} class="console-lines selectable"></div>
  </div>`;
}
