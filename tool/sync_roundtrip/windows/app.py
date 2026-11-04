# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets"]
# ///
"""Operate the Windows app of a sync round trip, one step per invocation.

`launch` starts the driver-enabled build (`test_driver/app.dart`) on an isolated data root, behind an
HTTPS_PROXY relay (relay.mjs) that can cut it off the network without a restart, and leaves it running.
Every other subcommand connects to that app over its pinned VM Service, performs one operation the way a
user does it -- through the widgets, the row's right-click menu, the hold-to-confirm buttons -- waits
until the app's own state says the operation took effect, prints one JSON object and exits. `stop`
closes the app and the relay and reports whether anything leaked into the user's real data root.

    uv run tool/sync_roundtrip/windows/app.py prepare --from <root> --root <root> [--logged-out]
    uv run tool/sync_roundtrip/windows/app.py launch --root <root> [--relay pass|refuse|drop|none]
    uv run tool/sync_roundtrip/windows/app.py list --shot list.png
    uv run tool/sync_roundtrip/windows/app.py rate fans:221134 3.5
    uv run tool/sync_roundtrip/windows/app.py stop

No native dialog is opened: the driver entry answers every file dialog from a queue this script fills
(`pick:` / `save:`), and dispatches clicks inside the app, so the OS cursor and the keyboard focus are
never touched. Exit status 0 means the operation was observed to take effect; 1 means it was not, and
the printed object carries `error`. See tool/sync_roundtrip/README.md, section "Windows".
"""

from __future__ import annotations

import argparse
import base64
import datetime
import json
import math
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "tool/live_capture_test"))
import app_drive_run as harness  # noqa: E402  (the VM Service client and the data-leak scan)

DEFAULT_EXE = ROOT / "build/windows/x64/runner/Profile/umacapture.exe"
DEFAULT_STATE_DIR = ROOT / ".notes/sync-roundtrip/windows"
TRANSLATIONS = ROOT / "assets/translations/ja.json"
DEFAULT_PORTS = {"vm": 18181, "proxy": 18080, "control": 18081}

ROUTES = {"capture": "CaptureRoute", "records": "CharaDetailRoute", "account": "AccountRoute", "settings": "SettingsRoute"}
# The page widget of each tab that lists its rows, which is what a drag scrolls.
PAGES = {"account": "AccountPage", "settings": "SettingsPage"}
# How long a hold-to-confirm button is held: its gauge fills in 1000 ms (kHoldToConfirmDuration).
HOLD_MS = 1600
POLL_SECONDS = 0.2


class Failure(RuntimeError):
    """An operation that was not observed to take effect."""


# ---------------------------------------------------------------------------------------- text


def _translations() -> dict:
    return json.loads(TRANSLATIONS.read_text(encoding="utf-8"))


_TABLE: dict | None = None


def tr(key: str, **named: object) -> str:
    """The app's Japanese text for [key], with `{name}` arguments filled in, as `.tr()` renders it."""
    global _TABLE
    if _TABLE is None:
        _TABLE = _translations()
    value: object = _TABLE
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            raise Failure(f"no translation for {key}")
        value = value[part]
    if not isinstance(value, str):
        raise Failure(f"{key} is not a sentence")
    for name, argument in named.items():
        value = value.replace("{" + name + "}", str(argument))
    return value


# ------------------------------------------------------------------------------------ the data root


def chara_detail(root: Path) -> Path:
    return root / "storage" / "chara_detail"


def _find_fans(node: object) -> int | None:
    if isinstance(node, dict):
        if isinstance(node.get("fans"), int):
            return node["fans"]
        children = node.values()
    elif isinstance(node, list):
        children = node
    else:
        return None
    for child in children:
        found = _find_fans(child)
        if found is not None:
            return found
    return None


def records_on_disk(root: Path) -> dict[str, dict]:
    """Every record of the data root, by id: its store and its fan count."""
    found: dict[str, dict] = {}
    for source in ("active", "archive"):
        for record_json in (chara_detail(root) / source).glob("*/record.json"):
            try:
                fans = _find_fans(json.loads(record_json.read_text(encoding="utf-8")))
            except (OSError, ValueError):
                fans = None
            found[record_json.parent.name] = {"source": source, "fans": fans}
    return found


def resolve_record(root: Path, reference: str) -> str:
    """A record id from `fans:<count>`, a whole id, or a unique id prefix of 8 or more characters."""
    records = records_on_disk(root)
    if reference.startswith("fans:"):
        fans = int(reference[5:])
        matches = [rid for rid, record in records.items() if record["fans"] == fans]
    elif reference in records:
        return reference
    elif len(reference) >= 8:
        matches = [rid for rid in records if rid.startswith(reference)]
    else:
        matches = []
    if len(matches) != 1:
        raise Failure(f"{reference} names {len(matches)} records on disk, not one")
    return matches[0]


def storage_columns(root: Path, kind: str) -> list[dict]:
    """The rating or memo storages of the data root: title, file and values by record id."""
    columns = []
    for path in sorted((chara_detail(root) / "metadata" / kind).glob("*.json")):
        try:
            content = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        columns.append({"title": content.get("title"), "file": path.name, "data": content.get("data") or {}})
    return columns


def storage_column(root: Path, kind: str, title: str | None, storage: str | None = None) -> dict:
    """The one storage named by [title] and, where two storages share a title, by a prefix of its file."""
    columns = storage_columns(root, kind)
    matches = [c for c in columns if (title is None or c["title"] == title)
               and (storage is None or c["file"].startswith(storage))]
    if len(matches) != 1:
        held = [f'{c["title"]} ({c["file"]})' for c in columns]
        raise Failure(f"{len(matches)} {kind} storages match {title!r} / {storage!r}; the root holds {held}; "
                      "name one with --column and --storage")
    return matches[0]


