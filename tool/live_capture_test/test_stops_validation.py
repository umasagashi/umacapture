# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets"]
# ///
"""Unit tests for the harness's refusals: the stops sidecar, and the verdict's own preconditions.

    uv run tool/live_capture_test/test_stops_validation.py

Nothing here launches the app, the mimic player or a capture. `validate_stops` is a pure function
over an already-parsed sidecar, and `scenario_run`'s `attribution_failure` /
`run_validity_failures` are pure functions over an already-parsed harness summary -- so the whole
class of "artefacts that are well formed while not being this run's" is testable without a clip.
Every case names, in its docstring, the wrong implementation it would catch -- a test that also
passes against the bug it is meant to hold is not a check.
"""

from __future__ import annotations

import json
import sys
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import app_drive_run  # noqa: E402
import scenario_run  # noqa: E402
from app_drive_run import frame_index_fault, validate_stops  # noqa: E402
from stops_schema import parse_frame_indices  # noqa: E402

SIDECAR = Path("/tmp/does_not_need_to_exist.stops.json")


def sidecar(*stops: dict, frame_count: int = 200, tabs: int | None = None) -> dict:
    """A parsed sidecar. `tabs` defaults to the number of stops, i.e. a COMPLETE annotation."""
    declared = len(stops) if tabs is None else tabs
    return {"clip": "clip.mkv", "frame_count": frame_count, "stops": list(stops),
            "definition": {"tabs": declared}}


def stop(tab: int = 0, **fields) -> dict:
    entry = {"tab": tab, "label": f"tab{tab}", "stop_frame": 62, "scroll_end_frame": 127}
    entry.update(fields)
    return entry


class ValidStopsAreAccepted(unittest.TestCase):
    """The control. Red if the checks reject anything they are handed, i.e. if the refusal were
    implemented as an unconditional failure or the bounds were off by one."""

    def test_a_well_formed_sidecar_passes(self):
        validate_stops(sidecar(stop(0), stop(1, stop_frame=161, scroll_end_frame=180)), SIDECAR,
                       require_scroll_end=True)

    def test_the_clip_boundary_frames_are_usable(self):
        validate_stops(sidecar(stop(0, stop_frame=0, scroll_end_frame=199), frame_count=200),
                       SIDECAR, require_scroll_end=True)

    def test_a_null_scroll_end_frame_passes_when_the_run_does_not_arm_one(self):
        """Red if the scroll_end_frame check were made unconditional: without --scroll-rate the
        field is never armed, and refusing it there would reject sidecars that work today."""
        validate_stops(sidecar(stop(0, scroll_end_frame=None)), SIDECAR, require_scroll_end=False)


class MeaninglessFrameNumbersAreRefused(unittest.TestCase):
    """Each case is red if the value it names were passed through to `pause-at` / `rate-at`, where
    the player's `resolveSpec` clamps it into range and the run silently uses a different frame."""

    def refusal(self, doc: dict, *, require_scroll_end: bool = True) -> str:
        with self.assertRaises(SystemExit) as caught:
            validate_stops(doc, SIDECAR, require_scroll_end=require_scroll_end)
        return str(caught.exception)

    def test_negative_stop_frame_is_refused(self):
        """The reported defect: `stable_stop` returns -1 when it found no stable run, and -1 clamps
        to frame 0. Red if a negative index were accepted."""
        message = self.refusal(sidecar(stop(0, stop_frame=-1)))
        self.assertIn("stop_frame", message)
        self.assertIn("-1", message)

    def test_stop_frame_past_the_end_of_the_clip_is_refused(self):
        """Red if only the lower bound were checked: the player clamps to frameCount-1, so an index
        past the end parks on the last frame instead of failing."""
        self.assertIn("outside the clip's frame indices 0..199",
                      self.refusal(sidecar(stop(0, stop_frame=200, scroll_end_frame=201))))

    def test_a_non_integral_stop_frame_is_refused(self):
        """Red if the check were `value < 0` alone: 62.5 passes that and is not a frame index."""
        self.assertIn("62.5", self.refusal(sidecar(stop(0, stop_frame=62.5))))

    def test_a_string_stop_frame_is_refused(self):
        """Red if the check assumed the JSON was already typed; `"62"` would be sent verbatim and
        parsed by the player, so the sidecar's type error would never surface here."""
        self.assertIn("'62'", self.refusal(sidecar(stop(0, stop_frame="62"))))

    def test_a_boolean_stop_frame_is_refused(self):
        """bool is a subclass of int in Python, so `isinstance(True, int)` is True. Red if the type
        check were a bare isinstance without excluding bool."""
        self.assertIn("True", self.refusal(sidecar(stop(0, stop_frame=True))))

    def test_a_missing_stop_frame_is_refused(self):
        """Red if the field were read with a default rather than required."""
        entry = stop(0)
        del entry["stop_frame"]
        self.assertIn("stop_frame", self.refusal(sidecar(entry)))

    def test_a_null_scroll_end_frame_is_refused_when_one_will_be_armed(self):
        """The pre-existing check, preserved. Red if replacing it lost the case it covered."""
        self.assertIn("scroll_end_frame", self.refusal(sidecar(stop(0, scroll_end_frame=None))))

    def test_a_scroll_end_before_the_stop_is_refused(self):
        """Both values are individually usable frame indices, so only an ordering check catches
        this. Red if the fields were checked independently and never against each other."""
        self.assertIn("not before", self.refusal(sidecar(stop(0, stop_frame=127,
                                                             scroll_end_frame=62))))

    def test_a_scroll_end_equal_to_the_stop_is_refused(self):
        """Red if the ordering check were `>` rather than `>=`: an empty scrolling phase is not a
        scrolling phase."""
        self.assertIn("not before", self.refusal(sidecar(stop(0, stop_frame=62,
                                                             scroll_end_frame=62))))

    def test_a_sidecar_without_a_frame_count_is_refused(self):
        """Red if a missing frame_count silently disabled the upper bound instead of failing."""
        doc = sidecar(stop(0))
        del doc["frame_count"]
        self.assertIn("frame_count", self.refusal(doc))

    def test_the_refusal_names_the_file_the_tab_and_the_field(self):
        """The defect class is "silently reads it as a different value"; a refusal that does not say
        which file and which field is a different way of telling the operator nothing. Red if the
        message were a bare 'invalid sidecar'."""
        message = self.refusal(sidecar(stop(0), stop(2, stop_frame=-1)))
        self.assertIn(str(SIDECAR), message)
        self.assertIn("tab 2", message)
        self.assertIn("stop_frame", message)


class TheFaultPredicateIsAClassNotAList(unittest.TestCase):
    """`frame_index_fault` is the single predicate every field is checked through. Red if the
    refusal were a hand-written enumeration of known-bad values: a value nobody listed -- here
    `None`, a complex number, a list -- would come back clean."""

    def test_only_ints_within_the_clip_are_clean(self):
        for value in (0, 5, 199):
            self.assertIsNone(frame_index_fault(value, 200), value)
        for value in (-1, -1.0, 200, 1000, None, True, False, "5", 5.0, [5], {"frame": 5}):
            self.assertIsNotNone(frame_index_fault(value, 200), value)


class ASidecarMustCoverEveryTabItWasAnnotatedFor(unittest.TestCase):
    """The gap a per-ENTRY validator cannot see. When detection finds fewer scroll groups than
    `--tabs`, `annotate_stops.py` writes a short or empty `stops` list, so there is no entry left to
    fault; the run then arms nothing, plays fully unsynchronised and still reports `timeouts: 0`,
    which is the number the verdict reads. Every case here is red if the refusal were written as a
    loop over the entries alone."""

    def refusal(self, doc: dict) -> str:
        with self.assertRaises(SystemExit) as caught:
            validate_stops(doc, SIDECAR, require_scroll_end=False)
        return str(caught.exception)

    def test_a_sidecar_with_no_stops_at_all_is_refused(self):
        """The extreme case: zero entries, zero faults, `play_synchronised([])` returns
        `{"armed": [], "held": [], "timeouts": 0}` and every downstream check is satisfied."""
        message = self.refusal(sidecar(tabs=3))
        self.assertIn("3 tab(s)", message)
        self.assertIn("0 stop(s)", message)

    def test_a_sidecar_covering_fewer_tabs_than_it_declares_is_refused(self):
        """The insidious case: two tabs held, one free-running, `timeouts` still 0. Red if only
        emptiness were refused rather than the count being compared."""
        message = self.refusal(sidecar(stop(0), stop(1, stop_frame=161), tabs=3))
        self.assertIn("2 stop(s)", message)

    def test_a_sidecar_that_does_not_say_how_many_tabs_it_covers_is_refused(self):
        """Red if a missing declaration silently disabled the coverage check: a sidecar that cannot
        state what a complete annotation of it looks like cannot be told from an incomplete one."""
        doc = sidecar(stop(0))
        del doc["definition"]
        self.assertIn("definition.tabs", self.refusal(doc))

    def test_a_complete_annotation_is_accepted(self):
        """The control. Red if the count comparison were off by one, or if it demanded a fixed
        three tabs rather than what the sidecar itself declares."""
        validate_stops(sidecar(stop(0), stop(1, stop_frame=161), stop(2, stop_frame=180), tabs=3),
                       SIDECAR, require_scroll_end=False)
        validate_stops(sidecar(stop(0), tabs=1), SIDECAR, require_scroll_end=False)


