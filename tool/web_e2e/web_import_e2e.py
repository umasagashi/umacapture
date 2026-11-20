# /// script
# requires-python = ">=3.11"
# dependencies = ["websocket-client>=1.7"]
# ///
"""Headless end-to-end check of the built web app (video import or live capture), through the real wasm core.

What it drives (every interaction is a CDP call into the renderer; the OS pointer, keyboard and
foreground window are never touched, and Chrome runs --headless=new on a throwaway profile):

  1. Starts the repository's own server (tool/serve_web_build.py) on a free localhost port.
  2. Starts headless Chrome with every non-localhost host resolved to NOTFOUND, so nothing leaves
     the machine (no module download, no Sentry, no Chrome background traffic).
  3. Boots the app on an empty OPFS. The module download fails (blocked), so the dashboard shows the
     manual module update card; the harness opens it and "picks" a modules.zip built from the
     recognizer module set provisioned in the repository (the file-picker <input>.click is replaced; every app line after the pick runs
     as for a real pick). Bytes for the zip and the clip are served by CDP Fetch interception of
     /__e2e/* on the app's own origin, so the server is used unmodified.
  4. Opens the capture page, presses the video-import button, "picks" the clip, waits until the
     record's prediction.json has appeared in OPFS and the console has been quiet for a while.
  5. Dumps OPFS (every .json as text) and the console of the page and every worker, then kills
     Chrome and the server and confirms both are gone.

From the moment the server starts, <out>/resources.json names the throwaway profile, both ports and
both PIDs (chrome_pid stays null until Chrome starts), so a caller can check the cleanup on its own.

Comparison against the golden is done by compare_record.py (separate, so it can be rerun and
positive-controlled without a browser).
"""

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

import websocket

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CHROME_CANDIDATES = [
    Path(os.environ.get(v, "")) / "Google" / "Chrome" / "Application" / "chrome.exe"
    for v in ("PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA") if os.environ.get(v)
]


def find_chrome(explicit):
    """--chrome if given, else chrome.exe on PATH, else the standard Windows install locations."""
    if explicit:
        return explicit
    found = shutil.which("chrome") or next((str(p) for p in CHROME_CANDIDATES if p.is_file()), None)
    if not found:
        sys.exit("Google Chrome not found; pass --chrome PATH")
    return found