def stored_value(root: Path, kind: str, column: dict, record_id: str):
    """[record_id]'s value in [column]'s storage, or None while the app is rewriting the file (it is then
    briefly unreadable, and [storage_columns] skips it)."""
    try:
        return storage_column(root, kind, column["title"], column["file"])["data"].get(record_id)
    except Failure:
        return None


def notes_of(root: Path, record_id: str) -> dict:
    # Two storages can share a title (each device made its own); the file tells them apart.
    return {kind: {f'{c["title"]} ({c["file"][:8]})': c["data"].get(record_id) for c in storage_columns(root, kind)}
            for kind in ("rating", "memo")}


# ---------------------------------------------------------------------------------------- session


def session_path(state_dir: Path) -> Path:
    return state_dir / "session.json"


def load_session(state_dir: Path) -> dict:
    path = session_path(state_dir)
    if not path.exists():
        raise Failure(f"no running app is recorded in {path}; run launch first")
    return json.loads(path.read_text(encoding="utf-8"))


def pid_alive(pid: int) -> bool:
    listing = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, errors="replace").stdout
    return f'"{pid}"' in listing


def running_app_pids() -> list[int]:
    listing = subprocess.run(["tasklist", "/FI", "IMAGENAME eq umacapture.exe", "/FO", "CSV", "/NH"],
                             capture_output=True, text=True, errors="replace").stdout
    return [int(line.split('","')[1]) for line in listing.splitlines() if line.startswith('"umacapture.exe"')]


def poll(read, until, timeout: float, interval: float = POLL_SECONDS):
    """Reads until [until] holds of what was read; answers (last read, whether it held)."""
    deadline = time.monotonic() + timeout
    while True:
        value = read()
        if until(value):
            return value, True
        if time.monotonic() >= deadline:
            return value, False
        time.sleep(interval)


# ------------------------------------------------------------------------------------- the driver


def by_text(text: str) -> dict:
    return {"finderType": "ByText", "text": text}


def by_key(key: str) -> dict:
    return {"finderType": "ByValueKey", "keyValueString": key, "keyValueType": "String"}


def by_tooltip(text: str) -> dict:
    return {"finderType": "ByTooltipMessage", "text": text}


def by_type(name: str) -> dict:
    return {"finderType": "ByType", "type": name}


# `firstMatchOnly` stays false: flutter_test's first-match filter throws on an empty match, which turns a
# `waitFor` that should retry into an error. A finder that matches several widgets fails a tap instead.
def descendant(of: dict, matching: dict) -> dict:
    return {"finderType": "Descendant", "of": json.dumps(of), "matching": json.dumps(matching),
            "matchRoot": "false", "firstMatchOnly": "false"}


def ancestor(of: dict, matching: dict) -> dict:
    return {"finderType": "Ancestor", "of": json.dumps(of), "matching": json.dumps(matching),
            "matchRoot": "false", "firstMatchOnly": "false"}


def in_dialog(finder: dict) -> dict:
    """[finder] inside the open card dialog, so a label the page behind it also shows is not matched."""
    return descendant(by_type("CardDialog"), finder)


