# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets"]
# ///
"""Drive the REAL Flutter app (not the CLI) against the mimic player, unattended.

Builds the driver-enabled entrypoint (`test_driver/app.dart`), launches the executable with the VM
Service pinned, connects to it from Python, talks to the `ext.flutter.driver` service extension
directly, navigates to the capture page, starts capture, plays the clip through the mimic player,
waits for the recognized record to land, stops capture and shuts the app down.

Every wait is a condition, never a fixed sleep:
  * TCP connect on the pinned VM Service port      -> the engine is up
  * VM Service `getIsolate().extensionRPCs`        -> `ext.flutter.driver` is registered
  * `set_frame_sync` no longer asserting           -> `runApp` has been called
  * driver `waitFor(ByValueKey)`                   -> the widget is mounted
  * driver `waitFor(capture_stop_label)`           -> the app confirmed the capture request
  * the app's own log lines                        -> the recorder is up and a frame reached Dart
  * mimic player `ok`/`event eos` reply lines      -> the clip actually reached the screen
  * `record.json` appearing under the scratch root -> recognition produced a record

The app's data root is redirected to a scratch tree via the `UMACAPTURE_DATA_ROOT` environment
variable (see `readDataRootOverride()` in lib/src/core/bootstrap.dart), set only in the launched
app's own environment, so nothing is written into the user's real `Documents/umacapture` and no
state is left behind if the harness itself dies mid-run. That is verified, not assumed: the real
roots are snapshotted before the run and re-scanned after it, and anything that appeared there is
reported as `data_isolation.leaked_record_dirs` and fails the run (`status: data-leak`).

    uv run tool/live_capture_test/app_drive_run.py --tag app1
    uv run tool/live_capture_test/app_drive_run.py --tag falsify --falsify no-wait

This is the driving half only; its success condition is "a record.json appeared". For a verdict on
what the record CONTAINS, run a scenario through scenario_run.py. See docs/live-capture-harness.md.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

from websockets.sync.client import connect as ws_connect

# The class of usable frame numbers, shared with annotate_stops.py so the writer cannot emit a value
# this reader refuses. Re-exported: validate_stops' callers and its tests import it from here.
from stops_schema import frame_index_fault  # noqa: F401

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BUILD = ROOT / "native/cmake-build-release"
# Run artefacts (logs, per-run summaries, captures) are deliberately written OUTSIDE the repository:
# they are machine-local, large and per-run, exactly like the clips they are produced from. `.notes/`
# is gitignored, and `.notes/analysis/<topic>/` is where this project keeps analysis output.
RUNS = ROOT / ".notes/analysis/mimic-player"
CLIP = ROOT / ".notes/player_standard_5.mkv"
FLUTTER = ROOT / ".fvm/flutter_sdk/bin/flutter.bat"
# Debug and Profile both register the flutter_driver service extension; Release does not
# (registerServiceExtension is compiled out in AOT release). Profile is the optimised one.
APP_EXE_BY_CONFIG = {
    "debug": ROOT / "build/windows/x64/runner/Debug/umacapture.exe",
    "profile": ROOT / "build/windows/x64/runner/Profile/umacapture.exe",
}

APP_SUPPORT = Path(os.environ["APPDATA"]) / "umasagashi" / "umacapture"
REAL_MODULES = APP_SUPPORT / "modules"
# The user's own data root -- where the app writes when nothing overrides it. Snapshotted before
# and after every run so the isolation guarantee is OBSERVED at the place it can be broken; see
# real_data_roots() / scan_data_leak().
REAL_DATA_ROOT = Path(os.environ["USERPROFILE"]) / "Documents" / "umacapture"
REAL_SETTINGS = REAL_DATA_ROOT / "settings"
# readDataRootOverride() falls back to this file when the env var is absent or unusable, so it is
# the second place a run can leak into (lib/src/core/bootstrap.dart).
BOOTSTRAP_FILE = APP_SUPPORT / "data_root.json"

SCRATCH_ROOT = ROOT / ".notes/appdrive_root"

# Per-tab scroll-ready markers in the app's own stdout, at debug level. Tabs 0 and 2 are logged by
# the `scroll_ready_connection` listener in native_api.cpp, which is a direct connection and so
# fires synchronously at the scraper's send instant. The factor tab never reaches that listener --
# `factor_scroll_ready` is a separate connection that runs the duplicate probe -- so its observable
# is the probe's own value dump, which crosses into the recognizer runner and therefore LAGS the
# scraper's instant by one queue hop. Waiting on it is still sound (it can only be late, never
# early), it just holds the clip marginally longer than tab 1 strictly needs.
#
# Tab 1's marker is the FUNCTION prefix and stops there on purpose. spdlog's pattern is
# `[%!:%#]` = `function:line` (native/src/util/logger_util.cpp), so a marker that carried the line
# number would stop matching the moment an unrelated edit added a line above it in
# chara_detail_recognizer.cpp -- and the failure would read as "the app never reported scroll-ready",
# sending the reader into the recognition pipeline. `CharaDetailRecognizer::probe` is the whole
# observable: it is the factor tab's duplicate probe and nothing else calls it, so ANY line it logs
# means the probe ran for that tab, which is the fact being waited on.
SCROLL_READY_MARKERS = {
    0: "scroll ready on tab 0",
    1: "CharaDetailRecognizer::probe:",
    2: "scroll ready on tab 2",
}

NAV_CAPTURE = "nav_CaptureRoute"
CAPTURE_BUTTON = "capture_control_button"
START_LABEL = "capture_start_label"
STOP_LABEL = "capture_stop_label"


# --------------------------------------------------------------------------------------- scratch


def validate_stops(sidecar: dict, sidecar_path: Path, *, require_scroll_end: bool) -> None:
    """Refuse a sidecar that cannot synchronise the run, naming file, tab, field and value.

    Nothing downstream can catch these. `stable_stop` writes -1 into `stop_frame` when it found no
    stable run, `app_drive_run` arms it verbatim, and the player's `resolveSpec` *clamps* whatever
    it parses into range -- so an unusable value does not fail there, it silently becomes a
    different frame and the run synchronises against a stop that was never detected. Reading a
    frame number therefore has to be the place that refuses one.

    Two independent things are refused, because a per-entry check cannot see a MISSING entry:
    an entry whose numbers do not mean anything, and a sidecar that does not carry one entry per
    tab it was annotated for.
    """
    frame_count = sidecar.get("frame_count")
    if isinstance(frame_count, bool) or not isinstance(frame_count, int) or frame_count <= 0:
        raise SystemExit(f"{sidecar_path} has frame_count {frame_count!r}; without the clip's frame "
                         f"count its stop frames cannot be checked. Re-run annotate_stops.py.")
    # Coverage, before the entries. When detection finds fewer scroll groups than `--tabs`,
    # `annotate_stops.py` writes `used = groups[:tabs]` -- a short or EMPTY stops list, with a
    # warning -- and the warning gate is bypassable by design (`--allow-warnings`, or simply
    # starting from an already-written sidecar). An entry-wise validator has nothing to reject
    # there, so the run proceeds, arms nothing, plays fully unsynchronised at real time and still
    # reports `timeouts: 0`, which is the value the verdict reads. The count is compared against the
    # sidecar's OWN declaration, so a clip with a different number of tabs needs no change here.
    definition = sidecar.get("definition")
    declared_tabs = definition.get("tabs") if isinstance(definition, dict) else None
    if isinstance(declared_tabs, bool) or not isinstance(declared_tabs, int) or declared_tabs <= 0:
        raise SystemExit(f"{sidecar_path} has definition.tabs {declared_tabs!r}; without the number "
                         f"of tabs it was annotated for, a sidecar that covers only some of them "
                         f"cannot be told from a complete one. Re-run annotate_stops.py.")
    stops = sidecar.get("stops")
    if not isinstance(stops, list) or len(stops) != declared_tabs:
        found = len(stops) if isinstance(stops, list) else repr(stops)
        raise SystemExit(f"{sidecar_path} was annotated for {declared_tabs} tab(s) "
                         f"(definition.tabs) but carries {found} stop(s); the tabs it does not "
                         f"cover would play unsynchronised while the run still reported no "
                         f"scroll-ready timeouts. Read its `warnings` -- detection most likely "
                         f"found fewer scroll groups than --tabs -- and re-annotate the clip "
                         f"(--group-gap/--tabs, or --stop-frames for the manual fallback). "
                         f"See docs/live-capture-harness.md, 'Manual fallback'.")
    fields = ["stop_frame"] + (["scroll_end_frame"] if require_scroll_end else [])
    faults: list[str] = []
    for position, stop in enumerate(stops):
        tab = stop.get("tab", f"at position {position}")
        before = len(faults)
        for field in fields:
            fault = frame_index_fault(stop.get(field), frame_count)
            if fault is not None:
                faults.append(f"tab {tab}: {field} {fault}")
        # Only meaningful once this entry's two fields are individually usable; otherwise the
        # comparison would report a second, derived complaint about the same bad value.
        if len(faults) == before and require_scroll_end and stop["stop_frame"] >= stop["scroll_end_frame"]:
            faults.append(f"tab {tab}: stop_frame {stop['stop_frame']} is not before "
                          f"scroll_end_frame {stop['scroll_end_frame']}; the scrolling phase they "
                          f"bracket would be empty or reversed")
    if faults:
        detail = "\n  ".join(faults)
        raise SystemExit(f"{sidecar_path} cannot be used as written:\n  {detail}\n"
                         f"Fix the annotation and re-run annotate_stops.py (--stop-frames writes "
                         f"stops by hand; scroll_end_frame is edited in the sidecar), or drop "
                         f"--scroll-rate if the scrolling phase is not being stretched. "
                         f"See docs/live-capture-harness.md, 'Annotating a new clip'.")


def modules_signature(root: Path) -> list[list]:
    """Identity of a modules tree as data: every file's path and content hash, sorted.

    Contents rather than timestamps, because the question is which MODELS a run recognised with,
    and a model restored from a backup or written by a different tool carries whatever mtime it
    likes. Thirty-six files, ~14 MB -- unmeasurable next to launching the app.
    """
    return sorted([str(path.relative_to(root)).replace("\\", "/"),
                   hashlib.sha256(path.read_bytes()).hexdigest()]
                  for path in root.rglob("*") if path.is_file())


def sync_scratch_modules() -> None:
    """Re-copies the real ONNX modules into the scratch root whenever they are no longer the ones
    that were copied.

    Redirecting the data root moves `modules` too, so the scratch tree needs its own copy. Copying
    it only `if not modules.exists()` freezes whatever the first run happened to find: replace a
    model in the real modules directory and every later run still recognises with the old one,
    while its records are diffed against a golden produced with the new one. A mismatch then looks
    like a regression in the new model and a match looks like proof it did not regress -- neither
    is a statement about the models on disk. So the identity of what was copied is recorded beside
    the copy and compared, which also means the copy is paid for only when it is actually stale.
    """
    modules = SCRATCH_ROOT / "modules"
    stamp = SCRATCH_ROOT / "modules_source.json"
    wanted = modules_signature(REAL_MODULES)
    try:
        current = json.loads(stamp.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        current = None
    if modules.exists() and current == wanted:
        return
    if modules.exists():
        shutil.rmtree(modules)
    shutil.copytree(REAL_MODULES, modules)
    stamp.write_text(json.dumps(wanted, indent=2) + "\n", encoding="utf-8")


def prepare_scratch(fresh: bool, settings_mode: str) -> Path:
    """Builds the redirected data root: the real modules copied in, an empty storage, and settings
    per [settings_mode].

    `fresh` settings (the default) is not just hygiene, it is correctness: the settings box carries
    `detailCropCalibration` and `forceResizeMode`, which the app writes straight into the native
    start config. This machine's real settings have detail-crop calibration OFF, and a run with
    them copied in reached the scene, scraped it, and then abandoned tab 1 with no record. An empty
    box yields the app's documented defaults, which is the only config a run can be attributed to.
    `copy` is kept only for diagnosing against the real installation.

    Those defaults are calibration ON and frame resize ON, and `native/src/core/cli.cpp` builds the
    same pair: `--frame-resize` is its default too (`--no-frame-resize` turns it off). So a `fresh`
    run is the config a CLI golden was produced under, which is what makes comparing the two a test
    of the app rather than of a configuration difference. The suite states it per case rather than
    inheriting it -- every entry in native/test/integration/cases.json carries `frame_resize` -- so
    read the case, not this docstring, for what a given golden is a baseline for."""
    if fresh and SCRATCH_ROOT.exists():
        shutil.rmtree(SCRATCH_ROOT)
    SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
    sync_scratch_modules()
    settings = SCRATCH_ROOT / "settings"
    if settings.exists():
        shutil.rmtree(settings)
    if settings_mode == "copy":
        shutil.copytree(REAL_SETTINGS, settings, ignore=shutil.ignore_patterns("*.lock"))
    else:
        settings.mkdir()
    storage = SCRATCH_ROOT / "storage"
    if storage.exists():
        shutil.rmtree(storage)
    return SCRATCH_ROOT


def active_dir(root: Path = SCRATCH_ROOT) -> Path:
    return root / "storage" / "chara_detail" / "active"


def records_under(root: Path) -> set[Path]:
    active = active_dir(root)
    if not active.exists():
        return set()
    return {p.parent for p in active.glob("*/record.json")}


def records() -> set[Path]:
    return records_under(SCRATCH_ROOT)


# ------------------------------------------------------------------------------- data isolation


def real_data_roots() -> list[Path]:
    """The roots the app would write to if `UMACAPTURE_DATA_ROOT` stopped being honoured.

    `readDataRootOverride()` (lib/src/core/bootstrap.dart) reads the env var first, then
    `data_root.json` in the app-support dir, then falls back to the native default. So a bootstrap
    regression -- the var renamed, reordered behind the file, or dropped -- lands in one of the
    other two, and those are the places to look. The scratch root is excluded by definition: a leak
    is a write OUTSIDE it.
    """
    roots = [REAL_DATA_ROOT]
    try:
        recorded = json.loads(BOOTSTRAP_FILE.read_text(encoding="utf-8")).get("data_root")
    except (OSError, ValueError, AttributeError):
        recorded = None
    if isinstance(recorded, str) and recorded.strip():
        roots.append(Path(recorded.strip()))
    scratch = SCRATCH_ROOT.resolve()
    unique: list[Path] = []
    for root in roots:
        resolved = root.resolve()
        if resolved == scratch or scratch in resolved.parents:
            continue
        if resolved not in unique:
            unique.append(resolved)
    return unique


def snapshot_real_records() -> dict[str, list[str]]:
    """Record dirs already present under each real root, keyed by root."""
    return {str(root): sorted(str(p) for p in records_under(root)) for root in real_data_roots()}


def scan_data_leak(before: dict[str, list[str]]) -> dict:
    """Re-scans the real roots and reports every record dir that appeared during the run.

    This is the isolation guarantee, observed rather than assumed. The check it replaces asked
    whether the harness's own record list sat under the scratch root -- but that list is produced by
    a glob INSIDE the scratch root, so it could not fail. The regression it claimed to catch (the
    app ignoring the override and writing into the user's own store) shows up there as "no records
    under scratch", i.e. as a record mismatch blamed on recognition, with the pollution left behind.
    Looking at the real roots is the only way this can fail on the system it is about.
    """
    after: dict[str, list[str]] = {}
    leaked: list[str] = []
    for root in real_data_roots():
        key = str(root)
        found = sorted(str(p) for p in records_under(root))
        after[key] = found
        leaked += [path for path in found if path not in before.get(key, [])]
    return {"roots": sorted(after), "before": before, "after": after,
            "leaked_record_dirs": sorted(leaked)}


# ---------------------------------------------------------------------------------- mimic player


class Player:
    def __init__(self, record: Path, log: Path) -> None:
        self.log = log.open("w", encoding="utf-8", errors="replace")
        self.process = subprocess.Popen(
            [str(BUILD / "umacapture_mimic_player.exe"), "--record", str(record), "--control",
             "--x", "60", "--y", "40", "--duration", "600"],
            cwd=str(BUILD), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, bufsize=1)
        self.events: list[str] = []

    def _line(self) -> str:
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("mimic player closed its stdout")
        line = line.rstrip("\r\n")
        self.log.write(f"[stdout] {line}\n")
        self.log.flush()
        return line

    def wait_ready(self) -> str:
        while True:
            line = self._line()
            if line.startswith("ready "):
                return line
            self.events.append(line)

    def send(self, command: str) -> str:
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()
        while True:
            line = self._line()
            if line.startswith("ok ") or line.startswith("err "):
                return line
            self.events.append(line)

    def play_stepped(self, pace_ms: float, timeout: float = 300.0) -> dict:
        """Plays the clip one source frame at a time, holding each for [pace_ms].

        Real-time `resume` is what the CLI stage used, and it is the honest reproduction of live
        play -- but the app can only be driven in a debug build (see DriverApp), whose native
        pipeline is compiled unoptimised, and at the clip's own 26.4 fps that pipeline misses
        enough frames that the tab-1 scroll sometimes never completes ("in-progress tab 1
        abandoned -> discard", measured 1 failure in 3 real-time runs). Holding each frame longer
        does not change what the app sees, only how long it has to see it: `step` re-presents the
        held frame continuously, so there is no stall either."""
        deadline = time.monotonic() + timeout
        steps = 0
        while time.monotonic() < deadline:
            due = time.monotonic() + pace_ms / 1000.0
            reply = self.send("step 1")
            steps += 1
            if reply.startswith("err ") or any(e.startswith("event eos") for e in self.events):
                return {"steps": steps, "last": reply}
            index = int(reply.split("index=")[1].split()[0])
            count = int(reply.split("count=")[1].split()[0])
            if index >= count - 1:
                return {"steps": steps, "last": reply}
            remaining = due - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
        raise RuntimeError("stepped playback never reached the end of the clip")

    def play_synchronised(self, stops: list[dict], app: DriverApp, timeout: float,
                          wait_for_marker: bool = True, scroll_rate: float = 1.0) -> dict:
        """Plays the clip at REAL TIME, holding it on each annotated stop frame until the app has
        reported scroll-ready for that tab.

        Why this and not slower playback: the app's scroll-ready gate waits for the screen to stop
        changing, and part of what has to stop is the tab's tap effect, whose length in the real
        game is fixed. Stretching the clip stretches that animation too, so the stable window does
        not actually widen -- measured, 250 ms/frame is worse than 80 ms/frame, not better. Holding
        instead of stretching does widen it: `pause` re-presents the held frame, so the app sees a
        screen that genuinely is not changing, exactly like a game sitting still after its animation
        finished, and everything in between still runs at the clip's own cadence.

        Ordering is handled by making the marker a level, not an edge: DriverApp sets a per-tab
        Event the moment the marker appears in the app's stdout, so a marker that arrives BEFORE the
        breakpoint fires leaves the Event already set and the wait returns immediately. There is no
        window in which an early marker can be missed and no ordering that deadlocks.

        [scroll_rate] < 1 additionally plays the SCROLLING PHASE of each tab in slow motion, and
        only that phase. The two halves are both necessary and neither is sufficient: the hold alone
        leaves the pipeline falling behind DURING the scroll, and the slowdown alone starts the
        scroll before the app has reached scroll-ready. Slowing everything is worse than either --
        the stationary and tap-animation periods are fixed-length in the real game, and over-holding
        them makes the scraper infer a character switch (measured: three record_ids in one scene at
        250 ms/frame). So the rate is dropped only between a tab's stop frame and its annotated
        scroll_end_frame, and is restored by an armed `rate-at`, not by a timed send."""
        armed = []
        for stop in stops:
            armed.append(self.send(f"pause-at {stop['stop_frame']} {stop['label']}"))
        if scroll_rate != 1.0:
            # Armed in advance, exactly like the breakpoints and for the same reason: the return to
            # real time has to land on a known frame, and a harness that watched for it and then
            # sent `rate` would be racing the playhead across the whole scroll.
            for stop in stops:
                armed.append(self.send(f"rate-at {stop['scroll_end_frame']} 1.0 end{stop['tab']}"))
        self.send("resume")
        held = []
        for stop in stops:
            event = self._wait_pause_at(stop["label"], timeout)
            hit_wall = time.time()
            tab = stop["tab"]
            # Sampled BEFORE waiting, so it records the ordering rather than the wait's outcome
            # (which would read as "early" whenever the wait is disabled).
            already_ready = app.scroll_ready[tab].is_set()
            waited = 0.0
            timed_out = False
            if wait_for_marker:
                started = time.monotonic()
                if not app.scroll_ready[tab].wait(timeout):
                    timed_out = True
                waited = round(time.monotonic() - started, 3)
            marker_wall = app.scroll_ready_wall.get(tab)
            held.append({
                "tab": tab,
                "stop_frame": stop["stop_frame"],
                "breakpoint_event": event,
                "breakpoint_wall": datetime.datetime.fromtimestamp(hit_wall).strftime("%H:%M:%S.%f"),
                "marker_wall": marker_wall,
                # The interesting ordering fact: with sync on, the marker is usually EARLIER than
                # the breakpoint for the tabs the app keeps up with, and later for the ones it does
                # not -- which is exactly the case the hold exists for.
                "marker_before_breakpoint": already_ready,
                "waited_seconds": waited,
                "timed_out": timed_out,
            })
            if timed_out:
                # Bounded, and loud. Resuming anyway keeps the run informative (the record either
                # appears or does not) instead of aborting with the clip half-played.
                print(f"SYNC TIMEOUT: tab {tab} never logged {SCROLL_READY_MARKERS[tab]!r} within "
                      f"{timeout:.0f}s while the player held frame {stop['stop_frame']}; resuming",
                      file=sys.stderr)
            # Sent while the player is PAUSED, so there is no playhead to race: the slowdown is in
            # force before the first frame of the scroll is presented.
            if scroll_rate != 1.0:
                held[-1]["rate_reply"] = self.send(f"rate {scroll_rate}")
            self.send("resume")
        return {"armed": armed, "held": held, "scroll_rate": scroll_rate,
                "rate_events": [e for e in self.events if e.startswith("event rate-at")],
                "timeouts": sum(1 for h in held if h["timed_out"])}

    def _wait_pause_at(self, label: str, timeout: float) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self._line()
            if line.startswith("event pause-at") and line.endswith(f"label={label}"):
                return line
            self.events.append(line)
            if line.startswith("event eos"):
                raise RuntimeError(f"the clip ended before the breakpoint {label!r} fired")
        raise RuntimeError(f"the player never reported the breakpoint {label!r}")

    def wait_eos(self, timeout: float) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            line = self._line()
            self.events.append(line)
            if line.startswith("event eos"):
                return line
        raise RuntimeError("player never reported eos")

    def close(self) -> None:
        try:
            self.send("quit")
        except Exception:  # noqa: BLE001
            pass
        try:
            self.process.stdin.close()
        except OSError:
            pass
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill()
        self.log.close()


# ------------------------------------------------------------------------------ app under driver


def build_app(config: str, log: Path) -> Path:
    """Builds the driver-enabled bundle for [config] and returns the executable."""
    with log.open("w", encoding="utf-8", errors="replace") as sink:
        result = subprocess.run(
            [str(FLUTTER), "build", "windows", f"--{config}", "-t", "test_driver/app.dart"],
            cwd=str(ROOT), stdout=sink, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"flutter build windows failed; see {log}")
    return APP_EXE_BY_CONFIG[config]


class DriverApp:
    """The app, launched directly from its debug bundle with the VM Service pinned.

    `flutter run --machine` was tried first and does not work here: its `app.debugPort` /
    `app.started` events depend on the tool scraping the "Dart VM service is listening on ..." line
    out of the app's stdout, and a Windows GUI-subsystem runner launched from this harness never
    delivers that line to the tool (measured: the service was listening on a port netstat could see
    while the tool sat silent forever). Launching the executable ourselves with the same engine
    switches `flutter run` would have passed -- `vm-service-port` plus `disable-service-auth-codes`
    (see flutter_tools desktop_device.dart `_computeEnvironment`) -- makes the service URI
    deterministic, so no discovery is needed and the app's PID is ours to manage."""

    def __init__(self, exe: Path, port: int, log: Path) -> None:
        self.port = port
        self.log = log.open("w", encoding="utf-8", errors="replace")
        switches = [
            "enable-dart-profiling=true",
            "enable-checked-mode=true",
            "verify-entry-points=true",
            f"vm-service-port={port}",
            "disable-service-auth-codes=true",
        ]
        environment = dict(os.environ)
        # Redirects this launch's data root only -- see readDataRootOverride() in
        # lib/src/core/bootstrap.dart, which now prefers this env var over data_root.json
        # precisely so a harness-only process, not the whole machine, is affected.
        environment["UMACAPTURE_DATA_ROOT"] = str(SCRATCH_ROOT)
        environment["FLUTTER_ENGINE_SWITCHES"] = str(len(switches))
        for index, switch in enumerate(switches, start=1):
            environment[f"FLUTTER_ENGINE_SWITCH_{index}"] = switch
        self.process = subprocess.Popen(
            [str(exe)], cwd=str(exe.parent), env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
            encoding="utf-8", errors="replace")
        self.recorder_started = threading.Event()
        self.first_frame = threading.Event()
        # One latched Event per tab. Latched, not a callback, precisely so the synchronised playback
        # loop cannot lose a marker that lands before it starts waiting.
        self.scroll_ready = {tab: threading.Event() for tab in SCROLL_READY_MARKERS}
        self.scroll_ready_wall: dict[int, str] = {}
        self.reader = threading.Thread(target=self._pump, daemon=True)
        self.reader.start()

    def _pump(self) -> None:
        for line in self.process.stdout:
            self.log.write(line)
            self.log.flush()
            for tab, marker in SCROLL_READY_MARKERS.items():
                if marker in line and not self.scroll_ready[tab].is_set():
                    self.scroll_ready_wall[tab] = datetime.datetime.now().strftime("%H:%M:%S.%f")
                    self.scroll_ready[tab].set()
            if "RecordingThread::run" in line and "started" in line:
                self.recorder_started.set()
            elif "emitPreviewFrame" in line:
                # One captured frame has completed the whole trip: WinRT -> pipeline -> Dart. The
                # capture button flips ~1.1 s before this (it only reports that the request was
                # accepted), so resuming the clip on the button would drop the head of the clip.
                self.first_frame.set()

    def wait_capturing(self, timeout: float = 120.0, frame_timeout: float = 20.0) -> dict:
        if not self.recorder_started.wait(timeout):
            raise RuntimeError("the capture thread never started")
        # The preview is the only per-frame signal the app prints; a user who turned it off would
        # not produce one, so its absence is reported rather than fatal.
        return {"recorder_started": True, "first_frame": self.first_frame.wait(frame_timeout)}

    @property
    def ws_uri(self) -> str:
        return f"ws://127.0.0.1:{self.port}/ws"

    def wait_service(self, timeout: float = 180.0) -> float:
        """Blocks until the VM Service accepts a connection on the pinned port."""
        import socket as socket_module

        started = time.monotonic()
        deadline = started + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"the app exited during startup (code {self.process.returncode})")
            with socket_module.socket() as probe:
                probe.settimeout(1.0)
                if probe.connect_ex(("127.0.0.1", self.port)) == 0:
                    return round(time.monotonic() - started, 2)
            time.sleep(0.1)
        raise RuntimeError("the VM Service never came up on the pinned port")

    def stop(self, timeout: float = 60.0) -> str:
        """Closes the app the way a user would: WM_CLOSE to its windows, by PID."""
        if self.process.poll() is not None:
            return "already-exited"
        subprocess.run(["taskkill", "/PID", str(self.process.pid)],
                       capture_output=True, text=True)
        try:
            self.process.wait(timeout=timeout)
            return "clean"
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(self.process.pid)],
                           capture_output=True, text=True)
            self.process.wait(timeout=30)
            return "killed"

    def close(self) -> None:
        if self.process.poll() is None:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(self.process.pid)],
                           capture_output=True, text=True)
        self.reader.join(timeout=10)
        self.log.close()


