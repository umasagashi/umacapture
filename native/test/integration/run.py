# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Golden integration test for the native recognition pipeline.

Drives the real ``umacapture_cli`` over recorded clips and compares the recognized
``record.json`` set against committed golden files. Each case states its ``mode``: a
``video`` case goes through the ``video`` subcommand (OpenCV decode of a plain clip),
a ``replay`` case is a lossless FFV1 recording driven through ``replay`` (the recorded
frames enter the pipeline directly). This exercises the full ONNX/WinRT/FFmpeg pipeline
end to end, so it depends on local-only assets (the ``testdata/clips/golden`` clips and
the ``sandbox/modules`` ONNX models, neither committed).

EVERY CASE STATES THE CONFIGURATION IT RUNS UNDER. ``frame_resize`` is required on each manifest
entry and is passed to the CLI explicitly, never left to the CLI's default: a golden is a baseline
for a configuration, so which configuration that is belongs in the file a reviewer reads, not in a
default two layers away. All cases currently state ``true`` -- the shipped band -- because a suite
whose baseline is a setting nobody ships verifies a configuration nobody uses.

AND EVERY CASE STATES THE GEOMETRY THAT MUST REACH RECOGNITION. ``frame_resize`` above is an
INTENTION; ``anchor_unit`` is the outcome, and until it existed nothing here could tell the two
apart. The shipped band's ~735 -> 720 step changes no record on any clip this suite holds -- all
18 goldens regenerate byte-identical through it -- so a CLI that never armed the band, or a core
whose band stopped applying, left the whole suite green (measured, both ways). The CLI now reports
what its frames actually reached the scraper at (``forwarded_frames`` / ``anchor_unit_min`` /
``anchor_unit_max`` on the run summary), and each case pins it. The band's BOUNDS still live only
in the C++ constants: the number in the manifest is an observation, never an input -- the CLI is
told a boolean and resolves the band itself -- so moving the shipped band turns every case red and
cannot be made green without re-stating the manifest, per case, where a reviewer sees it.

A case states what it expects in one of two ways, and CMake registers an
``integration_golden`` ctest when it states either:

* ``golden`` -- a committed record baseline the run must reproduce byte for byte.
* ``expect_records`` (with ``expect_errors``) -- the count the run must produce and the
  terminal error tags it must announce, for a clip whose correct outcome is *no records*.
  Such a case carries no golden: a committed ``[]`` would be a baseline that asserts
  nothing (it stays green against a build in which the reset rule does not exist -- measured
  in ``testdata/evidence/android-web-import/cpp/fix1-golden-intent.md`` §4), so the expectation
  is stated as data instead of as a two-byte file.

A case that states neither has nothing for this suite to assert, exists for
``run_dual_decode.py`` only, and is skipped here; CMake registers no ``integration_golden``
ctest for it, so it does not show up as a permanently Skipped line that would be
indistinguishable from a missing clip.

WHAT A CASE'S VERDICT IS MADE OF. The CLI reports the outcome of one run on stderr as a
marker-prefixed JSON line (``native/src/core/cli_run_report.h``) and classifies its exit code:
0 = ran, nothing reported; 1 = did not run; 2 = ran and reported a terminal error. This suite
therefore asserts three *separate* things and never collapses them into one bit: that the run
happened at all, that it produced the expected number of records, and that it announced
exactly the expected terminal errors. Exit 1 fails every case regardless of what the manifest
expects -- accepting it would let a build that cannot start pass a case that expects emptiness.

A case whose input clip -- or the modules dir -- is absent is skipped, not failed,
so a fresh checkout / CI can run this without the data present. If every selected case
is skipped the process exits 77 (ctest ``SKIP_RETURN_CODE``) so the ctest is reported
Skipped rather than Passed-with-nothing.

Three modes, and how each is meant to be reached:

* ``--only NAME`` runs exactly one case. This is how CMake registers the suite -- one
  ctest per case (``integration_golden.<name>``) -- so that a skipped case shows up as
  its own ``***Skipped`` line in a plain ``ctest`` run. ctest hides the stdout of a test
  that passes or skips, so per-case coverage has to be carried by test *identity and
  status*, not by anything this script prints.
* ``--coverage`` runs no pipeline at all. It reports how many cases are runnable here
  and compares that set against the local baseline (``coverage_baseline.json``, gitignored),
  failing when coverage *shrinks* -- a case that used to run and no longer can. This is
  the "fewer cases ran than last time" alarm; a partial set is still allowed, it just has
  to be acknowledged once with ``--accept-coverage``. It is a high-water mark, NOT a floor:
  "3 of 18 runnable" is green when 3 is all this machine ever reached. What it does promise
  is that the mark cannot drop silently, which is why a baseline that exists but cannot be
  read is a failure rather than a fresh start (see read_baseline). Its decision table is
  pinned by ``test_run_coverage.py`` / the ``integration_coverage_selftest`` ctest.
* No selector: every case in the manifest, as before (this is the ``--update-golden`` path).