class App:
    """The running app of a session, over its VM Service."""

    def __init__(self, state_dir: Path, name: str) -> None:
        self.session = load_session(state_dir)
        self.root = Path(self.session["root"])
        logs = state_dir / "driver"
        logs.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.driver = harness.Driver(f"ws://127.0.0.1:{self.session['ports']['vm']}/ws", logs / f"{stamp}-{name}.log")
        self.driver.main_isolate()

    def close(self) -> None:
        self.driver.close()

    # ---- primitives

    def command(self, name: str, finder: dict | None = None, timeout_ms: int = 10000, **params: str) -> dict:
        return self.driver.command(name, rpc_timeout=timeout_ms / 1000 + 15, timeout=timeout_ms,
                                   **(finder or {}), **params)

    def request(self, message: str) -> dict:
        response = self.driver.command("request_data", rpc_timeout=60.0, message=message)
        answer = json.loads(response["message"])
        if isinstance(answer, dict) and "error" in answer:
            raise Failure(f"{message.split(':')[0]} answered {answer['error']}")
        return answer

    def exists(self, finder: dict, timeout_ms: int = 10000) -> bool:
        try:
            self.command("waitFor", finder, timeout_ms=timeout_ms)
            return True
        except harness.DriverTimeout:
            return False

    def absent(self, finder: dict, timeout_ms: int = 10000) -> bool:
        try:
            self.command("waitForAbsent", finder, timeout_ms=timeout_ms)
            return True
        except harness.DriverTimeout:
            return False

    def tap(self, finder: dict, timeout_ms: int = 10000) -> None:
        self.command("tap", finder, timeout_ms=timeout_ms)

    def offset(self, finder: dict, kind: str = "center", timeout_ms: int = 10000) -> tuple[float, float]:
        response = self.command("get_offset", finder, timeout_ms=timeout_ms, offsetType=kind)
        return response["dx"], response["dy"]

    def text_of(self, finder: dict) -> str:
        return self.command("get_text", finder)["text"]

    def queue_answer(self, message: str) -> None:
        """Queues the answer of the next file dialog. One already waiting is an answer an operation that
        failed half way left behind, which would answer this operation's dialog in place of its own."""
        queued = self.request(message)["queued"]
        if queued != 1:
            raise Failure(f"{queued - 1} earlier file-dialog answer(s) are still queued; stop and relaunch the app")

    def press(self, x: float, y: float, buttons: int = 1, hold_ms: int = 50) -> None:
        self.request("pointer:" + json.dumps({"x": x, "y": y, "buttons": buttons, "hold_ms": hold_ms}))

    def hold(self, finder: dict, hold_ms: int = HOLD_MS) -> None:
        x, y = self.offset(finder)
        self.press(x, y, hold_ms=hold_ms)

    def scroll_into_view(self, finder: dict) -> None:
        self.command("scrollIntoView", finder, alignment="0.3")

    def reveal_on(self, page: str, finder: dict, drags: int = 20) -> None:
        """Opens the tab [page] and brings [finder] into view. The page builds its cards lazily, so one
        that is far down does not exist until the page is dragged towards it."""
        self.navigate(page)
        for _ in range(drags):
            if self.exists(finder, 300):
                self.scroll_into_view(finder)
                self.settle()
                return
            self.command("scroll", by_type(PAGES[page]), timeout_ms=10000, dx="0", dy="-400",
                         duration="150000", frequency="60")
        raise Failure(f"not found on the {page} page (the sync controls show only while logged in, and only "
                      "while sync is on)")

    def state(self) -> dict:
        state, ready = poll(lambda: self.request("harness_state"), lambda s: s.get("container"), 60)
        if not ready:
            raise Failure("the app's provider container never mounted")
        return state

    def sync_state(self) -> dict:
        return self.request("sync_state")

    def settle(self, timeout_ms: int = 3000) -> bool:
        """Waits for the running animations (a page transition, a dialog opening) to end; answers whether
        they did. A page that animates without end (the capture preview) ends the wait at the timeout."""
        try:
            self.command("waitForCondition", timeout_ms=timeout_ms, conditionName="NoTransientCallbacksCondition")
            return True
        except harness.DriverTimeout:
            return False

    def navigate(self, page: str) -> None:
        self.tap(by_key(f"nav_{ROUTES[page]}"))
        self.settle()

    def screenshot(self, path: Path) -> str:
        self.settle()
        response = self.driver.command("screenshot", rpc_timeout=60.0, format="4")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(base64.b64decode(response["data"]))
        return str(path)

    # ---- the grid

    def cell(self, record_id: str, column: str | None = None, inner: str | None = None, nth: int = 0) -> dict:
        """The on-screen rect of [record_id]'s cell in [column] (any column when None), whose centre is in
        the view; the grid page has to be showing the record's store. [nth] counts, from the left, the
        columns that share the title."""
        spec = {"record": record_id, "column": column, "inner": inner}

        def visible(answer: dict) -> list[dict]:
            # A cell wider than what is left of the view (a column sized to a long memo) is cut to its
            # visible part, so its centre is a point that can be pressed.
            view = answer["view"]
            cells = []
            for c in answer["cells"]:
                left, right = max(c["left"], 0), min(c["left"] + c["width"], view["width"])
                if right - left >= 20 and 0 <= c["top"] + c["height"] / 2 < view["height"]:
                    cells.append({**c, "left": left, "width": right - left})
            return cells

        answer, found = poll(lambda: self.request("locate_cell:" + json.dumps(spec)), lambda a: visible(a), 10)
        if not found:
            raise Failure(f"no cell of {record_id} in column {column!r} is on screen ({len(answer['cells'])} laid out)")
        cells = sorted(visible(answer), key=lambda c: c["left"])
        if nth >= len(cells):
            raise Failure(f"column {column!r} has {len(cells)} cells of {record_id} on screen, not {nth + 1}")
        return cells[nth]

    def press_cell(self, record_id: str, column: str | None = None, buttons: int = 1, nth: int = 0) -> None:
        cell = self.cell(record_id, column, nth=nth)
        self.press(cell["left"] + cell["width"] / 2, cell["top"] + cell["height"] / 2, buttons=buttons)

    def open_row_menu(self, record_id: str, item_key: str) -> None:
        """Right-clicks [record_id]'s row and chooses the menu item [item_key]."""
        self.press_cell(record_id, buttons=2)
        label = by_text(tr(item_key))
        if not self.exists(label, 5000):
            raise Failure("the row's context menu did not open")
        self.tap(label)

    def hold_until_gone(self, finder: dict, attempts: int = 3) -> int:
        """Holds a hold-to-confirm button until it leaves the tree (its dialog closed); a press that lands
        in the dialog's first frames is ignored, so it is held again, and a closed dialog cannot be held twice."""
        for attempt in range(1, attempts + 1):
            self.hold(finder)
            if self.absent(finder, 3000):
                return attempt
        raise Failure(f"the hold-to-confirm button was still there after {attempts} holds")


# -------------------------------------------------------------------------------------- operations


def op_prepare(args) -> dict:
    source, root = Path(args.source).resolve(), Path(args.root).resolve()
    if root.exists():
        raise Failure(f"{root} exists; prepare writes a fresh copy only")
    shutil.copytree(source, root, ignore=shutil.ignore_patterns("*.lock"))
    removed = []
    if args.logged_out:
        # The session lives in the record_shares box; without it the app is logged in to no account, so
        # sync is off for it and no round runs, whatever the settings box says sync was turned on for.
        for name in ("record_shares.hive", "record_shares.lock"):
            path = root / "settings" / name
            if path.exists():
                path.unlink()
                removed.append(str(path))
    return {"root": str(root), "from": str(source), "removed": removed,
            "records": len(records_on_disk(root))}


def start_relay(state_dir: Path, mode: str, ports: dict) -> int:
    log = (state_dir / "relay.log").open("a", encoding="utf-8")
    process = subprocess.Popen(["node", str(HERE / "relay.mjs"), str(ports["proxy"]), str(ports["control"]), mode],
                               stdout=log, stderr=subprocess.STDOUT, creationflags=_detached_flags())
    _, up = poll(lambda: _relay_get(ports["control"], "state"), lambda answer: answer == mode, 15)
    if not up:
        raise Failure("the relay never answered on its control port")
    return process.pid


def _relay_get(control_port: int, path: str) -> str | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{control_port}/{path}", timeout=2) as response:
            return response.read().decode().strip()
    except OSError:
        return None


