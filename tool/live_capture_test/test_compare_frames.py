# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Unit tests for the mimic player's fidelity verdict.

    uv run tool/live_capture_test/test_compare_frames.py

Nothing here decodes a video. `match_frames` and `evaluate` are pure functions over frame digests
and container durations, so every shape of capture this check is meant to refuse -- the frozen
presenter, the capture that kept a dozen frames, the container that reports no duration -- can be
written down directly. Each case names, in its docstring, the wrong implementation it would catch;
a test that also passes against the bug it is meant to hold is not a check.

These live apart from `test_stops_validation.py` because their subject is a different one: that file
tests the harness's refusals around the stops sidecar and the verdict's preconditions, and it pulls
in `app_drive_run` and therefore `websockets`. `compare_frames.py` declares no dependencies at all,
and a test of it should not acquire one.

The numbers in the "real run" fixtures are taken from the fidelity results recorded on this machine
(376 source frames over 14.216 s, an 8.2 s capture window, 138-204 frames kept).
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from compare_frames import evaluate, match_frames  # noqa: E402

SOURCE_FRAMES = 376
SOURCE_SECONDS = 14.216
CAPTURED_SECONDS = 8.2
# What `evaluate` computes as the presenter's walk for that window: 8.2 s * (376 / 14.216 s).
EXPECTED_SPAN = CAPTURED_SECONDS * (SOURCE_FRAMES / SOURCE_SECONDS)


def digests(indices: list[int]) -> list[str]:
    """Frame hashes for a source of `SOURCE_FRAMES` distinct frames, sampled at `indices`."""
    return [f"hash-{index:04d}" for index in indices]


def source_digests() -> list[str]:
    return digests(list(range(SOURCE_FRAMES)))


def spread(count: int, first: int = 158, last: int = 374) -> list[int]:
    """`count` source indices spread evenly from `first` to `last`, i.e. spanning the whole clip."""
    if count == 1:
        return [first]
    step = (last - first) / (count - 1)
    return [round(first + step * n) for n in range(count)]


def verdict(indices: list[int], **overrides) -> dict:
    """The verdict for a capture that showed exactly the source frames at `indices`, in order."""
    matched, reordered = match_frames(source_digests(), digests(indices))
    arguments = {
        "source_frames": SOURCE_FRAMES,
        "matched": matched,
        "reordered": reordered,
        "source_seconds": SOURCE_SECONDS,
        "captured_seconds": CAPTURED_SECONDS,
        "min_advance_ratio": 0.5,
        "min_coverage_ratio": 0.25,
    }
    arguments.update(overrides)
    result, _ = evaluate(**arguments)
    return result


class RealRunsStillPass(unittest.TestCase):
    """The control for every floor below. Red if a floor were raised to where real captures sit, or
    if the density floor counted something a healthy run does not have."""

    def test_the_worst_recorded_run_passes(self):
        """138 distinct frames of the ~217 walked -- the lowest coverage of the 21 passing runs on
        record. Red if the coverage floor were set anywhere near real behaviour."""
        result = verdict(spread(138))
        self.assertGreater(result["coverage_ratio"], 0.25)
        self.assertTrue(result["passed"], result)

    def test_the_best_recorded_run_passes(self):
        self.assertTrue(verdict(spread(204))["passed"])

    def test_a_capture_that_kept_every_other_frame_passes(self):
        """A capture sampling at half the source's rate is the ordinary case, not a regression."""
        self.assertTrue(verdict(list(range(0, SOURCE_FRAMES, 2)))["passed"])


