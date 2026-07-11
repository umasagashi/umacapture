# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Golden integration test for the native recognition pipeline.

Drives the real ``umacapture_cli`` over recorded clips and compares the recognized
``record.json`` set against committed golden files. Each case's input extension picks
the subcommand: an ``.mp4`` (or other plain clip) goes through ``video`` (OpenCV
decode), while an ``.mkv`` is treated as a lossless FFV1 recording and goes through
``replay`` (the recorded frames drive the pipeline directly). This exercises the full
ONNX/WinRT/FFmpeg pipeline end to end, so it depends on local-only assets (the
``.notes`` clips and the ``sandbox/modules`` ONNX models, neither committed).

A case whose input clip -- or the modules dir -- is absent is skipped, not failed,
so a fresh checkout / CI can run this without the data present. If every case is
skipped the process exits 77 (ctest ``SKIP_RETURN_CODE``) so the ctest is reported
Skipped rather than Passed-with-nothing.

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

# Non-deterministic metadata fields, stripped before comparison: a fresh UUID per record, a
# per-run random trainer id, and the wall-clock capture time. Everything else in record.json is a
# deterministic function of the input clip and the model set, and is the actual regression contract.
VOLATILE_METADATA_KEYS = ("record_id", "trainer_id", "captured_date")

# Exit code ctest maps to "Skipped" (see SKIP_RETURN_CODE in CMakeLists.txt). Used when no case
# could run because its local-only inputs were absent.
SKIP_EXIT_CODE = 77

# Generous per-clip ceiling: a multi-record clip runs the whole scrape/stitch/recognize pipeline
# plus the CLI's ~10s idle-drain before it self-terminates.
CLI_TIMEOUT_SECONDS = 900


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


def run_case(case: dict, cli: Path, data_dir: Path, assets_dir: Path, modules_dir: Path) -> tuple[str, object]:
    """Run one case's pipeline.

    Returns ``(kind, payload)``: ``("skip", reason)`` when a local-only input is absent,
    ``("fail", detail)`` on any error, or ``("records", [record, ...])`` on success.
    """
    video = (data_dir / case["video"]).resolve()
    if not video.exists():
        return "skip", f"input clip not found: {video}"
    if not modules_dir.exists():
        return "skip", f"modules dir not found: {modules_dir}"

    with tempfile.TemporaryDirectory(prefix=f"uma_it_{case['name']}_") as tmp:
        output_dir = Path(tmp)
        # An .mkv input is a lossless FFV1 recording (from `capture --record`): feed it through the
        # `replay` subcommand, which reads the recorded frames straight into the pipeline. Anything
        # else is a plain video clip decoded by OpenCV via the `video` subcommand. Both write the same
        # storage/chara_detail/active/*/record.json set, so collection and comparison are identical.
        if video.suffix.lower() == ".mkv":
            input_args = ["replay", "--record", str(video)]
        else:
            input_args = ["video", "--video_path_list", str(video)]
        command = [
            str(cli),
            *input_args,
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
        if completed.returncode != 0:
            tail = completed.stderr.strip().splitlines()[-15:]
            return "fail", "cli exited {}:\n{}".format(completed.returncode, "\n".join(tail))

        actual = collect_records(output_dir)

    if not actual:
        return "fail", "cli produced no record.json (recognition failed or clip yielded nothing)"

    return "records", actual


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="path to umacapture_cli(.exe)")
    parser.add_argument(
        "--data-dir", type=Path, default=HERE.parents[2] / ".notes", help="dir holding the input clips"
    )
    parser.add_argument(
        "--assets-dir", type=Path, default=HERE.parents[2] / "assets" / "config", help="config assets dir"
    )
    parser.add_argument(
        "--modules-dir", type=Path, default=HERE.parents[2] / "sandbox" / "modules", help="ONNX modules dir"
    )
    parser.add_argument("--update-golden", action="store_true", help="overwrite goldens with the current output")
    parser.add_argument("--cases", type=Path, default=HERE / "cases.json", help="cases manifest")
    args = parser.parse_args()

    if not args.cli.exists():
        # The cli is a local-only build artifact: CI (and any checkout that builds only
        # umacapture_tests) deliberately doesn't build it, since it links onnxruntime and
        # needs the uncommitted models/clips to run. Treat its absence like any other absent
        # input -- skip (exit 77) so ctest reports Skipped rather than Failed.
        print(f"SKIP: cli not built: {args.cli}", file=sys.stderr)
        return SKIP_EXIT_CODE

    manifest = json.loads(args.cases.read_text(encoding="utf-8"))
    cases = manifest["cases"]

    passed = skipped = failed = updated = 0
    for case in cases:
        name = case["name"]
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
        golden_path = (HERE / case["golden"]).resolve()
        actual_text = _dumps(actual)

        if args.update_golden:
            golden_path.parent.mkdir(parents=True, exist_ok=True)
            golden_path.write_text(actual_text, encoding="utf-8")
            updated += 1
            print(f"UPDATED {name}: wrote {len(actual)} record(s) -> {golden_path.name}")
            continue

        if not golden_path.exists():
            failed += 1
            print(f"FAIL {name}: no golden at {golden_path} (run with --update-golden to create it)")
            continue

        golden_text = golden_path.read_text(encoding="utf-8")
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