def _detached_flags() -> int:
    return subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_BREAKAWAY_FROM_JOB


def _popen_detached(argv: list[str], **kwargs) -> subprocess.Popen:
    """Starts a process that outlives this script: out of its process group, and out of its job object
    where the job allows it."""
    try:
        return subprocess.Popen(argv, creationflags=_detached_flags(), **kwargs)
    except PermissionError:
        return subprocess.Popen(argv, creationflags=subprocess.CREATE_NEW_PROCESS_GROUP, **kwargs)


def op_launch(args) -> dict:
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    if session_path(state_dir).exists():
        previous = load_session(state_dir)
        if pid_alive(previous["pid"]):
            raise Failure(f"the app of this state dir is still running (pid {previous['pid']}); stop it first")
    running = running_app_pids()
    if running:
        raise Failure(f"umacapture.exe is already running (pids {running}); the round trip launches only its own")
    root, exe = Path(args.root).resolve(), Path(args.exe).resolve()
    if not (root / "settings").is_dir():
        raise Failure(f"{root} is not a prepared data root (no settings/)")
    if not exe.exists():
        raise Failure(f"{exe} does not exist; build it first")
    ports = {"vm": args.vm_port, "proxy": args.proxy_port, "control": args.control_port}
    relay_pid = None if args.relay == "none" else start_relay(state_dir, args.relay, ports)

    switches = ["enable-dart-profiling=true", "enable-checked-mode=true", "verify-entry-points=true",
                f"vm-service-port={ports['vm']}", "disable-service-auth-codes=true"]
    environment = dict(os.environ)
    environment["UMACAPTURE_DATA_ROOT"] = str(root)
    for name in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy"):
        environment.pop(name, None)
    if relay_pid is not None:
        environment["HTTPS_PROXY"] = f"http://127.0.0.1:{ports['proxy']}"
    environment["FLUTTER_ENGINE_SWITCHES"] = str(len(switches))
    for index, switch in enumerate(switches, start=1):
        environment[f"FLUTTER_ENGINE_SWITCH_{index}"] = switch
    leak_before = harness.snapshot_real_records()
    app_log = state_dir / "app.log"
    with app_log.open("w", encoding="utf-8") as sink:
        process = _popen_detached([str(exe)], cwd=str(exe.parent), env=environment,
                                  stdout=sink, stderr=subprocess.STDOUT)
    session = {"pid": process.pid, "relay_pid": relay_pid, "relay": args.relay, "ports": ports,
               "root": str(root), "exe": str(exe),
               "exe_built": datetime.datetime.fromtimestamp(exe.stat().st_mtime).isoformat(timespec="seconds"),
               "log": str(app_log), "started": datetime.datetime.now().isoformat(timespec="seconds"),
               "leak_before": leak_before}
    session_path(state_dir).write_text(json.dumps(session, indent=2, ensure_ascii=False), encoding="utf-8")
    _, up = poll(lambda: _port_open(ports["vm"]) or not pid_alive(process.pid), lambda v: v, 180, 0.2)
    if not pid_alive(process.pid):
        raise Failure(f"the app exited during startup; see {app_log}")
    if not up:
        raise Failure("the VM Service never came up on the pinned port")
    app = App(state_dir, "launch")
    try:
        app.driver.wait_extension()
        app.driver.wait_root_widget()
        state = app.state()
        _, loaded = poll(app.state, lambda s: s["store"]["active_loaded"], 120)
        if not loaded:
            raise Failure("the record store never loaded")
        sync = app.sync_state()
    finally:
        app.close()
    return {"pid": process.pid, "relay": args.relay, "root": str(root), "exe_built": session["exe_built"],
            "active": len(state["store"]["active_ids"]), "sync": sync}


def _port_open(port: int) -> bool:
    import socket

    with socket.socket() as probe:
        probe.settimeout(1.0)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def op_stop(args) -> dict:
    state_dir = Path(args.state_dir)
    session = load_session(state_dir)
    pid = session["pid"]
    how = "already-exited"
    if pid_alive(pid):
        # WM_CLOSE to the app's windows, the way a user closes it.
        subprocess.run(["taskkill", "/PID", str(pid)], capture_output=True)
        _, closed = poll(lambda: pid_alive(pid), lambda alive: not alive, 60, 0.5)
        how = "clean"
        if not closed:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True)
            how = "killed"
    relay = None
    if session.get("relay_pid") and pid_alive(session["relay_pid"]):
        subprocess.run(["taskkill", "/F", "/PID", str(session["relay_pid"])], capture_output=True)
        relay = "stopped"
    leak = harness.scan_data_leak(session["leak_before"])
    stopped = state_dir / f"session.stopped-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    session_path(state_dir).rename(stopped)
    result = {"app": how, "relay": relay, "app_alive": pid_alive(pid), "leaked_record_dirs": leak["leaked_record_dirs"]}
    if leak["leaked_record_dirs"] or result["app_alive"]:
        raise Failure(json.dumps(result))
    return result


def op_relay(args) -> dict:
    session = load_session(Path(args.state_dir))
    if session.get("relay_pid") is None:
        raise Failure("this session was launched without a relay")
    answer = _relay_get(session["ports"]["control"], args.mode)
    if answer != args.mode:
        raise Failure(f"the relay answered {answer!r}")
    return {"relay": answer}


def op_state(app: App, args) -> dict:
    return app.state()


def op_sync_state(app: App, args) -> dict:
    return app.sync_state()


def op_list(app: App, args) -> dict:
    app.navigate("records")
    state = app.state()
    disk = records_on_disk(app.root)
    fans = lambda ids: [{"id": rid, "fans": disk.get(rid, {}).get("fans")} for rid in ids]  # noqa: E731
    return {"active_count": len(state["store"]["active_ids"]), "archive_count": len(state["store"]["archive_ids"]),
            "active": fans(state["store"]["active_ids"]), "archive": fans(state["store"]["archive_ids"]),
            "candidates": state["candidates"]}


