# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets"]
# ///
"""Run one declared scenario end to end and give a pass/fail verdict on the RECORD.

The golden suite (`native/test/integration/`) exercises the CLI's offline inputs. This exercises the
real Windows capture path and the real Flutter app, and answers the same question about the result:
it drives `app_drive_run.py` over the clip a scenario names, collects what the app wrote under its
isolated data root, normalises it with the golden suite's OWN code, and diffs it against the golden
the scenario names. See docs/live-capture-harness.md.

    uv run tool/live_capture_test/scenario_run.py tool/live_capture_test/scenarios/player_standard_5.json
    uv run tool/live_capture_test/scenario_run.py <scenario> --tag myrun

Nothing about the case lives here: the clip, its stops sidecar, the golden, the build config, the
settings mode, the scroll rate and every timeout come out of the scenario file. See SCHEMA below,
and `scenarios/player_standard_5.json` for a filled-in example.

Exit codes -- the verdict is scriptable:
    0  the app's records match the golden exactly, every clip's capture outcome was observed, and
       every per-clip expectation holds
    1  the records do not match (including "the app produced none") and the unified diff is
       printed, or a valid observation contradicts a per-clip expectation and its reason code is
       printed
    2  the scenario could not be run at all (bad/absent scenario, missing clip/golden/sidecar, a
       golden that states no records and therefore no expectation -- see expectation_failure --,
       missing app bundle, harness timeout, or the only summary under this tag is an EARLIER run's
       -- see attribution_failure), or it ran but cannot support a verdict: a record appeared
       outside the isolated data root, the isolation scan is missing, or a declared-synchronised
       run lost or never took a scroll-ready hold (see run_validity_failures), or the harness reports
       it stopped on an error (see harness_status_failure), or a per-clip expectation lacks the
       observation it needs, or no outcome of a clip's capture attempt was observed (see
       judge_clips)

A scenario plays one clip (`clip`) or several in one app session (`clips`); the single-clip form is
normalised to a one-element `clips` list, so both are judged by the same code, and both reach the
harness as a plan file (`build_plan`, passed with `--plan`). Every clip's capture outcome, per-clip
`expect`, `merge` and the run's `expect_links` are judged by `judge_clips`, a pure function over
the harness's per-clip observations, which returns reason codes rather than a bare boolean.

Normalisation is NOT reimplemented. `native/test/integration/run.py` is imported and its
`normalize` / `collect_records` / `_sort_key` / `_dumps` are called, so the four volatile keys
(record_id, trainer_id, captured_date, recognizer_version), the record sort order and the exact
serialisation are the golden suite's by construction and cannot drift from it.
"""

from __future__ import annotations

import argparse
import datetime
import difflib
import importlib.util
import json
import subprocess
import sys
import uuid
from pathlib import Path

# Single source of truth for the scratch data root and the harness's own path: the runner must
# look for the records exactly where the harness told the app to write them.
import app_drive_run

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HARNESS = HERE / "app_drive_run.py"
GOLDEN_SUITE = ROOT / "native/test/integration/run.py"
# Where the run artefacts go -- outside the repository, and the same directory the harness itself
# writes its per-run summary to, because this runner reads that summary back.
RUNS = app_drive_run.RUNS

# field -> (type(s), required). Unknown fields are an error, not a warning: a typo in
# "scroll_rate" would otherwise silently drop the one lever that makes the debug build reliable
# and the run would look like a real result.
SCHEMA: dict[str, tuple[tuple[type, ...], bool]] = {
    "version": ((int,), True),               # schema version, currently 1
    "name": ((str,), True),                  # case name; also the default run tag prefix
    "description": ((str,), False),          # free text, ignored by the runner
    "clip": ((str,), False),                 # .mkv to play, repo-root-relative or absolute; or `clips`
    "clips": ((list,), False),               # [CLIP_SCHEMA objects] played in order in one app session
    "expect_links": ((list,), False),        # [{"child": i, "slot": "parent1"|"parent2", "parent": j}]
    "stops": ((str, type(None)), False),     # annotate_stops.py sidecar; null -> <clip>.stops.json
    "golden": ((str,), True),                # golden json to diff against
    "config": ((str,), True),                # "debug" | "profile" -- which driver-enabled bundle
    "settings": ((str,), True),              # "fresh" | "copy" -- the app's settings box
    "sync": ((bool,), True),                 # hold on each annotated stop until scroll-ready
    "scroll_rate": ((int, float), False),    # speed multiplier on the SCROLLING PHASE only, 1.0 = real time
    "pace_ms": ((int, float), False),        # ms to hold each frame when sync is false; 0 = real time
    "range_seconds": ((list, type(None)), False),   # [A, B] clip seconds, or null for the whole clip
    "sync_timeout_seconds": ((int, float), False),  # per-stop wait for that tab's scroll-ready marker
    "record_wait_seconds": ((int, float), False),   # per clip, how long to wait for the attempt's outcome
    "run_timeout_seconds": ((int, float), False),   # wall ceiling for the whole harness process
}

# The per-clip fields, also the target the single-clip form is normalised into. `stops` and
# `range_seconds` mean what they mean at the top level of a single-clip scenario.
CLIP_SCHEMA: dict[str, tuple[tuple[type, ...], bool]] = {
    "clip": ((str,), True),
    "stops": ((str, type(None)), False),
    "range_seconds": ((list, type(None)), False),
    "expect": ((dict,), False),              # {"status", "candidate", "probe_duplicate"}; absent keys are not judged
    "merge": ((dict,), False),               # {"survivor": i, "retired": j}: merge after this clip
}
PER_CLIP_FIELDS = ("clip", "stops", "range_seconds")

# expect.status as the scenario writes it -> the capture status the app reports.
EXPECTED_STATUS = {"succeeded": "succeeded", "already_captured": "alreadyCaptured", "failed": "failed"}
LINK_SLOTS = ("parent1", "parent2")