class AVerdictNeedsTheRunToHaveExercisedItsTimingModel(unittest.TestCase):
    """`scenario_run.run_validity_failures` on the harness's summary. `timeouts` counts waits that
    were LOST, so it reads 0 both for a run that held every stop and for one that held none."""

    SCENARIO = {"sync": True}

    def summary(self, armed: list[int], held: list[int], timeouts: int = 0) -> dict:
        return {"run_id": "r", "stop_frames": armed, "record_dirs": [],
                "data_isolation": {"roots": [], "before": {}, "after": {}, "leaked_record_dirs": []},
                "synchronised": {"armed": [], "timeouts": timeouts,
                                 "held": [{"tab": tab, "timed_out": False} for tab in held]}}

    def test_a_sync_run_that_armed_nothing_is_not_a_verdict(self):
        """Red if the check were `timeouts` alone: 0 of 0 waits lost satisfies it exactly."""
        failures = scenario_run.run_validity_failures(self.SCENARIO, self.summary([], []))
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("armed no stop frames", failures[0])

    def test_a_sync_run_that_held_fewer_stops_than_it_armed_is_not_a_verdict(self):
        """Red if only emptiness were checked: a harness that loses a hold mid-run reports the
        remaining tabs as clean, and no wait it never took can time out."""
        failures = scenario_run.run_validity_failures(self.SCENARIO, self.summary([62, 161, 273], [0, 1]))
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("held 2", failures[0])

    def test_a_run_that_held_every_armed_stop_passes(self):
        """The control. Red if the comparison rejected a complete run -- e.g. if `held` were
        compared against a hardcoded three tabs instead of against what was armed."""
        self.assertEqual(scenario_run.run_validity_failures(
            self.SCENARIO, self.summary([62, 161, 273], [0, 1, 2])), [])

    def test_an_unsynchronised_scenario_is_not_asked_for_holds(self):
        """The other control: `sync: false` scenarios (the truncated-input falsification is one)
        arm no stops on purpose and must still reach a record verdict."""
        self.assertEqual(scenario_run.run_validity_failures({"sync": False}, self.summary([], [])), [])


class AGoldenMustStateAnExpectationARunCanFailToMeet(unittest.TestCase):
    """`scenario_run.expectation_failure`. The verdict is `actual_text == golden_text`, and equality
    is symmetric about emptiness: a golden holding no records is met by a run that recognised
    NOTHING, which the runner then prints as `PASS: 0 record(s) match` and exits 0. Every case here
    is red if the runner only compared the two texts, which is what it did."""

    GOLDEN = Path("/tmp/does_not_need_to_exist.json")

    def test_a_golden_stating_no_records_is_refused(self):
        """The reported defect. `[]` is exactly what a run that produced nothing serialises to (see
        the control below), so the comparison cannot tell the two claims apart. Red if emptiness
        were left to the diff."""
        message = scenario_run.expectation_failure("[]\n", self.GOLDEN)
        self.assertIsNotNone(message)
        self.assertIn("no records", message)
        self.assertIn(str(self.GOLDEN), message)

    def test_the_old_form_accepts_the_very_same_golden(self):
        """The control that makes the case above a DEFECT rather than a preference: the golden
        suite's own serialiser turns a zero-record run into the same bytes an empty golden holds, so
        `actual_text == golden_text` -- the whole of the old verdict -- is True for a run in which
        the app recognised nothing. Red if `_dumps([])` ever stopped being what an empty golden
        looks like, in which case this guard would need re-deriving rather than trusting."""
        self.assertEqual(scenario_run.load_golden_suite()._dumps([]), "[]\n")

    def test_emptiness_is_recognised_whatever_the_whitespace(self):
        """Red if the check were a byte comparison against `"[]\\n"`: the same vacuous expectation
        written by a different formatter would walk straight through it."""
        for text in ("[]", "[]\n", "[ ]\n", "[\n\n]\n", "  []  "):
            self.assertIsNotNone(scenario_run.expectation_failure(text, self.GOLDEN), text)

    def test_a_golden_that_is_not_json_is_refused(self):
        """`collect_records` can only ever produce a list, so unparseable text is not an expectation
        the app could meet either. Red if the parse failure were swallowed and the run allowed to
        report the scenario's own broken input as a recognition mismatch."""
        self.assertIsNotNone(scenario_run.expectation_failure("not json at all", self.GOLDEN))

    def test_a_golden_that_is_not_a_list_of_records_is_refused(self):
        """Red if only the empty LIST were refused: `{}` and `null` are just as unmeetable, and
        `null` in particular is what a truncated write can leave."""
        for text in ("{}", "null", '{"records": []}', "0"):
            self.assertIsNotNone(scenario_run.expectation_failure(text, self.GOLDEN), text)

    def test_a_golden_holding_a_record_is_accepted(self):
        """The control. Red if the refusal were unconditional -- every committed golden holds one or
        two records, and refusing them would take the whole harness out of service."""
        self.assertIsNone(scenario_run.expectation_failure('[{"record_id": "x"}]\n', self.GOLDEN))

    def test_every_golden_a_committed_scenario_names_is_accepted(self):
        """The end of the control: run the guard over the real files, so a golden that is
        regenerated into a shape this refuses fails HERE instead of on the machine that next spends
        ten minutes driving the app."""
        scenarios = sorted((Path(__file__).resolve().parent / "scenarios").glob("*.json"))
        self.assertTrue(scenarios, "no scenarios found; this control would be vacuous")
        for path in scenarios:
            golden = scenario_run.resolve(json.loads(path.read_text(encoding="utf-8"))["golden"])
            self.assertIsNone(
                scenario_run.expectation_failure(golden.read_text(encoding="utf-8"), golden),
                f"{path.name} -> {golden}")


class ASummaryMustBelongToTheRunBeingJudged(unittest.TestCase):
    """`scenario_run.attribution_failure`. `app_result_<tag>.json` is written once at the end of a
    run and never removed, and tags are reused on purpose, so a run that dies early leaves the
    PREVIOUS run's summary in place -- with its isolation scan, its `timeouts: 0` and its records."""

    THIS = "0123456789abcdef"

    def outcome(self, returncode: int = 0, timed_out: bool = False) -> dict:
        return {"returncode": returncode, "timed_out": timed_out}

    def test_an_earlier_runs_summary_under_the_same_tag_is_refused(self):
        """The reported defect. Red if the runner gated on the summary FILE existing, which is what
        it did: the sidecar refusals raise before anything is launched, so the harness exits in
        under a second having written nothing, and the previous summary decides this verdict."""
        message = scenario_run.attribution_failure(
            self.outcome(returncode=1), {"run_id": "an-earlier-run"}, self.THIS, SIDECAR)
        self.assertIsNotNone(message)
        self.assertIn("an-earlier-run", message)
        self.assertIn(self.THIS, message)

    def test_a_summary_with_no_run_id_is_refused(self):
        """Fail-closed against a harness that does not know the flag. Red if the identity were
        compared with `summary.get("run_id", run_id)` or only when present -- absence would then
        read as agreement, which is the same false green in a new place."""
        self.assertIsNotNone(scenario_run.attribution_failure(
            self.outcome(), {"status": "ok"}, self.THIS, SIDECAR))

    def test_a_killed_run_is_refused_even_if_a_summary_matches(self):
        """`timed_out` was recorded and never read. Red if the identity check alone were relied on:
        the kill can land after the summary is written, and a tree killed by `taskkill /F /T` did
        not finish the run whatever it left behind."""
        self.assertIsNotNone(scenario_run.attribution_failure(
            self.outcome(returncode=1, timed_out=True), {"run_id": self.THIS}, self.THIS, SIDECAR))

    def test_a_missing_summary_is_refused(self):
        """The pre-existing check, preserved. Red if moving the gate lost the case it covered."""
        self.assertIsNotNone(scenario_run.attribution_failure(
            self.outcome(returncode=2), None, self.THIS, SIDECAR))

    def test_this_runs_own_summary_is_accepted(self):
        """The control. Red if the comparison could never succeed."""
        self.assertIsNone(scenario_run.attribution_failure(
            self.outcome(), {"run_id": self.THIS}, self.THIS, SIDECAR))