def op_notes(app: App, args) -> dict:
    record_id = resolve_record(app.root, args.record)
    return {"id": record_id, **notes_of(app.root, record_id)}


def _star_x(bar: dict, value: float) -> float:
    """Where on a five-star half-rating bar a tap sets [value]: the left half of star n sets n - 0.5,
    the right half sets n."""
    item = bar["width"] / 5
    star = math.ceil(value)
    return bar["left"] + (star - 1) * item + (item * 0.25 if star != value else item * 0.75)


def op_rate(app: App, args) -> dict:
    value = float(args.value)
    if value <= 0 or value > 5 or value * 2 != int(value * 2):
        raise Failure("a rating set by tapping is 0.5 to 5.0 in steps of 0.5")
    record_id = resolve_record(app.root, args.record)
    column = storage_column(app.root, "rating", args.column, args.storage)
    app.navigate("records")
    cell = app.cell(record_id, column["title"], inner="RatingBar", nth=args.nth)
    bar = cell.get("inner")
    if bar is None:
        raise Failure("the rating cell holds no RatingBar")
    if column["data"].get(record_id) is None:
        # An unrated cell takes the rating from a tap on its own stars.
        app.press(_star_x(bar, value), bar["top"] + bar["height"] / 2)
        via = "cell"
    else:
        # A rated cell opens the rating dialog, whose stars take the tap; OK writes it.
        app.press(bar["left"] + bar["width"] / 2, bar["top"] + bar["height"] / 2)
        dialog_bar = in_dialog(by_type("RatingBar"))
        if not app.exists(dialog_bar, 5000):
            raise Failure("the rating dialog did not open")
        left, top = app.offset(dialog_bar, "topLeft")
        right, bottom = app.offset(dialog_bar, "bottomRight")
        app.press(_star_x({"left": left, "width": right - left}, value), (top + bottom) / 2)
        app.tap(by_tooltip(tr("pages.chara_detail.column_predicate.rating.dialog.ok_button.tooltip")))
        via = "dialog"
    read = lambda: stored_value(app.root, "rating", column, record_id)  # noqa: E731
    written, ok = poll(read, lambda v: v == value, 10)
    if not ok:
        raise Failure(f"the rating on disk is {written}, not {value}")
    return {"id": record_id, "column": column["title"], "storage": column["file"], "rating": written, "via": via}


def op_memo(app: App, args) -> dict:
    record_id = resolve_record(app.root, args.record)
    column = storage_column(app.root, "memo", args.column, args.storage)
    app.navigate("records")
    field = in_dialog(by_type("TextField"))
    # The grid opens a cell's dialog on a click on its current cell, so the first click of a cell that is
    # not current only makes it current.
    for _ in range(2):
        app.press_cell(record_id, column["title"], nth=args.nth)
        if app.exists(field, 1500):
            break
    if not app.exists(field, 5000):
        raise Failure("the memo dialog did not open (a cell click only moves the focus while the side preview is open)")
    app.command("enter_text", text=args.text)
    app.tap(by_tooltip(tr("pages.chara_detail.column_predicate.memo.dialog.ok_button.tooltip")))
    read = lambda: stored_value(app.root, "memo", column, record_id)  # noqa: E731
    written, ok = poll(read, lambda v: v == args.text, 10)
    if not ok:
        raise Failure(f"the memo on disk is {written!r}, not {args.text!r}")
    return {"id": record_id, "column": column["title"], "storage": column["file"], "memo": written}


def op_archive(app: App, args) -> dict:
    record_id = resolve_record(app.root, args.record)
    app.navigate("records")
    app.open_row_menu(record_id, "pages.chara_detail.context_menu.archive_record")
    option = {"jpeg": "resized_jpeg", "none": "none"}[args.images]
    option_label = in_dialog(by_text(tr(f"pages.chara_detail.archive_records.dialog.option.{option}.label")))
    if not app.exists(option_label, 5000):
        raise Failure("the archive dialog did not open")
    app.tap(option_label)
    holds = app.hold_until_gone(in_dialog(by_text(tr("pages.chara_detail.archive_records.dialog.ok_button.label"))))
    state, done = poll(app.state, lambda s: record_id in s["store"]["archive_ids"]
                       and record_id not in s["store"]["active_ids"], 60)
    if not done:
        raise Failure(f"{record_id} did not move to the archive")
    return {"id": record_id, "images": args.images, "holds": holds,
            "active_count": len(state["store"]["active_ids"]), "archive_count": len(state["store"]["archive_ids"])}


def op_delete(app: App, args) -> dict:
    record_id = resolve_record(app.root, args.record)
    app.navigate("records")
    app.open_row_menu(record_id, "pages.chara_detail.context_menu.delete_record")
    confirm = in_dialog(by_text(tr("pages.chara_detail.delete_record.dialog.ok_button.label")))
    if not app.exists(confirm, 5000):
        raise Failure("the delete dialog did not open")
    holds = app.hold_until_gone(confirm)
    state, done = poll(app.state, lambda s: record_id not in s["store"]["active_ids"]
                       and record_id not in s["store"]["archive_ids"], 60)
    if not done:
        raise Failure(f"{record_id} is still listed")
    return {"id": record_id, "holds": holds, "active_count": len(state["store"]["active_ids"])}


