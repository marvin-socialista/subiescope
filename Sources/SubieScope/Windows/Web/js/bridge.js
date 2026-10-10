// The page's line to the app. The app (Swift, see Sources/SubieScope/Bridge) sends named pieces
// of state, "slices", whenever they change; the page shows them and sends back what the person does.
//
//   const app = useSlice('app');          a slice's newest state, and a redraw when it changes
//   send('app.connect');                  ask the app to do something
//   const file = await request('x.y');    ask the app something and wait for the answer
//   onEvent('console.line', line => …);   something that happens once
//
// In the Windows app the line is WebView2's message channel. On a Mac, for development, it is the
// debug build's small web server (WebDevServer.swift).
import { useEffect, useState } from '../vendor/preact-htm.js';

const slices = {};
const sliceListeners = new Map();
const eventListeners = new Map();
const waiting = new Map();
let nextRequest = 1;

const webview = window.chrome && window.chrome.webview;

function post(message) {
  if (webview) {
    webview.postMessage(message);
  } else {
    fetch('/bridge/send', { method: 'POST', body: JSON.stringify(message) }).catch(() => {});
  }
}

function receive(message) {
  if (message.slice) {
    slices[message.slice] = message.state;
    const listeners = sliceListeners.get(message.slice);
    if (listeners) listeners.forEach(listener => listener(message.state));
  } else if (message.event) {
    const listeners = eventListeners.get(message.event);
    if (listeners) listeners.forEach(listener => listener(message.data));
  } else if (message.reply !== undefined) {
    const resolve = waiting.get(message.reply);
    waiting.delete(message.reply);
    if (resolve) resolve(message.value);
  }
}

/** Asks the app to do something. */
export function send(action, args = {}) {
  post({ ...args, action });
}

/** Asks the app something and waits for the answer. */
export function request(name, args = {}) {
  return new Promise(resolve => {
    const id = nextRequest++;
    waiting.set(id, resolve);
    post({ ...args, request: name, id });
  });
}

/** Calls `listener` for every event of this name. Returns a function that stops it. */
export function onEvent(name, listener) {
  if (!eventListeners.has(name)) eventListeners.set(name, new Set());
  eventListeners.get(name).add(listener);
  return () => eventListeners.get(name).delete(listener);
}

/** Calls `listener` with every new state of a slice. Returns a function that stops it. */
export function onSlice(name, listener) {
  if (!sliceListeners.has(name)) sliceListeners.set(name, new Set());
  sliceListeners.get(name).add(listener);
  return () => sliceListeners.get(name).delete(listener);
}

/** The newest state of a slice, or undefined before the app has sent it. Does not redraw. */
export function peek(name) {
  return slices[name];
}

/** A slice's newest state. The component is drawn again when it changes. */
export function useSlice(name) {
  const [state, setState] = useState(slices[name]);
  useEffect(() => {
    setState(slices[name]);
    return onSlice(name, setState);
  }, [name]);
  return state;
}

/** Calls `listener` for an event for as long as the component is on the page. */
export function useEvent(name, listener) {
  useEffect(() => onEvent(name, listener), [name]);
}

/** Starts the line. The app answers with every slice. */
export function connect() {
  if (webview) {
    webview.addEventListener('message', event => receive(event.data));
    send('page.ready');
  } else {
    const events = new EventSource('/bridge/events');
    events.onmessage = event => receive(JSON.parse(event.data));
    events.onopen = () => send('page.ready');
  }
}