Run it via ``uv run`` (see native/test/README.md); it uses only the standard
library. Regenerate goldens after an intended model/pipeline change with
``--update-golden`` and review the diff before committing.
"""

from __future__ import annotations

import argparse
import difflib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
# This script's path as the docs and the CLI hints spell it (repo-root relative, forward slashes).
SELF_REL = Path(__file__).resolve().relative_to(HERE.parents[2]).as_posix()

# Metadata fields stripped before comparison. THREE OF THEM ARE NON-DETERMINISTIC -- a fresh UUID per
# record, a per-run random trainer id, and the wall-clock capture time -- and the fourth is not:
# `recognizer_version` mirrors the local `sandbox/modules/version_info.json`, which every model refresh
# moves. It is stripped because the model VERSION STRING is deliberately not part of the regression
# contract: the goldens pin what the models recognised, not which build of them a machine happens to
# hold, so a vendor refresh that changes no prediction must not move 12 golden files.
# What remains after the strip -- every recognised leaf -- is the contract, and it is a deterministic
# function of the input clip and of the models actually in `sandbox/modules`. So a model change that
# DOES move a prediction still turns these cases red; only the version label is exempt.
VOLATILE_METADATA_KEYS = ("record_id", "trainer_id", "captured_date", "recognizer_version")

# Exit code ctest maps to "Skipped" (see SKIP_RETURN_CODE in CMakeLists.txt). Used when no case
# could run because its local-only inputs were absent.
SKIP_EXIT_CODE = 77

# The CLI's classified exit codes and its summary line, mirrored from native/src/core/cli_run_report.h.
# Nothing links a Python harness to a C++ header, so the mirror can go stale; the `schema` check in
# read_summary is what turns that into a loud failure instead of a field read at the wrong meaning.
CLI_EXIT_OK = 0
CLI_EXIT_DID_NOT_RUN = 1
CLI_EXIT_REPORTED_ERROR = 2
RUN_SUMMARY_MARKER = "UMACAPTURE_RUN_SUMMARY"
RUN_SUMMARY_SCHEMA = 1

# The config key whose name this suite guards. Every appearance of it in the CLI's output is the core warning
# that it could not use the `frame_resize` block as written -- see check_run step (5) for why the numbers
# being pinned in C++ leaves the key NAMES unguarded, and native/src/core/pipeline_config.h for the warnings.
FRAME_RESIZE_KEY = "frame_resize"

# How much of each stream a failing case shows. The verdict is on stderr (the summary line, and main's
# own fatal message); spdlog logs to stdout, so a failure whose cause is in the log needs both -- showing
# stderr alone once left "the harness reports a failure with no diagnosis" as a real outcome.
DIAGNOSTIC_TAIL_LINES = 15

# Generous per-clip ceiling: a multi-record clip runs the whole scrape/stitch/recognize pipeline
# before the CLI's drain barrier lets it self-terminate. The CLI has its own, shorter watchdog on that
# barrier and exits non-zero when it trips, so a wedged stage is reported as a failed case rather than
# as this timeout.
CLI_TIMEOUT_SECONDS = 900

# Local, per-checkout record of which cases were runnable the last time --coverage saw a
# non-empty set. Gitignored (see .gitignore next to this file): which clips a machine holds is a
# property of that machine, not of the repository, so it cannot be committed. What IS committed is
# cases.json -- the full expected set -- and `ctest -N` lists one test per entry, so the manifest
# states the ceiling and this file states what this machine reached.
DEFAULT_BASELINE = HERE / "coverage_baseline.json"


def normalize(record: dict) -> dict:
    """Return a copy of a record with the volatile metadata fields removed."""
    result = json.loads(json.dumps(record))  # deep copy without mutating the input
    metadata = result.get("metadata")
    if isinstance(metadata, dict):
        for key in VOLATILE_METADATA_KEYS:
            metadata.pop(key, None)
    return result


def _sort_key(record: dict) -> str:
    return json.dumps(record, sort_keys=True, ensure_ascii=False)


def collect_records(output_dir: Path) -> list[dict]:
    """Collect and normalize every record.json a `video` run wrote, in a stable order.

    The per-record output dirs are UUID-named, so a batch clip's records arrive in a
    nondeterministic filesystem order; sort by canonical content to make the set comparable.
    """
    active = output_dir / "storage" / "chara_detail" / "active"
    records = [normalize(json.loads(path.read_text(encoding="utf-8"))) for path in active.glob("*/record.json")]
    return sorted(records, key=_sort_key)


def _dumps(records: list[dict]) -> str:
    return json.dumps(records, indent=2, ensure_ascii=False, sort_keys=True) + "\n"


def case_mode(case: dict) -> str:
    """Return the case's pipeline mode, rejecting a manifest entry that does not state one.

    Stated per case instead of derived from the file extension: `.mkv` describes a container, not a
    pipeline entry point, and the suites branch on more than the subcommand -- run_dual_decode.py asks
    whether a case has a YUV -> RGB conversion to vary, which is a property of the mode, not of the name.
    """
    mode = case.get("mode")
    if mode not in ("video", "replay"):
        raise ValueError(f"case {case.get('name')!r} has mode {mode!r}; expected 'video' or 'replay'")
    return mode


def case_frame_resize(case: dict) -> bool:
    """Return whether this case runs through the shipped frame-resize band, refusing a case that is silent.

    Required, and deliberately not defaulted: what a golden is a baseline FOR is part of the baseline. A
    default here -- in either direction -- would put the answer in this file rather than in the manifest, so
    a reader would have to open a runner to learn what a case was recognised under, and a change to the CLI's
    own default would move every golden's meaning without touching anything a reviewer reads.
    """
    value = case.get("frame_resize")
    if not isinstance(value, bool):
        raise ValueError(
            f"case {case.get('name')!r} has frame_resize {value!r}; every case must state true or false. "
            "true = the shipped band (native/src/core/pipeline_config.h), false = no resize."
        )
    return value


def frame_resize_args(case: dict) -> list[str]:
    """The CLI flag for this case's configuration -- always passed, never left to the CLI's default."""
    return ["--frame-resize"] if case_frame_resize(case) else ["--no-frame-resize"]


def case_anchor_unit(case: dict) -> int:
    """The anchor unit every frame of this case must reach recognition at, refusing a case that is silent.

    Required and never defaulted, exactly like case_frame_resize: what a case is a baseline for includes the
    geometry it was recognised at, and a default would put that answer in this file instead of in the manifest.
    Refusing is also what stops the check from being skipped by omission -- a case added without the key fails
    loudly rather than quietly asserting nothing about the band.
    """
    value = case.get("anchor_unit")
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(
            f"case {case.get('name')!r} has anchor_unit {value!r}; every case must state a positive integer. "
            "It is the intersection width every forwarded frame must reach the scraper at -- an OBSERVATION "
            "the run reports, not a value passed to the cli (the band's bounds stay in "
            "native/src/core/pipeline_config.h)."
        )
    return value


def anchor_unit_failure(case: dict, summary: dict) -> str | None:
    """Judge the geometry a run actually recognised at against the case. Returns a detail, or None.

    Three separate things go wrong differently and are reported differently:

    * the cli reports no geometry at all -- an older binary that predates these keys, which must read as
      "rebuild", not as a geometry regression;
    * the run forwarded no frame, so there is no geometry to compare and the case's claim is unsupported;
    * the frames reached recognition at a unit the case does not state -- the band unarmed, not applied, or
      moved.
    """
    wanted = case_anchor_unit(case)
    frames = summary.get("forwarded_frames")
    low = summary.get("anchor_unit_min")
    high = summary.get("anchor_unit_max")
    if frames is None or low is None or high is None:
        return (
            "this cli reports no forwarded-frame geometry (forwarded_frames / anchor_unit_min / "
            "anchor_unit_max absent from the run summary); it predates the keys this suite asserts -- rebuild "
            "it from this tree rather than reading the absence as a result"
        )
    if not isinstance(frames, int) or frames <= 0:
        return (
            "cli reports {!r} frame(s) reaching recognition, so it measured no geometry at all; a case that "
            "states anchor_unit {} requires at least one frame to have been scraped".format(frames, wanted)
        )
    if low != wanted or high != wanted:
        return (
            "frames reached recognition at anchor unit {}..{} over {} frame(s), expected exactly {}. The "
            "frame_resize band this case states was not applied as configured -- see "
            "native/src/core/pipeline_config.h for the bounds and cases.json for what this key means.".format(
                low, high, frames, wanted
            )
        )
    return None


def check_anchor_unit(case: dict, completed: subprocess.CompletedProcess) -> str | None:
    """anchor_unit_failure against a finished process, for a caller that has not parsed the summary itself."""
    kind, payload = read_summary(completed.stderr)
    if kind == "fail":
        return str(payload)
    return anchor_unit_failure(case, payload)  # type: ignore[arg-type]


def frame_resize_complaint(completed: subprocess.CompletedProcess) -> str | None:
    """Did the core complain about the frame_resize block this run's CLI wrote? Returns a detail, or None.

    Shared by both runners, and shared rather than duplicated for the reason the guard exists at all: the
    band's NUMBERS are pinned in C++ and its KEY NAMES are not, so a CLI that regressed to the pre-band
    `unit` key configures a numerically identical band, produces identical records, and is observable ONLY
    through the core's warning. A runner without this scan is blind to that regression -- which is exactly
    what `landscape_2pane_ps5` was, being the one case that takes part in run_dual_decode.py alone.

    Any log line naming the config key is such a complaint: every use of the token in the core is a
    log_warning about a `frame_resize` block it could not use as written (legacy key, malformed bound,
    inverted band, wrong type). The healthy run logs "frame resize: enabled" -- with a space, from the CLI
    itself -- and no underscored token at all.

    spdlog writes to stdout and the summary line to stderr; both are scanned so a future move of the log
    stream cannot quietly disarm this. The C++ side names run.py at the warning site so the two stay linked.
    """
    complaints = [
        line for line in (completed.stdout + "\n" + completed.stderr).splitlines() if FRAME_RESIZE_KEY in line
    ]
    if not complaints:
        return None
    return (
        "the core complained about the frame_resize config this cli wrote, so the run did NOT use the "
        "configuration this case states:\n" + "\n".join(complaints[:DIAGNOSTIC_TAIL_LINES])
    )


def golden_path(case: dict) -> Path | None:
    """Return the case's committed record baseline, or None for a case that deliberately has none."""
    golden = case.get("golden")
    return (HERE / golden).resolve() if golden is not None else None


