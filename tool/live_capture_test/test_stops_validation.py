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


if __name__ == "__main__":
    unittest.main(verbosity=2)