class HandWrittenStopFramesGoThroughTheReadersPredicate(unittest.TestCase):
    """`--stop-frames` is the documented manual fallback, and what it writes is what the harness
    arms. Red if the writer parsed the spec with a bare `int()` and checked only the entry count:
    an out-of-range value then reached `stamps[stop]` as an unnamed IndexError, and a negative one
    was written into the sidecar to be caught (or clamped) much later."""

    def test_a_non_numeric_token_survives_parsing_so_it_can_be_named(self):
        self.assertEqual(parse_frame_indices("62, 161,x"), [62, 161, "x"])
        self.assertIsNotNone(frame_index_fault("x", 375))

    def test_the_values_the_reader_refuses_are_the_ones_the_writer_refuses(self):
        """The predicate is shared, not restated, so the two cannot drift apart."""
        for token, usable in (("0", True), ("374", True), ("375", False), ("-1", False),
                              ("62.5", False), ("", False)):
            value = parse_frame_indices(token)[0]
            self.assertEqual(frame_index_fault(value, 375) is None, usable, token)


class TheScrollReadyMarkersSurviveAnEditToTheAppsSources(unittest.TestCase):
    """The markers are matched against the app's stdout, whose spdlog pattern ends in
    `[%!:%#] %v` = `[function:line] message`. A marker that carried the line number stopped
    matching the moment an unrelated edit added a line above it, and the harness then reported that
    the app never became scroll-ready -- an app-side diagnosis for a fixture-side breakage."""

    def log_line(self, function: str, line: int, message: str = "record_id=… true") -> str:
        return f"D 12:00:00.000000 [1234] [{function}:{line}] {message}\n"

    def test_the_factor_marker_matches_the_same_call_at_any_line(self):
        """Red if the marker embedded a line number: only one of these two would match."""
        marker = app_drive_run.SCROLL_READY_MARKERS[1]
        for line in (733, 1, 9999):
            self.assertIn(marker, self.log_line("CharaDetailRecognizer::probe", line))

    def test_no_marker_embeds_a_line_number(self):
        """Stated over the whole table rather than the one tab that had the problem, so a marker
        added for a fourth tab cannot reintroduce it. Red if any marker ends in digits."""
        for tab, marker in app_drive_run.SCROLL_READY_MARKERS.items():
            self.assertFalse(marker.rstrip().split(":")[-1].isdigit(), f"tab {tab}: {marker}")

    def test_the_factor_marker_does_not_match_another_function(self):
        """The other direction: shortening the marker must not make it match neighbouring calls.
        Red if it had been cut back to a bare `CharaDetailRecognizer::`."""
        self.assertNotIn(app_drive_run.SCROLL_READY_MARKERS[1],
                         self.log_line("CharaDetailRecognizer::recognize", 770))


class TheScratchModulesTrackTheRealOnes(unittest.TestCase):
    """`modules_signature` is what tells a run whether the models under its scratch root are still
    the models on disk. Copying them `if not modules.exists()` froze the first run's copy, so a
    replaced model was never picked up and the records were diffed against a golden made with a
    different one."""

    def tree(self, files: dict[str, bytes]) -> Path:
        import tempfile
        root = Path(tempfile.mkdtemp())
        self.addCleanup(__import__("shutil").rmtree, root, True)
        for name, payload in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        return root

    def test_the_same_contents_signature_the_same(self):
        """The control: an identical copy must not provoke a re-copy on every run. Red if the
        signature included the mtime, which a copy does not reproduce."""
        import os
        first = self.tree({"a/model.onnx": b"weights", "index.json": b"{}"})
        second = self.tree({"a/model.onnx": b"weights", "index.json": b"{}"})
        os.utime(second / "a/model.onnx", (0, 0))
        self.assertEqual(app_drive_run.modules_signature(first),
                         app_drive_run.modules_signature(second))

    def test_a_replaced_model_of_the_same_size_changes_the_signature(self):
        """Red if the signature were the file list, or the list plus sizes: a retrained model of
        the same length would read as the same models."""
        self.assertNotEqual(app_drive_run.modules_signature(self.tree({"a/model.onnx": b"weights"})),
                            app_drive_run.modules_signature(self.tree({"a/model.onnx": b"WEIGHTS"})))

    def test_an_added_or_removed_file_changes_the_signature(self):
        self.assertNotEqual(app_drive_run.modules_signature(self.tree({"a.onnx": b"x"})),
                            app_drive_run.modules_signature(self.tree({"a.onnx": b"x", "b.onnx": b"y"})))


SCENARIOS = Path(__file__).resolve().parent / "scenarios"


def write_scenario(test: unittest.TestCase, doc: dict) -> Path:
    import tempfile
    handle = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    json.dump(doc, handle)
    handle.close()
    test.addCleanup(Path(handle.name).unlink)
    return Path(handle.name)


BASE = {"version": 1, "name": "t", "golden": "g.json", "config": "debug", "settings": "fresh", "sync": False}


class TheSingleClipFormIsAOneElementClipsList(unittest.TestCase):
    """`load_scenario` normalises `clip` into `clips`. Red if the committed scenarios changed meaning:
    the plan the harness is launched with is compared with the plan the harness builds from the
    command line the unnormalised file used to produce (`APlanMeansWhatTheOldCommandLineMeant`), so a
    dropped `stops` or `range_seconds` shows up here, not on a ten-minute run."""

    def expected_command(self, raw: dict) -> list[str]:
        command = ["uv", "run", str(scenario_run.HARNESS), "--tag", "T", "--run-id", "R",
                   "--clip", str(scenario_run.resolve(raw["clip"])), "--config", raw["config"],
                   "--settings", raw["settings"], "--record-wait", str(raw.get("record_wait_seconds", 120))]
        if raw["sync"]:
            command += ["--sync", "--sync-timeout", str(raw.get("sync_timeout_seconds", 30)),
                        "--scroll-rate", str(raw.get("scroll_rate", 1.0))]
            if raw.get("stops"):
                command += ["--stops", str(scenario_run.resolve(raw["stops"]))]
        else:
            command += ["--pace", str(raw.get("pace_ms", 0))]
        if raw.get("range_seconds"):
            command += ["--range", str(raw["range_seconds"][0]), str(raw["range_seconds"][1])]
        return command

    def test_every_committed_scenario_keeps_its_meaning(self):
        paths = sorted(SCENARIOS.glob("*.json"))
        self.assertTrue(paths, "no scenarios found; this control would be vacuous")
        for path in paths:
            scenario = scenario_run.load_scenario(path)
            self.assertEqual(len(scenario["clips"]), 1, path.name)
            self.assertNotIn("clip", scenario, path.name)
            self.assertEqual(scenario["expect_links"], [], path.name)
            self.assertTrue(set(scenario["clips"][0]) <= set(scenario_run.PER_CLIP_FIELDS), path.name)

    def test_clip_and_clips_are_exclusive(self):
        """Red if either form were allowed to shadow the other."""
        for doc in ({**BASE, "clip": "a.mkv", "clips": [{"clip": "a.mkv"}]}, dict(BASE)):
            with self.assertRaises(scenario_run.ScenarioError) as caught:
                scenario_run.load_scenario(write_scenario(self, doc))
            self.assertIn("exactly one of 'clip' and 'clips'", str(caught.exception))

    def test_per_clip_fields_are_refused_at_the_top_level_of_a_clips_scenario(self):
        """Red if a top-level `stops` were silently ignored next to `clips`."""
        with self.assertRaises(scenario_run.ScenarioError):
            scenario_run.load_scenario(write_scenario(self, {**BASE, "stops": None, "clips": [{"clip": "a"}]}))

    def test_an_expectation_must_name_a_clip_the_scenario_plays(self):
        """Red if an index were read with a default or never bounds-checked: the judgement would
        then compare against a clip that does not exist."""
        bad = [
            [{"clip": "a", "expect": {"candidate": {"with": 5, "enhanced": None}}}, {"clip": "b"}],
            [{"clip": "a", "expect": {"candidate": {"with": 0, "enhanced": None}}}],
            [{"clip": "a", "expect": {"status": "ok"}}],
            [{"clip": "a"}, {"clip": "b", "merge": {"survivor": 1, "retired": 1}}],
            [{"clip": "a", "merge": {"survivor": 0, "retired": 1}}, {"clip": "b"}],
        ]
        for clips in bad:
            with self.assertRaises(scenario_run.ScenarioError, msg=clips):
                scenario_run.load_scenario(write_scenario(self, {**BASE, "clips": clips}))
        with self.assertRaises(scenario_run.ScenarioError):
            scenario_run.load_scenario(write_scenario(self, {**BASE, "clips": [{"clip": "a"}, {"clip": "b"}],
                                                             "expect_links": [{"child": 0, "slot": "p", "parent": 1}]}))

    def test_a_well_formed_multi_clip_scenario_loads(self):
        """The control. Red if the checks refused the shape the design writes."""
        scenario = scenario_run.load_scenario(write_scenario(self, {**BASE, "clips": [
            {"clip": "a", "expect": {"status": "succeeded", "candidate": None}},
            {"clip": "b", "expect": {"status": "succeeded", "candidate": {"with": 0, "enhanced": 1}},
             "merge": {"survivor": 0, "retired": 1}}],
            "expect_links": [{"child": 1, "slot": "parent1", "parent": 0}]}))
        self.assertEqual([sorted(entry) for entry in scenario["clips"]], [["clip", "expect"], ["clip", "expect", "merge"]])
        self.assertEqual(len(scenario["expect_links"]), 1)



