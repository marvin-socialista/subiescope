// Looks at and drives a page through a browser's debug port (the DevTools protocol), without any
// other tool: the Windows app's own page (start the app with -debugPort 9339), or a headless Chrome
// that shows the page from the Mac's page host (scripts/dev/page-host.sh).
//   CDP_PORT=9339 node scripts/dev/cdp.mjs eval "<javascript expression>"
//   node scripts/dev/cdp.mjs shot out.png [maxWidth]
//   node scripts/dev/cdp.mjs nav <url> [milliseconds to wait]
//   node scripts/dev/cdp.mjs click "<css selector>"
//   node scripts/dev/cdp.mjs text "<visible text>"      clicks the element with exactly this text
//   node scripts/dev/cdp.mjs size <width> <height>      remembered for the commands that follow
//   node scripts/dev/cdp.mjs light | dark               remembered as well
//   node scripts/dev/cdp.mjs reload
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
const port = process.env.CDP_PORT || 9339;
// The size and the colour scheme asked for with "size" and "light"/"dark" only hold for as long as one
// connection lasts, so they are remembered per port and set again with every command.
const memory = `${tmpdir()}/cdp-state-${port}.json`;
const remembered = existsSync(memory) ? JSON.parse(readFileSync(memory, 'utf8')) : {};
const remember = change => writeFileSync(memory, JSON.stringify(Object.assign(remembered, change)));
const [command, ...rest] = process.argv.slice(2);
const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const page = targets.find(t => t.type === 'page');
if (!page) { console.error('no page', targets); process.exit(1); }
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
let next = 1;
const waiting = new Map();
socket.onmessage = event => {
  const message = JSON.parse(event.data);
  if (message.id && waiting.has(message.id)) { waiting.get(message.id)(message); waiting.delete(message.id); }
};
const send = (method, params = {}) => new Promise(resolve => {
  const id = next++;
  waiting.set(id, resolve);
  socket.send(JSON.stringify({ id, method, params }));
});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const evaluate = async expression => {
  const reply = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (reply.result?.exceptionDetails) return 'EXCEPTION ' + JSON.stringify(reply.result.exceptionDetails.exception?.description || reply.result.exceptionDetails);
  const value = reply.result?.result?.value;
  return typeof value === 'string' ? value : JSON.stringify(value, null, 1);
};
if (command === 'size') remember({ size: [Number(rest[0]), Number(rest[1]), Number(rest[2] || 1)] });
if (command === 'dark' || command === 'light') remember({ scheme: command });
if (remembered.size) await send('Emulation.setDeviceMetricsOverride', { width: remembered.size[0], height: remembered.size[1], deviceScaleFactor: remembered.size[2], mobile: false });
if (remembered.scheme) await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: remembered.scheme }] });
if (remembered.size || remembered.scheme) await sleep(150);
if (command === 'eval') {
  console.log(await evaluate(rest.join(' ')));
} else if (command === 'shot') {
  const metrics = await send('Page.getLayoutMetrics');
  const { clientWidth: width, clientHeight: height } = metrics.result.cssVisualViewport;
  const max = Number(rest[1] || 1300);
  const reply = await send('Page.captureScreenshot', { format: 'png', clip: { x: 0, y: 0, width, height, scale: Math.min(1, max / width) } });
  writeFileSync(rest[0], Buffer.from(reply.result.data, 'base64'));
  console.log('saved', rest[0], width + 'x' + height);
} else if (command === 'nav') {
  await send('Page.navigate', { url: rest[0] });
  await sleep(Number(rest[1] || 1500));
  console.log(await evaluate('document.title + " | " + location.href'));
} else if (command === 'click') {
  console.log(await evaluate(`(() => { const e = document.querySelector(${JSON.stringify(rest[0])}); if (!e) return 'not found'; e.click(); return 'clicked'; })()`));
} else if (command === 'text') {
  // Clicks the smallest element whose text is exactly this.
  console.log(await evaluate(`(() => { const want = ${JSON.stringify(rest[0])}; const all = [...document.querySelectorAll('body *')].filter(e => e.textContent.trim() === want && e.offsetParent !== null); if (!all.length) return 'not found'; all[all.length - 1].click(); return 'clicked'; })()`));
} else if (command === 'size') {
  console.log('size set');
} else if (command === 'dark' || command === 'light') {
  console.log(command);
} else if (command === 'reload') {
  await send('Page.reload', { ignoreCache: true });
  await sleep(1200);
  console.log('reloaded');
}
socket.close();