def op_merge(app: App, args) -> dict:
    """Merges the candidate pair of two records from the settings tile's review list, keeping the
    content of [keep]; the merged record keeps the older id either way."""
    first, second = resolve_record(app.root, args.a), resolve_record(app.root, args.b)
    keep = resolve_record(app.root, args.keep)
    if keep not in (first, second):
        raise Failure("--keep names neither record of the pair")
    state = app.state()
    pair = next((c for c in state["candidates"] if {c["older"], c["newer"]} == {first, second}), None)
    if pair is None:
        raise Failure(f"the pair is not a pending candidate; candidates: {state['candidates']}")
    tile = by_text(tr("pages.settings.about.resolve_inheritance.title"))
    app.reveal_on("settings", tile)
    app.tap(tile)
    row = next((by_key(f"enhancement_review_merge_{x}_{y}") for x, y in ((first, second), (second, first))
                if app.exists(by_key(f"enhancement_review_merge_{x}_{y}"), 3000)), None)
    if row is None:
        raise Failure("the review list does not offer the pair")
    app.tap(row)
    apply = by_key("enhancement_merge_apply")
    if not app.exists(apply, 10000):
        raise Failure("the merge dialog did not open")
    toggle = by_key(f"enhancement_merge_select_{keep}")
    toggle_text = lambda: app.text_of(descendant(toggle, by_type("Text")))  # noqa: E731
    deselect = tr("pages.chara_detail.enhancement_merge.deselect")
    # The dialog can apply its default selection after the label was read, and a tap on a selected card
    # deselects it, which turns the apply button into the dismissal. Hold only once [keep] has read as
    # selected on two reads a second apart, tapping it again whenever it reads as not selected.
    kept = False
    for _ in range(6):
        if toggle_text() != deselect:
            app.tap(toggle)
        time.sleep(1.0)
        if toggle_text() == deselect:
            time.sleep(1.0)
            if toggle_text() == deselect:
                kept = True
                break
    if not kept:
        raise Failure(f"{keep} is not the selected card; nothing was held (run dismiss)")
    # The apply button dismisses the pair whenever no card is selected, so every hold is preceded by
    # reading what the button says it will do now, not what the toggle said a moment before.
    merge_label = tr("pages.chara_detail.enhancement_merge.merge")
    apply_text = lambda: app.text_of(descendant(apply, by_type("Text")))  # noqa: E731
    holds = 0
    for holds in range(1, 4):
        label = apply_text()
        if label != merge_label or toggle_text() != deselect:
            raise Failure(f"the apply button reads {label!r}, not {merge_label!r}; nothing more was held "
                          f"after {holds - 1} holds (run dismiss)")
        app.hold(apply)
        if app.absent(apply, 3000):
            break
        # A merge that is still running relabels the button; it closes the dialog when it ends.
        if app.exists(apply, 500) and apply_text() == tr("pages.chara_detail.enhancement_merge.running"):
            if app.absent(apply, 60000):
                break
    else:
        raise Failure("the hold-to-confirm button was still there after 3 holds")
    retired = pair["newer"]
    state, done = poll(app.state, lambda s: harness.merge_done(s, pair["older"], retired), 60)
    if not done:
        raise Failure("the merge did not complete")
    # The settings tile's list is left with its cancel: its confirm goes on to resolve the inheritance.
    leave = by_key("enhancement_review_cancel")
    if app.exists(leave, 2000):
        app.tap(leave)
        app.settle()
    return {"kept_content_of": keep, "id": pair["older"], "retired": retired, "holds": holds,
            "active_count": len(state["store"]["active_ids"])}


def op_export_zip(app: App, args) -> dict:
    ids = [resolve_record(app.root, reference) for reference in args.records]
    target = Path(args.to).resolve()
    if target.exists():
        raise Failure(f"{target} exists")
    app.navigate("records")
    app.tap(by_tooltip(tr("pages.chara_detail.export.button_tooltip")))
    for record_id in ids:
        app.press_cell(record_id, "#check")
    _, selected = poll(lambda: app.exists(by_text(tr("pages.chara_detail.export.overlay.export")), 1000), bool, 5)
    if not selected:
        raise Failure("the export selection did not start")
    app.tap(by_text(tr("pages.chara_detail.export.overlay.export")))
    zip_option = by_text(tr("pages.chara_detail.export.zip.label"))
    if not app.exists(zip_option, 5000):
        raise Failure("the export dialog did not open (no row was checked?)")
    app.tap(zip_option)
    app.queue_answer("save:" + str(target))
    # The confirm's tooltip, not its label: the dialog's title is the same word.
    app.tap(by_tooltip(tr("pages.chara_detail.export.dialog.ok_button.tooltip")))
    sizes = []

    def settled() -> bool:
        sizes.append(target.stat().st_size if target.exists() else -1)
        return len(sizes) >= 3 and sizes[-1] > 0 and sizes[-1] == sizes[-2] == sizes[-3]

    _, written = poll(lambda: settled(), bool, 120, 0.5)
    if not written:
        raise Failure(f"{target} was not written")
    with zipfile.ZipFile(target) as archive:
        inside = sorted({Path(name).parent.name for name in archive.namelist() if name.endswith("record.json")})
    return {"zip": str(target), "bytes": target.stat().st_size, "records": inside}


