// The long-lived side of roundtrip_web.mjs: owns one headless Chrome and one CDP session on its page,
// and runs one operation per HTTP request. It is a separate process because the state an operation
// leaves behind has to outlive the call that made it: network emulation (offline) belongs to the CDP
// session and is dropped when the session detaches, and the page itself (semantics enabled, the app's
// in-memory state) would otherwise be reloaded by every call.
//
// With `attach` set, it launches nothing: it connects to a browser that is already running (an
// Android Chrome whose DevTools socket `adb forward` brought to a local port), drives one page of it,
// and on stop detaches without closing that browser.
//
// Started by `roundtrip_web.mjs start`; never run directly.

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { Cdp } from './cdp.mjs';
import { createOps } from './ops.mjs';

const [, , configJson] = process.argv;
const config = JSON.parse(configJson);
const { chromePath, profile, statePath, idleMinutes } = config;

const log = (...a) => console.log(new Date().toISOString(), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function writeState(extra) {
  writeFileSync(statePath, JSON.stringify({ ...config, pid: process.pid, ...extra }, null, 1));
}

// --headless=new is not optional: on Windows chrome.exe starts a visible window for almost any
// argument list it does not recognise as headless, and a visible window takes the user's focus.
const portFile = `${profile}/DevToolsActivePort`;
let shuttingDown = false;
let pageSessionId = null;
const chrome = config.attach ? null : launchChrome();

function launchChrome() {
  rmSync(portFile, { force: true });
  const launched = spawn(chromePath, [
    '--headless=new',
    '--remote-debugging-port=0',
    `--user-data-dir=${profile}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--lang=ja',
    '--accept-lang=ja',
    `--window-size=${config.width},${config.height}`,
    'about:blank',
  ], { stdio: 'ignore', windowsHide: true });
  log('chrome pid', launched.pid);
  launched.on('exit', (code) => {
    log('chrome exited', code);
    if (!shuttingDown) finish(1);
  });
  return launched;
}

function finish(code) {
  shuttingDown = true;
  try { rmSync(statePath, { force: true }); } catch { /* best effort */ }
  process.exit(code);
}

async function waitFor(fn, ms, label) {
  const end = Date.now() + ms;
  for (;;) {
    try { const v = await fn(); if (v) return v; } catch { /* not yet */ }
    if (Date.now() > end) throw new Error(`timeout: ${label}`);
    await sleep(200);
  }
}

try {
  const devtools = config.attach
    ?? `http://127.0.0.1:${await waitFor(() => existsSync(portFile) && readFileSync(portFile, 'utf8').split('\n')[0].trim(), 30000, 'DevToolsActivePort')}`;
  const version = await waitFor(async () => (await fetch(`${devtools}/json/version`)).json(), 30000, 'devtools');
  const cdp = await Cdp.connect(version.webSocketDebuggerUrl);
  const page = await pickPage(cdp);
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId: page.targetId, flatten: true });
  pageSessionId = sessionId;
  const ops = await createOps({ cdp, sessionId, config, log });

  let last = Date.now();
  let queue = Promise.resolve();
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      last = Date.now();
      const { op, args } = JSON.parse(body || '{}');
      queue = queue.then(async () => {
        log('op', op, JSON.stringify(args));
        let out;
        try {
          if (op === 'stop') out = { ok: true, result: 'stopping' };
          else if (!ops[op]) out = { ok: false, error: `unknown operation: ${op}` };
          else out = { ok: true, result: await ops[op](args ?? {}) };
        } catch (e) {
          out = { ok: false, error: String(e?.message ?? e) };
        }
        log('op done', op, out.ok ? 'ok' : out.error);
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify(out));
        last = Date.now();
        if (op === 'stop') await shutdown(cdp);
      });
    });
  });
  server.listen(0, '127.0.0.1', () => {
    writeState({ port: server.address().port, chromePid: chrome?.pid ?? null, ready: true });
    log('listening', server.address().port);
  });
  // An idle daemon closes its browser, so a forgotten `stop` does not leave Chrome running for days.
  setInterval(() => {
    if (Date.now() - last > idleMinutes * 60000) { log('idle, stopping'); shutdown(cdp); }
  }, 30000).unref();
} catch (e) {
  log('startup failed', String(e?.stack ?? e));
  writeState({ ready: false, error: String(e?.message ?? e) });
  shuttingDown = true;
  try { chrome?.kill(); } catch { /* already gone */ }
  process.exit(1);
}

// The page to drive. A launched browser has exactly one (about:blank). An attached one is the user's
// browser with its own tabs: take the tab already on the app's origin, or open a new one, and never
// take over an unrelated tab.
async function pickPage(cdp) {
  const { targetInfos } = await cdp.send('Target.getTargets');
  const pages = targetInfos.filter((t) => t.type === 'page');
  if (!config.attach) return pages[0];
  const origin = new URL(config.url).origin;
  const mine = pages.find((t) => t.url.startsWith(origin));
  if (mine) return mine;
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  return { targetId };
}

async function shutdown(cdp) {
  shuttingDown = true;
  if (!chrome) {
    // Not ours to close: put the page back online and leave the browser running.
    const online = { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 };
    try { await cdp.send('Network.emulateNetworkConditions', online, pageSessionId); } catch { /* best effort */ }
    finish(0);
    return;
  }
  try { await cdp.send('Browser.close'); } catch { /* the browser may already be closing */ }
  const end = Date.now() + 15000;
  while (chrome.exitCode === null && Date.now() < end) await sleep(200);
  if (chrome.exitCode === null) {
    // Browser.close did not end it; take down this Chrome's own process tree, and nothing else.
    spawn('taskkill', ['/T', '/F', '/PID', String(chrome.pid)], { stdio: 'ignore', windowsHide: true });
    await sleep(2000);
  }
  finish(0);
}
