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
    0  the app's records match the golden exactly
    1  they do not (including "the app produced none"); the unified diff is printed
    2  the scenario could not be run at all (bad/absent scenario, missing clip/golden/sidecar, a
       golden that states no records and therefore no expectation -- see expectation_failure --,
       missing app bundle, harness timeout, or the only summary under this tag is an EARLIER run's
       -- see attribution_failure), or it ran but cannot support a verdict: a record appeared
       outside the isolated data root, the isolation scan is missing, or a declared-synchronised
       run lost or never took a scroll-ready hold (see run_validity_failures)

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
    "clip": ((str,), True),                  # .mkv to play, repo-root-relative or absolute
    "stops": ((str, type(None)), False),     # annotate_stops.py sidecar; null -> <clip>.stops.json
    "golden": ((str,), True),                # golden json to diff against
    "config": ((str,), True),                # "debug" | "profile" -- which driver-enabled bundle
    "settings": ((str,), True),              # "fresh" | "copy" -- the app's settings box
    "sync": ((bool,), True),                 # hold on each annotated stop until scroll-ready
    "scroll_rate": ((int, float), False),    # speed multiplier on the SCROLLING PHASE only, 1.0 = real time
    "pace_ms": ((int, float), False),        # ms to hold each frame when sync is false; 0 = real time
    "range_seconds": ((list, type(None)), False),   # [A, B] clip seconds, or null for the whole clip
    "sync_timeout_seconds": ((int, float), False),  # per-stop wait for that tab's scroll-ready marker
    "record_wait_seconds": ((int, float), False),   # how long to wait for record.json after playback
    "run_timeout_seconds": ((int, float), False),   # wall ceiling for the whole harness process
}


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


def load_scenario(path: Path) -> dict:
    scenario = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(scenario, dict):
        raise ScenarioError(f"{path}: a scenario is a JSON object")
    unknown = sorted(set(scenario) - set(SCHEMA))
    if unknown:
        raise ScenarioError(f"{path}: unknown field(s) {unknown}; known fields are {sorted(SCHEMA)}")
    for field, (types, required) in SCHEMA.items():
        if field not in scenario:
            if required:
                raise ScenarioError(f"{path}: missing required field {field!r}")
            continue
        if not isinstance(scenario[field], types) or isinstance(scenario[field], bool) != (bool in types):
            names = "/".join(t.__name__ for t in types)
            raise ScenarioError(f"{path}: field {field!r} must be {names}, got {type(scenario[field]).__name__}")
    if scenario["version"] != 1:
        raise ScenarioError(f"{path}: unsupported scenario version {scenario['version']}")
    if scenario["config"] not in ("debug", "profile"):
        raise ScenarioError(f"{path}: config must be 'debug' or 'profile'")
    if scenario["settings"] not in ("fresh", "copy"):
        raise ScenarioError(f"{path}: settings must be 'fresh' or 'copy'")
    rng = scenario.get("range_seconds")
    if rng is not None and (len(rng) != 2 or not all(isinstance(v, (int, float)) for v in rng)):
        raise ScenarioError(f"{path}: range_seconds must be [A, B] in clip seconds, or null")
    return scenario


def harness_command(scenario: dict, tag: str, run_id: str) -> list[str]:
    clip = resolve(scenario["clip"])
    command = [
        "uv", "run", str(HARNESS),
        "--tag", tag,
        "--run-id", run_id,
        "--clip", str(clip),
        "--config", scenario["config"],
        "--settings", scenario["settings"],
        "--record-wait", str(scenario.get("record_wait_seconds", 120)),
    ]
    if scenario["sync"]:
        command += ["--sync", "--sync-timeout", str(scenario.get("sync_timeout_seconds", 30))]
        command += ["--scroll-rate", str(scenario.get("scroll_rate", 1.0))]
        stops = scenario.get("stops")
        if stops:
            command += ["--stops", str(resolve(stops))]
    else:
        command += ["--pace", str(scenario.get("pace_ms", 0))]
    if scenario.get("range_seconds"):
        command += ["--range", str(scenario["range_seconds"][0]), str(scenario["range_seconds"][1])]
    return command


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
    clip = resolve(scenario["clip"])
    if not clip.is_file():
        raise ScenarioError(f"clip not found: {clip}")
    golden = resolve(scenario["golden"])
    if not golden.is_file():
        raise ScenarioError(f"golden not found: {golden}")
    vacuous = expectation_failure(golden.read_text(encoding="utf-8"), golden)
    if vacuous is not None:
        raise ScenarioError(vacuous)
    if scenario["sync"]:
        stops = resolve(scenario["stops"]) if scenario.get("stops") else clip.with_suffix(".stops.json")
        if not stops.is_file():
            raise ScenarioError(f"stops sidecar not found: {stops} (run annotate_stops.py, or set sync=false)")
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
    return failures


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
        golden_suite = load_golden_suite()
    except (ScenarioError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    tag = args.tag or f"{scenario['name']}_{datetime.datetime.now().strftime('%H%M%S')}"
    run_id = uuid.uuid4().hex

    verdict: dict = {"scenario": str(args.scenario.resolve()), "name": scenario["name"], "tag": tag,
                     "run_id": run_id,
                     "clip": str(resolve(scenario["clip"])), "golden": str(resolve(scenario["golden"]))}
    command = harness_command(scenario, tag, run_id)
    verdict["harness_command"] = " ".join(command)
    # The parent opens the harness log itself and runs the child with RUNS as its cwd, so the
    # directory has to exist HERE too. The harness creates it in its own main() (never at import
    # time), which is one process too late: on a clone that has the clips but no analysis directory
    # yet, `log.open("w")` below raised FileNotFoundError and the runner exited 1 -- the code that
    # means "the records did not match the golden", for a run that never started.
    RUNS.mkdir(parents=True, exist_ok=True)
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

    # Isolation and synchronisation, asserted rather than assumed. Both are properties of the RUN,
    # not of the records, so a failure here is exit 2 ("could not be run") and not a verdict.
    invalid = run_validity_failures(scenario, summary)
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
    (RUNS / f"scenario_result_{tag}.json").write_text(
        json.dumps(verdict, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(verdict, indent=2, ensure_ascii=False))

    if verdict["match"]:
        print(f"\nPASS {scenario['name']}: {len(actual)} record(s) match {Path(scenario['golden']).name}")
        return 0
    diff = difflib.unified_diff(golden_text.splitlines(), actual_text.splitlines(),
                                fromfile="golden", tofile="actual", lineterm="")
    print(f"\nFAIL {scenario['name']}: record mismatch "
          f"({len(actual)} record(s) produced, harness status {summary.get('status')!r})")
    print("\n".join(diff))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
