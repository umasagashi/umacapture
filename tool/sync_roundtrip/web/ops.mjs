// The operations roundtrip_web.mjs exposes, each one step of the round-trip sheet or a primitive the
// named steps are built from. Elements are found through the Flutter web semantics tree (the DOM
// `flt-semantics` nodes the engine builds for screen readers) by their label, and pressed by
// dispatching CDP input events at their centre — synthetic events delivered to the page, which never
// move the OS cursor or take focus from another window.

import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The semantics tree as a flat list. `label` is the node's own aria-label, or its text when the node
// is a leaf holding only text.
const NODES_JS = `(() => {
  const vh = innerHeight, vw = innerWidth;
  return [...document.querySelectorAll('flt-semantics, flt-semantics input, flt-semantics textarea')].map(e => {
    const r = e.getBoundingClientRect();
    const text = e.childNodes.length === 1 && e.firstChild.nodeType === 3 ? e.textContent : null;
    const n = { tag: e.tagName.toLowerCase(), role: e.getAttribute('role'), label: e.getAttribute('aria-label') || text,
      x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), w: Math.round(r.width), h: Math.round(r.height) };
    for (const a of ['aria-checked', 'aria-selected', 'aria-disabled', 'aria-expanded']) if (e.hasAttribute(a)) n[a.slice(5)] = e.getAttribute(a);
    if ('value' in e && e.tagName !== 'FLT-SEMANTICS') n.value = e.value;
    n.inView = n.x >= 0 && n.y >= 0 && n.x <= vw && n.y <= vh;
    return n;
  }).filter(n => n.w > 0 && (n.label || n.role || n.tag !== 'flt-semantics'));
})()`;

// The label of the button that opens the navigation drawer, the navigation a narrow window has.
const NAV_MENU = 'ナビゲーション メニューを開く';

const OPFS_AT_JS = `const at = async (names, create = false) => { let d = await navigator.storage.getDirectory(); for (const n of names) d = await d.getDirectoryHandle(n, { create }); return d; };`;

// The parts of an OPFS path, refusing anything that is not a plain relative path.
function opfsParts(p) {
  const parts = String(p ?? '').split('/').filter((s) => s.length > 0);
  if (parts.some((s) => s === '.' || s === '..')) throw new Error(`not a plain OPFS path: ${p}`);
  return parts;
}

/** A node matching [sel]: {label} exact, {prefix}, {contains}, {regex}, optionally {role} and {nth}. */
export function matchNodes(nodes, sel) {
  const re = sel.regex ? new RegExp(sel.regex) : null;
  return nodes.filter((n) => {
    if (sel.role && n.role !== sel.role) return false;
    if (sel.tag && n.tag !== sel.tag) return false;
    const l = n.label ?? '';
    if (sel.label !== undefined && l !== sel.label) return false;
    if (sel.prefix !== undefined && !l.startsWith(sel.prefix)) return false;
    if (sel.contains !== undefined && !l.includes(sel.contains)) return false;
    if (re && !re.test(l)) return false;
    return true;
  });
}

function describe(sel) {
  return JSON.stringify(Object.fromEntries(Object.entries(sel).filter(([k]) => ['label', 'prefix', 'contains', 'regex', 'role', 'tag', 'nth'].includes(k))));
}