def op_import_zip(app: App, args) -> dict:
    source = Path(args.zip).resolve()
    with zipfile.ZipFile(source) as archive:
        count = len({Path(name).parent for name in archive.namelist() if name.endswith("record.json")})
    before = app.state()["store"]
    app.navigate("records")
    app.queue_answer("pick:" + json.dumps([str(source)]))
    app.tap(by_tooltip(tr("pages.chara_detail.import.button_tooltip")))
    # The toasts the import ends with: one of these zip-level ones, and a refusal toast per reason the store
    # refused records for (where every record was refused, only the refusal toasts are shown).
    outcomes = {"success": tr("pages.chara_detail.import.success", count=count),
                "empty": tr("pages.chara_detail.import.empty"),
                "failure": tr("pages.chara_detail.import.failure"),
                "too_large": tr("pages.chara_detail.import.too_large")}
    for refusal in ("duplicate_of_existing", "not_stored"):
        for refused in range(1, count + 1):
            outcomes[f"refused.{refusal}:{refused}"] = tr(f"pages.chara_detail.import.refused.{refusal}", count=refused)

    def outcome() -> str | None:
        return next((name for name, text in outcomes.items() if app.exists(by_text(text), 200)), None)

    told, ended = poll(outcome, lambda o: o is not None, 120, 0)
    after = app.state()["store"]
    result = {"zip": str(source), "records_in_zip": count, "toast": told,
              "active_count": len(after["active_ids"]),
              "new_ids": sorted(set(after["active_ids"]) - set(before["active_ids"]))}
    if told != "success":
        raise Failure(json.dumps(result, ensure_ascii=False))
    return result


def op_video_import(app: App, args) -> dict:
    clip = Path(args.clip).resolve()
    if not clip.exists():
        raise Failure(f"{clip} does not exist")
    before = set(app.state()["store"]["active_ids"])
    app.navigate("capture")
    app.queue_answer("pick:" + json.dumps([str(clip)]))
    app.tap(by_key("video_import_pick_button"))
    cancel = by_key("video_import_cancel_button")
    started = app.exists(cancel, 30000)
    if started and not app.absent(cancel, int(args.timeout * 1000)):
        raise Failure("the video import did not end within the timeout")
    state, landed = poll(app.state, lambda s: set(s["store"]["active_ids"]) - before, 30)
    new_ids = sorted(set(state["store"]["active_ids"]) - before)
    result = {"clip": str(clip), "import_seen_running": started, "new_ids": new_ids, "event": state["event"],
              "capture": state["capture"]}
    if not landed:
        raise Failure(json.dumps(result, ensure_ascii=False))
    return result


def _sync_card_control(app: App, finder: dict) -> None:
    app.reveal_on("account", finder)


def op_sync_now(app: App, args) -> dict:
    button = by_text(tr("pages.account.sync.sync_now"))
    _sync_card_control(app, button)
    before = app.sync_state()
    app.tap(button)
    def ended(s: dict) -> bool:
        return not s["running"] and (s["last_synced"] != before["last_synced"] or s["told"] != before["told"])

    state, ended = poll(app.sync_state, ended, args.timeout, 0.5)
    if not ended:
        raise Failure(json.dumps({"sync": state}, ensure_ascii=False))
    return {"sync": state}


def op_image_form(app: App, args) -> dict:
    option = by_text(tr(f"pages.account.sync.image_form.option.{args.form}.label"))
    _sync_card_control(app, option)
    app.tap(option)
    # The form is the server's: the section reads it back asynchronously, so the shot is what shows it.
    return {"form": args.form, "sync": app.sync_state()}


def op_sync_on(app: App, args) -> dict:
    title = by_text(tr("pages.account.sync.title"))
    _sync_card_control(app, title)
    if app.sync_state()["on"]:
        return {"sync": app.sync_state(), "already_on": True}
    # The card's title is its header; the switch sits in the card's first row, below it.
    app.tap(descendant(by_type("AccountSyncCard"), by_type("Switch")))
    ok = in_dialog(by_text(tr("pages.account.sync.turn_on.ok_button.label")))
    if not app.exists(ok, 10000):
        raise Failure("the turn-on dialog did not open")
    if args.form:
        app.tap(in_dialog(by_text(tr(f"pages.account.sync.image_form.option.{args.form}.label"))))
    # The button stays disabled while the dialog reads the counts and the image form, and a tap on it then
    # does nothing; tap again until the dialog takes it.
    for _ in range(10):
        if not app.exists(ok, 500):
            break
        app.tap(ok)
        state, on = poll(app.sync_state, lambda s: s["on"], 3)
        if on:
            break
    state, on = poll(app.sync_state, lambda s: s["on"], 30)
    if not on:
        raise Failure(json.dumps({"sync": state}, ensure_ascii=False))
    return {"sync": state}


def op_dismiss(app: App, args) -> dict:
    """Closes the open dialog, as after an operation that failed half way: the merge review list by its
    cancel or close button, any other card dialog by its close button."""
    leaves = (by_key("enhancement_review_cancel"), by_key("enhancement_review_close"), in_dialog(by_type("IconButton")))
    for leave in leaves:
        if app.exists(leave, 500):
            app.tap(leave)
            return {"dismissed": app.absent(by_type("CardDialog"), 5000)}
    return {"dismissed": False}


def op_screenshot(app: App, args) -> dict:
    return {"shot": app.screenshot(Path(args.path))}


def op_tap(app: App, args) -> dict:
    finder = by_key(args.key) if args.key else by_tooltip(args.tooltip) if args.tooltip else by_text(args.text)
    if args.scroll:
        app.scroll_into_view(finder)
        app.settle()
    app.tap(finder)
    return {"tapped": finder}


def op_reveal(app: App, args) -> dict:
    finder = by_key(args.key) if args.key else by_tooltip(args.tooltip) if args.tooltip else by_text(args.text)
    app.scroll_into_view(finder)
    app.settle()
    return {"revealed": finder}


def op_press(app: App, args) -> dict:
    app.press(args.x, args.y, buttons=args.button, hold_ms=args.hold_ms)
    return {"pressed": [args.x, args.y], "buttons": args.button, "hold_ms": args.hold_ms}