def has_expectation(case: dict) -> bool:
    """Whether this suite has anything to assert about the case.

    Kept as one predicate because CMake mirrors it to decide whether to register an
    integration_golden ctest (native/CMakeLists.txt); a case this returns False for would
    otherwise be a permanently Skipped line indistinguishable from a missing clip.
    """
    return case.get("golden") is not None or "expect_records" in case


def expected_errors(case: dict) -> list[str]:
    """The terminal error tags the run must announce -- empty for every healthy case.

    Empty is a real expectation, not the absence of one: a case that states nothing here requires
    the run to report NO terminal error, which is what keeps a new end-of-input report from quietly
    starting to fire on the healthy clips.
    """
    return sorted(str(tag) for tag in case.get("expect_errors", []))


def expected_discarded_incomplete(case: dict) -> int:
    """How many sessions this run must report as LOST -- discarded before they had produced their record.

    ZERO IS THE DEFAULT AND IT IS A REAL EXPECTATION, exactly like expect_errors' empty list: a case that
    states nothing here requires the run to have lost nothing. That is what makes the key worth having.
    `discarded` counts every mid-run reset, including the ordinary character switch that happens AFTER a
    record was produced and loses nothing; `discarded_incomplete` is the one that answers "did this run lose
    anything?", and it is the number the app's partial-import card is built from (`videoImportIsPartial`).
    Nothing pinned it at clip level before, so a build that stopped setting the `completed` bit on a discard
    would reclassify every healthy character switch as a lost session -- records unchanged, `discarded`
    unchanged, every golden green -- and tell the user a clean import lost characters.

    The three zero-record cases state it explicitly and non-trivially: they complete no session at all, so
    for them every discard IS a loss and the number equals `expect_discarded`. The two must-fire cases that
    DO produce a record state 1, because the record is the second character's and the first character's
    session was thrown away before it completed. The remaining cases leave it at the default 0.
    """
    value = case.get("expect_discarded_incomplete", 0)
    if not isinstance(value, bool) and isinstance(value, int) and value >= 0:
        return value
    raise ValueError(
        f"case {case.get('name')!r} has expect_discarded_incomplete {value!r}; state a non-negative integer "
        "or omit the key (omitted means 0 -- this run lost nothing)."
    )