# ------------------------------------------------------------------------------ VM Service driver


class Driver:
    """Minimal Dart VM Service JSON-RPC client that speaks to `ext.flutter.driver` directly.

    Python-side rather than `flutter drive` + a Dart driver script: the rest of this harness
    (mimic player control channel, record polling) is already Python, and `flutter drive` owns the
    process lifetime, which would leave the player orchestration on the wrong side of the fence."""

    def __init__(self, ws_uri: str, log: Path) -> None:
        self.socket = ws_connect(ws_uri, open_timeout=60, max_size=None)
        self.log = log.open("w", encoding="utf-8", errors="replace")
        self._next_id = 1
        self.isolate_id: str | None = None

    def rpc(self, method: str, params: dict, timeout: float = 120.0) -> dict:
        request_id = self._next_id
        self._next_id += 1
        self.socket.send(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                     "method": method, "params": params}))
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"VM Service call {method} timed out")
            message = json.loads(self.socket.recv(timeout=remaining))
            if message.get("id") != request_id:
                continue  # stream event or a stale reply
            self.log.write(f"{method} {json.dumps(params)[:200]} -> {json.dumps(message)[:400]}\n")
            self.log.flush()
            if "error" in message:
                raise RuntimeError(f"{method} failed: {message['error']}")
            return message["result"]

    def main_isolate(self) -> str:
        vm = self.rpc("getVM", {})
        isolates = vm.get("isolates") or []
        if not isolates:
            raise RuntimeError("the VM reports no isolates")
        self.isolate_id = isolates[0]["id"]
        return self.isolate_id

    def wait_extension(self, timeout: float = 300.0) -> float:
        """Blocks until the driver extension is registered on the main isolate."""
        started = time.monotonic()
        deadline = started + timeout
        while time.monotonic() < deadline:
            isolate = self.rpc("getIsolate", {"isolateId": self.isolate_id})
            if "ext.flutter.driver" in (isolate.get("extensionRPCs") or []):
                return round(time.monotonic() - started, 2)
            time.sleep(0.2)
        raise RuntimeError("ext.flutter.driver was never registered")

    def wait_root_widget(self, timeout: float = 300.0) -> float:
        """Blocks until the app has actually called `runApp`.

        The extension being registered is NOT readiness: `test_driver/app.dart` registers it as its
        very first statement, before `main()` awaits Hive, localization and the license index --
        measured 0.44 s after launch, several seconds before any widget exists. Every command that
        touches the tree asserts `isRootWidgetAttached` first, so the honest gate is a command that
        carries that assertion succeeding. `set_frame_sync` is that command and is idempotent, and
        turning frame sync off is needed anyway: the app repaints continuously (preview, progress
        rings), so it never settles and a synced tap would block until its timeout."""
        started = time.monotonic()
        deadline = started + timeout
        while True:
            try:
                self.command("set_frame_sync", enabled="false")
                return round(time.monotonic() - started, 2)
            except RuntimeError as error:
                if "No root widget is attached" not in str(error):
                    raise
                if time.monotonic() >= deadline:
                    raise RuntimeError("the app never called runApp") from error
                time.sleep(0.2)

    def command(self, name: str, rpc_timeout: float = 120.0, **kwargs: str) -> dict:
        params = {"isolateId": self.isolate_id, "command": name}
        params.update({k: str(v) for k, v in kwargs.items()})
        result = self.rpc("ext.flutter.driver", params, timeout=rpc_timeout)
        if result.get("isError"):
            raise RuntimeError(f"driver {name} {kwargs} failed: {result.get('response')}")
        return result.get("response")

    def by_key(self, name: str, key: str, timeout_ms: int = 60000) -> dict:
        return self.command(name, rpc_timeout=timeout_ms / 1000.0 + 15, finderType="ByValueKey",
                            keyValueString=key, keyValueType="String", timeout=timeout_ms)

    def close(self) -> None:
        try:
            self.socket.close()
        except Exception:  # noqa: BLE001
            pass
        self.log.close()