def chrome_command(chrome, cdp_port, profile):
    """The headless Chrome command line. `--mute-audio` keeps the app's capture chimes off the
    speakers: headless Chrome still plays audio to the default output device, autoplay is allowed
    here, and the machine the check runs on may be in use by a person (.claude/rules/silent-automated-runs.md)."""
    return [
        chrome, "--headless=new", "--mute-audio", f"--remote-debugging-port={cdp_port}", f"--user-data-dir={profile}",
        "--no-first-run", "--no-default-browser-check", "--remote-allow-origins=*",
        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
        "--autoplay-policy=no-user-gesture-required", "--disable-background-networking", "--disable-component-update", "--disable-sync",
        "--disable-domain-reliability", "--no-pings", "--metrics-recording-only",
        "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
        "--disable-backgrounding-occluded-windows", "--window-size=1280,1600", "about:blank"]


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Cdp:
    def __init__(self, url):
        self.ws = websocket.create_connection(url, max_size=512 * 1024 * 1024)
        self._id = 0
        self.console = []  # (t, session, level, text)
        self._pending = {}
        self.child_sessions = []
        self.blobs = {}  # url suffix -> path

    def send(self, method, params=None, session=None):
        self._id += 1
        msg = {"id": self._id, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        self.ws.send(json.dumps(msg))
        return self._id

    def call(self, method, params=None, session=None, timeout=30.0):
        mid = self.send(method, params, session)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if mid in self._pending:
                r = self._pending.pop(mid)
                if "error" in r:
                    raise RuntimeError(f"{method}: {r['error']}")
                return r
            self.poll(0.2)
        raise TimeoutError(f"{method} timed out")

    def poll(self, seconds=0.2):
        end = time.time() + seconds
        while True:
            try:
                self.ws.settimeout(max(0.01, end - time.time()))
                raw = self.ws.recv()
            except websocket.WebSocketTimeoutException:
                return
            msg = json.loads(raw)
            if "id" in msg:
                self._pending[msg["id"]] = msg
            else:
                self._on_event(msg)
            if time.time() >= end:
                return

    def _on_event(self, msg):
        method = msg.get("method", "")
        params = msg.get("params", {})
        sid = msg.get("sessionId", "page")
        if method == "Runtime.consoleAPICalled":
            parts = []
            for a in params.get("args", []):
                if "value" in a:
                    parts.append(str(a["value"]))
                elif a.get("description"):
                    parts.append(a["description"])
                else:
                    parts.append(json.dumps(a.get("preview", {}))[:300])
            self.console.append((time.time(), sid, params.get("type", "log"), " ".join(parts)))
        elif method == "Runtime.exceptionThrown":
            det = params.get("exceptionDetails", {})
            self.console.append((time.time(), sid, "exception", json.dumps(det)[:3000]))
        elif method == "Log.entryAdded":
            e = params.get("entry", {})
            self.console.append((time.time(), sid, "browser-" + e.get("level", ""), f"{e.get('text', '')} {e.get('url', '')}"))
        elif method == "Fetch.requestPaused":
            self._fulfil(params, sid)
        elif method == "Target.attachedToTarget":
            child = params["sessionId"]
            if child not in self.child_sessions:
                self.child_sessions.append(child)
            for m, p in (("Runtime.enable", {}), ("Runtime.runIfWaitingForDebugger", {}),
                         ("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": False, "flatten": True})):
                self.send(m, p, session=child)

    def _fulfil(self, params, sid):
        url = params["request"]["url"]
        m = re.match(r"https://www\.gstatic\.com/flutter-canvaskit/[0-9a-f]+/(.+?)(\?|$)", url)
        if m:
            # The build bootstraps CanvasKit from Google's CDN, which the offline profile cannot reach.
            # build/web/canvaskit holds the copy `flutter build web` put there for the same engine.
            p = self.canvaskit_dir / m.group(1)
            mime = "application/wasm" if p.suffix == ".wasm" else "text/javascript"
            body = base64.b64encode(p.read_bytes()).decode() if p.is_file() else ""
            self.send("Fetch.fulfillRequest", {
                "requestId": params["requestId"], "responseCode": 200 if p.is_file() else 404,
                "responseHeaders": [{"name": "Content-Type", "value": mime},
                                    {"name": "Access-Control-Allow-Origin", "value": "*"},
                                    {"name": "Cross-Origin-Resource-Policy", "value": "cross-origin"}],
                "body": body}, session=None if sid == "page" else sid)
            return
        if url.startswith("https://fonts.gstatic.com/"):
            # Offline profile: answer every Google-Fonts request with the local Noto Sans JP, so text
            # renders and the engine does not retry the fetch in a loop (200k console lines otherwise).
            self.send("Fetch.fulfillRequest", {
                "requestId": params["requestId"], "responseCode": 200,
                "responseHeaders": [{"name": "Content-Type", "value": "font/ttf"},
                                    {"name": "Access-Control-Allow-Origin", "value": "*"},
                                    {"name": "Cross-Origin-Resource-Policy", "value": "cross-origin"}],
                "body": self.font_b64}, session=None if sid == "page" else sid)
            return
        name = url.split("/__e2e/", 1)[-1].split("?")[0]
        path = self.blobs.get(name)
        if path is None:
            self.send("Fetch.fulfillRequest", {"requestId": params["requestId"], "responseCode": 404, "body": ""},
                      session=None if sid == "page" else sid)
            return
        body = base64.b64encode(Path(path).read_bytes()).decode()
        self.send("Fetch.fulfillRequest", {
            "requestId": params["requestId"], "responseCode": 200,
            "responseHeaders": [{"name": "Content-Type", "value": "application/octet-stream"},
                                {"name": "Cross-Origin-Resource-Policy", "value": "same-origin"}],
            "body": body}, session=None if sid == "page" else sid)

    def evaluate(self, expr, session=None, await_promise=False, timeout=60.0):
        r = self.call("Runtime.evaluate", {"expression": expr, "returnByValue": True, "awaitPromise": await_promise},
                      session=session, timeout=timeout)
        res = r.get("result", {})
        if "exceptionDetails" in res:
            raise RuntimeError(json.dumps(res["exceptionDetails"])[:1500])
        return res.get("result", {}).get("value")