def _tail(label: str, text: str) -> str:
    lines = text.strip().splitlines()[-DIAGNOSTIC_TAIL_LINES:]
    return f"--- {label} (last {len(lines)}) ---\n" + "\n".join(lines)


def diagnostics(completed: subprocess.CompletedProcess) -> str:
    return _tail("stderr", completed.stderr) + "\n" + _tail("stdout", completed.stdout)


def read_summary(stderr: str) -> tuple[str, object]:
    """Parse the CLI's one machine-readable line. Returns ``("summary", dict)`` or ``("fail", detail)``.

    Refuses to read a line whose ``schema`` it does not know, rather than picking out the keys it
    recognizes: a harness that guesses at an unfamiliar report is how a moved field turns into a
    silently weaker assertion.
    """
    lines = [line for line in stderr.splitlines() if line.startswith(RUN_SUMMARY_MARKER)]
    if not lines:
        return "fail", f"no {RUN_SUMMARY_MARKER} line on stderr; this cli reports no run summary"
    if len(lines) > 1:
        return "fail", f"{len(lines)} {RUN_SUMMARY_MARKER} lines on stderr; expected exactly one per run"
    try:
        summary = json.loads(lines[0][len(RUN_SUMMARY_MARKER):])
    except json.JSONDecodeError as error:
        return "fail", f"{RUN_SUMMARY_MARKER} line is not valid JSON: {error}"
    if not isinstance(summary, dict):
        return "fail", f"{RUN_SUMMARY_MARKER} payload is {type(summary).__name__}, expected an object"
    schema = summary.get("schema")
    if schema != RUN_SUMMARY_SCHEMA:
        return "fail", (
            f"{RUN_SUMMARY_MARKER} schema is {schema!r}, this harness reads {RUN_SUMMARY_SCHEMA}. "
            "Refusing to interpret it: update run.py together with core/cli_run_report.h."
        )
    return "summary", summary