class AnErrorSummaryIsNeverAVerdict(unittest.TestCase):
    """R1. `app_drive_run` writes `status: "error"` from its exception path with whatever it had
    observed; a summary like that once sat beside `match: true`. Red if the runner read the
    records' content and never the status."""

    def test_an_error_status_is_refused_even_with_every_observation_present(self):
        message = scenario_run.harness_status_failure(
            {"status": "error", "error": "TimeoutException: x", "record_dirs": ["r"], "clips": [{}]})
        self.assertIsNotNone(message)
        self.assertIn("'error'", message)
        self.assertIn("TimeoutException", message)

    def test_a_missing_or_unknown_status_is_refused(self):
        """Red if absence read as completion (`summary.get('status', 'ok')`)."""
        for summary in ({}, {"status": None}, {"status": "data-leak"}):
            self.assertIsNotNone(scenario_run.harness_status_failure(summary), summary)

    def test_a_completed_run_is_accepted_even_with_no_record(self):
        """The control: a completed run whose app wrote nothing is judged -- by its clips' outcomes
        and the record verdict -- not refused. Red if every non-"ok" status were refused."""
        self.assertIsNone(scenario_run.harness_status_failure({"status": "ok"}))
        self.assertIsNone(scenario_run.harness_status_failure({"status": "no-record"}))


def clips_scenario(*clips: dict, links: list | None = None, sync: bool = False) -> dict:
    return {"sync": sync, "clips": list(clips), "expect_links": links or []}


def seen(record_id: str, status: str = "succeeded", **fields) -> dict:
    """A complete, settled observation of one clip whose capture ended in `status`."""
    obs = {"container_seen": True, "record_id": record_id,
           "capture": {"attempt_id": f"a-{record_id}", "status": status, "record_id": record_id},
           "settled": True, "unsettled": [], "factor_info_loaded": True,
           "event": {"status": "succeeded", "record_id": record_id},
           "candidates": [], "tile": "absent", "probe_duplicates": [False]}
    obs.update(fields)
    return obs


PAIR = {"older": "X", "newer": "Y", "enhanced": "Y"}
TWO = clips_scenario({"clip": "x", "expect": {"candidate": None}},
                     {"clip": "y", "expect": {"candidate": {"with": 0, "enhanced": 1}}})


class TheClipJudgementClassifiesRatherThanDefaults(unittest.TestCase):
    """`scenario_run.judge_clips`. R2/R3: an observation that is missing, ill-typed or marked as a
    driver error is inconclusive (exit 2) -- never false, never "no candidate", never "not
    completed". Each case asserts the reason CODE, so a case that goes red for another reason is
    not mistaken for the one it names."""

    def judge(self, scenario, clips, disk=None):
        return scenario_run.judge_clips(scenario, clips, disk or {})

    def test_the_passing_pair_passes(self):
        """The control. Red if any check refused a complete, agreeing observation."""
        j = self.judge(TWO, [seen("X"), seen("Y", candidates=[PAIR], tile="present")])
        self.assertEqual((j.exit_code, j.codes()), (0, []))

    def test_each_missing_required_key_is_inconclusive(self):
        """R3. Red if any of these keys were read with `.get(key, <falsy default>)`: the candidate
        check would then see no pairs and report 'no candidate' for a run that never looked."""
        for key in ("container_seen", "capture", "settled", "factor_info_loaded", "candidates", "tile",
                    "event", "record_id"):
            obs = seen("X")
            del obs[key]
            j = self.judge(clips_scenario({"clip": "x", "expect": {"candidate": None}}), [obs])
            self.assertEqual(j.exit_code, 2, key)
            self.assertTrue(set(j.codes()) & {scenario_run.OBSERVATION_MISSING, scenario_run.EVENT_NOT_THIS_RECORD},
                            (key, j.codes()))

    def test_a_factor_table_that_was_not_loaded_is_inconclusive(self):
        """R3 (未読込). Without the table only exact duplicates are found, so 'no candidate' says
        nothing. Red if factor_info_loaded were not consulted."""
        j = self.judge(clips_scenario({"clip": "x", "expect": {"candidate": None}}),
                       [seen("X", factor_info_loaded=False)])
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.FACTOR_INFO_NOT_LOADED]))

    def test_an_event_that_is_not_this_records_success_is_inconclusive(self):
        """R3 (イベント不一致). The tile only draws on this record's success; otherwise its absence
        proves nothing. Red if the event premise were dropped from the 'no candidate' judgement."""
        for event in ({"status": "alreadyCaptured", "record_id": "X"}, {"status": "succeeded", "record_id": "W"}, None):
            j = self.judge(clips_scenario({"clip": "x", "expect": {"candidate": None}}), [seen("X", event=event)])
            self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.EVENT_NOT_THIS_RECORD]), event)

    def test_settling_without_evidence_is_inconclusive_but_a_named_failure_is_a_mismatch(self):
        """R3. Red if a missing settle were read as settled, or if every unsettled run were exit 2
        (the store/disk disagreement is a product defect and must stay exit 1)."""
        scenario = clips_scenario({"clip": "x", "expect": {"candidate": None}})
        j = self.judge(scenario, [seen("X", settled=False, unsettled=[])])
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.OBSERVATION_MISSING]))
        j = self.judge(scenario, [seen("X", settled=False, unsettled=["disk_matches_store"])])
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.UNSETTLED]))

    def test_a_driver_error_is_inconclusive_not_false(self):
        """R2. A waitFor that timed out is not an observation of the tile. Red if the harness's
        {"error": ...} were compared as a tile state (it is neither present nor absent) and turned
        into tile_disagrees."""
        j = self.judge(TWO, [seen("X"), seen("Y", candidates=[PAIR], tile={"error": "TimeoutException"})])
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.DRIVER_FAILED]))
        j = self.judge(TWO, [seen("X", state_error="request_data failed"), seen("Y", candidates=[PAIR], tile="present")])
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.DRIVER_FAILED]))

    def test_a_failed_merge_dialog_wait_is_inconclusive_not_incomplete(self):
        """R2. Red if a driver failure during the merge became `completed: false`."""
        scenario = clips_scenario({"clip": "x"}, {"clip": "y", "merge": {"survivor": 0, "retired": 1}})
        j = self.judge(scenario, [seen("X"), seen("Y", merge={"error": "waitFor enhancement_merge_apply timed out"})])
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.DRIVER_FAILED]))

    def test_a_short_clip_list_is_inconclusive(self):
        """Red if the per-clip loop zipped the lists and judged only the clips that were reached."""
        j = self.judge(TWO, [seen("X")])
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.CLIP_COUNT]))
        self.assertEqual(self.judge(TWO, None).codes(), [scenario_run.OBSERVATION_MISSING])

    def test_an_inconclusive_clip_outranks_a_mismatch(self):
        """A falsification passes on a VALID run with the targeted reason, so a run carrying any
        inconclusive finding is exit 2 whatever else it found. Red if exit were `1 if mismatches`."""
        j = self.judge(TWO, [seen("X", candidates=[PAIR]), seen("Y", candidates=[PAIR], tile={"error": "t"})])
        self.assertEqual(j.exit_code, 2)
        self.assertIn(scenario_run.CANDIDATE_UNEXPECTED, j.codes())

    def test_an_outcome_nobody_observed_is_inconclusive_not_a_mismatch(self):
        """(ii) `capture: null` is a wait that ran out, not an attempt that produced nothing: the harness
        reads the outcome from a record the app keeps past the detail screen's close, so a null says only
        that none was seen. Red if it were the product mismatch (exit 1)."""
        j = self.judge(clips_scenario({"clip": "x", "expect": {"status": "succeeded"}}), [seen("X", capture=None)])
        self.assertEqual(j.exit_code, 2, j.codes())
        self.assertEqual(j.codes(), [scenario_run.OUTCOME_UNOBSERVED])

    def test_a_clip_without_expectations_still_needs_its_outcome_observed(self):
        """(iii) A single-clip scenario states no per-clip expectation. Red if such a clip were skipped:
        its run would then pass on the records alone with no outcome ever seen. The control: the same
        clip with its outcome observed has nothing to report."""
        scenario = clips_scenario({"clip": "x"})
        j = self.judge(scenario, [seen("X", capture=None)])
        self.assertEqual(j.exit_code, 2, j.codes())
        self.assertEqual(j.codes(), [scenario_run.OUTCOME_UNOBSERVED])
        self.assertEqual(self.judge(scenario, [seen("X")]).codes(), [])

    def test_candidate_mismatches_each_carry_their_own_code(self):
        """Red if the candidate check collapsed to a boolean: the reason code says which way it failed."""
        j = self.judge(TWO, [seen("X", candidates=[PAIR]), seen("Y", candidates=[PAIR], tile="present")])
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.CANDIDATE_UNEXPECTED, scenario_run.TILE_DISAGREES]))
        j = self.judge(TWO, [seen("X"), seen("Y")])
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.CANDIDATE_MISMATCH]))
        wrong_side = {**PAIR, "enhanced": "X"}
        j = self.judge(TWO, [seen("X"), seen("Y", candidates=[wrong_side], tile="present")])
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.CANDIDATE_MISMATCH]))
        j = self.judge(TWO, [seen("X"), seen("Y", candidates=[PAIR], tile="absent")])
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.TILE_DISAGREES]))

    def test_an_extra_pair_beside_the_right_one_is_a_mismatch(self):
        """Red if only the presence of the expected pair were checked: a second pair naming the
        same record is a candidate the product should not have offered."""
        extra = {"older": "Z", "newer": "Y", "enhanced": "Y"}
        j = self.judge(TWO, [seen("X"), seen("Y", candidates=[PAIR, extra], tile="present")])
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.CANDIDATE_MISMATCH]))

    def test_links_are_read_from_the_raw_record(self):
        scenario = clips_scenario({"clip": "x"}, {"clip": "y"}, links=[{"child": 1, "slot": "parent1", "parent": 0}])
        clips = [seen("X"), seen("Y")]
        ok = {"Y": {"exists": True, "parents": {"parent1": "X", "parent2": None}}}
        self.assertEqual(self.judge(scenario, clips, ok).exit_code, 0)
        bad = {"Y": {"exists": True, "parents": {"parent1": None, "parent2": "X"}}}
        self.assertEqual(self.judge(scenario, clips, bad).codes(), [scenario_run.LINK_MISMATCH])
        self.assertEqual(self.judge(scenario, clips, {}).codes(), [scenario_run.OBSERVATION_MISSING])