# Replaces the native file dialog: any <input type=file>.click() fetches the next queued /__e2e/ blob,
# sets it as the input's files, and dispatches `change`.
FILE_INPUT_OVERRIDE = """
(() => {
  window.__e2eNext = %s;
  if (window.__e2ePatched) return 'already';
  window.__e2ePatched = true;
  const orig = HTMLInputElement.prototype.click;
  HTMLInputElement.prototype.click = function () {
    const cfg = window.__e2eNext;
    if (this.type !== 'file' || !cfg) return orig.apply(this, arguments);
    const self = this;
    fetch(cfg.url).then((r) => r.blob()).then((b) => {
      const f = new File([b], cfg.name, { type: cfg.type, lastModified: 1785000000000 });
      const dt = new DataTransfer();
      dt.items.add(f);
      self.files = dt.files;
      window.__e2eFed = { name: f.name, size: f.size };
      self.dispatchEvent(new Event('change', { bubbles: true }));
    }).catch((e) => { window.__e2eFed = { error: String(e) }; });
  };
  return 'patched';
})()
"""

SEMANTICS = """
(() => {
  const p = document.querySelector('flt-semantics-placeholder');
  if (p) p.click();
  const out = [];
  document.querySelectorAll('flt-semantics').forEach((n) => {
    const r = n.getBoundingClientRect();
    out.push({ role: n.getAttribute('role'), label: n.getAttribute('aria-label'),
      text: (n.textContent || '').slice(0, 60), x: r.x, y: r.y, w: r.width, h: r.height });
  });
  return JSON.stringify(out);
})()
"""


def find(cdp, needle, role=None):
    try:
        # The page's main thread can be busy for tens of seconds (zip extraction, decode setup).
        nodes = json.loads(cdp.evaluate(SEMANTICS, timeout=180.0))
    except TimeoutError:
        return None
    hits = [n for n in nodes if needle in ((n.get("label") or "") + " | " + (n.get("text") or ""))
            and n["w"] > 0 and n["h"] > 0 and (role is None or n.get("role") == role)]
    hits.sort(key=lambda n: n["w"] * n["h"])
    return hits[0] if hits else None


def click_text(cdp, needle, timeout=30.0, role=None):
    deadline = time.time() + timeout
    while time.time() < deadline:
        n = find(cdp, needle, role)
        if n is not None:
            x, y = n["x"] + n["w"] / 2, n["y"] + n["h"] / 2
            for kind in ("mousePressed", "mouseReleased"):
                cdp.call("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left",
                                                      "clickCount": 1, "buttons": 1 if kind == "mousePressed" else 0})
            cdp.poll(1.0)
            return n
        cdp.poll(0.5)
    visible = [(n.get("label"), n.get("text")) for n in json.loads(cdp.evaluate(SEMANTICS, timeout=180)) if n["w"] > 0]
    raise RuntimeError(f"no semantics node containing {needle!r}; visible: " + json.dumps(visible[:80]))


def feed_next(cdp, name, mime):
    cdp.evaluate(FILE_INPUT_OVERRIDE % json.dumps({"url": "/__e2e/" + name, "name": name, "type": mime}))
    cdp.evaluate("window.__e2eFed = null")