def check_run(case: dict, completed: subprocess.CompletedProcess) -> str | None:
    """Judge the *run* against the case definition. Returns a failure detail, or None when it holds.

    Separate claims, asserted one at a time and never folded into one bit -- which is the whole point of the
    CLI classifying its exit code instead of returning a single non-zero:

    1. the run happened (it neither failed to start nor threw), so an expectation of emptiness cannot
       be satisfied by a build that cannot run at all;
    2. the process and its own summary line agree about how the run ended;
    3. it announced exactly the terminal errors the manifest names -- no more, and no fewer;
    4. it discarded the number of sessions the manifest states, when it states one, and it LOST the number
       the manifest states -- which every case states, since omitting the key claims zero;
    5. the core understood the frame_resize block the cli wrote (the config was ACCEPTED);
    6. the frames reached recognition at the geometry the manifest states (the config had EFFECT).

    5 and 6 are two halves of one question and neither substitutes for the other: a config the core
    cannot use is silent in the records, and a config it uses perfectly to do nothing is silent too.

    The record count is deliberately NOT here: it is checked against the files on disk by the caller,
    and cross-checked against the core's own count, so the two measurements stay independent.
    """
    # (1) Exit 1 -- and any code outside the classified scale, e.g. CLI11's parse failures or a crash --
    # means nothing can be concluded about the run. It fails every case, whatever the case expects.
    if completed.returncode not in (CLI_EXIT_OK, CLI_EXIT_REPORTED_ERROR):
        return "cli exited {} (the run did not happen; nothing about it can be asserted):\n{}".format(
            completed.returncode, diagnostics(completed)
        )

    kind, payload = read_summary(completed.stderr)
    if kind == "fail":
        return f"{payload}\n{diagnostics(completed)}"
    summary: dict = payload  # type: ignore[assignment]

    # (2) The line and the process must tell the same story; a disagreement means one of them is stale.
    if summary.get("exit") != completed.returncode:
        return "cli exited {} but its summary line says exit={!r}".format(completed.returncode, summary.get("exit"))
    # A notification the report could not read is the same silence this whole change removes, one layer in.
    if summary.get("unparsed"):
        return "cli reported {} unparsed notification(s); the run's account of itself is incomplete".format(
            summary.get("unparsed")
        )

    # (3) The announcement. Exact set, not "contains": an unexpected extra tag is a run announcing
    # something the manifest never claimed, which is a finding, not noise.
    wanted = expected_errors(case)
    actual = sorted(str(tag) for tag in summary.get("errors", []))
    if actual != wanted:
        return "cli announced {} terminal error tag(s) {}, expected {}".format(len(actual), actual, wanted)
    expected_code = CLI_EXIT_REPORTED_ERROR if wanted else CLI_EXIT_OK
    if completed.returncode != expected_code:
        return "cli exited {}, expected {} for a case that expects {} terminal error(s)".format(
            completed.returncode, expected_code, len(wanted)
        )

    # (4) How many sessions the run threw away, when the case states it. This is the mid-run reset count --
    # the signal fix1-golden-intent.md §4 measured as the ONLY thing the three zero-record must-fire clips
    # carry, and which a record-set golden structurally cannot see (they produce zero records with the reset
    # rule ripped out as well as with it in place). The summary line can see it, so a case that would
    # otherwise assert nothing about the gate asserts it here.
    expected_discarded = case.get("expect_discarded")
    if expected_discarded is not None and summary.get("discarded") != expected_discarded:
        return "cli discarded {!r} session(s), expected {!r}".format(summary.get("discarded"), expected_discarded)

    # (4b) How many of those discards LOST something -- the count the core reports separately and the only one
    # that answers "did this run lose anything?". Asserted on EVERY case, defaulting to zero, because the
    # regression it catches shows up on the healthy clips rather than on the must-fire ones: see
    # expected_discarded_incomplete. An absent key means a CLI that predates the counter, which must read as
    # "rebuild" and not as a result -- the same distinction anchor_unit_failure draws.
    incomplete = summary.get("discarded_incomplete")
    if incomplete is None:
        return (
            "this cli reports no discarded_incomplete count on its run summary; it predates the key this "
            "suite asserts -- rebuild it from this tree rather than reading the absence as a result"
        )
    wanted_incomplete = expected_discarded_incomplete(case)
    if incomplete != wanted_incomplete:
        return (
            "cli reports {!r} session(s) discarded before completing, expected {!r}. This is the number the "
            "run's own account of itself calls a LOSS (and the app's partial-import card is built from), so a "
            "disagreement is either a reset rule that moved or a `completed` bit that stopped being set."
        ).format(incomplete, wanted_incomplete)

    # (5) The core UNDERSTOOD the frame_resize block the CLI wrote. This is the only place in either suite
    # where what a writer emits is read back, and it exists because the constants are pinned and the KEY NAMES
    # are not: `readFrameResizeBand` (native/src/core/pipeline_config.h) falls back to the shipped default
    # bounds for an absent `min_unit`/`max_unit`, and the CLI writes exactly those bounds -- so a CLI that
    # regressed to the pre-band `unit` key would configure a band numerically IDENTICAL to the one it meant to
    # ask for, produce identical records, and leave every golden green while the config it emitted was one no
    # other writer's value could survive. What that regression does change is that the core COMPLAINS, and the
    # complaint is the only observable. See frame_resize_complaint, which run_dual_decode.py calls too.
    config_failure = frame_resize_complaint(completed)
    if config_failure is not None:
        return config_failure

    # (6) THE GEOMETRY THE RUN ACTUALLY RECOGNIZED AT. Step (5) above proves the core UNDERSTOOD the config;
    # this proves the config had the effect the case claims. They are different failures and neither implies
    # the other: `"enabled": false` is a perfectly well-formed block the core reads without a word of
    # complaint, and a `Frame::resizedIntoBand` that forwards every frame untouched is not a config fault at
    # all. Both leave every golden byte-identical (the band's ~735 -> 720 step moves no record on this
    # material), so before this step the whole suite was blind to a regression that costs the shipping path a
    # factor of two in decode-and-recognize work. Read off the core's own measurement of the frames the
    # scraper dequeued, never inferred from an artefact's pixel width -- that width is a property of the
    # scraper config and of which intermediates a discarded session leaves behind, not of the pipeline.
    return anchor_unit_failure(case, summary)