class TheDuplicateRecaptureIsJudgedOnEachSignalSeparately(unittest.TestCase):
    """R4. C5 expects the second capture to end `alreadyCaptured` AND the early probe to say
    duplicate=true. Changing both at once proves neither check exists, so each is changed alone
    and must fail with ITS OWN code."""

    SCENARIO = clips_scenario({"clip": "x", "expect": {"status": "succeeded", "probe_duplicate": False}},
                              {"clip": "x", "expect": {"status": "already_captured", "probe_duplicate": True}})

    def judge(self, second):
        return scenario_run.judge_clips(self.SCENARIO, [seen("X"), second], {})

    def test_the_expected_recapture_passes(self):
        j = self.judge(seen("X2", status="alreadyCaptured", probe_duplicates=[True, True]))
        self.assertEqual((j.exit_code, j.codes()), (0, []))

    def test_only_the_status_differs(self):
        """Red if the status expectation were not checked (the probe alone still says true)."""
        j = self.judge(seen("X2", status="succeeded", probe_duplicates=[True]))
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.STATUS_MISMATCH]))

    def test_only_the_probe_differs(self):
        """Red if the probe expectation were not checked (the status alone still matches)."""
        j = self.judge(seen("X2", status="alreadyCaptured", probe_duplicates=[True, False]))
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.PROBE_MISMATCH]))

    def test_a_probe_that_never_ran_is_its_own_mismatch_and_a_missing_one_is_inconclusive(self):
        j = self.judge(seen("X2", status="alreadyCaptured", probe_duplicates=[]))
        self.assertEqual((j.exit_code, j.codes()), (1, [scenario_run.PROBE_NOT_RUN]))
        obs = seen("X2", status="alreadyCaptured")
        del obs["probe_duplicates"]
        self.assertEqual(self.judge(obs).codes(), [scenario_run.OBSERVATION_MISSING])


class TheMergeIsJudgedOnDiskNotOnTheDialog(unittest.TestCase):
    SCENARIO = clips_scenario({"clip": "x"}, {"clip": "y", "merge": {"survivor": 0, "retired": 1}})
    DONE = {"completed": True, "candidates_after": [], "tile_after": "absent"}
    DISK = {"X": {"exists": True, "merged_ids": ["Y"]}, "Y": {"exists": False}}

    def judge(self, merge, disk):
        return scenario_run.judge_clips(self.SCENARIO, [seen("X"), seen("Y", merge=merge)], disk)

    def test_a_complete_merge_passes(self):
        self.assertEqual(self.judge(self.DONE, self.DISK).codes(), [])

    def test_each_merge_failure_carries_its_own_code(self):
        cases = [
            ({**self.DONE, "completed": False}, self.DISK, scenario_run.MERGE_INCOMPLETE),
            (self.DONE, {**self.DISK, "X": {"exists": False}}, scenario_run.MERGE_SURVIVOR_MISSING),
            (self.DONE, {**self.DISK, "X": {"exists": True, "merged_ids": []}}, scenario_run.MERGE_MARK_MISSING),
            (self.DONE, {**self.DISK, "Y": {"exists": True}}, scenario_run.MERGE_RETIRED_PRESENT),
            ({**self.DONE, "candidates_after": [PAIR]}, self.DISK, scenario_run.MERGE_CANDIDATE_REMAINS),
        ]
        for merge, disk, code in cases:
            j = self.judge(merge, disk)
            self.assertEqual((j.exit_code, j.codes()), (1, [code]), code)

    def test_an_unread_disk_is_inconclusive(self):
        self.assertEqual(self.judge(self.DONE, {}).codes(), [scenario_run.OBSERVATION_MISSING])


class FakeDriver:
    """Stands in for `app_drive_run.Driver`: answers `harness_state` from a script of states and
    `by_key` from a table of (command, key) -> exception or None. Nothing is launched."""

    def __init__(self, states, failing=None):
        self.states = list(states)
        self.failing = failing or {}
        self.calls: list[tuple] = []

    def harness_state(self):
        state = self.states.pop(0) if len(self.states) > 1 else self.states[0]
        if isinstance(state, Exception):
            raise state
        return state

    def by_key(self, name, key, timeout_ms=60000):
        self.calls.append((name, key))
        error = self.failing.get((name, key))
        if error is not None:
            raise error
        return {}

    def hold(self, key, seconds):
        self.calls.append(("hold", key, seconds))
        return {}


class HoldIgnoringDriver(FakeDriver):
    """The apply button stays in the tree after the first [ignored] holds, as it does when a press
    lands while the button is still disabled; after that the hold is accepted, the button goes away
    and the state reads [merged] instead of [before]."""

    def __init__(self, before, merged, ignored):
        super().__init__([before])
        self.merged = merged
        self.ignored = ignored

    def accepted(self):
        return sum(1 for c in self.calls if c[0] == "hold") > self.ignored

    def harness_state(self):
        return self.merged if self.accepted() else super().harness_state()

    def by_key(self, name, key, timeout_ms=60000):
        if (name, key) == ("waitForAbsent", app_drive_run.MERGE_APPLY_KEY):
            self.calls.append((name, key))
            if not self.accepted():
                raise app_drive_run.DriverTimeout("driver waitForAbsent failed: Timeout while executing")
            return {}
        return super().by_key(name, key, timeout_ms)


def app_state(attempt="a1", status="succeeded", link="X", active=("X",), candidates=(), loaded=True,
              event=True) -> dict:
    """A `harness_state` answer. `event` True records the status as the app would on reaching it, False
    records none, and anything else is the event as given."""
    if event is True:
        event = {"status": status, "record_id": link}
    elif event is False:
        event = None
    return {"container": True,
            "capture": {"attempt_id": attempt, "status": status, "link_id": link, "duplicate_record_id": None},
            "event": event,
            "store": {"active_loaded": True, "active_ids": list(active), "archive_ids": []},
            "factor_info_loaded": loaded, "candidates": list(candidates)}


PLAN_CLIP = {"clip": "x.mkv", "stops": None, "range": None, "wait_factor_info": True, "merge": None}