# ------------------------------------------------------------------------------------------- run


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--run-id", default=None,
                        help="opaque identity of this run, echoed into the summary as `run_id`. A "
                             "runner that reads the summary back passes one so it can tell this "
                             "run's summary from an earlier run's under the same tag; a hand-run "
                             "harness needs none.")
    parser.add_argument("--fresh", action="store_true", help="force a re-copy of the scratch modules tree")
    parser.add_argument("--build", action="store_true", help="rebuild the bundle first")
    parser.add_argument("--config", choices=["debug", "profile"], default="debug",
                        help="which driver-enabled bundle to run")
    parser.add_argument("--port", type=int, default=57391, help="pinned VM Service port")
    parser.add_argument("--settings", choices=["fresh", "copy"], default="fresh")
    parser.add_argument("--pace", type=float, default=80.0,
                        help="ms to hold each source frame (0 plays the clip in real time)")
    parser.add_argument("--sync", action="store_true",
                        help="synchronised playback: real time, but hold on each annotated stop "
                             "frame until the app reports scroll-ready for that tab. Implies "
                             "--pace 0 and requires the clip's sidecar annotation.")
    parser.add_argument("--stops", default=None,
                        help="sidecar written by annotate_stops.py (default <clip>.stops.json)")
    parser.add_argument("--sync-timeout", type=float, default=30.0,
                        help="seconds to hold a stop frame waiting for its scroll-ready marker")
    parser.add_argument("--scroll-rate", type=float, default=1.0,
                        help="speed multiplier applied to each tab's SCROLLING PHASE only "
                             "(1.0 = real time, 0.5 = half speed). Everything outside "
                             "[stop_frame, scroll_end_frame] still plays at real time. Requires "
                             "--sync and a sidecar carrying scroll_end_frame.")
    parser.add_argument("--record-wait", type=float, default=120.0)
    parser.add_argument("--clip", default=None,
                        help="clip to play (default the S2b/S6c one, .notes/player_standard_5.mkv). "
                             "A scenario runner names it; nothing else does.")
    parser.add_argument("--range", nargs=2, type=float, metavar=("A", "B"), default=None,
                        help="restrict playback to [A, B] clip seconds (sent as the player's "
                             "`range` before resume). The player emits `event eos` at the range "
                             "end and holds there, so a range that stops mid-scene is how a run "
                             "is perturbed into producing no record.")
    parser.add_argument("--falsify", choices=["no-wait", "no-runapp", "no-marker-wait"], default=None,
                        help="no-wait: skip every readiness gate and drive as soon as the VM "
                             "Service socket opens, to show the harness is not passing on luck. "
                             "no-marker-wait: arm the breakpoints and resume the instant each one "
                             "fires, without waiting for the tab's scroll-ready marker.")
    args = parser.parse_args()

    clip = Path(args.clip) if args.clip else CLIP
    summary: dict = {"tag": args.tag, "run_id": args.run_id, "falsify": args.falsify, "clip": str(clip),
                     "settings": args.settings, "pace_ms": args.pace, "config": args.config,
                     "sync": args.sync, "range": args.range}
    stops: list[dict] = []
    if args.sync:
        sidecar_path = Path(args.stops) if args.stops else clip.with_suffix(".stops.json")
        sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        # The annotation is only about THIS clip; a sidecar for a different one would park the
        # player on frames that mean nothing. Cheap check, and the alternative failure is silent.
        if sidecar["clip"] != clip.name:
            raise SystemExit(f"{sidecar_path} annotates {sidecar['clip']}, not {clip.name}")
        # Every frame number this run is about to arm is checked here, before anything is launched.
        # A null scroll_end_frame would otherwise become `rate-at None 1.0`, which the player
        # rejects and the harness then fails on while parsing the reply; a negative or out-of-clip
        # stop_frame is worse, because the player clamps it into range and the run looks fine.
        validate_stops(sidecar, sidecar_path, require_scroll_end=args.scroll_rate != 1.0)
        stops = sidecar["stops"]
        summary["stops_sidecar"] = str(sidecar_path)
        summary["stop_frames"] = [s["stop_frame"] for s in stops]
        args.pace = 0.0
        summary["pace_ms"] = 0.0
        summary["scroll_rate"] = args.scroll_rate
        if args.scroll_rate != 1.0:
            summary["scroll_end_frames"] = [s["scroll_end_frame"] for s in stops]
    elif args.scroll_rate != 1.0:
        raise SystemExit("--scroll-rate only means anything with --sync")
    app_exe = APP_EXE_BY_CONFIG[args.config]
    # Every log and the run summary below are opened under RUNS, on a clone that may have clips but
    # no analysis directory yet. Created here rather than at import time so importing this module
    # (scenario_run.py does) writes nothing. Never removed or emptied: RUNS holds earlier runs'
    # measurements, which are test material.
    RUNS.mkdir(parents=True, exist_ok=True)
    wall_start = time.monotonic()
    if args.build:
        t_build = time.monotonic()
        build_app(args.config, RUNS / f"app_build_{args.tag}.log")
        summary["build_seconds"] = round(time.monotonic() - t_build, 2)
    if not app_exe.exists():
        print(f"{app_exe} is missing; run once with --build", file=sys.stderr)
        return 2
    summary["exe"] = str(app_exe)
    summary["exe_mtime"] = time.strftime("%Y-%m-%d %H:%M:%S",
                                         time.localtime(app_exe.stat().st_mtime))
    prepare_scratch(args.fresh, args.settings)
    # Taken before anything is launched, so anything that appears under a real root afterwards is
    # this run's doing. Outside the try, so the post-run scan below always has a baseline.
    real_before = snapshot_real_records()

    player: Player | None = None
    app: DriverApp | None = None
    driver: Driver | None = None
    status = "error"
    try:
        player = Player(clip, RUNS / f"app_mimic_{args.tag}.log")
        summary["player_ready"] = player.wait_ready()

        t_launch = time.monotonic()
        app = DriverApp(app_exe, args.port, RUNS / f"app_stdout_{args.tag}.log")
        summary["app_pid"] = app.process.pid
        summary["service_wait_seconds"] = app.wait_service()
        summary["ws_uri"] = app.ws_uri

        driver = Driver(app.ws_uri, RUNS / f"app_driver_{args.tag}.log")
        driver.main_isolate()
        if args.falsify == "no-wait":
            summary["skipped"] = ("ext.flutter.driver registration, runApp gate, set_frame_sync, "
                                  "every waitFor")
        elif args.falsify == "no-runapp":
            # Waits for the extension, then issues the first real command without retrying: the
            # extension is registered long before runApp, so this is the gate that looks redundant
            # and is not.
            summary["extension_wait_seconds"] = driver.wait_extension()
            summary["skipped"] = "runApp gate (set_frame_sync issued once, not retried)"
            driver.command("set_frame_sync", enabled="false")
        else:
            summary["extension_wait_seconds"] = driver.wait_extension()
            summary["health"] = driver.command("get_health")
            summary["root_widget_wait_seconds"] = driver.wait_root_widget()
            driver.by_key("waitFor", NAV_CAPTURE)
        summary["ready_seconds"] = round(time.monotonic() - t_launch, 2)

        driver.by_key("tap", NAV_CAPTURE)
        if args.falsify is None:
            driver.by_key("waitFor", START_LABEL)
        t_capture = time.monotonic()
        driver.by_key("tap", CAPTURE_BUTTON)
        # Confirms the native side actually entered the capturing state: the label only flips when
        # capturingStateProvider reports it, which on the first capture includes the model load.
        driver.by_key("waitFor", STOP_LABEL, timeout_ms=120000)
        summary["capture_start_seconds"] = round(time.monotonic() - t_capture, 2)
        if args.falsify is None:
            summary["capturing"] = app.wait_capturing()

        before = records()
        # Sent while the player is still paused on frame 0, so the restriction is in force before
        # anything is presented. `range` repositions only when the playhead is outside [A, B].
        if args.range is not None:
            summary["range_reply"] = player.send(f"range {args.range[0]} {args.range[1]}")
        t_play = time.monotonic()
        # Wall clock of the instant playback is released, so a marker in the app's log (which is
        # wall-stamped) can be converted to a clip timestamp: clip_ms = (marker - resume_wall) * 1000
        # plus the ts the `resume` reply reports. Needed to state how far ahead of a scroll a
        # scroll-ready marker lands.
        summary["play_started_wall"] = datetime.datetime.now().strftime("%H:%M:%S.%f")
        if args.sync:
            summary["synchronised"] = player.play_synchronised(
                stops, app, args.sync_timeout,
                wait_for_marker=args.falsify != "no-marker-wait",
                scroll_rate=args.scroll_rate)
            summary["eos"] = player.wait_eos(180.0)
            # Re-collected after eos: the last tab's `event rate-at` arrives while wait_eos is
            # reading, i.e. after play_synchronised has already returned.
            summary["synchronised"]["rate_events"] = [e for e in player.events
                                                      if e.startswith("event rate-at")]
        elif args.pace > 0:
            summary["stepped"] = player.play_stepped(args.pace)
        else:
            summary["resume"] = player.send("resume")
            summary["eos"] = player.wait_eos(180.0)
        summary["play_ended_wall"] = datetime.datetime.now().strftime("%H:%M:%S.%f")
        summary["playback_seconds"] = round(time.monotonic() - t_play, 2)

        t_record = time.monotonic()
        produced: set[Path] = set()
        deadline = t_record + args.record_wait
        while time.monotonic() < deadline:
            produced = records() - before
            if produced:
                break
            time.sleep(0.5)
        summary["record_wait_seconds"] = round(time.monotonic() - t_record, 2)
        summary["record_dirs"] = sorted(str(p) for p in produced)

        driver.by_key("tap", CAPTURE_BUTTON)
        driver.by_key("waitFor", START_LABEL, timeout_ms=60000)
        summary["capture_stopped"] = True
        status = "ok" if produced else "no-record"
    except Exception as error:  # noqa: BLE001
        summary["error"] = f"{type(error).__name__}: {error}"
    finally:
        if driver is not None:
            driver.close()
        if app is not None:
            summary["app_stop"] = app.stop()
            app.close()
        if player is not None:
            player.close()

    # After the app has exited, so a record written on shutdown is still seen. Runs whatever
    # happened above, including the error path -- a run that died half way can still have leaked.
    summary["data_isolation"] = scan_data_leak(real_before)
    if summary["data_isolation"]["leaked_record_dirs"]:
        print(f"DATA LEAK: this run wrote record(s) OUTSIDE {SCRATCH_ROOT} -- "
              f"{summary['data_isolation']['leaked_record_dirs']}. The app is not honouring "
              f"UMACAPTURE_DATA_ROOT; the user's own store now holds fixture records.",
              file=sys.stderr)
        status = "data-leak"

    summary["status"] = status
    summary["total_seconds"] = round(time.monotonic() - wall_start, 2)
    (RUNS / f"app_result_{args.tag}.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if status == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
