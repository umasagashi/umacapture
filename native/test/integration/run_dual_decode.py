# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Dual-decode equivalence test: the same clip, two YUV -> RGB matrices, one record set.

WHAT IT MEASURES. The CLI decodes video through cv::VideoCapture, whose FFmpeg backend converts YUV to
RGB with **swscale**, and swscale uses BT.601 limited range regardless of the stream's colour tags. A
browser decoding the same file converts with BT.709 -- not by honouring a tag, but as its default: the
clips this suite drives carry no colour tags at all (``color_space=unknown``, no ``colr`` box), and a
browser's reported ``VideoFrame.colorSpace.matrix`` says ``bt709`` whatever it actually did, so it is
not a signal anything may branch on (see ``native/src/cv/decoded_frame_to_bgr.h``). The two decoders
disagree by roughly 7 on average and up to 37 out of 255, and a fair part of the pipeline gates on colours
(``isHeaderGreen`` in ``native/src/cv/detail_crop_calibrator.h``, the ``Range<Color>`` bands in
``assets/config/chara_detail/recognizer.json``, the ``PointColor`` / ``LineColor`` rules in
``scene_context.json``). Whether recognition survives that shift was, until this test, an opinion.

So each case runs ``umacapture_cli video`` twice over the same clip -- ``--color_matrix bt601`` and
``--color_matrix bt709``, which decode the clip's own planes and convert them here rather than letting
swscale decide -- and requires the two record sets to be **identical**. The contract is deliberately
"the same records", not "the accepted colour volume grew": widening a threshold is only progress if the
recognition it produces does not move.

THE CONTROL MATTERS AS MUCH AS THE TREATMENT. ``--color_matrix bt601`` is a different decoder (libav
planes + ``cv/decoded_frame_to_bgr.h``) reaching the pixels swscale reaches to within one unit per channel --
its limited-range luma ramp is deliberately coarsened, so the control below is a RECORD identity and never a
pixel one -- so a mismatch could come from the harness rather than from colour. Every case therefore also
diffs its bt601 run against the committed golden -- the same file ``run.py`` pins the shipping ``video``
path to -- and reports a
disagreement as ``HARNESS`` rather than as a colour finding. A red ``bt601 vs bt709`` line is only
meaningful with a green ``bt601 vs golden`` line above it.

NOT EVERY CASE IS ELIGIBLE, for two structural reasons, and an ineligible case is skipped **with that
reason named** rather than silently dropped from the manifest.

* A ``replay`` case is an FFV1 recording; FFV1 stores BGR0 and no YUV conversion happens anywhere on
  that path, so there is no matrix to vary. Eligibility reads the manifest's ``mode`` and not the file
  extension: what disqualifies a case is the absence of a YUV -> RGB step, which is a property of the
  pipeline it enters, and a `.mkv` is a container that says nothing about that.
* A case whose manifest entry says ``expect_records: 0`` produces no records **by design** (a clip that
  ends mid-character, or in which every character is switched away from before it completes). "bt601
  and bt709 agree" is then satisfied by two empty sets, which is exactly the pass-by-vacuum the empty-set
  guard below refuses -- and the alternative, calling it a failure, would make a correct outcome red.
  Neither answer is available, so the case takes no part. What such a clip *does* assert lives in
  ``run.py``, which reads the CLI's run summary and requires the emptiness to have been announced.

A CASE MAY HAVE NO GOLDEN, and then the control above is simply absent -- the run reports the
equivalence with an explicit note that it was judged without one. ``landscape_2pane_ps5`` is that case:
it is the only clip in the manifest that shows the defect (portrait clips pass both matrices), and it
is a locally derived transcode whose exact pixels depend on the local encoder, so a committed record
baseline would be a false alarm elsewhere. Losing the control costs the ability to distinguish "the
planar bt601 decoder disagrees with swscale" from "colour moved the records"; for this case that is
covered instead by the ten portrait cases, which run the same control over the same decoder.

EVERY RUN'S GEOMETRY IS CHECKED TOO, against the manifest's ``anchor_unit``. It is what gives that key
force for ``landscape_2pane_ps5``, the one case ``run.py`` has nothing to judge and therefore skips, and
it makes explicit something this suite otherwise only assumes: that the two decodes differ in colour and
in nothing else. A matrix that moved the pane latch would move the anchor unit with it, and the record
comparison below would then be comparing two different pipelines rather than two conversions.