def observe(driver, *, before="a0", disk=("X",), probe=(), falsify=None, record_wait=0.5):
    signals = app_drive_run.ClipSignals()
    for line in probe:
        signals.feed(line)
    return app_drive_run.observe_clip(app_drive_run.StateReader(driver), driver, signals, before, PLAN_CLIP,
                                      record_wait, falsify, disk_ids=lambda: set(disk))


class APlanMeansWhatTheOldCommandLineMeant(unittest.TestCase):
    """U3. `scenario_run` now writes a plan and passes `--plan`. Red if a committed scenario's plan
    differs from the plan the harness builds out of the single-clip flags the runner used to pass --
    a dropped `stops`, `range` or `scroll_rate` would change the run without a word."""

    def legacy_argv(self, raw: dict) -> list[str]:
        return TheSingleClipFormIsAOneElementClipsList.expected_command(None, raw)[3:]

    def test_every_committed_scenario_plans_what_its_command_line_meant(self):
        paths = sorted(SCENARIOS.glob("*.json"))
        self.assertTrue(paths, "no scenarios found; this control would be vacuous")
        for path in paths:
            raw = json.loads(path.read_text(encoding="utf-8"))
            args = app_drive_run.build_parser().parse_args(self.legacy_argv(raw))
            legacy = app_drive_run.load_plan(args)
            planned = scenario_run.build_plan(scenario_run.load_scenario(path))
            self.assertEqual(planned, legacy, path.name)
            self.assertEqual(app_drive_run.validate_plan(json.loads(json.dumps(planned)), path.name), planned)

    def test_the_plan_is_all_the_command_line_carries(self):
        self.assertEqual(scenario_run.harness_command("T", "R", Path("p.json")),
                         ["uv", "run", str(scenario_run.HARNESS), "--tag", "T", "--run-id", "R", "--plan", "p.json"])

    def test_a_multi_clip_scenario_plans_every_clip(self):
        """Red if the plan kept only the first clip, lost a merge, or asked for the factor table
        where no expectation needs it."""
        scenario = scenario_run.load_scenario(write_scenario(self, {**BASE, "clips": [
            {"clip": "a", "expect": {"status": "succeeded"}},
            {"clip": "b", "expect": {"candidate": {"with": 0, "enhanced": 1}}, "merge": {"survivor": 0, "retired": 1}},
            {"clip": "c", "range_seconds": [1, 2]}]}))
        plan = app_drive_run.validate_plan(scenario_run.build_plan(scenario), "t")
        self.assertEqual([Path(c["clip"]).name for c in plan["clips"]], ["a", "b", "c"])
        self.assertEqual([c["wait_factor_info"] for c in plan["clips"]], [False, True, False])
        self.assertEqual([c["merge"] for c in plan["clips"]], [None, {"survivor": 0, "retired": 1}, None])
        self.assertEqual(plan["clips"][2]["range"], [1.0, 2.0])

    def test_a_plan_excludes_the_single_clip_flags(self):
        """Red if `--plan` and `--clip` together silently let one win."""
        args = app_drive_run.build_parser().parse_args(["--tag", "t", "--plan", "p.json", "--clip", "c.mkv"])
        with self.assertRaises(SystemExit):
            app_drive_run.load_plan(args)

    def test_a_malformed_plan_is_refused(self):
        good = scenario_run.build_plan(scenario_run.load_scenario(SCENARIOS / "player_standard_5.json"))
        bad = [{**good, "extra": 1}, {**good, "sync": "yes"}, {**good, "clips": []},
               {**good, "sync": False, "scroll_rate": 0.5},
               {**good, "clips": [{**good["clips"][0], "merge": {"survivor": 0, "retired": 0}}]}]
        for plan in bad:
            with self.assertRaises(SystemExit, msg=plan):
                app_drive_run.validate_plan(plan, "t")


class EachClipIsSynchronisedByItsOwnSignals(unittest.TestCase):
    """U3. A latched scroll-ready Event that outlived its clip releases every hold of the next clip
    at once, with no timeout and every hold counted -- invisible to the sync checks."""

    MARKER = app_drive_run.SCROLL_READY_MARKERS[0]

    def test_arming_a_clip_starts_unset_signals(self):
        """Red if arm_clip reused the previous clip's Events."""
        app = app_drive_run.DriverApp.__new__(app_drive_run.DriverApp)
        app.signals = app_drive_run.ClipSignals()
        app.signals.feed(f"x {self.MARKER}\n")
        app.signals.feed("RecordingThread::run started\n")
        first = app.signals
        second = app.arm_clip()
        self.assertIsNot(first, second)
        self.assertTrue(first.scroll_ready[0].is_set())
        self.assertFalse(second.scroll_ready[0].is_set())
        self.assertFalse(second.recorder_started.is_set())

    def test_a_marker_seen_before_arming_is_not_after_arm(self):
        """Red if marker_after_arm were true for any marker at all."""
        signals = app_drive_run.ClipSignals()
        signals.feed(f"x {self.MARKER}\n")
        self.assertTrue(signals.marker_after_arm(0))
        signals.armed_at += 1000.0  # the same Events, carried into a later clip
        self.assertFalse(signals.marker_after_arm(0))
        self.assertFalse(signals.marker_after_arm(2), "a tab never seen is not after arm")

    def test_arming_moves_the_time_base_even_when_the_events_are_reused(self):
        """F2. arm_clip with its Event re-creation removed: the same set, the previous clip's marker,
        a new armed_at. Red if the time base moved only with a new set -- the stale marker would then
        read as this clip's and the verdict would pass an unsynchronised clip."""
        app = app_drive_run.DriverApp.__new__(app_drive_run.DriverApp)
        with mock.patch.object(app_drive_run.time, "monotonic", side_effect=[1.0, 2.0, 3.0]):
            app.signals = app_drive_run.ClipSignals()
            app.signals.feed(f"x {self.MARKER}\n")
            reused = app.signals
            with mock.patch.object(app_drive_run, "ClipSignals", lambda: reused):
                armed = app.arm_clip()
        self.assertIs(armed, reused)
        self.assertEqual(armed.armed_at, 3.0)
        held = [{"tab": 0, "timed_out": False, "marker_after_arm": armed.marker_after_arm(0)}]
        clip = {"stop_frames": [10], "synchronised": {"timeouts": 0, "held": held}}
        self.assertEqual(held[0]["marker_after_arm"], False)
        j = scenario_run.judge_clips(clips_scenario({"clip": "x", "expect": {"status": "succeeded"}}, sync=True),
                                     [seen("X", **clip)], {})
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.SYNC_INVALID]))

    def test_probe_lines_are_parsed_and_a_line_without_a_value_is_skipped(self):
        """Red if a line lacking `duplicate=` were read as false."""
        signals = app_drive_run.ClipSignals()
        for line in ("Factor probe: 12 factors, below_threshold=false, duplicate=true\n",
                     "Factor probe: truncated\n", "unrelated duplicate=false\n",
                     "Factor probe: 12 factors, below_threshold=true, duplicate=false\n"):
            signals.feed(line)
        self.assertEqual(app_drive_run.probe_duplicates(signals.probe_lines), [True, False])


class ACaptureAttemptEndsOnlyOnItsOwnOutcome(unittest.TestCase):
    """U3, the outcome and settling as pure functions over (harness_state, disk ids)."""

    def test_the_previous_clips_outcome_is_not_this_clips(self):
        """Red if the attempt id were not compared: the second clip would 'finish' before it began."""
        self.assertIsNone(app_drive_run.attempt_outcome(app_state(attempt="a1"), "a1"))
        self.assertIsNone(app_drive_run.attempt_outcome({"container": True, "capture": None, "event": None}, None))
        for status in ("succeeded", "alreadyCaptured", "failed"):
            self.assertEqual(app_drive_run.attempt_outcome(app_state(attempt="a2", status=status), "a1")["status"],
                             status)

    def test_only_a_terminal_event_is_an_outcome(self):
        """Red if any event counted: the early check's `duplicateHint` is recorded as an event, and the
        attempt's outcome replaces it later."""
        for event in (None, {"status": "duplicateHint", "record_id": "D"}, {"status": "videoImport", "record_id": None}):
            state = app_state(attempt="a2", status="capturing", link=None, event=event)
            self.assertIsNone(app_drive_run.attempt_outcome(state, "a1"), event)

    def test_the_outcome_outlives_the_detail_screen(self):
        """(i) The app's state once the detail screen has closed: `onCharaDetailClosed` resets the capture
        state, so its status is back to `waitingForDetail` with no link, and only the attempt id and the
        event still say what happened. Red if the outcome were read from the capture status: the clip
        would wait out `record_wait` and report no outcome for a capture that succeeded."""
        closed = app_state(attempt="a2", status="waitingForDetail", link=None,
                           event={"status": "succeeded", "record_id": "X"})
        self.assertEqual(app_drive_run.attempt_outcome(closed, "a1"),
                         {"attempt_id": "a2", "status": "succeeded", "record_id": "X"})
        refused = app_state(attempt="a2", status="waitingForDetail", link=None,
                            event={"status": "alreadyCaptured", "record_id": "X"})
        self.assertEqual(app_drive_run.attempt_outcome(refused, "a1")["status"], "alreadyCaptured")

    def test_each_unmet_settle_condition_is_named(self):
        capture = app_drive_run.attempt_outcome(app_state(), None)
        self.assertEqual(app_drive_run.settle_failures(app_state(), capture, {"X"}, True), [])
        self.assertEqual(app_drive_run.settle_failures(app_state(active=()), capture, set(), False),
                         ["store_has_record"])
        self.assertEqual(app_drive_run.settle_failures(app_state(), capture, {"X", "D"}, False),
                         ["disk_matches_store"])
        self.assertEqual(app_drive_run.settle_failures(app_state(loaded=False), capture, {"X"}, True),
                         ["factor_info_loaded"])
        self.assertEqual(app_drive_run.settle_failures(app_state(loaded=False), capture, {"X"}, False), [])
        unloaded = {**app_state(), "store": {"active_loaded": False, "active_ids": []}}
        self.assertEqual(app_drive_run.settle_failures(unloaded, capture, set(), False), ["store_loaded"])


