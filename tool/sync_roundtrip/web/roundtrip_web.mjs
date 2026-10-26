// Drives the web app (side B of the sync round trip) in a headless Chrome, one operation per call.
//
//   node tool/sync_roundtrip/web/roundtrip_web.mjs start [--profile DIR] [--url URL] [--attach http://127.0.0.1:PORT]
//   node tool/sync_roundtrip/web/roundtrip_web.mjs <operation> [args] [--profile DIR]
//   node tool/sync_roundtrip/web/roundtrip_web.mjs stop
//
// `start` launches a background daemon (daemon.mjs) that owns the browser; every other call is one
// request to it and prints one JSON result. The exit code is 0 on success and 1 on failure. The
// operations are listed in tool/sync_roundtrip/README.md ("Web").

import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, openSync, readFileSync, rmSync } from 'node:fs';
import { request } from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..', '..');
const DEFAULTS = {
  profile: path.join(repo, '.notes', 'sync-roundtrip', 'chrome-profile'),
  url: 'https://umacapture-web-staging.umasagashi.workers.dev/',
  chrome: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  idleMinutes: 120,
  width: 1440,
  height: 960,
};

// Positional arguments per operation, in order.
const POSITIONAL = {
  open: ['url'], type: ['text'], key: ['name'], shot: ['name'], tab: ['name'], scroll: ['dy'],
  'import-video': ['file'], 'image-form': ['form'], 'corrupt-record': ['id'], eval: ['js'],
  'opfs-ls': ['path'], 'opfs-read': ['path'], 'opfs-write': ['path'], 'opfs-rm': ['path'], 'opfs-push': ['from', 'to'],
  tap: ['label'], hold: ['label'], rclick: ['label'], find: ['label'], wait: ['label'], 'tap-xy': ['x', 'y'],
  row: ['fans'], rate: ['fans', 'value'], memo: ['fans', 'text'], archive: ['fans', 'images'], merge: ['index', 'keep'],
};
const BOOLEAN_FLAGS = new Set(['scroll', 'gone', 'recursive', 'all', 'worker', 'semantic', 'unchanged', 'viaPage']);

function parse(argv) {
  const [op, ...rest] = argv;
  const args = {};
  const positional = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (a.startsWith('--')) {
      const k = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
      if (BOOLEAN_FLAGS.has(k)) args[k] = true;
      else args[k] = rest[++i];
    } else positional.push(a);
  }
  (POSITIONAL[op] ?? []).forEach((name, i) => { if (positional[i] !== undefined && args[name] === undefined) args[name] = positional[i]; });
  for (const k of ['nth', 'ms', 'dx', 'dy', 'maxScrolls', 'step', 'settleMs', 'appearMs', 'timeout', 'depth', 'index']) if (args[k] !== undefined) args[k] = +args[k];
  return { op, args };
}

const out = (v) => console.log(JSON.stringify(v, null, 1));
const fail = (msg) => { out({ ok: false, error: msg }); process.exit(1); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const statePathOf = (profile) => `${profile}.daemon.json`;

function readState(profile) {
  try { return JSON.parse(readFileSync(statePathOf(profile), 'utf8')); } catch { return null; }
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

// Every chrome.exe whose command line names [profile] as its user-data-dir. Starting a second Chrome
// on a profile that is already open hands the request to the running browser instead — which, if
// that browser is the user's visible login window, opens a tab in front of them.
function chromesOnProfile(profile) {
  const ps = "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | ForEach-Object { \"$($_.ProcessId)`t$($_.CommandLine)\" }";
  const lines = execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps], { encoding: 'utf8', windowsHide: true }).split(/\r?\n/);
  const norm = (s) => s.replace(/\\/g, '/').toLowerCase();
  const want = norm(profile);
  return lines.filter((l) => l.includes('\t') && norm(l).includes(want)).map((l) => +l.split('\t')[0]);
}

async function start(args) {
  const profile = path.resolve(args.profile ?? DEFAULTS.profile);
  const state = readState(profile);
  if (state?.pid && alive(state.pid)) fail(`already running (daemon pid ${state.pid}); run stop first`);
  // An attached browser is not started here, so no profile of this machine is opened.
  const holders = args.attach ? [] : chromesOnProfile(profile);
  if (holders.length > 0) fail(`a Chrome already has this profile open (pids ${holders.join(', ')}); close it first`);
  mkdirSync(profile, { recursive: true });
  rmSync(statePathOf(profile), { force: true });
  const config = {
    chromePath: args.chrome ?? DEFAULTS.chrome,
    profile,
    statePath: statePathOf(profile),
    shotsDir: path.resolve(args.shots ?? path.join(path.dirname(profile), 'shots')),
    url: args.url ?? DEFAULTS.url,
    attach: args.attach ?? null,
    idleMinutes: +(args.idleMinutes ?? DEFAULTS.idleMinutes),
    width: +(args.width ?? DEFAULTS.width),
    height: +(args.height ?? DEFAULTS.height),
  };
  const logFd = openSync(`${profile}.daemon.log`, 'a');
  const child = spawn(process.execPath, [path.join(here, 'daemon.mjs'), JSON.stringify(config)], {
    detached: true, stdio: ['ignore', logFd, logFd], windowsHide: true,
  });
  child.unref();
  const end = Date.now() + 60000;
  for (;;) {
    const s = readState(profile);
    if (s?.ready) return out({ ok: true, result: { daemonPid: s.pid, chromePid: s.chromePid, profile, url: config.url, shots: config.shotsDir } });
    if (s && s.ready === false) fail(`daemon failed to start: ${s.error} (log: ${profile}.daemon.log)`);
    if (Date.now() > end) fail(`daemon did not become ready (log: ${profile}.daemon.log)`);
    await sleep(200);
  }
}

async function call(op, args) {
  const profile = path.resolve(args.profile ?? DEFAULTS.profile);
  delete args.profile;
  const state = readState(profile);
  if (!state?.port || !alive(state.pid)) {
    if (op === 'stop') return out({ ok: true, result: 'not running' });
    fail('not running; run start first');
  }
  // node:http rather than fetch: an operation may wait for many minutes (a sync round, a video import),
  // and fetch gives up on a response whose headers take longer than five.
  const body = await new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port: state.port, method: 'POST', path: '/' }, (res) => {
      let text = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { text += c; });
      res.on('end', () => { try { resolve(JSON.parse(text)); } catch (e) { reject(e); } });
    });
    req.on('error', reject);
    req.end(JSON.stringify({ op, args }));
  });
  out(body);
  if (op === 'stop') {
    const end = Date.now() + 30000;
    while (alive(state.pid) && Date.now() < end) await sleep(200);
    if (state.chromePid && alive(state.chromePid)) fail(`chrome pid ${state.chromePid} is still running`);
  }
  process.exit(body.ok ? 0 : 1);
}

const { op, args } = parse(process.argv.slice(2));
if (!op) fail('usage: roundtrip_web.mjs <start|stop|operation> [args]');
if (op === 'start') await start(args);
else await call(op, args);