export async function createOps({ cdp, sessionId, config, log }) {
  const send = (method, params = {}, sid = sessionId) => cdp.send(method, params, sid);
  const events = [];
  // The page's attached workers, kept so `eval --worker` can reach them. Network emulation is not
  // applied to them separately: a worker session refuses Network.emulateNetworkConditions, and the
  // page's emulation already fails the dedicated worker's fetches too.
  const workers = new Map(); // sessionId -> {type, url}
  let offline = false;

  const networkConditions = () => ({ offline, latency: 0, downloadThroughput: -1, uploadThroughput: -1 });
  async function applyNetwork() {
    await send('Network.enable');
    await send('Network.emulateNetworkConditions', networkConditions());
  }

  cdp.on((msg) => {
    if (msg.method === 'Target.attachedToTarget') {
      const info = msg.params.targetInfo;
      workers.set(msg.params.sessionId, { type: info.type, url: info.url });
    } else if (msg.method === 'Target.detachedFromTarget') {
      workers.delete(msg.params.sessionId);
    } else if (msg.sessionId === sessionId) {
      events.push(msg);
      if (events.length > 2000) events.splice(0, 1000);
    }
  });

  await send('Page.enable');
  await send('Runtime.enable');
  await applyNetwork();
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });

  async function evalJs(expression) {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      throw new Error(`js: ${d.exception?.description ?? d.text}`.slice(0, 600));
    }
    return r.result.value;
  }

  async function waitFor(fn, ms, label) {
    const end = Date.now() + ms;
    let lastError;
    for (;;) {
      try { const v = await fn(); if (v) return v; } catch (e) { lastError = e; }
      if (Date.now() > end) throw new Error(`timeout after ${ms} ms: ${label}${lastError ? ` (${lastError.message})` : ''}`);
      await sleep(200);
    }
  }

  const appRunning = () => evalJs(`!!document.querySelector('flt-semantics-placeholder, flutter-view, flt-glass-pane')`);

  // Semantics are off until something asks for them; the placeholder's click is how a screen reader
  // turns them on, and it has to be repeated after every page load. On a mobile browser the engine
  // ignores a scripted click and turns them on only for a touch tap on the placeholder, so a touch
  // tap at its centre follows when the click has not done it.
  async function ensureSemantics() {
    const count = await evalJs(`document.querySelectorAll('flt-semantics').length`);
    if (count > 0) return;
    await evalJs(`(() => { const p = document.querySelector('flt-semantics-placeholder'); if (p) p.click(); return true; })()`);
    const on = async () => (await evalJs(`document.querySelectorAll('flt-semantics').length`)) > 2;
    try {
      await waitFor(on, 3000, 'semantics nodes');
      return;
    } catch { /* a mobile engine: tap it */ }
    const c = await evalJs(`(() => { const p = document.querySelector('flt-semantics-placeholder'); if (!p) return null; const r = p.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
    if (c) {
      await send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: c.x, y: c.y }] });
      await sleep(60);
      await send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    }
    await waitFor(on, 30000, 'semantics nodes');
  }

  async function nodes() {
    await ensureSemantics();
    return evalJs(NODES_JS);
  }

  async function find(sel) {
    const found = matchNodes(await nodes(), sel);
    return found[sel.nth ?? 0];
  }

  async function wheel(dy, at) {
    const vp = await evalJs(`({ w: innerWidth, h: innerHeight })`);
    const x = at?.x ?? Math.round(vp.w * 0.6);
    const y = at?.y ?? Math.round(vp.h / 2);
    await send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: dy });
    await sleep(350);
  }

  // Finds [sel], scrolling the view under [sel.at] (default: the content area) until the node is on
  // screen. The scroll gives up in a direction once the visible labels stop changing.
  async function reveal(sel) {
    const signature = (ns) => ns.filter((n) => n.inView).map((n) => `${n.label}@${n.y}`).join('|');
    let n = await find(sel);
    if (n?.inView) return n;
    if (!sel.scroll && !n) return undefined;
    for (const dir of n && n.y < 0 ? [-1] : [1, -1]) {
      let before = signature(await nodes());
      for (let i = 0; i < (sel.maxScrolls ?? 40); i++) {
        await wheel(dir * (sel.step ?? 300), sel.at);
        n = await find(sel);
        if (n?.inView) return n;
        const now = signature(await nodes());
        if (now === before) break;
        before = now;
      }
    }
    return n?.inView ? n : undefined;
  }

  // [sel] on screen, waiting up to [sel.appearMs] (default 5 s) for it to be built — a menu or dialog
  // opened by the previous press is not in the tree yet when the press returns.
  async function need(sel) {
    const end = Date.now() + Number(sel.appearMs ?? 5000);
    while (Date.now() < end && !matchNodes(await nodes(), sel).length) await sleep(200);
    const n = await reveal(sel);
    if (!n) throw new Error(`no node ${describe(sel)} on screen`);
    return n;
  }

  // With [raw], the semantics overlay is made transparent to the pointer for the press, so the event
  // reaches the Flutter view as a pointer event, the way a mouse click does. Without it the press lands
  // on a semantics node, which the engine turns into a semantics tap: no position, and nothing at all
  // for gesture detectors that expose no tap action (the table's memo cell, measured).
  async function mouse(x, y, button = 'left', holdMs = 0, raw = false) {
    const buttons = button === 'right' ? 2 : 1;
    const overlay = (v) => evalJs(`(() => { const h = document.querySelector('flt-semantics-host'); if (h) h.style.pointerEvents = ${JSON.stringify(v)}; return !!h; })()`);
    if (raw) await overlay('none');
    try {
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0 });
      await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button, buttons, clickCount: 1 });
      if (holdMs > 0) await sleep(holdMs);
      await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button, buttons: 0, clickCount: 1 });
    } finally {
      if (raw) await overlay('');
    }
  }

  async function tapNode(sel, opts = {}) {
    const n = await need(sel);
    await mouse(n.x + (opts.dx ?? 0), n.y + (opts.dy ?? 0), opts.button, opts.holdMs, !opts.semantic);
    await sleep(opts.settleMs ?? 400);
    return n;
  }

  async function key(name, modifiers = 0) {
    const vk = { Enter: 13, Escape: 27, Backspace: 8, Tab: 9, Delete: 46, a: 65 }[name];
    const code = name.length === 1 ? `Key${name.toUpperCase()}` : name;
    for (const type of ['keyDown', 'keyUp']) {
      await send('Input.dispatchKeyEvent', { type, key: name, code, windowsVirtualKeyCode: vk, modifiers });
    }
  }

  async function labels() {
    return (await nodes()).filter((n) => n.label).map((n) => n.label);
  }

  function shotPath(name) {
    const file = /[\\/]/.test(name) || name.endsWith('.png') ? path.resolve(name) : path.join(config.shotsDir, `${name}.png`);
    mkdirSync(path.dirname(file), { recursive: true });
    return file.endsWith('.png') ? file : `${file}.png`;
  }

  async function shot(name) {
    const r = await send('Page.captureScreenshot', { format: 'png' });
    const file = shotPath(name);
    writeFileSync(file, Buffer.from(r.data, 'base64'));
    return file;
  }

  async function currentUrl() {
    return evalJs('location.href');
  }

  async function openApp(url) {
    const t0 = Date.now();
    await send('Page.navigate', { url });
    await waitFor(appRunning, 120000, 'flutter mounted');
    await ensureSemantics();
    // The home screen is up once its navigation is in the semantics tree: the rail on a wide window,
    // the drawer's menu button on a narrow one (a phone).
    await waitFor(async () => {
      const n = await evalJs(NODES_JS);
      return matchNodes(n, { prefix: '設定\nタブ' }).length > 0 || matchNodes(n, { prefix: NAV_MENU }).length > 0;
    }, 120000, 'navigation');
    return Date.now() - t0;
  }

  // Leaves the app by loading the same origin's privacy page, so nothing of the app (page or worker)
  // is running while its OPFS files are changed.
  async function leaveApp() {
    const origin = new URL(config.url).origin;
    if (await appRunning()) {
      await send('Page.navigate', { url: `${origin}/privacy/` });
      await waitFor(async () => !(await appRunning()) && (await evalJs('document.readyState')) === 'complete', 30000, 'privacy page');
    }
    // The app's recognition worker is the page's attached child; it detaches when it ends.
    await waitFor(() => workers.size === 0, 30000, 'app workers gone');
    return currentUrl();
  }

  async function requireAppClosedFor(p) {
    if (opfsParts(p)[0] === 'umacapture' && (await appRunning())) {
      throw new Error(`the app is running in this page; run leave-app before changing ${p}`);
    }
  }

  // A destination on the navigation rail, or, on a narrow window that has no rail, in the drawer.
  // Gives the file input [backendNodeId] the bytes of the local file [abs], built into a File inside the
  // page from base64 chunks, and fires the change event a picked file fires.
  async function setFileFromBytes(backendNodeId, abs) {
    const bytes = readFileSync(abs);
    const key = '__roundtripUpload';
    await evalJs(`(window.${key} = [], true)`);
    const chunk = 1 << 20;
    for (let i = 0; i < bytes.length; i += chunk) {
      const b64 = bytes.subarray(i, i + chunk).toString('base64');
      await evalJs(`(window.${key}.push(Uint8Array.from(atob(${JSON.stringify(b64)}), (c) => c.charCodeAt(0))), true)`);
    }
    const { object } = await send('DOM.resolveNode', { backendNodeId });
    const name = path.basename(abs);
    await send('Runtime.callFunctionOn', {
      objectId: object.objectId,
      functionDeclaration: `function () {
        const f = new File(window.${key}, ${JSON.stringify(name)}, { type: 'video/mp4' });
        delete window.${key};
        const dt = new DataTransfer(); dt.items.add(f); this.files = dt.files;
        this.dispatchEvent(new Event('input', { bubbles: true }));
        this.dispatchEvent(new Event('change', { bubbles: true }));
      }`,
    });
  }

  async function goTab(name) {
    if (await find({ prefix: `${name}\nタブ` })) {
      await tapNode({ prefix: `${name}\nタブ` }, { settleMs: 800 });
      return;
    }
    await tapNode({ prefix: NAV_MENU }, { settleMs: 800 });
    await tapNode({ label: name }, { settleMs: 800 });
  }

  // The account screen, scrolled until the device-sync card's title is on screen.
  async function syncSection() {
    await goTab('アカウント');
    return need({ prefix: '端末間の同期', scroll: true });
  }

  const COUNTS_RE = /削除を取り消した (\d+) 件・2 件に分けた (\d+) 件・片方の端末にだけあって足し合わせた (\d+) 件/;

  // The device-sync card is built only while logged in (and the server is known or sync is on), or to tell
  // that the server dropped the login; without it, the status is read from the account card's login line.
  // [tile] is the card's title: the state of the rounds is a line of its own, among [lines].
  async function syncStatus() {
    await goTab('アカウント');
    const tile = (await reveal({ prefix: '端末間の同期', scroll: true }))
      ?? (await reveal({ regex: 'ログインしていません|ログインしています|ログインが切れた|Google でログイン', scroll: true }));
    // The lines under the tile (image form, counts, halts) may sit below the fold; collect while scrolling.
    const seen = new Set();
    for (const l of await labels()) seen.add(l);
    for (let i = 0; i < 3; i++) { await wheel(250); for (const l of await labels()) seen.add(l); }
    const all = [...seen];
    const pick = (re) => all.filter((l) => re.test(l));
    const countsLine = all.find((l) => COUNTS_RE.test(l));
    const m = countsLine?.match(COUNTS_RE);
    const switchNode = await syncSwitch();
    return {
      // The login line does not always reach the semantics tree; the ログアウト button exists only while logged in.
      loggedIn: all.some((l) => l.includes('Google アカウントでログインしています') || l === 'ログアウト'),
      loggedOut: all.some((l) => l.includes('ログインしていません') || l === 'Google でログイン'),
      syncOn: switchNode ? switchNode.checked === 'true' : null,
      tile: tile?.label?.startsWith('端末間の同期') ? tile.label : null,
      running: all.some((l) => l.includes('同期しています…')),
      counts: m ? { restored: +m[1], split_off: +m[2], added: +m[3] } : null,
      lines: pick(/同期|レコード: |容量|上限|200 字|隔離|画像/),
    };
  }

  // The switch of the device-sync card: the first switch node below the card's title, in the card's first row.
  async function syncSwitch() {
    const all = await nodes();
    const tile = matchNodes(all, { prefix: '端末間の同期' })[0];
    if (!tile) return undefined;
    const switches = all.filter((n) => n.role === 'switch' || (n.checked !== undefined && n.role !== 'radio'));
    return switches.filter((s) => s.y > tile.y).sort((a, b) => a.y - b.y)[0];
  }

  const fansLabel = (fans) => Number(String(fans).replace(/,/g, '')).toLocaleString('en-US');

  // The row of the record table whose fan-count cell reads [fans] (the table needs a ファン数 column).
  async function tableRow(fans) {
    if (!(await find({ prefix: '表示するレコード種別の選択' }))) await goTab('殿堂入り管理');
    const sel = { label: fansLabel(fans), role: 'button', scroll: true, at: { x: 822, y: 500 } };
    // Banners (a quarantine notice, a store warning) appear after the table and push it down, so the
    // row is taken once its position has held for half a second.
    let row = await need(sel);
    for (let i = 0; i < 20; i++) {
      await sleep(500);
      const again = await need(sel);
      if (again.y === row.y && again.x === row.x) return again;
      row = again;
    }
    throw new Error(`row ${fans} kept moving`);
  }

  // The nodes of [fans]' row that lie under the header [column].
  async function tableCell(fans, column) {
    const row = await tableRow(fans);
    const all = await nodes();
    const header = matchNodes(all, { label: column, role: 'button' }).find((n) => n.y < row.y);
    if (!header) throw new Error(`no column header ${column}`);
    const left = header.x - header.w / 2;
    const right = header.x + header.w / 2;
    const cell = all.filter((n) => Math.abs(n.y - row.y) < 4 && n.x >= left && n.x <= right && n !== header);
    return { row, header, cell };
  }

  // The review list is a dialog over the settings page: left open, it takes every later press (今すぐ同期
  // included). Its cancel leaves it without going on to resolve the inheritance, as its confirm would.
  async function closeReviewList() {
    if (!(await labels()).some((l) => l.startsWith('統合候補の一覧'))) return;
    await tapNode({ label: 'キャンセル', role: 'button' });
    await waitFor(async () => !(await labels()).some((l) => l.startsWith('統合候補の一覧')), 15000, 'review list closed');
  }

  async function openReviewList() {
    if (await find({ contains: '統合候補の一覧' })) return;
    await goTab('設定');
    await tapNode({ prefix: '親子関係の再解決', scroll: true }, { settleMs: 1500 });
    await waitFor(async () => matchNodes(await nodes(), { contains: '統合候補の一覧' })[0], 30000, 'review list');
  }

  const ops = {
    // ---- the browser and the page
    async status() {
      const { targetInfos } = await cdp.send('Target.getTargets');
      return {
        url: await currentUrl(), appRunning: await appRunning(), offline, workers: [...workers.values()],
        targets: targetInfos.map((t) => ({ type: t.type, url: t.url, attached: t.attached })),
      };
    },
    async open({ url }) {
      const ms = await openApp(url ?? config.url);
      return {
        url: await currentUrl(), mountedMs: ms,
        crossOriginIsolated: await evalJs('self.crossOriginIsolated'),
        serviceWorkerControlled: await evalJs('!!navigator.serviceWorker?.controller'),
        offline,
      };
    },
    async 'leave-app'() {
      return { url: await leaveApp() };
    },
    // Evaluates [js] in the page, or with --worker in the first attached worker.
    async eval({ js, worker }) {
      if (!worker) return evalJs(js);
      const sid = [...workers.keys()][0];
      if (!sid) throw new Error('no worker attached');
      const r = await send('Runtime.evaluate', { expression: js, awaitPromise: true, returnByValue: true }, sid);
      if (r.exceptionDetails) throw new Error(`js: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      return r.result.value;
    },

    // ---- primitives over the semantics tree
    async nodes({ all, file }) {
      const ns = await nodes();
      const out = all ? ns : ns.filter((n) => n.inView);
      if (file) { writeFileSync(path.resolve(file), JSON.stringify(out, null, 1)); return { file: path.resolve(file), count: out.length }; }
      return out;
    },
    async find(sel) {
      return (await reveal(sel)) ?? null;
    },
    async tap(sel) {
      return tapNode(sel, sel);
    },
    async hold(sel) {
      return tapNode(sel, { ...sel, holdMs: sel.ms ?? 1300 });
    },
    async rclick(sel) {
      return tapNode(sel, { ...sel, button: 'right' });
    },
    async 'tap-xy'({ x, y, button, ms, semantic }) {
      await mouse(+x, +y, button ?? 'left', ms ? +ms : 0, !semantic);
      return { x: +x, y: +y };
    },
    async type({ text }) {
      await send('Input.insertText', { text });
      return text;
    },
    async fill(sel) {
      await tapNode(sel, sel);
      await key('a', process.platform === 'darwin' ? 4 : 2);
      await key('Backspace');
      await send('Input.insertText', { text: sel.text });
      await sleep(300);
      return { text: sel.text };
    },
    async key({ name }) {
      await key(name);
      return name;
    },
    async wait(sel) {
      const ms = sel.timeout ? +sel.timeout * 1000 : 30000;
      if (sel.gone) {
        await waitFor(async () => matchNodes(await nodes(), sel).length === 0, ms, `gone ${describe(sel)}`);
        return { gone: true };
      }
      return waitFor(async () => matchNodes(await nodes(), sel)[0], ms, describe(sel));
    },
    async scroll({ dy, x, y }) {
      await wheel(+(dy ?? 300), x !== undefined ? { x: +x, y: +y } : undefined);
      return (await nodes()).filter((n) => n.inView && n.label).map((n) => n.label);
    },
    async labels() {
      return labels();
    },
    async tab({ name }) {
      await goTab(name);
      return (await nodes()).filter((n) => n.inView && n.label).map((n) => n.label);
    },
    async shot({ name }) {
      return { file: await shot(name ?? `shot-${Date.now()}`) };
    },

    // ---- network: this page (and its workers) only
    async offline() {
      offline = true;
      await applyNetwork();
      return ops['net-check']();
    },
    async online() {
      offline = false;
      await applyNetwork();
      return ops['net-check']();
    },
    async 'net-check'() {
      const probe = await evalJs(`fetch(location.origin + '/privacy/', { cache: 'no-store' }).then(r => 'ok ' + r.status, e => 'failed: ' + e.message)`);
      return { offline, sameOriginFetch: probe, workers: [...workers.values()] };
    },

    // ---- the account screen's device-sync card
    async 'sync-status'() {
      return syncStatus();
    },
    async 'sync-on'({ shotName }) {
      await syncSection();
      const sw = await syncSwitch();
      if (!sw) throw new Error('no switch on the device-sync card (logged out?)');
      if (sw.checked === 'true') return { alreadyOn: true };
      await mouse(sw.x, sw.y, 'left', 0, true);
      await waitFor(async () => matchNodes(await nodes(), { contains: '端末間の同期をオンにする' })[0], 30000, 'turn-on dialog');
      // The dialog reads the counts from the server; wait for the counts line (or its failure line).
      await waitFor(async () => (await labels()).some((l) => /この端末から送るレコード|件数を読めませんでした/.test(l)), 60000, 'turn-on counts').catch(() => {});
      const dialog = await labels();
      const file = await shot(shotName ?? 'sync-on-dialog');
      await tapNode({ regex: '^オンにする' });
      await waitFor(async () => matchNodes(await nodes(), { contains: '端末間の同期をオンにする' }).length === 0, 30000, 'turn-on dialog closed');
      return { dialog, shot: file };
    },
    async 'sync-now'({ timeout }) {
      await syncSection();
      const lastSynced = () => labels().then((ls) => ls.find((l) => l.includes('最終同期')) ?? null);
      const before = await lastSynced();
      await tapNode({ regex: '今すぐ同期', scroll: true });
      const ms = timeout ? +timeout * 1000 : 600000;
      // 最終同期 shows minutes only, so a round that ends within the same minute leaves it unchanged; the
      // running line appearing and then going away is the other sign the round ended.
      let sawRunning = false;
      await waitFor(async () => {
        const ls = await labels();
        if (ls.some((l) => l.includes('同期しています…'))) {
          sawRunning = true;
          return false;
        }
        const after = ls.find((l) => l.includes('最終同期')) ?? null;
        return sawRunning || after !== before || ls.some((l) => /同期を止めています|同期できませんでした|止まっています/.test(l));
      }, ms, 'round finished');
      return syncStatus();
    },
    async 'image-form'({ form }) {
      const label = { png: '元の画像（PNG）', jpeg: '縮小した画像（JPEG）', none: '画像は同期しない' }[form];
      if (!label) throw new Error('form is one of png, jpeg, none');
      await syncSection();
      await tapNode({ prefix: label, scroll: true }, { settleMs: 1500 });
      return syncStatus();
    },

    // ---- the record table (殿堂入り管理). A row is named by its fan count, as the sheet does.
    async row({ fans }) {
      return tableRow(fans);
    },
    // Rates an unrated row by pressing a star in its cell. A synthetic press lands on the star's half
    // value (measured: anywhere on star k gives k - 0.5), so only those values are offered.
    async rate({ fans, value, column }) {
      const v = Number(value);
      if (!(v > 0 && v <= 5 && v % 1 === 0.5)) throw new Error('value is one of 0.5, 1.5, 2.5, 3.5, 4.5');
      const col = column ?? 'レーティング';
      const { row, cell } = await tableCell(fans, col);
      const hint = cell.find((n) => n.role === 'group');
      // An unrated cell exposes its five stars; a rated one exposes nothing (its stars ignore the pointer).
      if (hint?.label === 'クリックして評価') {
        const stars = cell.filter((n) => n.role === 'button').sort((a, b) => a.x - b.x);
        if (stars.length !== 5) throw new Error(`expected 5 stars in the cell, found ${stars.length}`);
        await mouse(stars[Math.ceil(v) - 1].x, row.y, 'left', 0, true);
        await sleep(600);
        const after = (await tableCell(fans, col)).cell.find((n) => n.role === 'group');
        return { fans, value: v, via: 'cell', rated: after?.label !== 'クリックして評価' };
      }
      // A press on a rated cell opens the rating dialog (measured), but a press on the dialog's stars
      // closed the dialog without saving in every attempt, so changing a rating is not offered.
      throw new Error(`row ${fans} is already rated; changing a rating is not supported by this tool`);
    },
    // Opens the memo of a row and saves [text]; with --unchanged, presses OK without changing anything.
    async memo({ fans, text, unchanged, column }) {
      const { cell } = await tableCell(fans, column ?? 'メモ');
      const button = cell.find((n) => n.role === 'button');
      if (!button) throw new Error(`no memo cell in row ${fans}`);
      const field = async () => (await nodes()).find((n) => n.tag === 'input' || n.tag === 'textarea');
      // A press on a cell that is not the table's current cell may only make it current (measured: the
      // first press on another row's memo sometimes opens nothing), so the press is repeated once.
      let input;
      for (let attempt = 0; attempt < 2 && !input; attempt++) {
        await mouse(button.x, button.y, 'left', 0, true);
        input = await waitFor(field, 4000, 'memo field').catch(() => undefined);
      }
      if (!input) throw new Error(`the memo dialog of row ${fans} did not open`);
      if (!unchanged) {
        await mouse(input.x, input.y, 'left', 0, true);
        await key('a', 2);
        await key('Backspace');
        await send('Input.insertText', { text: String(text ?? '') });
        await sleep(300);
      }
      await tapNode({ label: 'OK' }, { settleMs: 800 });
      await waitFor(async () => matchNodes(await nodes(), { tag: 'input' }).length === 0, 15000, 'memo dialog closed');
      const after = (await tableCell(fans, column ?? 'メモ')).cell.find((n) => n.role === 'button');
      return { fans, unchanged: !!unchanged, after: after?.label ?? null };
    },
    // Archives a row through its context menu; images is `none` (画像を保持しない) or `jpeg`.
    async archive({ fans, images }) {
      const option = { none: '画像を保持しない', jpeg: '画像を縮小して保持' }[images ?? 'none'];
      if (!option) throw new Error('images is none or jpeg');
      const row = await tableRow(fans);
      await mouse(row.x, row.y, 'right', 0, true);
      await tapNode({ label: 'データをアーカイブ' }, { settleMs: 800 });
      await tapNode({ prefix: option });
      await tapNode({ label: '長押しでアーカイブ' }, { holdMs: 1500, settleMs: 800 });
      await waitFor(async () => !(await labels()).some((l) => l.includes('アーカイブしています')), 120000, 'archive finished');
      const stillListed = matchNodes(await nodes(), { label: fansLabel(fans) }).length > 0;
      return { fans, images: images ?? 'none', stillListed, shot: await shot(`archive-${fans}`) };
    },
    // The merge candidates (settings > 親子関係の再解決): each pair's label, in list order.
    async 'merge-list'() {
      await openReviewList();
      const pairs = (await nodes()).filter((n) => n.role === 'group' && /\n\/\n/.test(n.label ?? ''));
      const file = await shot('merge-list');
      await closeReviewList();
      return { pairs: pairs.map((n, i) => ({ index: i, label: n.label })), shot: file };
    },
    // Opens pair [index] of the merge candidates and merges it, keeping the `left` or `right` card.
    // The cards show evaluation points and capture time, not fan counts: the shot taken before the
    // merge is how the pair is confirmed.
    async merge({ index, keep, values }) {
      if (!['left', 'right'].includes(keep)) throw new Error('keep is left or right');
      await openReviewList();
      const confirms = matchNodes(await nodes(), { label: '確認', role: 'button' }).sort((a, b) => a.y - b.y);
      const target = confirms[Number(index ?? 0)];
      if (!target) throw new Error(`no candidate ${index}; there are ${confirms.length}`);
      await mouse(target.x, target.y, 'left', 0, true);
      await waitFor(async () => matchNodes(await nodes(), { contains: '統合対象の選択' })[0], 15000, 'merge dialog');
      // The dialog holds the older side until it has loaded the records' marks, then selects its default;
      // a press on 選択 during the load lands afterwards and clears the side it selected. So the kept
      // card has to read 選択解除 on two reads a second apart before anything else is pressed.
      const keptCard = async () => {
        const cards = matchNodes(await nodes(), { regex: '^(選択|選択解除)$', role: 'button' }).sort((a, b) => a.x - b.x || a.y - b.y);
        if (cards.length !== 2) throw new Error(`expected two cards, found ${cards.length}`);
        return keep === 'left' ? cards[0] : cards[1];
      };
      let steady = 0;
      for (let tries = 0; steady < 2; tries++) {
        if (tries > 20) throw new Error('the kept card did not stay selected');
        await sleep(1000);
        const pick = await keptCard();
        if (pick.label === '選択解除') steady++;
        else { steady = 0; await mouse(pick.x, pick.y, 'left', 0, true); }
      }
      // Where the two records' rating or memo differ, the dialog asks which value the merge keeps
      // (「古い方: …」/「新しい方: …」/「自由入力」); `values` answers every such question the same way.
      const prefix = { older: '古い方: ', newer: '新しい方: ' }[values];
      const choices = matchNodes(await nodes(), { regex: '^(古い方|新しい方): ' });
      if (choices.length > 0 && !prefix) {
        await tapNode({ prefix: '何もせずに閉じる' }).catch(() => {});
        throw new Error(`the pair has values to choose (${choices.map((c) => c.label).join(' / ')}); pass --values older|newer`);
      }
      for (const c of choices.filter((n) => n.label.startsWith(prefix))) await mouse(c.x, c.y, 'left', 0, true);
      await sleep(500);
      const before = await shot(`merge-${index}-${keep}`);
      if ((await keptCard()).label !== '選択解除') throw new Error('the kept card lost its selection; nothing was pressed');
      // 統合する is a hold-to-confirm button (kHoldToConfirmDuration, 1 s), though its label does not say so.
      await tapNode({ regex: '統合する$', role: 'button' }, { holdMs: 1500, settleMs: 800 });
      await waitFor(async () => !(await labels()).some((l) => l.includes('統合対象の選択') || l.includes('処理中...')), 60000, 'merge finished');
      await closeReviewList();
      return { index: Number(index ?? 0), keep, shotBefore: before, after: await labels() };
    },

    // ---- video import: answer the page's file chooser with a file, without a dialog
    // [file] is a path on this machine. With [viaPage] its bytes are sent into the page over the
    // protocol and handed to the file input from there, because a browser on another machine (an
    // attached Android Chrome) cannot open a path of this one, and Android Chrome may not hold the
    // permission to read a video file pushed onto the phone either.
    async 'import-video'({ file, viaPage, timeout }) {
      const abs = path.resolve(file);
      statSync(abs);
      await goTab('キャプチャ');
      await send('Page.setInterceptFileChooserDialog', { enabled: true });
      try {
        const from = events.length;
        await tapNode({ prefix: '動画取り込み', scroll: true });
        const chooser = await waitFor(() => events.slice(from).find((e) => e.method === 'Page.fileChooserOpened'), 20000, 'file chooser');
        if (viaPage) await setFileFromBytes(chooser.params.backendNodeId, abs);
        else await send('DOM.setFileInputFiles', { files: [abs], backendNodeId: chooser.params.backendNodeId });
      } finally {
        await send('Page.setInterceptFileChooserDialog', { enabled: false });
      }
      const ms = timeout ? +timeout * 1000 : 900000;
      await waitFor(async () => (await labels()).some((l) => l.startsWith('取り込み中止') || l.startsWith('中止')), 30000, 'import started').catch(() => {});
      const result = await waitFor(async () => {
        const ls = await labels();
        if (ls.some((l) => l.startsWith('取り込み中止') || l.startsWith('中止しています'))) return false;
        return ls.filter((l) => /取り込み|登録|認識|フレーム/.test(l));
      }, ms, 'import finished');
      return { result, shot: await shot(`import-${path.basename(abs)}`) };
    },

    // ---- OPFS
    async 'opfs-ls'({ path: p, depth }) {
      const parts = opfsParts(p);
      return evalJs(`(async () => { ${OPFS_AT_JS}
        const walk = async (d, prefix, left) => { const out = []; for await (const [n, h] of d.entries()) {
          if (h.kind === 'file') { const f = await h.getFile(); out.push({ path: prefix + n, size: f.size }); }
          else { out.push({ path: prefix + n + '/' }); if (left > 0) out.push(...await walk(h, prefix + n + '/', left - 1)); } } return out; };
        return walk(await at(${JSON.stringify(parts)}), ${JSON.stringify(parts.length ? parts.join('/') + '/' : '')}, ${+(depth ?? 2)});
      })()`);
    },
    async 'opfs-read'({ path: p }) {
      const parts = opfsParts(p);
      const file = parts.pop();
      return evalJs(`(async () => { ${OPFS_AT_JS} return (await (await at(${JSON.stringify(parts)})).getFileHandle(${JSON.stringify(file)})).getFile().then(f => f.text()); })()`);
    },
    async 'opfs-write'({ path: p, text, file }) {
      await requireAppClosedFor(p);
      const parts = opfsParts(p);
      const name = parts.pop();
      const b64 = (file !== undefined ? readFileSync(path.resolve(file)) : Buffer.from(String(text ?? ''), 'utf8')).toString('base64');
      return evalJs(`(async () => { ${OPFS_AT_JS}
        const bytes = Uint8Array.from(atob(${JSON.stringify(b64)}), c => c.charCodeAt(0));
        const w = await (await (await at(${JSON.stringify(parts)}, true)).getFileHandle(${JSON.stringify(name)}, { create: true })).createWritable();
        await w.write(bytes); await w.close(); return { path: ${JSON.stringify(p)}, size: bytes.length }; })()`);
    },
    async 'opfs-rm'({ path: p, recursive }) {
      await requireAppClosedFor(p);
      const parts = opfsParts(p);
      const name = parts.pop();
      return evalJs(`(async () => { ${OPFS_AT_JS}
        await (await at(${JSON.stringify(parts)})).removeEntry(${JSON.stringify(name)}, { recursive: ${!!recursive} }); return 'removed'; })()`);
    },
    // Copies a local directory tree into OPFS under [to], file by file.
    async 'opfs-push'({ from, to }) {
      await requireAppClosedFor(to);
      const root = path.resolve(from);
      const files = [];
      const walk = (d) => { for (const e of readdirSync(d, { withFileTypes: true })) { const f = path.join(d, e.name); if (e.isDirectory()) walk(f); else files.push(f); } };
      walk(root);
      let bytes = 0;
      for (const f of files) {
        const rel = path.relative(root, f).split(path.sep).join('/');
        const r = await ops['opfs-write']({ path: `${opfsParts(to).join('/')}/${rel}`, file: f });
        bytes += r.size;
      }
      return { files: files.length, bytes };
    },

    // ---- the sheet's direct changes to B's data (columns 11 and 12, and the column-4 read).
    // Each leaves the app first, the way the sheet closes the app's tab; `open` brings the app back.
    async 'corrupt-record'({ id }) {
      if (!/^[0-9A-Za-z-]+$/.test(id ?? '')) throw new Error(`not a record id: ${id}`);
      await leaveApp();
      return evalJs(`(async () => { ${OPFS_AT_JS}
        const dir = await at(['umacapture', 'storage', 'chara_detail', 'active', ${JSON.stringify(id)}]);
        const w = await (await dir.getFileHandle('record.json')).createWritable(); await w.write('broken'); await w.close(); return 'done'; })()`);
    },
    async 'drop-sync-base'() {
      await leaveApp();
      return evalJs(`(async () => { ${OPFS_AT_JS}
        await (await at(['umacapture', 'storage', 'chara_detail', 'metadata', 'sync'])).removeEntry('base.json'); return 'done'; })()`);
    },
    async 'read-dismissed'() {
      return ops['opfs-read']({ path: 'umacapture/storage/chara_detail/metadata/enhancement_dismissed.json' });
    },
  };
  return ops;
}