class TheHarnessObservationIsWhatTheVerdictReads(unittest.TestCase):
    """The real `observe_clip` / `perform_merge` against a fake driver, judged by the real
    `judge_clips`. Red if the harness wrote a shape the verdict does not read, or collapsed a
    driver failure into an answer (R2)."""

    NONE = clips_scenario({"clip": "x", "expect": {"status": "succeeded", "candidate": None}})

    def test_a_settled_clip_with_no_candidate_passes(self):
        driver = FakeDriver([app_state()])
        obs = observe(driver)
        obs["container_seen"] = True
        j = scenario_run.judge_clips(self.NONE, [obs], {})
        self.assertEqual((j.exit_code, j.codes()), (0, []))
        self.assertEqual(obs["tile"], "absent")
        self.assertIn(("waitForAbsent", app_drive_run.TILE_KEY), driver.calls)

    def test_the_tile_wait_follows_the_data(self):
        """Red if the harness chose the wait from anything but the candidate data."""
        driver = FakeDriver([app_state(candidates=[{"older": "W", "newer": "X", "enhanced": "X"}], active=("W", "X"))])
        obs = observe(driver, disk=("W", "X"))
        self.assertEqual(obs["tile"], "present")
        self.assertEqual(driver.calls[0], ("waitFor", app_drive_run.TILE_KEY))

    def test_a_failed_tile_wait_is_an_error_unless_the_other_state_is_seen(self):
        """R2. Red if a failed wait were written as the opposite state."""
        timeout = RuntimeError("driver waitForAbsent failed: timeout")
        both = FakeDriver([app_state()], {("waitForAbsent", app_drive_run.TILE_KEY): timeout,
                                          ("waitFor", app_drive_run.TILE_KEY): RuntimeError("timeout")})
        obs = observe(both)
        obs["container_seen"] = True
        self.assertIn("error", obs["tile"])
        self.assertEqual(scenario_run.judge_clips(self.NONE, [obs], {}).codes(), [scenario_run.DRIVER_FAILED])
        shown = FakeDriver([app_state()], {("waitForAbsent", app_drive_run.TILE_KEY): timeout})
        obs = observe(shown)
        obs["container_seen"] = True
        self.assertEqual(obs["tile"], "present")
        self.assertEqual(scenario_run.judge_clips(self.NONE, [obs], {}).codes(), [scenario_run.TILE_DISAGREES])

    def test_an_outcome_recorded_before_the_close_is_read_after_it(self):
        """(i) The answers one clip produces: the attempt in progress, then the detail screen closed and
        the capture state reset. Red if observe_clip read the capture status (it is never terminal
        here) or took the record id from the link the reset dropped."""
        in_progress = app_state(attempt="a1", status="capturing", link=None, active=(), event=False)
        closed = app_state(attempt="a1", status="waitingForDetail", link=None,
                           event={"status": "succeeded", "record_id": "X"})
        obs = observe(FakeDriver([in_progress, closed]))
        obs["container_seen"] = True
        self.assertEqual(obs["capture"], {"attempt_id": "a1", "status": "succeeded", "record_id": "X"})
        self.assertEqual(obs["record_id"], "X")
        self.assertEqual(scenario_run.judge_clips(self.NONE, [obs], {}).codes(), [])

    def test_an_outcome_never_seen_is_inconclusive(self):
        """Red if a wait that ran out were reported as the attempt's answer, or lost what was read."""
        obs = observe(FakeDriver([app_state(attempt="a0")]))
        obs["container_seen"] = True
        self.assertIsNone(obs["capture"])
        self.assertEqual(obs["last_capture_state"]["attempt_id"], "a0")
        self.assertEqual(scenario_run.judge_clips(self.NONE, [obs], {}).codes(), [scenario_run.OUTCOME_UNOBSERVED])

    def test_a_store_that_never_settles_is_named(self):
        with mock.patch.object(app_drive_run, "SETTLE_SECONDS", 0.3):
            obs = observe(FakeDriver([app_state()]), disk=("X", "D"))
        obs["container_seen"] = True
        self.assertEqual(obs["unsettled"], ["disk_matches_store"])
        self.assertEqual(scenario_run.judge_clips(self.NONE, [obs], {}).codes(), [scenario_run.UNSETTLED])

    def test_settling_on_an_unloaded_table_or_store_is_inconclusive(self):
        """F1. What observe_clip writes when settling times out on something never loaded:
        `settled: false` with the load named in `unsettled`. Red if that were judged a measured
        disagreement (`unsettled`, exit 1) instead of nothing measured (exit 2)."""
        unloaded_store = {**app_state(), "store": {"active_loaded": False, "active_ids": []}}
        cases = [(app_state(loaded=False), ["factor_info_loaded"], scenario_run.FACTOR_INFO_NOT_LOADED),
                 (unloaded_store, ["store_loaded"], scenario_run.STORE_NOT_LOADED)]
        for state, unmet, code in cases:
            with mock.patch.object(app_drive_run, "SETTLE_SECONDS", 0.3):
                obs = observe(FakeDriver([state]))
            obs["container_seen"] = True
            self.assertEqual((obs["settled"], obs["unsettled"]), (False, unmet))
            j = scenario_run.judge_clips(self.NONE, [obs], {})
            self.assertEqual((j.exit_code, j.codes()), (2, [code]), code)

    def test_no_settle_removes_the_evidence_and_the_verdict_refuses(self):
        """R3. `--falsify no-settle` is defined as dropping the evidence, so it is deterministic.
        Red if it merely skipped a wait (the state may have settled anyway) or if the verdict
        accepted a clip with no settle evidence."""
        obs = observe(FakeDriver([app_state()]), falsify="no-settle")
        obs["container_seen"] = True
        self.assertNotIn("settled", obs)
        self.assertNotIn("unsettled", obs)
        j = scenario_run.judge_clips(self.NONE, [obs], {})
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.OBSERVATION_MISSING]))

    def test_the_duplicate_recapture_is_observed_without_a_record_id(self):
        state = app_state(attempt="a2", status="waitingForDetail", link=None, active=("X",),
                          event={"status": "alreadyCaptured", "record_id": "X"})
        obs = observe(FakeDriver([state]), before="a1",
                      probe=["Factor probe: 12 factors, below_threshold=false, duplicate=true\n"])
        obs["container_seen"] = True
        self.assertIsNone(obs["record_id"])
        self.assertEqual(obs["probe_duplicates"], [True])
        scenario = clips_scenario({"clip": "x", "expect": {"status": "already_captured", "probe_duplicate": True}})
        self.assertEqual(scenario_run.judge_clips(scenario, [obs], {}).codes(), [])

    def test_a_state_read_failure_propagates_rather_than_reading_as_not_yet(self):
        """R2. Red if a driver failure while polling were treated as 'no outcome yet'."""
        with self.assertRaises(RuntimeError):
            observe(FakeDriver([RuntimeError("request_data failed")]))

    def test_a_merge_whose_dialog_never_opens_is_a_driver_error(self):
        """R2. Red if it were written as completed: false (a product mismatch)."""
        driver = FakeDriver([app_state()], {("waitFor", app_drive_run.MERGE_APPLY_KEY): RuntimeError("timeout")})
        merge = app_drive_run.perform_merge(app_drive_run.StateReader(driver), driver, "X", "Y")
        self.assertEqual(merge["taps"], app_drive_run.MERGE_TAPS)
        self.assertIn("error", merge)
        self.assertNotIn("completed", merge)

    def test_a_merge_is_confirmed_by_holding_and_observed_from_the_state(self):
        pair = {"older": "X", "newer": "Y", "enhanced": "Y"}
        driver = FakeDriver([app_state(active=("X", "Y"), candidates=[pair]), app_state(active=("X",))])
        merge = app_drive_run.perform_merge(app_drive_run.StateReader(driver), driver, "X", "Y")
        self.assertIn(("hold", app_drive_run.MERGE_APPLY_KEY, app_drive_run.MERGE_HOLD_SECONDS), driver.calls)
        self.assertNotIn(("tap", app_drive_run.MERGE_APPLY_KEY), driver.calls)
        self.assertEqual((merge["completed"], merge["active_ids_after"], merge["tile_after"]), (True, ["X"], "absent"))
        self.assertEqual(merge["holds"], 1)

    def test_a_hold_the_button_ignored_is_held_again(self):
        """Red if the harness held once and waited for a merge the ignored press never started."""
        pair = {"older": "X", "newer": "Y", "enhanced": "Y"}
        driver = HoldIgnoringDriver(app_state(active=("X", "Y"), candidates=[pair]), app_state(active=("X",)), 1)
        with mock.patch.object(app_drive_run, "MERGE_WAIT_SECONDS", 0.3):
            merge = app_drive_run.perform_merge(app_drive_run.StateReader(driver), driver, "X", "Y")
        self.assertTrue(merge["completed"])
        self.assertEqual(merge["holds"], 2)

    def test_holds_that_are_never_accepted_stop_at_the_limit_and_stay_incomplete(self):
        pair = {"older": "X", "newer": "Y", "enhanced": "Y"}
        driver = HoldIgnoringDriver(app_state(active=("X", "Y"), candidates=[pair]), app_state(active=("X",)), 99)
        with mock.patch.object(app_drive_run, "MERGE_WAIT_SECONDS", 0.3):
            merge = app_drive_run.perform_merge(app_drive_run.StateReader(driver), driver, "X", "Y")
        self.assertEqual((merge["holds"], merge["completed"]), (app_drive_run.MERGE_HOLDS, False))
        self.assertNotIn("error", merge)

    def test_a_driver_failure_after_a_hold_is_an_error_not_a_retry(self):
        """R2. Red if a failure other than the wait running out were read as the button remaining."""
        pair = {"older": "X", "newer": "Y", "enhanced": "Y"}
        driver = FakeDriver([app_state(active=("X", "Y"), candidates=[pair])],
                            {("waitForAbsent", app_drive_run.MERGE_APPLY_KEY): RuntimeError("VM Service call timed out")})
        merge = app_drive_run.perform_merge(app_drive_run.StateReader(driver), driver, "X", "Y")
        self.assertEqual(merge["holds"], 1)
        self.assertIn("error", merge)
        self.assertNotIn("completed", merge)