class ScenarioError(Exception):
    """A scenario that cannot be run at all (exit 2), as opposed to one that runs and fails."""


def load_golden_suite():
    """Import native/test/integration/run.py as a module, for its normalisation."""
    spec = importlib.util.spec_from_file_location("golden_run", GOLDEN_SUITE)
    if spec is None or spec.loader is None:
        raise ScenarioError(f"cannot import the golden suite from {GOLDEN_SUITE}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve(value: str) -> Path:
    """Scenario paths are repo-root-relative unless absolute."""
    path = Path(value)
    return path if path.is_absolute() else (ROOT / path)


def check_fields(where: str, obj: dict, schema: dict[str, tuple[tuple[type, ...], bool]]) -> None:
    unknown = sorted(set(obj) - set(schema))
    if unknown:
        raise ScenarioError(f"{where}: unknown field(s) {unknown}; known fields are {sorted(schema)}")
    for field, (types, required) in schema.items():
        if field not in obj:
            if required:
                raise ScenarioError(f"{where}: missing required field {field!r}")
            continue
        if not isinstance(obj[field], types) or isinstance(obj[field], bool) != (bool in types):
            names = "/".join(t.__name__ for t in types)
            raise ScenarioError(f"{where}: field {field!r} must be {names}, got {type(obj[field]).__name__}")


def check_range(where: str, rng) -> None:
    if rng is not None and (len(rng) != 2 or not all(isinstance(v, (int, float)) for v in rng)):
        raise ScenarioError(f"{where}: range_seconds must be [A, B] in clip seconds, or null")


def is_index(value, count: int) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value < count


def check_clip_expectations(where: str, clips: list[dict], links: list) -> None:
    """Refuses an expectation that names a clip the scenario does not play, or that cannot hold."""
    count = len(clips)
    for i, entry in enumerate(clips):
        expect = entry.get("expect", {})
        unknown = sorted(set(expect) - {"status", "candidate", "probe_duplicate"})
        if unknown:
            raise ScenarioError(f"{where}: clips[{i}].expect has unknown field(s) {unknown}")
        if "status" in expect and expect["status"] not in EXPECTED_STATUS:
            raise ScenarioError(f"{where}: clips[{i}].expect.status must be one of {sorted(EXPECTED_STATUS)}")
        if "probe_duplicate" in expect and not isinstance(expect["probe_duplicate"], bool):
            raise ScenarioError(f"{where}: clips[{i}].expect.probe_duplicate must be true or false")
        if "candidate" in expect and expect["candidate"] is not None:
            candidate = expect["candidate"]
            if not isinstance(candidate, dict) or set(candidate) != {"with", "enhanced"}:
                raise ScenarioError(f"{where}: clips[{i}].expect.candidate must be null or "
                                    f"{{\"with\": j, \"enhanced\": k|null}}")
            if not is_index(candidate["with"], count) or candidate["with"] == i:
                raise ScenarioError(f"{where}: clips[{i}].expect.candidate.with must name another clip")
            if candidate["enhanced"] is not None and candidate["enhanced"] not in (i, candidate["with"]):
                raise ScenarioError(f"{where}: clips[{i}].expect.candidate.enhanced must be null or one "
                                    f"of the pair's clips ({i}, {candidate['with']})")
        if "merge" in entry:
            merge = entry["merge"]
            if set(merge) != {"survivor", "retired"} or not all(is_index(merge[k], i + 1) for k in merge) \
                    or merge["survivor"] == merge["retired"]:
                raise ScenarioError(f"{where}: clips[{i}].merge must be {{\"survivor\": a, \"retired\": b}} "
                                    f"naming two different clips played up to this one")
    for n, link in enumerate(links):
        if not isinstance(link, dict) or set(link) != {"child", "slot", "parent"} \
                or not is_index(link["child"], count) or not is_index(link["parent"], count) \
                or link["child"] == link["parent"] or link["slot"] not in LINK_SLOTS:
            raise ScenarioError(f"{where}: expect_links[{n}] must be {{\"child\": i, \"slot\": "
                                f"{'|'.join(LINK_SLOTS)}, \"parent\": j}} naming two different clips")


def load_scenario(path: Path) -> dict:
    """Parses and checks a scenario, and normalises it so that `clips` always holds the clips.

    A single-clip scenario's `clip`/`stops`/`range_seconds` move into a one-element `clips` list
    carrying no expectation, so it is judged by the record set and by whether its clip's capture
    outcome was observed.
    """
    scenario = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(scenario, dict):
        raise ScenarioError(f"{path}: a scenario is a JSON object")
    check_fields(str(path), scenario, SCHEMA)
    if ("clip" in scenario) == ("clips" in scenario):
        raise ScenarioError(f"{path}: a scenario names exactly one of 'clip' and 'clips'")
    if "clips" in scenario:
        stray = [f for f in PER_CLIP_FIELDS if f in scenario]
        if stray:
            raise ScenarioError(f"{path}: {stray} belong inside each 'clips' entry, not at the top level")
        if not scenario["clips"]:
            raise ScenarioError(f"{path}: 'clips' is empty")
        for i, entry in enumerate(scenario["clips"]):
            if not isinstance(entry, dict):
                raise ScenarioError(f"{path}: clips[{i}] is not a JSON object")
            check_fields(f"{path}: clips[{i}]", entry, CLIP_SCHEMA)
            check_range(f"{path}: clips[{i}]", entry.get("range_seconds"))
    else:
        if "expect_links" in scenario:
            raise ScenarioError(f"{path}: 'expect_links' relates clips, so it needs 'clips'")
        check_range(str(path), scenario.get("range_seconds"))
        scenario["clips"] = [{f: scenario.pop(f) for f in PER_CLIP_FIELDS if f in scenario}]
    scenario.setdefault("expect_links", [])
    check_clip_expectations(str(path), scenario["clips"], scenario["expect_links"])
    if scenario["version"] != 1:
        raise ScenarioError(f"{path}: unsupported scenario version {scenario['version']}")
    if scenario["config"] not in ("debug", "profile"):
        raise ScenarioError(f"{path}: config must be 'debug' or 'profile'")
    if scenario["settings"] not in ("fresh", "copy"):
        raise ScenarioError(f"{path}: settings must be 'fresh' or 'copy'")
    return scenario


def build_plan(scenario: dict) -> dict:
    """The harness plan for this scenario: the run's settings and, per clip, what the harness plays
    and what it has to wait for. The harness judges nothing, so no expectation is in it -- only
    whether a clip's observation needs the factor table (a candidate or merge expectation), and the
    merges to perform. See `app_drive_run.validate_plan` for the shape."""
    sync = scenario["sync"]
    clips = []
    for entry in scenario["clips"]:
        stops = entry.get("stops")
        rng = entry.get("range_seconds")
        clips.append({
            "clip": str(resolve(entry["clip"])),
            "stops": str(resolve(stops)) if sync and stops else None,
            "range": [float(rng[0]), float(rng[1])] if rng else None,
            "wait_factor_info": "candidate" in entry.get("expect", {}) or "merge" in entry,
            "merge": dict(entry["merge"]) if "merge" in entry else None,
        })
    return {
        "config": scenario["config"],
        "settings": scenario["settings"],
        "sync": sync,
        "sync_timeout": float(scenario.get("sync_timeout_seconds", 30)),
        "scroll_rate": float(scenario.get("scroll_rate", 1.0)) if sync else 1.0,
        "pace": 0.0 if sync else float(scenario.get("pace_ms", 0)),
        "record_wait": float(scenario.get("record_wait_seconds", 120)),
        "clips": clips,
    }


def harness_command(tag: str, run_id: str, plan_path: Path) -> list[str]:
    """The harness's command line: everything about the run is in the plan file."""
    return ["uv", "run", str(HARNESS), "--tag", tag, "--run-id", run_id, "--plan", str(plan_path)]


def expectation_failure(golden_text: str, golden: Path) -> str | None:
    """Why this golden cannot state an expectation, or None if it can.

    The verdict is `actual_text == golden_text`, and equality is symmetric about emptiness: a golden
    holding no records is satisfied by a run that recognised NOTHING, and the runner then prints
    `PASS: 0 record(s) match` and exits 0 for an app that produced no output at all. "The run
    produced nothing" and "the run was supposed to produce nothing" are different claims, and a
    comparison against an empty expectation cannot tell them apart -- so the empty expectation is
    refused rather than the empty result reinterpreted. Refused HERE, before anything is launched,
    because the fault is in the scenario's inputs and not in what the app did.

    An empty result is a legitimate expectation elsewhere, and this is how the repository already
    states it: `native/test/integration/cases.json` writes `expect_records: 0` -- with
    `expect_errors`, since run.py refuses a zero-record case that names no error tag -- INSTEAD of a
    golden, never as an empty golden file. So no committed golden is empty, and a scenario has no
    field with which to declare that its run should end empty. If one is ever wanted, it belongs in
    SCHEMA as its own key, on the same footing, and not as a golden that happens to be `[]`.

    The two neighbouring shapes -- text that is not JSON, and JSON that is not a list of records --
    are refused by the same function for the same reason: `collect_records` can only ever produce a
    list, so neither can be an expectation the app could meet, and a bare mismatch would report the
    scenario's own broken input as a recognition failure.
    """
    try:
        expected = json.loads(golden_text)
    except ValueError as error:
        return f"golden {golden} is not readable as JSON ({error}), so it states no expectation"
    if not isinstance(expected, list):
        return (f"golden {golden} holds a JSON {type(expected).__name__}, not the list of records "
                f"the golden suite's collection produces, so nothing the app can do would match it")
    if not expected:
        return (f"golden {golden} states no records, so it is met by a run that recognised nothing: "
                f"an app that produced no output at all would be reported as "
                f"'PASS: 0 record(s) match'. A scenario cannot declare that its run should end "
                f"empty -- the golden suite states that as expect_records/expect_errors in "
                f"native/test/integration/cases.json, never as an empty golden -- so an empty "
                f"golden here is a broken expectation, not a case")
    return None


def preflight(scenario: dict) -> None:
    """Fail with exit 2, before launching anything, on an input the run cannot proceed without."""
    for entry in scenario["clips"]:
        clip = resolve(entry["clip"])
        if not clip.is_file():
            raise ScenarioError(f"clip not found: {clip}")
        if scenario["sync"]:
            stops = resolve(entry["stops"]) if entry.get("stops") else clip.with_suffix(".stops.json")
            if not stops.is_file():
                raise ScenarioError(f"stops sidecar not found: {stops} (run annotate_stops.py, or set sync=false)")
    golden = resolve(scenario["golden"])
    if not golden.is_file():
        raise ScenarioError(f"golden not found: {golden}")
    vacuous = expectation_failure(golden.read_text(encoding="utf-8"), golden)
    if vacuous is not None:
        raise ScenarioError(vacuous)
    exe = app_drive_run.APP_EXE_BY_CONFIG[scenario["config"]]
    if not exe.is_file():
        raise ScenarioError(f"app bundle not built: {exe}")


def attribution_failure(outcome: dict, summary: dict | None, run_id: str, summary_path: Path) -> str | None:
    """Why the artefacts under this tag are not THIS run's, or None if they are.

    Everything the verdict rests on -- the isolation scan, `synchronised.timeouts`, `exe_mtime` --
    is read out of `app_result_<tag>.json`, and that file is written once at the end of a run and
    never removed (RUNS holds earlier runs' measurements, which are test material). So a run that
    dies before writing one leaves the PREVIOUS run's summary under the same tag, and a tag is
    reused on purpose (`--tag myrun` is the documented invocation). Dying early is not exotic: every
    sidecar refusal in the harness raises before it has launched anything, and the harness kills its
    whole process tree on timeout.

    The identity is carried as data rather than inferred from the file's timestamp: the runner mints
    a `run_id`, passes it on the command line and requires it back. A harness too old to know the
    flag reports no `run_id` and is refused rather than trusted, and a summary carrying this run's
    id also proves `prepare_scratch()` ran -- it is the only route to the write -- so the records
    the diff is about are this run's too.
    """
    if outcome["timed_out"]:
        return (f"the harness exceeded run_timeout_seconds and its process tree was killed "
                f"(returncode {outcome['returncode']}), so it cannot have completed this run")
    if summary is None:
        return (f"the harness produced no summary at {summary_path} "
                f"(returncode {outcome['returncode']})")
    found = summary.get("run_id")
    if found != run_id:
        return (f"{summary_path} carries run_id {found!r}, not this run's {run_id!r}: it is an "
                f"EARLIER run's summary left under the same tag, and the harness wrote none for "
                f"this run (returncode {outcome['returncode']}). Reading it would give this run the "
                f"verdict of that one -- that run's isolation scan, timing result and records. See "
                f"the harness log for why this run stopped, then re-run with a fresh --tag.")
    return None


def run_validity_failures(scenario: dict, summary: dict) -> list[str]:
    """Reasons the run cannot support a verdict at all (exit 2), read off what the harness OBSERVED.

    Both checks are about a run that produces well-formed artefacts while not being the run it
    claims to be, which is the only way this suite can report a broken system as green:

    * **Isolation** -- `data_isolation` is the harness's before/after scan of the user's own data
      roots. Its absence is a failure too: an older or patched harness that does not perform the
      scan must not read as "nothing leaked".
    * **Synchronisation** -- a `sync` scenario that timed out waiting for a tab's scroll-ready
      marker played that tab unsynchronised, i.e. it exercised a different timing regime than the
      one the scenario declares. The harness prints the timeout and resumes on purpose (the run
      stays informative), but the VERDICT must not call the result a pass.
    * **Coverage of the timing model** -- `timeouts` counts waits that were LOST, so on its own it
      reads 0 for a run that never waited at all: a sidecar carrying no stops arms nothing, holds
      nothing and returns 0 of 0. So the count of stops actually held is asserted against the count
      the harness armed, and both against being empty. `validate_stops` refuses such a sidecar
      before the harness launches anything, so what this catches is the harness losing a hold it
      was given -- the gap `timeouts` alone cannot express.
    """
    failures: list[str] = []

    isolation = summary.get("data_isolation")
    if not isinstance(isolation, dict) or "leaked_record_dirs" not in isolation:
        failures.append("the harness reported no data-isolation scan (no 'data_isolation' in its "
                        "summary), so nothing observed whether the app honoured UMACAPTURE_DATA_ROOT")
    elif isolation["leaked_record_dirs"]:
        failures.append(f"record(s) appeared OUTSIDE the isolated data root during this run: "
                        f"{isolation['leaked_record_dirs']} (roots scanned: {isolation['roots']})")

    # Kept as a cheap invariant on the harness's own bookkeeping. It cannot catch a leak -- the
    # list it inspects is globbed from inside the scratch root -- so it is not the isolation check.
    scratch = app_drive_run.SCRATCH_ROOT.resolve()
    stray = [d for d in summary.get("record_dirs", []) if scratch not in Path(d).resolve().parents]
    if stray:
        failures.append(f"the harness attributed record dir(s) outside {scratch} to this run: {stray}")

    if scenario["sync"]:
        failures += sync_failures(summary)
    return failures


def sync_failures(summary: dict) -> list[str]:
    """The synchronisation half of `run_validity_failures`, over one playback's observation: the
    whole summary for a single-clip run, or one entry of the harness's per-clip `clips`."""
    failures: list[str] = []
    synchronised = summary.get("synchronised")
    if not isinstance(synchronised, dict) or "timeouts" not in synchronised:
        failures.append("the scenario declares sync but the harness reported no synchronisation "
                        f"result, so the run never reached synchronised playback"
                        + (f" ({summary['error']})" if summary.get("error") else ""))
    else:
        if synchronised["timeouts"]:
            timed_out = [h["tab"] for h in synchronised.get("held", []) if h.get("timed_out")]
            failures.append(f"{synchronised['timeouts']} scroll-ready timeout(s) (tab(s) {timed_out}): "
                            f"those tabs played unsynchronised, so this run did not exercise the "
                            f"scenario's timing model")
        armed = summary.get("stop_frames")
        held = synchronised.get("held")
        if not isinstance(armed, list) or not armed:
            failures.append(f"the scenario declares sync but the harness armed no stop frames "
                            f"(stop_frames {armed!r}), so nothing held the clip and the whole "
                            f"run played unsynchronised -- with no wait to lose, timeouts is 0")
        elif not isinstance(held, list) or len(held) != len(armed):
            count = len(held) if isinstance(held, list) else repr(held)
            failures.append(f"the harness armed {len(armed)} stop frame(s) {armed} but held "
                            f"{count}: the tabs it did not hold played unsynchronised, and a "
                            f"hold that never happened cannot time out")
        if isinstance(held, list):
            # A hold released by a scroll-ready marker seen BEFORE this clip armed its signals (a
            # previous clip's marker on a signal that was never re-created) waited for nothing. A
            # timed-out hold also reads False here, and is already reported above.
            early = [h.get("tab") for h in held
                     if isinstance(h, dict) and h.get("marker_after_arm") is False and not h.get("timed_out")]
            if early:
                failures.append(f"tab(s) {early} were released by a scroll-ready marker seen before the "
                                f"clip armed its signals, so they played unsynchronised")
    return failures


# The harness statuses that describe a run which completed. "no-record" is a completed run whose
# app wrote nothing: that is an observation the verdict judges, not a run that could not be judged.
COMPLETED_STATUSES = ("ok", "no-record")


def harness_status_failure(summary: dict) -> str | None:
    """Why the harness's own status rules out a verdict, or None.

    A summary with `status: "error"` was written from the harness's exception path. Whatever it
    observed before the exception -- every record, every per-clip observation -- the run did not
    finish the sequence it was given (stopping the capture, quitting the app), so matching content
    does not make it a pass. Any status outside COMPLETED_STATUSES, and a missing one, is refused the
    same way: absence must not read as "completed".
    """
    status = summary.get("status")
    if status in COMPLETED_STATUSES:
        return None
    return (f"the harness reported status {status!r}, not one of {list(COMPLETED_STATUSES)}"
            + (f" ({summary['error']})" if summary.get("error") else "")
            + ": the run did not complete, so what it observed cannot support a verdict")


class Finding:
    """One reason code with its clip and a human-readable message."""

    def __init__(self, code: str, clip: int | None, message: str):
        self.code, self.clip, self.message = code, clip, message

    def as_dict(self) -> dict:
        return {"code": self.code, "clip": self.clip, "message": self.message}

    def __repr__(self) -> str:
        return f"Finding({self.code!r}, {self.clip!r}, {self.message!r})"


class Judgement:
    """`inconclusive` findings mean the observation cannot support a verdict (exit 2) and take
    precedence; `mismatches` are valid observations that contradict the expectation (exit 1)."""

    def __init__(self):
        self.inconclusive: list[Finding] = []
        self.mismatches: list[Finding] = []

    def unjudgeable(self, code: str, clip: int | None, message: str) -> None:
        self.inconclusive.append(Finding(code, clip, message))

    def mismatch(self, code: str, clip: int | None, message: str) -> None:
        self.mismatches.append(Finding(code, clip, message))

    @property
    def exit_code(self) -> int:
        return 2 if self.inconclusive else (1 if self.mismatches else 0)

    def codes(self) -> list[str]:
        return [f.code for f in self.inconclusive + self.mismatches]


# Inconclusive (exit 2).
CLIP_COUNT = "clip_count_mismatch"          # the harness observed a different number of clips
OBSERVATION_MISSING = "observation_missing"  # a key the expectation needs is absent or ill-typed
DRIVER_FAILED = "driver_failed"             # a driver/RPC call failed or timed out
NO_CONTAINER = "container_never_seen"       # harness_state never found the app's ProviderContainer
SYNC_INVALID = "sync_invalid"               # this clip's synchronised playback is not valid
FACTOR_INFO_NOT_LOADED = "factor_info_not_loaded"  # candidates cannot be judged without the table
STORE_NOT_LOADED = "store_not_loaded"       # settling gave up with the store's active list never loaded
EVENT_NOT_THIS_RECORD = "event_not_this_record"    # "no candidate" means nothing unless the tile could show
OUTCOME_UNOBSERVED = "outcome_unobserved"   # no outcome of the clip's capture attempt was observed
# Mismatch (exit 1).
STATUS_MISMATCH = "status_mismatch"
UNSETTLED = "unsettled"                     # disk and store still disagreed when settling gave up
CANDIDATE_MISMATCH = "candidate_mismatch"   # the pair is absent, extra, or names the wrong records
CANDIDATE_UNEXPECTED = "candidate_unexpected"
TILE_DISAGREES = "tile_disagrees"           # the UI tile contradicts the candidate data
PROBE_NOT_RUN = "probe_not_run"
PROBE_MISMATCH = "probe_mismatch"
LINK_MISMATCH = "link_mismatch"
MERGE_INCOMPLETE = "merge_incomplete"
MERGE_SURVIVOR_MISSING = "merge_survivor_missing"
MERGE_RETIRED_PRESENT = "merge_retired_present"
MERGE_MARK_MISSING = "merge_mark_missing"
MERGE_CANDIDATE_REMAINS = "merge_candidate_remains"

TILE_STATES = ("present", "absent")


def _driver_error(value) -> str | None:
    """A driver-derived observation the harness could not take is reported as {"error": ...}."""
    if isinstance(value, dict) and "error" in value:
        return str(value["error"])
    return None


def _pairs_with(candidates: list, record_id: str) -> list[dict]:
    return [c for c in candidates if isinstance(c, dict) and record_id in (c.get("older"), c.get("newer"))]


def judge_clips(scenario: dict, clips: list | None, disk: dict) -> Judgement:
    """Judges every per-clip expectation and `expect_links` against the harness's observations.

    `clips` is the harness summary's per-clip list; `disk` maps a record id to what the scratch root
    holds for it: {"exists": bool, "merged_ids": [...], "parents": {"parent1": id|None, ...}}.

    The rule that keeps this from reporting a broken instrument as a product result: an expectation
    whose observation is missing, ill-typed or marked as a driver error is INCONCLUSIVE, never
    defaulted to false, to "no candidate" or to "not completed". Only a well-formed observation can
    contradict an expectation.

    Every clip's capture outcome is checked, a clip that states no expectation included: a clip whose
    outcome was never observed has not shown that its capture completed, so the run supports no
    verdict -- neither a pass nor the record comparison's FAIL. The harness reads the outcome from a
    record the app keeps until the next attempt begins (`app_drive_run.attempt_outcome`), so a null
    one is a wait that ran out, not a statement that the attempt produced nothing.
    """
    j = Judgement()
    expected = scenario["clips"]
    if not isinstance(clips, list):
        j.unjudgeable(OBSERVATION_MISSING, None, "the harness summary carries no per-clip 'clips' list")
        return j
    if len(clips) != len(expected):
        j.unjudgeable(CLIP_COUNT, None, f"the scenario plays {len(expected)} clip(s) but the harness "
                                        f"observed {len(clips)}")
        return j

    def record_id(i: int) -> str | None:
        rid = clips[i].get("record_id") if isinstance(clips[i], dict) else None
        return rid if isinstance(rid, str) else None

    for i, (want, seen) in enumerate(zip(expected, clips)):
        expect = want.get("expect", {})
        judged = bool(expect) or "merge" in want
        if not isinstance(seen, dict):
            j.unjudgeable(OBSERVATION_MISSING, i, "the clip's observation is not an object")
            continue
        if seen.get("state_error"):
            j.unjudgeable(DRIVER_FAILED, i, f"reading the app state failed: {seen['state_error']}")
            continue
        if seen.get("container_seen") is not True:
            j.unjudgeable(NO_CONTAINER if seen.get("container_seen") is False else OBSERVATION_MISSING, i,
                          f"container_seen is {seen.get('container_seen')!r}: the app state was never read")
            continue
        if judged and scenario["sync"]:
            for reason in sync_failures(seen):
                j.unjudgeable(SYNC_INVALID, i, reason)
        if "capture" not in seen:
            j.unjudgeable(OBSERVATION_MISSING, i, "no 'capture' observation")
            continue
        capture = seen["capture"]
        if capture is None:
            j.unjudgeable(OUTCOME_UNOBSERVED, i,
                          f"no outcome of the clip's capture attempt was observed within the wait (last "
                          f"capture state {seen.get('last_capture_state')!r}, last event "
                          f"{seen.get('last_event')!r})")
            continue
        if not isinstance(capture, dict) or not isinstance(capture.get("status"), str):
            j.unjudgeable(OBSERVATION_MISSING, i, f"capture observation {capture!r} carries no status")
            continue
        if not judged:
            continue
        if "status" in expect and capture["status"] != EXPECTED_STATUS[expect["status"]]:
            j.mismatch(STATUS_MISMATCH, i, f"expected {expect['status']}, the app reported {capture['status']}")
        if "probe_duplicate" in expect:
            _judge_probe(j, i, expect["probe_duplicate"], seen)
        if "candidate" in expect or "merge" in want:
            if not _settled(j, i, seen):
                continue
        if "candidate" in expect:
            _judge_candidate(j, i, expect["candidate"], seen, record_id)
        if "merge" in want:
            _judge_merge(j, i, want["merge"], seen, record_id, disk)

    for link in scenario["expect_links"]:
        child, parent = record_id(link["child"]), record_id(link["parent"])
        if child is None or parent is None:
            j.unjudgeable(OBSERVATION_MISSING, link["child"], f"expect_links {link}: a clip has no record id")
            continue
        on_disk = disk.get(child)
        if not isinstance(on_disk, dict) or not isinstance(on_disk.get("parents"), dict):
            j.unjudgeable(OBSERVATION_MISSING, link["child"], f"no record.json was read for {child}")
            continue
        found = on_disk["parents"].get(link["slot"])
        if found != parent:
            j.mismatch(LINK_MISMATCH, link["child"],
                       f"{link['slot']} of clip {link['child']}'s record is {found!r}, expected clip "
                       f"{link['parent']}'s {parent!r}")
    return j


# The settle conditions `app_drive_run.settle_failures` names. A measured one is a disagreement the
# harness saw between disk and store (exit 1); an unobserved one means what settling needed was
# never loaded or never read, so nothing was measured (exit 2).
SETTLE_MEASURED = ("store_has_record", "disk_matches_store")
SETTLE_UNOBSERVED = {"store_loaded": STORE_NOT_LOADED, "factor_info_loaded": FACTOR_INFO_NOT_LOADED,
                     "container": OBSERVATION_MISSING}


def _settled(j: Judgement, i: int, seen: dict) -> bool:
    """Whether the store and disk had settled; a missing, unobserved or unexplained settle is
    inconclusive, and only a measured disagreement is a mismatch."""
    settled = seen.get("settled")
    if settled is True:
        return True
    unsettled = seen.get("unsettled")
    if settled is False and isinstance(unsettled, list) and unsettled:
        for name in unsettled:
            if name not in SETTLE_MEASURED:
                j.unjudgeable(SETTLE_UNOBSERVED.get(name, OBSERVATION_MISSING), i,
                              f"settling gave up with {name!r} unobserved: {unsettled}")
        measured = [name for name in unsettled if name in SETTLE_MEASURED]
        if measured:
            j.mismatch(UNSETTLED, i, f"store and disk did not settle: {measured}")
    else:
        j.unjudgeable(OBSERVATION_MISSING, i, f"no evidence of settling (settled={settled!r}, "
                                              f"unsettled={unsettled!r})")
    return False


def _judge_probe(j: Judgement, i: int, want: bool, seen: dict) -> None:
    lines = seen.get("probe_duplicates")
    if not isinstance(lines, list) or not all(isinstance(v, bool) for v in lines):
        j.unjudgeable(OBSERVATION_MISSING, i, f"probe_duplicates is {lines!r}, not a list of booleans")
    elif not lines:
        j.mismatch(PROBE_NOT_RUN, i, "the early duplicate check logged no result")
    elif any(v != want for v in lines):
        j.mismatch(PROBE_MISMATCH, i, f"expected duplicate={want}, the check logged {lines}")


def _tile(j: Judgement, i: int, value, what: str) -> str | None:
    error = _driver_error(value)
    if error is not None:
        j.unjudgeable(DRIVER_FAILED, i, f"{what}: {error}")
    elif value not in TILE_STATES:
        j.unjudgeable(OBSERVATION_MISSING, i, f"{what} is {value!r}, not one of {list(TILE_STATES)}")
    else:
        return value
    return None


def _judge_candidate(j: Judgement, i: int, want, seen: dict, record_id) -> None:
    own = record_id(i)
    candidates = seen.get("candidates")
    loaded = seen.get("factor_info_loaded")
    if own is None or not isinstance(candidates, list) or not isinstance(loaded, bool):
        j.unjudgeable(OBSERVATION_MISSING, i, f"record_id {own!r}, candidates {type(candidates).__name__}, "
                                              f"factor_info_loaded {loaded!r}")
        return
    if not loaded:
        j.unjudgeable(FACTOR_INFO_NOT_LOADED, i, "the factor table was not loaded, so only exact "
                                                 "duplicates could have been found")
        return
    pairs = _pairs_with(candidates, own)
    if want is None:
        event = seen.get("event")
        if not isinstance(event, dict) or event.get("status") != "succeeded" or event.get("record_id") != own:
            j.unjudgeable(EVENT_NOT_THIS_RECORD, i, f"event {event!r} is not this record's success, so "
                                                    f"the tile could not have shown even with a candidate")
            return
        if pairs:
            j.mismatch(CANDIDATE_UNEXPECTED, i, f"expected no candidate, found {pairs}")
    else:
        other, enhanced = record_id(want["with"]), (None if want["enhanced"] is None else record_id(want["enhanced"]))
        if other is None or (want["enhanced"] is not None and enhanced is None):
            j.unjudgeable(OBSERVATION_MISSING, i, "a clip named by the candidate has no record id")
            return
        match = [p for p in pairs if {p.get("older"), p.get("newer")} == {own, other}
                 and p.get("enhanced") == enhanced]
        if len(pairs) != 1 or len(match) != 1:
            j.mismatch(CANDIDATE_MISMATCH, i, f"expected exactly the pair ({own}, {other}) enhanced "
                                              f"{enhanced!r}, found {pairs}")
    tile = _tile(j, i, seen.get("tile"), "tile")
    if tile is not None and tile != ("present" if pairs else "absent"):
        j.mismatch(TILE_DISAGREES, i, f"the candidate data has {len(pairs)} pair(s) but the tile is {tile}")


def _judge_merge(j: Judgement, i: int, want: dict, seen: dict, record_id, disk: dict) -> None:
    merge = seen.get("merge")
    error = _driver_error(merge)
    if error is not None:
        j.unjudgeable(DRIVER_FAILED, i, f"merge: {error}")
        return
    if not isinstance(merge, dict) or not isinstance(merge.get("completed"), bool) \
            or not isinstance(merge.get("candidates_after"), list):
        j.unjudgeable(OBSERVATION_MISSING, i, f"merge observation {merge!r} lacks completed/candidates_after")
        return
    survivor, retired = record_id(want["survivor"]), record_id(want["retired"])
    if survivor is None or retired is None:
        j.unjudgeable(OBSERVATION_MISSING, i, "a merged clip has no record id")
        return
    if not merge["completed"]:
        j.mismatch(MERGE_INCOMPLETE, i, "the merge did not complete")
        return
    kept, gone = disk.get(survivor), disk.get(retired)
    if not isinstance(kept, dict) or not isinstance(gone, dict) or not isinstance(kept.get("exists"), bool) \
            or not isinstance(gone.get("exists"), bool):
        j.unjudgeable(OBSERVATION_MISSING, i, "the scratch root was not read for the merged records")
        return
    if not kept["exists"]:
        j.mismatch(MERGE_SURVIVOR_MISSING, i, f"the survivor {survivor} is gone")
    elif retired not in (kept.get("merged_ids") or []):
        j.mismatch(MERGE_MARK_MISSING, i, f"the survivor's merged_ids {kept.get('merged_ids')!r} "
                                          f"lacks {retired}")
    if gone["exists"]:
        j.mismatch(MERGE_RETIRED_PRESENT, i, f"the retired {retired} is still on disk")
    remaining = [p for p in merge["candidates_after"] if isinstance(p, dict)
                 and {p.get("older"), p.get("newer")} == {survivor, retired}]
    tile = _tile(j, i, merge.get("tile_after"), "tile after the merge")
    if remaining or tile == "present":
        j.mismatch(MERGE_CANDIDATE_REMAINS, i, f"the merged pair is still a candidate "
                                               f"({remaining}, tile {tile})")


def read_disk(scratch: Path, record_ids: list[str]) -> dict:
    """What the scratch root holds for each record id, in the shape `judge_clips` reads.

    Reads the RAW record.json (the golden normalisation drops metadata.record_id, where the parent
    links live) and the survivor's merged_ids.json (its `ids`).
    """
    disk: dict = {}
    for rid in record_ids:
        directory = next((d for d in scratch.glob(f"**/{rid}") if d.is_dir()), None)
        entry: dict = {"exists": directory is not None and (directory / "record.json").is_file()}
        if entry["exists"]:
            try:
                raw = json.loads((directory / "record.json").read_text(encoding="utf-8"))
                ids = (raw.get("metadata") or {}).get("record_id") or {}
                entry["parents"] = {slot: ids.get(slot) for slot in LINK_SLOTS}
            except (OSError, ValueError, AttributeError):
                pass
            marks = directory / "merged_ids.json"
            try:
                entry["merged_ids"] = json.loads(marks.read_text(encoding="utf-8")).get("ids", []) \
                    if marks.is_file() else []
            except (OSError, ValueError, AttributeError):
                entry.pop("exists")
        disk[rid] = entry
    return disk


def run_harness(command: list[str], timeout: float, log: Path) -> dict:
    """Runs the harness, tee-ing its stdout to [log]. Returns {returncode, timed_out}.

    On timeout the whole process TREE is killed by PID (`taskkill /F /T /PID`), because the harness
    owns two grandchildren -- the app and the mimic player -- that terminating only the python
    process would leave running.
    """
    with log.open("w", encoding="utf-8", errors="replace") as handle:
        process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, cwd=str(RUNS))
        try:
            returncode = process.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)],
                           capture_output=True, check=False)
            returncode = process.wait(timeout=60)
            timed_out = True
    return {"returncode": returncode, "timed_out": timed_out}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", type=Path, help="path to a scenario json")
    parser.add_argument("--tag", default=None,
                        help="run tag for the harness's logs (default <name>_<HHMMSS>)")
    args = parser.parse_args()

    try:
        scenario = load_scenario(args.scenario)
        preflight(scenario)
        plan = app_drive_run.validate_plan(build_plan(scenario), "the plan built from the scenario")
        golden_suite = load_golden_suite()
    except (ScenarioError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    except SystemExit as refusal:  # validate_plan refuses the way the harness does
        print(f"ERROR: {refusal}", file=sys.stderr)
        return 2
    tag = args.tag or f"{scenario['name']}_{datetime.datetime.now().strftime('%H%M%S')}"
    run_id = uuid.uuid4().hex

    verdict: dict = {"scenario": str(args.scenario.resolve()), "name": scenario["name"], "tag": tag,
                     "run_id": run_id,
                     "clips": [str(resolve(entry["clip"])) for entry in scenario["clips"]],
                     "golden": str(resolve(scenario["golden"]))}
    # The parent writes the plan and opens the harness log itself, and runs the child with RUNS as
    # its cwd, so the directory has to exist HERE too. The harness creates it in its own main()
    # (never at import time), which is one process too late: on a clone that has the clips but no
    # analysis directory yet, `log.open("w")` below raised FileNotFoundError and the runner exited 1
    # -- the code that means "the records did not match the golden", for a run that never started.
    RUNS.mkdir(parents=True, exist_ok=True)
    plan_path = RUNS / f"plan_{tag}.json"
    plan_path.write_text(json.dumps(plan, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    verdict["plan"] = str(plan_path)
    command = harness_command(tag, run_id, plan_path)
    verdict["harness_command"] = " ".join(command)
    outcome = run_harness(command, float(scenario.get("run_timeout_seconds", 600)),
                          RUNS / f"scenario_{tag}.log")
    verdict["harness"] = outcome

    summary_path = RUNS / f"app_result_{tag}.json"
    try:
        # A summary that cannot be read is not a summary. Unreadable is also what a half-written one
        # looks like, and the killed-tree path can leave one, so it is handled here rather than as
        # an uncaught decode error -- which would exit 1, the code that means "records mismatched".
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        summary = None
    unattributed = attribution_failure(outcome, summary, run_id, summary_path)
    if unattributed is not None or summary is None:
        print(f"ERROR {scenario['name']}: {unattributed}; see scenario_{tag}.log", file=sys.stderr)
        return 2
    verdict["harness_status"] = summary.get("status")
    verdict["record_dirs"] = summary.get("record_dirs", [])
    verdict["playback_seconds"] = summary.get("playback_seconds")
    verdict["exe_mtime"] = summary.get("exe_mtime")
    verdict["data_isolation"] = summary.get("data_isolation")
    verdict["sync_timeouts"] = (summary.get("synchronised") or {}).get("timeouts")
    if summary.get("error"):
        verdict["harness_error"] = summary["error"]

    # Isolation, synchronisation and completion, asserted rather than assumed. All are properties of
    # the RUN, not of the records, so a failure here is exit 2 ("could not be run") and not a verdict.
    invalid = run_validity_failures(scenario, summary)
    status_failure = harness_status_failure(summary)
    if status_failure is not None:
        invalid.append(status_failure)
    if invalid:
        verdict["invalid_run"] = invalid
        (RUNS / f"scenario_result_{tag}.json").write_text(
            json.dumps(verdict, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        for reason in invalid:
            print(f"ERROR {scenario['name']}: {reason}", file=sys.stderr)
        return 2

    # The golden suite's own collection: normalise (drop the four volatile metadata keys), then
    # sort by canonical content, then serialise. Same functions the committed goldens are compared
    # with, called on the app's storage tree instead of a `replay` temp dir.
    scratch = app_drive_run.SCRATCH_ROOT.resolve()
    actual = golden_suite.collect_records(scratch)
    actual_text = golden_suite._dumps(actual)
    golden_text = resolve(scenario["golden"]).read_text(encoding="utf-8")
    verdict["records_found"] = len(actual)
    if len(actual) != len(verdict["record_dirs"]):
        # Not fatal -- the diff is still the verdict -- but it means the scratch storage held
        # something the harness did not attribute to this run.
        verdict["note"] = (f"the harness attributed {len(verdict['record_dirs'])} record dir(s) to this "
                           f"run but the scratch storage holds {len(actual)}")

    verdict["match"] = actual_text == golden_text
    observed = summary.get("clips")
    ids = [c["record_id"] for c in observed or [] if isinstance(c, dict) and isinstance(c.get("record_id"), str)]
    judgement = judge_clips(scenario, observed, read_disk(scratch, ids))
    verdict["clip_findings"] = {"inconclusive": [f.as_dict() for f in judgement.inconclusive],
                                "mismatches": [f.as_dict() for f in judgement.mismatches]}
    (RUNS / f"scenario_result_{tag}.json").write_text(
        json.dumps(verdict, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(verdict, indent=2, ensure_ascii=False))

    if judgement.inconclusive:
        for finding in judgement.inconclusive:
            print(f"ERROR {scenario['name']}: clip {finding.clip}: [{finding.code}] {finding.message}",
                  file=sys.stderr)
        return 2
    for finding in judgement.mismatches:
        print(f"FAIL {scenario['name']}: clip {finding.clip}: [{finding.code}] {finding.message}")
    if verdict["match"] and not judgement.mismatches:
        print(f"\nPASS {scenario['name']}: {len(actual)} record(s) match {Path(scenario['golden']).name}")
        return 0
    if verdict["match"]:
        print(f"\nFAIL {scenario['name']}: {len(judgement.mismatches)} per-clip finding(s) above; the "
              f"{len(actual)} record(s) match {Path(scenario['golden']).name}")
        return 1
    diff = difflib.unified_diff(golden_text.splitlines(), actual_text.splitlines(),
                                fromfile="golden", tofile="actual", lineterm="")
    print(f"\nFAIL {scenario['name']}: record mismatch "
          f"({len(actual)} record(s) produced, harness status {summary.get('status')!r})")
    print("\n".join(diff))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