def skip_reason(case: dict, data_dir: Path, modules_dir: Path) -> str | None:
    """Return why this case cannot run here, or None when its local-only inputs are present.

    Single source of truth for "runnable", shared by the per-case runner and the --coverage
    report so the two can never disagree about what a machine can exercise.
    """
    video = (data_dir / case["video"]).resolve()
    if not video.exists():
        return f"input clip not found: {video}"
    if not modules_dir.exists():
        return f"modules dir not found: {modules_dir}"
    return None


def run_case(case: dict, cli: Path, data_dir: Path, assets_dir: Path, modules_dir: Path) -> tuple[str, object]:
    """Run one case's pipeline.

    Returns ``(kind, payload)``: ``("skip", reason)`` when a local-only input is absent,
    ``("fail", detail)`` on any error, or ``("records", [record, ...])`` on success.
    """
    reason = skip_reason(case, data_dir, modules_dir)
    if reason is not None:
        return "skip", reason

    # A manifest guard, checked before the pipeline costs minutes. A case that expects no records and names
    # no error tag would assert "the run produced nothing AND said nothing" -- which is the defect this whole
    # change removes, re-created inside the test that is supposed to police it. Refuse the case instead.
    if case.get("expect_records") == 0 and not expected_errors(case):
        return "fail", (
            "manifest: expect_records is 0 but no expect_errors is stated. A run that ends empty must "
            "announce why, so a zero-record case has to name the tag(s) it expects."
        )

    # Manifest guards for the keys the verdict is built from, resolved BEFORE the pipeline costs minutes, so a
    # case that cannot be judged says so immediately instead of after a full decode. Both raise on a case that
    # omits or misstates the key -- refusing is what keeps the checks from being disabled by omission.
    case_frame_resize(case)
    case_anchor_unit(case)
    expected_discarded_incomplete(case)

    video = (data_dir / case["video"]).resolve()

    with tempfile.TemporaryDirectory(prefix=f"uma_it_{case['name']}_") as tmp:
        output_dir = Path(tmp)
        # A `replay` case is a lossless FFV1 recording (from `capture --record`): the `replay`
        # subcommand reads the recorded frames straight into the pipeline. A `video` case is a plain
        # clip decoded by OpenCV. Both write the same storage/chara_detail/active/*/record.json set,
        # so collection and comparison are identical.
        if case_mode(case) == "replay":
            input_args = ["replay", "--record", str(video)]
        else:
            input_args = ["video", "--video_path_list", str(video)]
        command = [
            str(cli),
            *input_args,
            *frame_resize_args(case),
            "--output_dir",
            str(output_dir),
            "--assets_dir",
            str(assets_dir.resolve()),
            "--modules_dir",
            str(modules_dir.resolve()),
        ]
        try:
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=CLI_TIMEOUT_SECONDS,
                cwd=output_dir,
            )
        except subprocess.TimeoutExpired:
            return "fail", f"cli timed out after {CLI_TIMEOUT_SECONDS}s"

        # The run itself, judged against what this case says it expects (see check_run). A non-zero exit
        # is no longer read as "harness failure" on its own: exit 2 is the CLI reporting that it announced
        # a terminal error, which for a zero-record case is the expectation rather than the defect.
        failure = check_run(case, completed)
        if failure is not None:
            return "fail", failure

        actual = collect_records(output_dir)

    # The record count, measured on disk and cross-checked against the count the core states in its summary
    # line. Two independent measurements on purpose: a core that stopped counting and a pipeline that stopped
    # writing are different defects, and one number could not tell them apart.
    expected_records = case.get("expect_records")
    if expected_records is None:
        if not actual:
            return "fail", "cli produced no record.json (recognition failed or clip yielded nothing)"
    else:
        if len(actual) != expected_records:
            return "fail", f"cli produced {len(actual)} record.json, expected {expected_records}"
        _, summary = read_summary(completed.stderr)  # already validated by check_run
        if summary["records"] != expected_records:  # type: ignore[index]
            return "fail", "cli wrote {} record.json but reports records={!r}".format(
                len(actual), summary["records"]  # type: ignore[index]
            )

    return "records", actual