class ASparseCaptureIsRefused(unittest.TestCase):
    """The finding this suite exists for: a capture that reached the end of the clip on almost
    nothing in between. Red against the verdict as it stood, which was `captured and not unmatched
    and not reordered and advanced` -- all four of which this capture satisfies."""

    def test_a_dozen_frames_spread_over_the_whole_clip_fails(self):
        result = verdict(spread(12))
        self.assertTrue(result["advanced"], "the old three conditions must still be met")
        self.assertEqual(result["unmatched_captured_frames"], 0)
        self.assertEqual(result["reorderings"], 0)
        self.assertFalse(result["dense"])
        self.assertFalse(result["passed"], result)

    def test_the_failure_names_the_density_floor(self):
        """Red if the check were folded into the advance message: the two failures have different
        causes and a reader sent to the presenter would look in the wrong place."""
        matched, reordered = match_frames(source_digests(), digests(spread(12)))
        _, failures = evaluate(source_frames=SOURCE_FRAMES, matched=matched, reordered=reordered,
                               source_seconds=SOURCE_SECONDS, captured_seconds=CAPTURED_SECONDS,
                               min_advance_ratio=0.5, min_coverage_ratio=0.25)
        self.assertEqual(len(failures), 1, failures)
        self.assertIn("witnessed 12 distinct source frame(s)", failures[0])

    def test_coverage_counts_distinct_source_frames_and_not_captured_ones(self):
        """A capture full of duplicates of a few source frames: 240 frames kept, 12 witnessed. Red
        if the floor were `captured_frames / expected_span`, which this passes handily."""
        result = verdict([index for index in spread(12) for _ in range(20)])
        self.assertEqual(result["captured_frames"], 240)
        self.assertGreater(result["captured_frames"], 0.25 * EXPECTED_SPAN)
        self.assertFalse(result["dense"])

    def test_a_capture_just_above_the_floor_passes(self):
        """The floor is a floor, not a band. Red if the comparison were strict-greater or off by
        one whole frame."""
        self.assertTrue(verdict(spread(round(0.25 * EXPECTED_SPAN) + 1))["dense"])


class TheFrozenPresenterIsStillRefused(unittest.TestCase):
    """Condition 3's own regression. Red if the advance floor were dropped while adding the density
    one -- a frozen presenter clears conditions 1 and 2."""

    def test_a_constant_capture_fails_the_advance_floor(self):
        result = verdict([200] * 190)
        self.assertEqual(result["unmatched_captured_frames"], 0)
        self.assertEqual(result["reorderings"], 0)
        self.assertFalse(result["advanced"])
        self.assertFalse(result["passed"])


class TheFloorsFailClosed(unittest.TestCase):
    """Red if an unevaluable floor were treated as a met floor -- the state a container with no
    duration puts both of them in."""

    def test_a_missing_captured_duration_fails_both_floors(self):
        result = verdict(spread(138), captured_seconds=None)
        self.assertFalse(result["advanced"])
        self.assertFalse(result["dense"])
        self.assertIsNone(result["coverage_ratio"])
        self.assertFalse(result["passed"])

    def test_a_missing_source_duration_fails_both_floors(self):
        result = verdict(spread(138), source_seconds=None)
        self.assertFalse(result["advanced"])
        self.assertFalse(result["dense"])

    def test_an_empty_capture_fails(self):
        result = verdict([])
        self.assertFalse(result["passed"])
        self.assertEqual(result["captured_frames"], 0)


class TheFloorsSwitchOffSeparately(unittest.TestCase):
    """The still-screen escape. Red if one flag disabled both floors, which would put the density
    check back in the class of guards that quietly stop checking."""

    def test_disabling_the_advance_floor_leaves_the_density_floor_armed(self):
        result = verdict(spread(12), min_advance_ratio=0)
        self.assertTrue(result["advanced"])
        self.assertFalse(result["dense"])
        self.assertFalse(result["passed"])

    def test_disabling_the_density_floor_leaves_the_advance_floor_armed(self):
        result = verdict([200] * 190, min_coverage_ratio=0)
        self.assertTrue(result["dense"])
        self.assertFalse(result["advanced"])
        self.assertFalse(result["passed"])

    def test_a_still_window_passes_with_both_disabled(self):
        result = verdict([200] * 190, min_advance_ratio=0, min_coverage_ratio=0)
        self.assertTrue(result["passed"])


class MatchingIsGreedyMonotone(unittest.TestCase):
    """Conditions 1 and 2, which the refactor into `match_frames` must not have moved."""

    def test_a_frame_absent_from_the_source_is_unmatched(self):
        matched, _ = match_frames(source_digests(), ["hash-9999"] + digests(spread(50)))
        self.assertEqual(matched[0], -1)

    def test_going_backwards_is_reported_as_a_reordering(self):
        matched, reordered = match_frames(source_digests(), digests([100, 200, 150]))
        self.assertEqual(matched, [100, 200, 150])
        self.assertEqual([entry[0] for entry in reordered], [2])

    def test_a_repeated_source_frame_takes_the_earliest_index_not_before_the_last(self):
        """Duplicates in a recording are common; the assignment most favourable to condition 2 is
        the one that makes a reordering failure mean no in-order assignment exists."""
        source = ["a", "b", "a", "b", "c"]
        matched, reordered = match_frames(source, ["a", "b", "a", "c"])
        self.assertEqual(matched, [0, 1, 2, 4])
        self.assertEqual(reordered, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