def wait_fed(cdp, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        cdp.poll(0.5)
        fed = cdp.evaluate("JSON.stringify(window.__e2eFed || null)")
        if fed and fed != "null":
            return fed
    raise TimeoutError("the file picker override was never fed")


# Replaces navigator.mediaDevices.getDisplayMedia (the share picker) with a stream that plays the clip:
# a hidden <video> is drawn frame by frame onto a canvas, and canvas.captureStream() is the "shared
# window". Everything after getDisplayMedia -- startLiveFromTrack, the worker's pull loop, the core --
# is the release build's own code. resizeAt > 0 changes the canvas size that many seconds in, which is
# what a game window resized mid-capture looks like to the track.
LIVE_STUB = """
(() => {
  const cfg = %s;
  window.__e2eLive = { started: false, ended: false, frames: 0, resized: false };
  navigator.mediaDevices.getDisplayMedia = async () => {
    const blob = await (await fetch(cfg.url)).blob();
    const video = document.createElement('video');
    video.muted = true; video.playsInline = true; video.src = URL.createObjectURL(blob);
    await new Promise((r) => { video.onloadedmetadata = r; });
    const canvas = document.createElement('canvas');
    canvas.width = video.videoWidth; canvas.height = video.videoHeight;
    const ctx = canvas.getContext('2d');
    const draw = () => {
      if (cfg.resizeAt > 0 && !window.__e2eLive.resized && video.currentTime >= cfg.resizeAt) {
        canvas.width = Math.round(video.videoWidth * cfg.resizeScale / 2) * 2;
        canvas.height = Math.round(video.videoHeight * cfg.resizeScale / 2) * 2;
        window.__e2eLive.resized = { at: video.currentTime, w: canvas.width, h: canvas.height };
      }
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      window.__e2eLive.frames++;
      if (!video.ended) video.requestVideoFrameCallback(draw);
    };
    video.onended = () => { window.__e2eLive.ended = true; };
    ctx.drawImage(video, 0, 0);
    const stream = canvas.captureStream(30);
    await video.play();
    video.requestVideoFrameCallback(draw);
    window.__e2eLive.started = { w: canvas.width, h: canvas.height, duration: video.duration };
    return stream;
  };
  return 'stubbed';
})()
"""

# Looks for texts among the accessibility nodes' OWN text (aria-label and direct text nodes, so a
# container does not match on its children's text). A match counts as visible only when the node and
# every ancestor are rendered (display, visibility, opacity, aria-hidden) and its box is non-empty and
# inside the viewport; matches that fail this are returned as visible=false and never counted.
VISIBLE_TEXT = """
(() => {
  const needles = %s;
  const p = document.querySelector('flt-semantics-placeholder');
  if (p) p.click();
  const vw = window.innerWidth, vh = window.innerHeight;
  const shown = (n) => {
    for (let e = n; e && e !== document.documentElement; e = e.parentElement) {
      const s = getComputedStyle(e);
      if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
      if (e.getAttribute && e.getAttribute('aria-hidden') === 'true') return false;
    }
    const r = n.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && r.right > 0 && r.bottom > 0 && r.left < vw && r.top < vh;
  };
  const own = (n) => {
    let t = n.getAttribute('aria-label') || '';
    for (const c of n.childNodes) if (c.nodeType === 3) t += ' ' + c.textContent;
    return t;
  };
  const out = { nodes: 0, matches: [] };
  document.querySelectorAll('flt-semantics-host *, flt-semantics').forEach((n) => {
    out.nodes++;
    const t = own(n);
    for (const nd of needles) {
      if (!t.includes(nd)) continue;
      const r = n.getBoundingClientRect();
      out.matches.push({ needle: nd, visible: shown(n), tag: n.tagName.toLowerCase(), role: n.getAttribute('role'),
        label: t.slice(0, 160), rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)] });
    }
  });
  return JSON.stringify(out);
})()
"""


class Watcher:
    """Polls the UI for texts that must be visible (expect) or must never be visible (forbid)."""

    def __init__(self, expect, forbid):
        self.expect, self.forbid = list(expect), list(forbid)
        self.needles = self.expect + [f for f in self.forbid if f not in self.expect]
        self.times = []  # seconds since `start` of every successful observation
        self.failed = 0  # observations that timed out (page busy)
        self.first_visible = {}  # needle -> {t, node}
        self.hidden_matches = {n: 0 for n in self.needles}  # present-but-not-visible matches, never counted
        self.visible_obs = {n: 0 for n in self.needles}

    def observe(self, cdp, start):
        if not self.needles:
            return
        try:
            res = json.loads(cdp.evaluate(VISIBLE_TEXT % json.dumps(self.needles), timeout=20))
        except TimeoutError:
            self.failed += 1
            return
        t = round(time.time() - start, 3)
        self.times.append(t)
        seen_now = set()
        for m in res["matches"]:
            if m["visible"]:
                seen_now.add(m["needle"])
                self.first_visible.setdefault(m["needle"], {"t": t, "node": m})
            else:
                self.hidden_matches[m["needle"]] += 1
        for n in self.needles:
            self.visible_obs[n] += n in seen_now

    def frequency(self):
        gaps = sorted(b - a for a, b in zip(self.times, self.times[1:]))
        if not gaps:
            return {"observations": len(self.times), "failed_observations": self.failed}
        return {"observations": len(self.times), "failed_observations": self.failed,
                "span_s": round(self.times[-1] - self.times[0], 1), "gap_min_s": round(gaps[0], 3),
                "gap_median_s": round(gaps[len(gaps) // 2], 3), "gap_max_s": round(gaps[-1], 3)}

OPFS_COUNT = """
(async () => {
  const names = [];
  async function walk(d, p) { for await (const [k, h] of d.entries()) {
    if (h.kind === 'directory') await walk(h, p + '/' + k);
    else if (k === 'prediction.json') names.push(p + '/' + k); } }
  await walk(await navigator.storage.getDirectory(), '');
  return JSON.stringify(names);
})()
"""


def write_resources(out: Path, resources):
    """Record what this run started (profile, ports, PIDs) in <out>/resources.json, rewritten whenever a
    resource is added, so a caller can check the cleanup itself even if this process dies mid-run."""
    tmp = out / "resources.json.tmp"
    tmp.write_text(json.dumps(resources, indent=1), encoding="utf-8")
    os.replace(tmp, out / "resources.json")


def build_modules_zip(modules_dir: Path, out: Path):
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(modules_dir.rglob("*")):
            if p.is_file():
                z.write(p, "modules/" + p.relative_to(modules_dir).as_posix())


def judge(args, data, watcher, console, live_state):
    """Pass/fail of everything the run itself can establish. Each entry is {name, ok, detail}."""
    checks = []

    def add(name, ok, detail):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    paths = [f["path"] for f in data["files"]]
    records = [p for p in paths if re.search(r"/chara_detail/active/[^/]+/record\.json$", p)]
    preds = [p for p in paths if re.search(r"/chara_detail/active/[^/]+/prediction\.json$", p)]
    if args.expect_outcome == "record":
        add("outcome=record", records and preds, f"{len(records)} active record(s), {len(preds)} prediction.json")
    else:
        add("outcome=refused", not records and not preds, f"{len(records)} active record(s), {len(preds)} prediction.json")
    if args.mode == "live":
        want_resize = args.resize_at > 0
        add("stimulus", bool(live_state and live_state.get("resized")) == want_resize,
            f"resize requested={want_resize}; track state={json.dumps(live_state)}")
        add("clip played to its end", bool(live_state and live_state.get("ended")), f"ended={live_state and live_state.get('ended')}")
    freq = watcher.frequency()
    for text in watcher.expect:
        seen = watcher.first_visible.get(text)
        add(f"expect-visible {text!r}", seen is not None,
            f"visible at {watcher.visible_obs[text]}/{len(watcher.times)} observations"
            + (f", first at {seen['t']} s in node {json.dumps(seen['node'], ensure_ascii=False)}" if seen else "")
            + f"; present-but-hidden matches (not counted): {watcher.hidden_matches[text]}; observed {json.dumps(freq)}")
    for text in watcher.forbid:
        n = watcher.visible_obs[text]
        add(f"forbid-visible {text!r}", n == 0 and len(watcher.times) > 0,
            f"visible at {n}/{len(watcher.times)} observations; present-but-hidden matches (not counted): "
            f"{watcher.hidden_matches[text]}; observed {json.dumps(freq)}")
    lines = [c[3] for c in console]
    for rx in args.expect_console:
        n = sum(1 for ln in lines if re.search(rx, ln))
        add(f"expect-console /{rx}/", n > 0, f"{n} matching line(s) of {len(lines)}")
    for rx in args.forbid_console:
        n = sum(1 for ln in lines if re.search(rx, ln))
        add(f"forbid-console /{rx}/", n == 0, f"{n} matching line(s) of {len(lines)}")
    return {"observation": freq, "checks": checks}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(REPO), help="repository root (holds build/web, tool/, sandbox/modules)")
    ap.add_argument("--chrome", default=None, help="chrome.exe (default: PATH, then the standard install locations)")
    ap.add_argument("--clip", required=True)
    ap.add_argument("--out", required=True, help="output directory for this run")
    ap.add_argument("--mode", choices=("import", "live"), default="import")
    ap.add_argument("--resize-at", type=float, default=0.0,
                    help="live only: seconds into playback at which the shared surface changes size (0 = never)")
    ap.add_argument("--resize-scale", type=float, default=0.9, help="live only: new size = original * this")
    ap.add_argument("--expect-text", action="append", default=[],
                    help="this text must be VISIBLE in the UI at some observation (repeatable)")
    ap.add_argument("--forbid-text", action="append", default=[],
                    help="this text must be visible at NO observation of the whole run (repeatable)")
    ap.add_argument("--expect-console", action="append", default=[],
                    help="regex that must match some console line of the page or a worker (repeatable)")
    ap.add_argument("--forbid-console", action="append", default=[],
                    help="regex that must match no console line (repeatable)")
    ap.add_argument("--expect-outcome", choices=("record", "refused"), default="record",
                    help="record: a record and prediction.json are written; refused: neither is")
    ap.add_argument("--font", default=str(Path(os.environ.get("WINDIR", r"C:\Windows")) / "Fonts" / "NotoSansJP-VF.ttf"),
                    help="font served for every Google Fonts request (the profile is offline)")
    ap.add_argument("--import-timeout", type=float, default=900.0)
    ap.add_argument("--quiet-seconds", type=float, default=20.0,
                    help="after the first prediction.json, wait until the console is silent this long")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    zip_path = out / "modules.zip"
    build_modules_zip(repo / "sandbox" / "modules", zip_path)
    clip = Path(args.clip).resolve()

    http_port, cdp_port = free_port(), free_port()
    origin = f"http://127.0.0.1:{http_port}"
    server = subprocess.Popen(["uv", "run", "--quiet", str(repo / "tool" / "serve_web_build.py"),
                               "--port", str(http_port), "--directory", str(repo / "build" / "web")],
                              cwd=str(repo), stdout=open(out / "server.log", "w"), stderr=subprocess.STDOUT,
                              creationflags=subprocess.CREATE_NO_WINDOW)
    profile = tempfile.mkdtemp(prefix="uma-e2e-chrome-")
    chrome = None
    cdp = None
    rc = 1
    watcher = Watcher(args.expect_text, args.forbid_text)
    resources = {"profile": profile, "http_port": http_port, "cdp_port": cdp_port, "server_pid": server.pid,
                 "chrome_pid": None}
    write_resources(out, resources)
    print(f"PROFILE {profile}", flush=True)
    print(f"PORTS http={http_port} cdp={cdp_port}", flush=True)
    print(f"SERVER-PID {server.pid}", flush=True)
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(origin + "/index.html", timeout=1).read()
                break
            except Exception:
                time.sleep(0.3)
        else:
            raise RuntimeError("server did not come up")
        chrome = subprocess.Popen(chrome_command(find_chrome(args.chrome), cdp_port, profile),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
        resources["chrome_pid"] = chrome.pid
        write_resources(out, resources)
        print(f"CHROME-PID {chrome.pid}", flush=True)
        version = None
        for _ in range(100):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{cdp_port}/json/version", timeout=1) as r:
                    version = json.load(r)
                break
            except Exception:
                time.sleep(0.3)
        print("BROWSER", version and version.get("Browser"), flush=True)
        with urllib.request.urlopen(f"http://127.0.0.1:{cdp_port}/json/list", timeout=5) as r:
            page = next(t for t in json.load(r) if t["type"] == "page")
        cdp = Cdp(page["webSocketDebuggerUrl"])
        cdp.font_b64 = base64.b64encode(Path(args.font).read_bytes()).decode()
        cdp.canvaskit_dir = repo / "build" / "web" / "canvaskit"
        cdp.blobs = {"modules.zip": str(zip_path), clip.name: str(clip)}
        for m, p in (("Runtime.enable", {}), ("Page.enable", {}), ("Log.enable", {}),
                     ("Fetch.enable", {"patterns": [{"urlPattern": "*/__e2e/*"}, {"urlPattern": "https://www.gstatic.com/flutter-canvaskit/*"},
                                            {"urlPattern": "https://fonts.gstatic.com/*"}]}),
                     ("Target.setAutoAttach", {"autoAttach": True, "waitForDebuggerOnStart": False, "flatten": True})):
            cdp.call(m, p)
        cdp.call("Page.navigate", {"url": origin + "/"})
        t0 = time.time()
        # Boot is done when the dashboard shows the manual module-update card (download is blocked).
        click_text(cdp, "認識モジュールを自動取得できませんでした", timeout=240)
        print(f"BOOT+MODULE-CARD {time.time() - t0:.1f}s", flush=True)
        feed_next(cdp, "modules.zip", "application/zip")
        click_text(cdp, "ファイルを選択", role="button", timeout=30)
        print("MODULES-FED", wait_fed(cdp), flush=True)
        cdp.poll(5.0)
        deadline = time.time() + 120
        while time.time() < deadline and find(cdp, "認識モジュールの手動更新") is not None:
            cdp.poll(1.0)
        print("MODULE-DIALOG-CLOSED", find(cdp, "認識モジュールの手動更新") is None, flush=True)
        cdp.poll(3.0)
        # At this window width the app shows a navigation rail (no drawer); the capture tab is 2/5.
        click_text(cdp, "キャプチャ\nタブ: 2/5")
        cdp.poll(3.0)
        start = time.time()
        if args.mode == "import":
            feed_next(cdp, clip.name, "video/mp4")
            click_text(cdp, "動画取り込み", timeout=60)
            print("CLIP-FED", wait_fed(cdp), flush=True)
        else:
            # Live: the share picker is replaced by a canvas stream that plays the clip in real time.
            cdp.evaluate(LIVE_STUB % json.dumps({"url": "/__e2e/" + clip.name, "resizeAt": args.resize_at,
                                                 "resizeScale": args.resize_scale}))
            click_text(cdp, "画面キャプチャ", timeout=60)
            deadline = time.time() + 60
            while time.time() < deadline and not cdp.evaluate("!!(window.__e2eLive && window.__e2eLive.started)"):
                cdp.poll(0.5)
            print("LIVE-STARTED", cdp.evaluate("JSON.stringify(window.__e2eLive)"), flush=True)
            deadline = time.time() + args.import_timeout
            while time.time() < deadline and not cdp.evaluate("!!(window.__e2eLive && window.__e2eLive.ended)"):
                cdp.poll(0.25)
                watcher.observe(cdp, start)
            cdp.poll(3.0)
            watcher.observe(cdp, start)
            print("LIVE-ENDED", cdp.evaluate("JSON.stringify(window.__e2eLive)"), flush=True)
            try:
                click_text(cdp, "キャプチャ停止", timeout=20)
                print("STOP-CLICKED", flush=True)
            except RuntimeError as e:
                print("STOP-NOT-FOUND", str(e)[:300], flush=True)
        deadline = time.time() + args.import_timeout
        names = "[]"
        while time.time() < deadline:
            if args.mode == "live" and time.time() - start > 0 and names == "[]" and \
                    time.time() - cdp.console[-1][0] > args.quiet_seconds * 3:
                break  # live run that produced nothing: stop waiting once the console has gone quiet
            cdp.poll(2.0)
            watcher.observe(cdp, start)
            names = cdp.evaluate(OPFS_COUNT, await_promise=True)
            if names != "[]" and time.time() - cdp.console[-1][0] > args.quiet_seconds:
                break
        print(f"IMPORT-DONE {time.time() - start:.1f}s predictions={names}", flush=True)
        walk = (HERE / "opfs_walk.js").read_text(encoding="utf-8")
        data = json.loads(cdp.evaluate(walk, await_promise=True, timeout=300.0))
        (out / "opfs.json").write_text(json.dumps(data, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
        watcher.observe(cdp, start)
        shot = cdp.call("Page.captureScreenshot", {"format": "png"}, timeout=60)
        (out / "final.png").write_bytes(base64.b64decode(shot["result"]["data"]))
        live_state = json.loads(cdp.evaluate("JSON.stringify(window.__e2eLive || null)")) if args.mode == "live" else None
        checks = judge(args, data, watcher, cdp.console, live_state)
        (out / "e2e_checks.json").write_text(json.dumps(checks, ensure_ascii=False, indent=1), encoding="utf-8")
        for c in checks["checks"]:
            print("CHECK", "ok  " if c["ok"] else "FAIL", c["name"], "-", c["detail"], flush=True)
        rc = 0 if all(c["ok"] for c in checks["checks"]) else 2
        print("E2E-VERDICT", "PASS" if rc == 0 else "FAIL", flush=True)
    finally:
        if cdp is not None:
            with open(out / "console.log", "w", encoding="utf-8") as f:
                for t, sid, lvl, txt in cdp.console:
                    f.write(f"{t:.3f}\t{sid}\t{lvl}\t{txt}\n")
            print("CONSOLE", len(cdp.console), "lines", flush=True)
        for proc in (chrome, server):
            if proc is not None:
                subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
                proc.wait(timeout=30)
        time.sleep(1.0)
        for _ in range(5):
            shutil.rmtree(profile, ignore_errors=True)
            if not os.path.exists(profile):
                break
            time.sleep(1.0)
        print(f"PROFILE-EXISTS {os.path.exists(profile)}", flush=True)
        for port in (http_port, cdp_port):
            s = socket.socket()
            alive = s.connect_ex(("127.0.0.1", port)) == 0
            s.close()
            print(f"PORT {port} {'STILL OPEN' if alive else 'closed'}", flush=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