Registered as one ctest per case (``integration_dual_decode.<name>``) for the reason ``run.py`` states:
ctest hides the stdout of a passing or skipping test, so per-case coverage has to live in test identity
and status. A case whose clip or models are absent exits 77 and is reported Skipped.
"""

from __future__ import annotations

import argparse
import difflib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

# Shares the manifest, the record normalisation and the "can this machine run it" rule with the golden
# suite, so the two can never disagree about what a case is.
from run import (
    CLI_TIMEOUT_SECONDS,
    SKIP_EXIT_CODE,
    case_mode,
    check_anchor_unit,
    collect_records,
    frame_resize_args,
    frame_resize_complaint,
    golden_path,
    skip_reason,
    _dumps,
)

HERE = Path(__file__).resolve().parent

MATRICES = ("bt601", "bt709")


def run_matrix(case: dict, matrix: str, cli: Path, data_dir: Path, assets_dir: Path, modules_dir: Path):
    """Run one case under one colour matrix. Returns ``(kind, payload)`` like ``run.run_case``."""
    video = (data_dir / case["video"]).resolve()
    with tempfile.TemporaryDirectory(prefix=f"uma_dd_{case['name']}_{matrix}_") as tmp:
        output_dir = Path(tmp)
        command = [
            str(cli),
            "video",
            "--video_path_list",
            str(video),
            "--color_matrix",
            matrix,
            # From the manifest, and passed explicitly for the reason run.py states: this suite's bt601 run is
            # diffed against the same golden run.py pins, so the two must build the same pipeline config. A
            # default relied on here and stated there would make the control fail as a colour finding.
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
                command, capture_output=True, text=True, timeout=CLI_TIMEOUT_SECONDS, cwd=output_dir
            )
        except subprocess.TimeoutExpired:
            return "fail", f"cli timed out after {CLI_TIMEOUT_SECONDS}s ({matrix})"
        if completed.returncode != 0:
            tail = completed.stderr.strip().splitlines()[-15:]
            return "fail", "cli exited {} ({}):\n{}".format(completed.returncode, matrix, "\n".join(tail))
        # The geometry that actually reached recognition, asserted here as well as in run.py, for two reasons
        # that are not the same reason. First, this is the ONLY suite landscape_2pane_ps5 takes part in -- it
        # states no golden and no expect_records, so run.py has nothing to judge it by and skips it -- and
        # without this the manifest key it is required to declare would be inert for that case alone. Second,
        # the geometry must not depend on the colour matrix: this suite's whole claim is that the two decodes
        # are the same run bar the conversion, so a matrix that moved the pane latch, and with it the unit,
        # would make the record comparison a comparison of two different pipelines.
        geometry_failure = check_anchor_unit(case, completed)
        if geometry_failure is not None:
            return "fail", f"{geometry_failure} ({matrix})"
        # The config key name, asserted here for the SAME reason the geometry above is, and it is the reason
        # this scan cannot live in run.py alone: landscape_2pane_ps5 states neither a golden nor
        # expect_records, so it registers no integration_golden ctest and this suite is the only one that runs
        # it. Without this call, the one case with single-suite cover was the one case with NO cover against a
        # CLI that regressed to the pre-band `unit` key -- a regression that configures a numerically
        # identical band and leaves the records untouched, so the core's warning is its only observable.
        # Shared with run.py rather than reimplemented, so the two runners cannot drift on what a complaint is.
        config_failure = frame_resize_complaint(completed)
        if config_failure is not None:
            return "fail", f"{config_failure} ({matrix})"
        records = collect_records(output_dir)
    if not records:
        # An empty set is exactly the failure mode this test exists to catch (the landscape import that
        # latched no pane produced no records at all), so it is a failure, never a pass-by-vacuum.
        return "fail", f"cli produced no record.json under {matrix}"
    return "records", records


def eligibility(case: dict, data_dir: Path, modules_dir: Path) -> str | None:
    """Return why this case cannot take part, or None when it can."""
    if case_mode(case) != "video":
        return "replay case: FFV1 stores BGR0, so no YUV -> RGB matrix is applied on that path"
    if case.get("expect_records") == 0:
        return (
            "zero-record case: the manifest expects no records, so bt601 == bt709 would hold over two "
            "empty sets -- the pass-by-vacuum this suite refuses. run.py carries what this clip asserts"
        )
    return skip_reason(case, data_dir, modules_dir)


def diff(label_a: str, text_a: str, label_b: str, text_b: str) -> str:
    return "\n".join(
        difflib.unified_diff(
            text_a.splitlines(), text_b.splitlines(), fromfile=label_a, tofile=label_b, lineterm=""
        )
    )


def run_case(case: dict, cli: Path, data_dir: Path, assets_dir: Path, modules_dir: Path) -> tuple[str, str]:
    """Returns ``(status, detail)`` with status in {skip, pass, fail, harness}."""
    reason = eligibility(case, data_dir, modules_dir)
    if reason is not None:
        return "skip", reason

    texts: dict[str, str] = {}
    for matrix in MATRICES:
        kind, payload = run_matrix(case, matrix, cli, data_dir, assets_dir, modules_dir)
        if kind == "fail":
            return "fail", str(payload)
        texts[matrix] = _dumps(payload)

    # Control first: a planar bt601 run must reproduce the RECORDS of the shipping swscale path exactly. Its
    # pixels agree only to within one unit per channel (cv/decoded_frame_to_bgr.h's coarsened luma ramp), and
    # that is precisely what this comparison exists to hold harmless: the text below is record JSON. A case
    # that states no golden has no control to run; the note is carried into the pass line so a green
    # result is never read as stronger than it is.
    golden_file = golden_path(case)
    control = "no golden in the manifest, so the bt601 control was not run"
    if golden_file is not None:
        if not golden_file.exists():
            return "harness", f"no golden at {golden_file}"
        golden_text = golden_file.read_text(encoding="utf-8")
        if texts["bt601"] != golden_text:
            return "harness", "the bt601 control does not reproduce the golden, so this case cannot judge " \
                              "bt709:\n" + diff("golden", golden_text, "bt601", texts["bt601"])
        control = "bt601 reproduces the golden"

    if texts["bt601"] == texts["bt709"]:
        return "pass", f"{len(json.loads(texts['bt601']))} record(s) identical under both matrices ({control})"
    return "fail", "records differ between bt601 and bt709:\n" + diff(
        "bt601", texts["bt601"], "bt709", texts["bt709"]
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="path to umacapture_cli(.exe)")
    parser.add_argument("--data-dir", type=Path, default=HERE.parents[2] / "testdata" / "clips" / "golden")
    parser.add_argument("--assets-dir", type=Path, default=HERE.parents[2] / "assets" / "config")
    parser.add_argument("--modules-dir", type=Path, default=HERE.parents[2] / "sandbox" / "modules")
    parser.add_argument("--cases", type=Path, default=HERE / "cases.json")
    parser.add_argument("--only", metavar="NAME", help="run just this case (one ctest per case registers this)")
    args = parser.parse_args()

    cases = json.loads(args.cases.read_text(encoding="utf-8"))["cases"]
    if args.only is not None:
        cases = [case for case in cases if case["name"] == args.only]
        if not cases:
            print(f"ERROR: no case named {args.only!r} in {args.cases}", file=sys.stderr)
            return 2

    if not args.cli.exists():
        print(f"SKIP: cli not built: {args.cli}", file=sys.stderr)
        return SKIP_EXIT_CODE

    passed = failed = skipped = 0
    for case in cases:
        status, detail = run_case(case, args.cli, args.data_dir, args.assets_dir, args.modules_dir)
        if status == "skip":
            skipped += 1
            print(f"SKIP {case['name']}: {detail}")
        elif status == "pass":
            passed += 1
            print(f"PASS {case['name']}: {detail}")
        elif status == "harness":
            failed += 1
            print(f"HARNESS {case['name']}: {detail}")
        else:
            failed += 1
            print(f"FAIL {case['name']}: {detail}")

    print(f"\ndual decode: {passed} passed, {failed} failed, {skipped} skipped")
    if failed:
        return 1
    if passed == 0:
        return SKIP_EXIT_CODE
    return 0


if __name__ == "__main__":
    sys.exit(main())