class BaselineUnreadable(Exception):
    """The baseline file exists but cannot be read as a record of what this machine could exercise."""


def read_baseline(path: Path) -> list[str] | None:
    """Return the previously recorded runnable case names, or None when this machine has no record yet.

    ABSENT AND UNREADABLE ARE DIFFERENT ANSWERS, and collapsing them is what disarmed this test.
    Absent means the first run on this machine: the file is gitignored, so every clone and every
    fresh build tree legitimately starts there, and recording the current set costs nothing because
    there is no earlier set to lower. Unreadable means a record that DID exist and whose contents
    are now unknown -- and the previous behaviour, "treat it as no record and let this run rewrite
    it", turned the exact loss this test exists to catch into a green run: with the baseline
    truncated mid-write, the same missing clip printed "coverage baseline recorded" and exited 0
    where an intact baseline printed "coverage shrank" and exited 1, silently lowering the
    high-water mark (measured, 3 -> 2). A damaged record cannot be repaired from the present, so the
    only reading that does not lose information is to refuse, and let the operator either restore it
    or lower it on purpose with --accept-coverage.

    Shape is validated rather than coerced. ``[str(name) for name in recorded]`` accepted anything
    iterable, so a ``"runnable": "abc"`` written by a broken hand-edit read as the three case names
    a, b and c -- a baseline that can never intersect the real set, i.e. a permanently green test.
    """
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:  # noqa: BLE001 -- any failure to read is the same verdict: unusable record
        raise BaselineUnreadable(f"{path}: not readable as JSON ({error})") from error
    if not isinstance(payload, dict) or "runnable" not in payload:
        raise BaselineUnreadable(f"{path}: no 'runnable' key")
    recorded = payload["runnable"]
    if not isinstance(recorded, list) or not all(isinstance(name, str) for name in recorded):
        raise BaselineUnreadable(f"{path}: 'runnable' is not a list of case names")
    return list(recorded)