# ------------------------------------------------------------------------------------------- cli


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--state-dir", default=str(DEFAULT_STATE_DIR),
                        help="where the session, the app's log and the driver logs are kept")
    parser.add_argument("--shot", help="after the operation, write a PNG of the app's window to this path")
    sub = parser.add_subparsers(dest="op", required=True)

    p = sub.add_parser("prepare", help="copy a data root to a fresh isolated root")
    p.add_argument("--from", dest="source", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--logged-out", action="store_true", help="drop the copied session, so the copy syncs nothing")

    p = sub.add_parser("launch", help="start the app on an isolated root and leave it running")
    p.add_argument("--root", required=True)
    p.add_argument("--exe", default=str(DEFAULT_EXE))
    p.add_argument("--relay", choices=["pass", "refuse", "drop", "none"], default="pass")
    p.add_argument("--vm-port", type=int, default=DEFAULT_PORTS["vm"])
    p.add_argument("--proxy-port", type=int, default=DEFAULT_PORTS["proxy"])
    p.add_argument("--control-port", type=int, default=DEFAULT_PORTS["control"])

    sub.add_parser("stop", help="close the app and the relay; check the real data root for leaks")
    p = sub.add_parser("relay", help="switch the relay")
    p.add_argument("mode", choices=["pass", "refuse", "drop"])

    sub.add_parser("state", help="the app's harness_state")
    sub.add_parser("sync-state", help="the record sync as the sync card reads it")
    sub.add_parser("list", help="open the records page; the listed records with their fan counts")
    p = sub.add_parser("notes", help="a record's ratings and memos, as written on disk")
    p.add_argument("record")
    p = sub.add_parser("rate", help="set a record's rating through its cell")
    p.add_argument("record")
    p.add_argument("value")
    p.add_argument("--column", help="the rating column's title, where the root holds several")
    p.add_argument("--storage", help="a prefix of the storage's file name, where two storages share the title")
    p.add_argument("--nth", type=int, default=0,
                   help="which on-screen column of that title holds the storage, counted from 0 at the left")
    p = sub.add_parser("memo", help="write a record's memo through its cell's dialog")
    p.add_argument("record")
    p.add_argument("text")
    p.add_argument("--column", help="the memo column's title, where the root holds several")
    p.add_argument("--storage", help="a prefix of the storage's file name, where two storages share the title")
    p.add_argument("--nth", type=int, default=0,
                   help="which on-screen column of that title holds the storage, counted from 0 at the left")
    p = sub.add_parser("archive", help="archive a record from its row's right-click menu")
    p.add_argument("record")
    p.add_argument("--images", choices=["jpeg", "none"], required=True)
    p = sub.add_parser("delete", help="delete a record from its row's right-click menu")
    p.add_argument("record")
    p = sub.add_parser("merge", help="merge a candidate pair from the review list")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("--keep", required=True, help="the record whose content the merge keeps")
    p = sub.add_parser("export-zip", help="export records to a zip at a path")
    p.add_argument("records", nargs="+")
    p.add_argument("--to", required=True)
    p = sub.add_parser("import-zip", help="import a zip from a path")
    p.add_argument("zip")
    p = sub.add_parser("video-import", help="capture by importing a clip")
    p.add_argument("clip")
    p.add_argument("--timeout", type=float, default=900.0)
    p = sub.add_parser("sync-now", help="press sync now and wait for the round to end")
    p.add_argument("--timeout", type=float, default=300.0)
    p = sub.add_parser("image-form", help="set the account's image form")
    p.add_argument("form", choices=["png", "jpeg", "none"])
    p = sub.add_parser("sync-on", help="turn sync on (needs a logged-in session)")
    p.add_argument("--form", choices=["png", "jpeg", "none"])
    sub.add_parser("dismiss", help="close the open card dialog")
    p = sub.add_parser("screenshot", help="a PNG of the app's window")
    p.add_argument("path")
    p = sub.add_parser("tap", help="tap one widget")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--text")
    group.add_argument("--key")
    group.add_argument("--tooltip")
    p.add_argument("--scroll", action="store_true", help="scroll the target into view before the tap")
    p = sub.add_parser("reveal", help="scroll one widget into view without pressing it")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--text")
    group.add_argument("--key")
    group.add_argument("--tooltip")
    p = sub.add_parser("press", help="press at logical coordinates inside the app")
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    p.add_argument("--button", type=int, choices=[1, 2], default=1)
    p.add_argument("--hold-ms", type=int, default=50)
    return parser


APP_OPS = {"state": op_state, "sync-state": op_sync_state, "list": op_list, "notes": op_notes, "rate": op_rate,
           "memo": op_memo, "archive": op_archive, "delete": op_delete, "merge": op_merge,
           "export-zip": op_export_zip, "import-zip": op_import_zip, "video-import": op_video_import,
           "sync-now": op_sync_now, "image-form": op_image_form, "sync-on": op_sync_on,
           "dismiss": op_dismiss, "screenshot": op_screenshot, "tap": op_tap, "reveal": op_reveal, "press": op_press}
PROCESS_OPS = {"prepare": op_prepare, "launch": op_launch, "stop": op_stop, "relay": op_relay}


def main() -> int:
    # The app's texts are Japanese; the console's code page is not to decide whether they can be printed.
    sys.stdout.reconfigure(encoding="utf-8")
    args = build_parser().parse_args()
    try:
        if args.op in PROCESS_OPS:
            result = PROCESS_OPS[args.op](args)
            if args.shot and args.op == "launch":
                app = App(Path(args.state_dir), "shot")
                try:
                    result["shot"] = app.screenshot(Path(args.shot))
                finally:
                    app.close()
        else:
            app = App(Path(args.state_dir), args.op)
            try:
                result = APP_OPS[args.op](app, args)
                if args.shot:
                    result["shot"] = app.screenshot(Path(args.shot))
            finally:
                app.close()
    except (Failure, RuntimeError, OSError) as error:
        print(json.dumps({"op": args.op, "error": f"{type(error).__name__}: {error}"}, ensure_ascii=False))
        return 1
    print(json.dumps({"op": args.op, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