class TheRunLevelPlaybackCoversEveryClip(unittest.TestCase):
    """`run_validity_failures` reads `stop_frames` / `synchronised` at the top of the summary."""

    def clip(self, held=2, timeouts=0):
        return {"stop_frames": [1, 2], "playback_seconds": 1.0,
                "synchronised": {"held": [{"tab": t} for t in range(held)], "timeouts": timeouts}}

    def test_a_single_clip_keeps_its_own_fields(self):
        one = self.clip()
        self.assertEqual(app_drive_run.playback_summary([one]),
                         {k: one[k] for k in ("stop_frames", "synchronised", "playback_seconds")})

    def test_a_hold_lost_in_any_clip_is_lost_for_the_run(self):
        """Red if the run-level fields were the first clip's only."""
        summary = app_drive_run.playback_summary([self.clip(), self.clip(held=1, timeouts=1)])
        self.assertEqual(summary["stop_frames"], [1, 2, 1, 2])
        self.assertEqual(summary["synchronised"]["timeouts"], 1)
        failures = scenario_run.sync_failures(summary)
        self.assertEqual(len(failures), 2, failures)

    def test_a_clip_that_never_played_leaves_the_run_unsynchronised(self):
        summary = app_drive_run.playback_summary([self.clip(), {"stop_frames": [1, 2]}])
        self.assertNotIn("synchronised", summary)
        self.assertTrue(scenario_run.sync_failures(summary))


class EachHoldWaitedForItsOwnClipsMarker(unittest.TestCase):
    """`marker_after_arm` per hold: a second clip whose signals were not re-armed is released at once
    by the first clip's marker, with no timeout and every stop held."""

    def clip(self, *after_arm: bool) -> dict:
        return {"stop_frames": [10 * (t + 1) for t in range(len(after_arm))],
                "synchronised": {"timeouts": 0, "held": [
                    {"tab": t, "timed_out": False, "marker_after_arm": a} for t, a in enumerate(after_arm)]}}

    def test_a_hold_released_by_an_earlier_marker_is_not_synchronised(self):
        """Red if `marker_after_arm` were not read: nothing else in the observation differs."""
        failures = scenario_run.sync_failures(self.clip(True, False))
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("[1]", failures[0])
        run = app_drive_run.playback_summary([self.clip(True, True), self.clip(False, False)])
        self.assertEqual(len(scenario_run.sync_failures(run)), 1)
        j = scenario_run.judge_clips(clips_scenario({"clip": "x", "expect": {"status": "succeeded"}}, sync=True),
                                     [seen("X", **self.clip(False))], {})
        self.assertEqual((j.exit_code, j.codes()), (2, [scenario_run.SYNC_INVALID]))

    def test_holds_that_waited_for_their_own_markers_pass(self):
        """The control. Red if the check refused a hold whose marker came after arming, or re-reported
        a timed-out hold (whose marker was never seen) on top of its timeout."""
        self.assertEqual(scenario_run.sync_failures(self.clip(True, True)), [])
        timed_out = self.clip(True, False)
        timed_out["synchronised"]["held"][1]["timed_out"] = True
        timed_out["synchronised"]["timeouts"] = 1
        self.assertEqual(len(scenario_run.sync_failures(timed_out)), 1)


class MainTurnsAnErrorStatusIntoExitTwo(unittest.TestCase):
    """R1 through `main()`: an error summary whose records match the golden exits 2. Red if `main()`
    computed `harness_status_failure` and dropped it -- the pure-function tests cannot see that."""

    def run_main(self, status: str, clips: list | None = None) -> int:
        import tempfile
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(__import__("shutil").rmtree, tmp, True)
        golden = tmp / "golden.json"
        golden.write_text("[]", encoding="utf-8")
        scenario = {"name": "t", "sync": False, "config": {}, "settings": {}, "expect_links": [],
                    "clips": [{"clip": str(tmp / "c.mp4")}], "golden": str(golden)}
        suite = type("Suite", (), {"collect_records": staticmethod(lambda root: []),
                                   "_dumps": staticmethod(lambda records: "[]")})

        def harness(command, timeout, log):
            tag, run_id = command[command.index("--tag") + 1], command[command.index("--run-id") + 1]
            summary = {"run_id": run_id, "status": status, "error": "TimeoutException", "record_dirs": [],
                       "data_isolation": {"roots": [], "leaked_record_dirs": []},
                       "clips": [seen("X")] if clips is None else clips}
            (tmp / f"app_result_{tag}.json").write_text(json.dumps(summary), encoding="utf-8")
            return {"returncode": 0, "timed_out": False}

        with mock.patch.object(scenario_run, "load_scenario", return_value=scenario), \
                mock.patch.object(scenario_run, "preflight"), \
                mock.patch.object(app_drive_run, "validate_plan", side_effect=lambda plan, where: plan), \
                mock.patch.object(scenario_run, "load_golden_suite", return_value=suite), \
                mock.patch.object(scenario_run, "run_harness", side_effect=harness), \
                mock.patch.object(scenario_run, "RUNS", tmp), \
                mock.patch.object(app_drive_run, "SCRATCH_ROOT", tmp), \
                mock.patch.object(sys, "argv", ["scenario_run.py", "s.json", "--tag", "t"]), \
                mock.patch("builtins.print"):
            return scenario_run.main()

    def test_an_error_summary_with_matching_records_exits_two(self):
        self.assertEqual(self.run_main("error"), 2)

    def test_the_same_run_completed_passes(self):
        """The control: the fixture reaches a pass when only the status differs."""
        self.assertEqual(self.run_main("ok"), 0)

    def test_a_single_clip_run_whose_outcome_was_never_seen_exits_two(self):
        """(iii) through `main()`: a completed single-clip run whose records match and whose clip's outcome
        was never observed. Red if `main()` judged the clips only for a scenario stating a per-clip
        expectation -- a single-clip scenario states none, so it would pass on the records alone."""
        self.assertEqual(self.run_main("ok", clips=[seen("X", capture=None)]), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
