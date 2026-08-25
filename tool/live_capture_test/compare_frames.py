# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Pixel-fidelity check for the mimic player.

Asserts that a live capture taken while the mimic player was presenting a recording is a faithful
sampling of that recording:

  1. every frame of the capture is bit-identical to *some* frame of the source recording,
  2. the matched source indices are monotonically non-decreasing over the capture,
  3. the capture ADVANCED through the source: the matched indices reach about as far as the
     source's own rate says the presenter walked while the capture was running, and
  4. it advanced DENSELY: it did not reach that far on a handful of frames scattered over the way.

Duplicates and skips are expected -- WinRT Graphics Capture only yields on DWM composition
boundaries (~24 fps), so it samples whatever is on screen and misses frames in between.
Reordering is not expected and is what condition 2 catches.

Condition 3 exists because 1 and 2 are vacuously true of a frozen presenter. If `present()` stops
updating the window (it returns early on a size/type mismatch, a failed Map, GetBuffer or Present --
see mimic_player.cpp), the capture is a run of copies of one source frame: every frame matches, the
chosen indices are constant and therefore non-decreasing, and the check this file exists to be would
print PASS on the exact regression it is the only guard against. So the floor is stated positively:
over the capture's own duration the presenter should have walked `captured_seconds * source_fps`
frames of the source, and the matched span must be at least `--min-advance-ratio` of that (capped by
the source's length). It fails closed when the containers carry no duration to compute it from.

Condition 4 exists because the same argument applies to condition 3. `span` is the distance between
the FIRST and the LAST matched index, so it is decided by two frames and says nothing about the ones
in between: a regression that keeps a dozen frames scattered over a nine-second capture still spans
the whole clip, and 1-3 are all satisfied. So the same expected walk carries a second floor, over
what the capture actually witnessed: `distinct_source_frames_covered` must be at least
`--min-coverage-ratio` of it. Both floors are ratios of one derived quantity rather than of a frame
rate written down here, so neither has to be revised when a clip of another rate is used.

The two defaults differ because the quantities do: a healthy capture spans nearly all of the walk
(condition 3 is near 1.0) but only witnesses the fraction of it that fits its own, lower, sampling
rate. The 0.25 default is measured, not guessed: the captures still on disk here score 0.835 to
0.899, and the 21 passing results on record reach down to about 0.64 (138 distinct frames; those
runs predate the field, but every capture window is the same ~8.2 s, so the walk is ~217). The floor
sits at about 40% of the worst real run, while the dozen-frame capture above scores 0.06 -- and if
a capture path is ever legitimately slower than that, it is the measurement that should move, in one
place, with a run behind it. What condition 4 does NOT bound is where the witnessed frames sit: a
capture that stalls for a stretch and makes it up elsewhere still clears it. `largest_skip` is
reported for that, but is deliberately not a floor -- the runs on record top out at 3, which is too
short a tail to put a bound on without guessing.

`--min-advance-ratio 0` disables condition 3, for a capture window you know sits on a still screen.
That same knowledge disables condition 4, so it has its own `--min-coverage-ratio 0`: a still screen
cannot satisfy a density floor either. They are not coupled implicitly, because a floor that
switches itself off in response to an unrelated flag is the failure this file already has one of.

Frames are compared as raw BGR24 (what the pipeline actually receives), decoded through ffmpeg.
Identical frames are common in a recording (static screens), so a captured frame's hash can match
many source indices. Matching is therefore greedy-monotone: take the smallest candidate index that
is >= the previously matched one. That is the assignment most favourable to condition 2, so a
failure here means no in-order assignment exists at all.

    uv run tool/live_capture_test/compare_frames.py --source <source.mkv> --captured <out.mkv>

`fidelity_run.sh` performs the whole sequence (start the player, capture it, compare).
"""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


def probe_size(path: Path) -> tuple[int, int]:
    out = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height", "-of", "csv=p=0", str(path),
        ],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    width, height = (int(v) for v in out.split(",")[:2])
    return width, height


def probe_duration(path: Path) -> float | None:
    """Container duration in seconds, or None when the container does not carry a usable one."""
    out = subprocess.run(
        [
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "csv=p=0", str(path),
        ],
        capture_output=True, text=True, check=True,
    ).stdout.strip().split(",")[0]
    try:
        duration = float(out)
    except ValueError:
        return None
    return duration if duration > 0 else None


def frame_hashes(path: Path, width: int, height: int) -> list[str]:
    """Returns the SHA-256 of every decoded frame, as raw BGR24."""
    frame_bytes = width * height * 3
    process = subprocess.Popen(
        [
            "ffmpeg", "-v", "error", "-i", str(path), "-fps_mode", "passthrough",
            "-f", "rawvideo", "-pix_fmt", "bgr24", "-",
        ],
        stdout=subprocess.PIPE,
    )
    hashes: list[str] = []
    assert process.stdout is not None
    while True:
        buffer = process.stdout.read(frame_bytes)
        if not buffer:
            break
        if len(buffer) != frame_bytes:
            raise RuntimeError(f"{path}: truncated frame ({len(buffer)} of {frame_bytes} bytes)")
        hashes.append(hashlib.sha256(buffer).hexdigest())
    process.stdout.close()
    if process.wait() != 0:
        raise RuntimeError(f"{path}: ffmpeg decode failed")
    return hashes


def match_frames(source: list[str], captured: list[str]) -> tuple[list[int], list[tuple[int, int, int]]]:
    """Assigns each captured frame a source index, greedy-monotone; -1 where nothing matches.

    Returns `(matched, reordered)`, where `reordered` holds `(captured index, previous source index,
    chosen)` for every position at which no candidate >= the previous one existed.
    """
    index_of: dict[str, list[int]] = defaultdict(list)
    for index, digest in enumerate(source):
        index_of[digest].append(index)

    matched: list[int] = []
    reordered: list[tuple[int, int, int]] = []
    previous = 0
    for position, digest in enumerate(captured):
        candidates = index_of.get(digest)
        if not candidates:
            matched.append(-1)
            continue
        # Smallest candidate >= previous keeps the assignment monotone whenever that is possible.
        slot = bisect.bisect_left(candidates, previous)
        if slot < len(candidates):
            chosen = candidates[slot]
        else:
            chosen = candidates[-1]
            reordered.append((position, previous, chosen))
        matched.append(chosen)
        previous = chosen
    return matched, reordered


def evaluate(
    *,
    source_frames: int,
    matched: list[int],
    reordered: list[tuple[int, int, int]],
    source_seconds: float | None,
    captured_seconds: float | None,
    min_advance_ratio: float,
    min_coverage_ratio: float,
) -> tuple[dict, list[str]]:
    """The whole verdict, as a pure function of the measurements. Returns `(result, failures)`."""
    unmatched = [position for position, index in enumerate(matched) if index < 0]
    covered = sorted({index for index in matched if index >= 0})
    skips = [b - a for a, b in zip(covered, covered[1:])]
    largest_skip = max(skips) if skips else 0
    span = covered[-1] - covered[0] if covered else 0

    # `expected_span` is what the presenter should have walked while the capture ran: the capture's
    # own duration times the source's own frame rate, capped by the source (a capture that outlasts
    # the clip cannot advance past its end). None means the containers do not carry the durations to
    # compute it, which is reported as a failure rather than skipped -- an unevaluable floor is not
    # a met floor. Conditions 3 and 4 are both ratios of it: how far the capture reached, and how
    # much of the way it actually witnessed.
    expected_span: float | None = None
    if source_seconds is not None and captured_seconds is not None and source_frames > 1:
        expected_span = min(captured_seconds * (source_frames / source_seconds), source_frames - 1)
    coverage_ratio = round(len(covered) / expected_span, 3) if expected_span else None

    if min_advance_ratio <= 0:
        advanced = True
    elif not matched or expected_span is None:
        advanced = False
    else:
        advanced = span >= min_advance_ratio * expected_span
    if min_coverage_ratio <= 0:
        dense = True
    elif not matched or expected_span is None:
        dense = False
    else:
        dense = len(covered) >= min_coverage_ratio * expected_span

    result = {
        "source_frames": source_frames,
        "captured_frames": len(matched),
        "unmatched_captured_frames": len(unmatched),
        "distinct_source_frames_covered": len(covered),
        "first_source_index": covered[0] if covered else None,
        "last_source_index": covered[-1] if covered else None,
        "source_index_span": span,
        "source_seconds": source_seconds,
        "captured_seconds": captured_seconds,
        "expected_source_span": round(expected_span, 1) if expected_span is not None else None,
        "min_advance_ratio": min_advance_ratio,
        "advanced": advanced,
        "coverage_ratio": coverage_ratio,
        "min_coverage_ratio": min_coverage_ratio,
        "dense": dense,
        "largest_skip": largest_skip,
        "reorderings": len(reordered),
        "passed": bool(matched) and not unmatched and not reordered and advanced and dense,
    }

    failures: list[str] = []
    if not matched:
        failures.append("FAIL: the capture holds no frames")
    if unmatched:
        failures.append(f"FAIL: {len(unmatched)} captured frame(s) match no source frame, "
                        f"e.g. {unmatched[:10]}")
    if reordered:
        failures.append(f"FAIL: {len(reordered)} out-of-order match(es), e.g. {reordered[:5]}")
    unevaluable = ("FAIL: {0} cannot be evaluated -- one of the containers reports no duration. "
                   "Pass --{1} 0 only if you know the capture window is still.")
    if matched and not advanced:
        if expected_span is None:
            failures.append(unevaluable.format("the advance floor", "min-advance-ratio"))
        else:
            failures.append(
                f"FAIL: the capture advanced {span} source frame(s) over {captured_seconds:.2f}s, "
                f"below the floor {min_advance_ratio} * {expected_span:.1f}. A presenter that froze "
                f"looks exactly like this: every frame matches, in order, going nowhere.")
    if matched and not dense:
        if expected_span is None:
            failures.append(unevaluable.format("the density floor", "min-coverage-ratio"))
        else:
            failures.append(
                f"FAIL: the capture witnessed {len(covered)} distinct source frame(s) of the "
                f"{expected_span:.1f} the presenter walked, below the floor {min_coverage_ratio}. "
                f"A capture path that drops nearly everything looks exactly like this: what "
                f"survives still spans the clip, so the advance floor above is met.")
    return result, failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path, help="the recording the player presented")
    parser.add_argument("--captured", required=True, type=Path, help="capture --record output")
    parser.add_argument("--json", type=Path, help="also write the result as JSON")
    parser.add_argument("--min-advance-ratio", type=float, default=0.5,
                        help="fraction of the source the capture must have walked through, relative "
                             "to what its own duration says the presenter played (default 0.5). "
                             "0 disables the floor -- use it only for a capture window you KNOW "
                             "sits on a still screen.")
    parser.add_argument("--min-coverage-ratio", type=float, default=0.25,
                        help="fraction of that same walk the capture must have actually witnessed, "
                             "as distinct source frames (default 0.25, measured -- see the module "
                             "docstring). This is what the advance floor above cannot see: it is "
                             "decided by the first and last matched frame only. 0 disables it.")
    args = parser.parse_args()

    source_size = probe_size(args.source)
    captured_size = probe_size(args.captured)
    if source_size != captured_size:
        print(f"FAIL: frame size {captured_size} != source {source_size}")
        return 1

    source = frame_hashes(args.source, *source_size)
    captured = frame_hashes(args.captured, *captured_size)
    print(f"source   {args.source.name}: {len(source)} frames, {len(set(source))} distinct")
    print(f"captured {args.captured.name}: {len(captured)} frames, {len(set(captured))} distinct")

    matched, reordered = match_frames(source, captured)
    result, failures = evaluate(
        source_frames=len(source),
        matched=matched,
        reordered=reordered,
        source_seconds=probe_duration(args.source),
        captured_seconds=probe_duration(args.captured),
        min_advance_ratio=args.min_advance_ratio,
        min_coverage_ratio=args.min_coverage_ratio,
    )
    print(json.dumps(result, indent=2))
    for line in failures:
        print(line)
    if args.json:
        args.json.write_text(json.dumps(result, indent=2))
    if not result["passed"]:
        return 1
    print("PASS: every captured frame is bit-identical to a source frame, in non-decreasing order, "
          f"advancing {result['source_index_span']} source frame(s) and witnessing "
          f"{result['distinct_source_frames_covered']} of them")
    return 0


if __name__ == "__main__":
    sys.exit(main())
