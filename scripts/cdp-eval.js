#!/usr/bin/env node
/**
 * One-shot: connect to a running browser tab, evaluate a JS expression,
 * print the result, and exit. Also supports --reload.
 *
 * Usage:
 *   node cdp-eval.js "expression"
 *   node cdp-eval.js --reload
 *   node cdp-eval.js --port 9222 --url localhost:3000 "expression"
 */
'use strict';
const http = require('http');

const args = process.argv.slice(2);
if (args.length === 0 || args.includes('--help') || args.includes('-h')) {
  console.log(`
Usage: node cdp-eval.js [--port PORT] [--url URL_SUBSTR] <expression>
       node cdp-eval.js [--port PORT] [--url URL_SUBSTR] --reload

Connects to a running browser tab and evaluates a JS expression, printing the
result. Exits immediately after.

Options:
  --port PORT       CDP debug port (default: 9222)
  --url URL_SUBSTR  Match tab by URL substring (default: first non-extension page)
  --reload          Reload the tab instead of evaluating an expression
  --help            Show this help

Examples:
  node cdp-eval.js "document.title"
  node cdp-eval.js "JSON.stringify(window.__store?.getState())"
  node cdp-eval.js --url localhost:3000 "window.APP_VERSION"
  node cdp-eval.js --reload
`);
  process.exit(args.length === 0 ? 1 : 0);
}

const portIdx = args.indexOf('--port');
const port    = parseInt(portIdx >= 0 ? args[portIdx + 1] : '9222', 10);
const urlIdx  = args.indexOf('--url');
const urlFilter = urlIdx >= 0 ? args[urlIdx + 1] : null;
const doReload  = args.includes('--reload');
const expr = args
  .filter(a => !a.startsWith('--') && a !== String(port) && a !== urlFilter)
  .join(' ');

if (!doReload && !expr) {
  console.error('Error: provide a JS expression or --reload');
  process.exit(1);
}

function httpGet(url) {
  return new Promise(resolve => {
    const req = http.get(url, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => { try { resolve(JSON.parse(d)); } catch { resolve(null); } });
    });
    req.on('error', () => resolve(null));
    req.setTimeout(1000, () => { req.destroy(); resolve(null); });
  });
}

function makeCDPClient(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let id = 1;
    const pending = new Map();
    ws.addEventListener('message', ({ data }) => {
      const msg = JSON.parse(data);
      if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
    });
    ws.addEventListener('open', () => {
      resolve({
        send(method, params = {}) {
          const cid = id++;
          return new Promise(res => { pending.set(cid, res); ws.send(JSON.stringify({ id: cid, method, params })); });
        },
        close() { ws.close(); },
      });
    });
    ws.addEventListener('error', () => reject(new Error(`Cannot connect to CDP at ${wsUrl}`)));
  });
}

function pickTarget(targets) {
  return targets.find(t =>
    t.type === 'page' &&
    !t.url.startsWith('devtools://') &&
    !t.url.startsWith('chrome-extension://') &&
    (!urlFilter || t.url.includes(urlFilter))
  );
}

async function main() {
  const targets = await httpGet(`http://localhost:${port}/json`);
  if (!targets) {
    console.error(`Error: no CDP server at localhost:${port}. Is the browser running with --remote-debugging-port=${port}?`);
    process.exit(1);
  }
  const page = pickTarget(targets);
  if (!page) {
    const hint = urlFilter ? ` matching URL "${urlFilter}"` : '';
    console.error(`Error: no page target found${hint}.`);
    process.exit(1);
  }

  const client = await makeCDPClient(page.webSocketDebuggerUrl);

  if (doReload) {
    client.send('Page.enable').then(() => client.send('Page.reload', { ignoreCache: true })).catch(() => {});
    client.close();
    console.log('Reload sent.');
    process.exit(0);
  }

  // Evaluate the expression
  // CDP result shape: { result: { result: { type, value, description } } }
  const r = await client.send('Runtime.evaluate', { expression: expr, returnByValue: true });
  client.close();

  const inner = r.result?.result;
  if (!inner) { console.error('No result returned.'); process.exit(1); }
  if (inner.subtype === 'error' || r.result?.exceptionDetails) {
    console.error(`Error: ${inner.description ?? r.result.exceptionDetails?.text}`);
    process.exit(1);
  }

  const value = inner.value !== undefined ? inner.value : inner.description ?? `<${inner.type}>`;
  console.log(typeof value === 'object' ? JSON.stringify(value, null, 2) : String(value));
}

main().catch(e => { console.error(e.message); process.exit(1); });