def write_baseline(path: Path, runnable: list[str]) -> None:
    payload = {
        "comment": [
            "Local record of which integration_golden cases were runnable on this machine.",
            "Written by run.py --coverage; gitignored (holding clips is a property of the machine).",
            "A later run that can exercise FEWER of these fails, so a silently shrinking golden set",
            "is caught instead of merely being visible. Acknowledge an intended shrink with",
            "run.py --coverage --accept-coverage.",
        ],
        "runnable": sorted(runnable),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def report_coverage(
    cases: list[dict], cli: Path, data_dir: Path, modules_dir: Path, baseline: Path, accept: bool
) -> int:
    """Report and police how much of the golden manifest this machine can actually exercise.

    Runs no pipeline -- it only resolves inputs -- so it is cheap enough to register as its own
    ctest. Returns 77 (ctest Skipped) when nothing is runnable, 1 when coverage shrank against the
    local baseline, 0 otherwise.
    """
    if not cli.exists():
        print(f"SKIP: cli not built: {cli}")
        return SKIP_EXIT_CODE

    runnable: list[str] = []
    blocked: list[tuple[str, str]] = []
    for case in cases:
        reason = skip_reason(case, data_dir, modules_dir)
        if reason is None:
            runnable.append(case["name"])
        else:
            blocked.append((case["name"], reason))

    for name, reason in blocked:
        print(f"NOT RUNNABLE {name}: {reason}")
    print(f"integration coverage: {len(runnable)} of {len(cases)} case(s) runnable")

    if not runnable:
        # No assets at all (CI, fresh clone). Honest total skip; deliberately does not touch the
        # baseline, so an asset-less run can never erase a real machine's record.
        return SKIP_EXIT_CODE

    try:
        recorded = read_baseline(baseline)
    except BaselineUnreadable as error:
        if not accept:
            print(f"FAIL coverage baseline unreadable: {error}")
            print(
                "This machine HAS a record of what it could exercise and it can no longer be read, so a\n"
                "shrink cannot be detected. Restore the file from wherever it was damaged, or -- if the\n"
                "set runnable right now is what this machine should be held to from here on -- lower the\n"
                "mark deliberately:\n"
                f"  uv run {SELF_REL} --coverage --accept-coverage --cli <path-to-umacapture_cli>"
            )
            return 1
        write_baseline(baseline, runnable)
        print(f"coverage baseline was unreadable ({error}); rewritten by request ({len(runnable)} case(s))")
        return 0

    if recorded is None:
        write_baseline(baseline, runnable)
        print(f"coverage baseline recorded ({len(runnable)} case(s)) at {baseline}")
        return 0

    lost = sorted(set(recorded) - set(runnable))
    if lost and not accept:
        print(f"FAIL coverage shrank: {len(lost)} case(s) ran on this machine before and cannot run now:")
        for name in lost:
            print(f"  - {name}")
        print(
            "Restore the missing inputs, or -- if the smaller set is intended -- acknowledge it explicitly:\n"
            f"  uv run {SELF_REL} --coverage --accept-coverage --cli <path-to-umacapture_cli>"
        )
        return 1

    gained = sorted(set(runnable) - set(recorded))
    if gained or lost:
        write_baseline(baseline, runnable)
        if lost:
            print(f"coverage baseline lowered by request: dropped {', '.join(lost)}")
        if gained:
            print(f"coverage baseline raised: added {', '.join(gained)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="path to umacapture_cli(.exe)")
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=HERE.parents[2] / "testdata" / "clips" / "golden",
        help="dir holding the input clips",
    )
    parser.add_argument(
        "--assets-dir", type=Path, default=HERE.parents[2] / "assets" / "config", help="config assets dir"
    )
    parser.add_argument(
        "--modules-dir", type=Path, default=HERE.parents[2] / "sandbox" / "modules", help="ONNX modules dir"
    )
    parser.add_argument("--update-golden", action="store_true", help="overwrite goldens with the current output")
    parser.add_argument("--cases", type=Path, default=HERE / "cases.json", help="cases manifest")
    parser.add_argument("--only", metavar="NAME", help="run just this case (one ctest per case registers this)")
    parser.add_argument(
        "--coverage", action="store_true", help="report runnable cases and police the local coverage baseline"
    )
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE, help="coverage baseline file")
    parser.add_argument(
        "--accept-coverage", action="store_true", help="record a smaller runnable set as the new baseline"
    )
    args = parser.parse_args()

    manifest = json.loads(args.cases.read_text(encoding="utf-8"))
    cases = manifest["cases"]

    if args.coverage:
        return report_coverage(
            cases, args.cli, args.data_dir, args.modules_dir, args.baseline, args.accept_coverage
        )

    if args.only is not None:
        cases = [case for case in cases if case["name"] == args.only]
        if not cases:
            # A stale build tree registering a case the manifest no longer names is a real defect,
            # not something to skip past.
            print(f"ERROR: no case named {args.only!r} in {args.cases}", file=sys.stderr)
            return 2

    if not args.cli.exists():
        # The cli is a local-only build artifact: CI (and any checkout that builds only
        # umacapture_tests) deliberately doesn't build it, since it links onnxruntime and
        # needs the uncommitted models/clips to run. Treat its absence like any other absent
        # input -- skip (exit 77) so ctest reports Skipped rather than Failed.
        print(f"SKIP: cli not built: {args.cli}", file=sys.stderr)
        return SKIP_EXIT_CODE

    passed = skipped = failed = updated = 0
    for case in cases:
        name = case["name"]
        if not has_expectation(case):
            # Not a defect and not an absent input: the manifest states neither a record baseline nor an
            # expectation for this case (see cases.json). Skipped before the pipeline runs, because running
            # it would cost minutes to produce something nothing here compares.
            skipped += 1
            print(f"SKIP {name}: nothing expected in the manifest; this case belongs to run_dual_decode.py only")
            continue
        kind, payload = run_case(case, args.cli, args.data_dir, args.assets_dir, args.modules_dir)
        if kind == "skip":
            skipped += 1
            print(f"SKIP {name}: {payload}")
            continue
        if kind == "fail":
            failed += 1
            print(f"FAIL {name}: {payload}")
            continue

        actual = payload  # list[dict]
        golden_file = golden_path(case)
        actual_text = _dumps(actual)

        if golden_file is None:
            # An expectation-only case: run_case already asserted the record count, the announced error
            # tags and the discarded-session count against the manifest, and there is no baseline to
            # compare. Nothing to update either, so this comes before --update-golden.
            passed += 1
            print(f"PASS {name}: {len(actual)} record(s), announced as the manifest states")
            continue

        if args.update_golden:
            golden_file.parent.mkdir(parents=True, exist_ok=True)
            golden_file.write_text(actual_text, encoding="utf-8")
            updated += 1
            print(f"UPDATED {name}: wrote {len(actual)} record(s) -> {golden_file.name}")
            continue

        if not golden_file.exists():
            failed += 1
            print(f"FAIL {name}: no golden at {golden_file} (run with --update-golden to create it)")
            continue

        golden_text = golden_file.read_text(encoding="utf-8")
        if actual_text == golden_text:
            passed += 1
            print(f"PASS {name}: {len(actual)} record(s) match")
        else:
            failed += 1
            diff = difflib.unified_diff(
                golden_text.splitlines(), actual_text.splitlines(), fromfile="golden", tofile="actual", lineterm=""
            )
            print(f"FAIL {name}: record mismatch")
            print("\n".join(diff))

    print(f"\nintegration: {passed} passed, {failed} failed, {skipped} skipped, {updated} updated")

    if failed:
        return 1
    if passed == 0 and updated == 0:
        # Nothing actually ran (all inputs absent). Signal ctest to mark this Skipped.
        return SKIP_EXIT_CODE
    return 0


if __name__ == "__main__":
    sys.exit(main())
