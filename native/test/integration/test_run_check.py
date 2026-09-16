# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Self-test for run.py's per-run judge (check_run), for the claims it decides from the summary line alone.

WHY THIS EXISTS AS A TEST OF ITS OWN. A golden case exercises a claim only against the numbers the real corpus
happens to produce, and a claim that silently stopped comparing stays green on every case whose declaration is
right. The factor switch verdicts are the sharpest instance: a declaration that matches the run passes whether
or not the judge reads it, so only a DISAGREEING declaration can show the judge is still looking -- and the real
manifest must never carry one. Here the disagreement is synthetic: check_run is imported and fed a hand-built
CompletedProcess, so no cli, clip or model is needed and this runs in CI.

Every check below states the wrong implementation it excludes. Nothing here touches a file.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

_spec = importlib.util.spec_from_file_location("run", HERE / "run.py")
assert _spec is not None and _spec.loader is not None
run = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(run)

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: object = "") -> None:
    if condition:
        print(f"PASS {name}")
    else:
        FAILURES.append(name)
        print(f"FAIL {name}: {detail}")


def verdicts(same: int = 0, different: int = 0, empty: int = 0, unreadable: int = 0) -> dict[str, int]:
    return {"same": same, "different": different, "empty": empty, "unreadable": unreadable}


def case(**extra: object) -> dict:
    """A case every OTHER claim of check_run accepts, so a verdict is the only thing that can fail it."""
    return {"name": "synthetic", "frame_resize": True, "anchor_unit": 720, **extra}


def completed(**summary_overrides: object) -> subprocess.CompletedProcess[str]:
    """A clean run's process, whose summary line carries `summary_overrides` (a None value removes the key)."""
    summary: dict[str, object] = {
        "schema": run.RUN_SUMMARY_SCHEMA,
        "subcommand": "video",
        "unit": "run",
        "inputs": 1,
        "records": 1,
        "failed": 0,
        "discarded": 1,
        "discarded_incomplete": 0,
        "errors": [],
        "error_total": 0,
        "unparsed": 0,
        "forwarded_frames": 10,
        "anchor_unit_min": 720,
        "anchor_unit_max": 720,
        "factor_switch_verdicts": verdicts(different=1),
        "exit": run.CLI_EXIT_OK,
    }
    for key, value in summary_overrides.items():
        if value is None:
            summary.pop(key, None)
        else:
            summary[key] = value
    line = f"{run.RUN_SUMMARY_MARKER} {json.dumps(summary)}"
    return subprocess.CompletedProcess(args=[], returncode=run.CLI_EXIT_OK, stdout="", stderr=line + "\n")


def raises_value_error(declaration: object) -> bool:
    try:
        run.expected_factor_switch_verdicts(case(expect_factor_switch_verdicts=declaration))
    except ValueError:
        return True
    return False


def main() -> int:
    # 1. Positive control: a declaration that matches the run passes, so every failure below is the verdict's.
    result = run.check_run(case(expect_factor_switch_verdicts=verdicts(different=1)), completed())
    check(
        "a declaration that matches the run's verdicts passes",
        result is None,
        # Excludes: a judge that fails every declared case, against which every check below would pass for nothing.
        result,
    )

    # 2. THE CLAIM ITSELF. Each verdict disagreeing on its own, so a judge that compared only some of them -- or
    # summed them, or folded empty into unreadable -- is caught by the verdict it stopped seeing.
    actual = verdicts(same=1, different=2, empty=3, unreadable=4)
    for word in run.FACTOR_SWITCH_VERDICTS:
        declared = dict(actual)
        declared[word] += 1
        result = run.check_run(case(expect_factor_switch_verdicts=declared), completed(factor_switch_verdicts=actual))
        check(
            f"a declaration that disagrees on {word!r} alone fails",
            result is not None and "factor switch rule reached verdicts" in result,
            # Excludes: a judge that ignores the declaration (the whole regression this file exists for), and one
            # that compares only the verdicts that reset or only the total.
            result,
        )
    swapped = verdicts(same=1, different=2, empty=4, unreadable=3)
    result = run.check_run(case(expect_factor_switch_verdicts=swapped), completed(factor_switch_verdicts=actual))
    check(
        "empty and unreadable swapped fails",
        result is not None,
        # Excludes: a judge that compares `empty + unreadable` as one "unread" number, which is the conflation the
        # four separate counts exist to refuse.
        result,
    )

    # 3. An older cli is a rebuild, not a result.
    result = run.check_run(case(expect_factor_switch_verdicts=verdicts()), completed(factor_switch_verdicts=None))
    check(
        "a declared case against a summary without the key fails as an old cli",
        result is not None and "predates" in result,
        # Excludes: reading an absent object as "no verdicts", which passes an all-zero declaration against a cli
        # that cannot count them.
        result,
    )

    # 4. A summary whose vocabulary is not the one declared is refused rather than partly read.
    moved = {"same": 0, "different": 1, "unread": 0}
    result = run.check_run(case(expect_factor_switch_verdicts=verdicts(different=1)), completed(factor_switch_verdicts=moved))
    check(
        "a summary whose verdict words differ fails",
        result is not None and "verdict words" in result,
        # Excludes: comparing only the words both sides share, which would pass `different` and never notice that
        # `empty` and `unreadable` stopped being reported separately.
        result,
    )
    extra = {**verdicts(different=1), "maybe": 0}
    result = run.check_run(case(expect_factor_switch_verdicts=verdicts(different=1)), completed(factor_switch_verdicts=extra))
    check(
        "a summary carrying a verdict word beyond the four fails",
        result is not None and "verdict words" in result,
        # Excludes: a vocabulary check that only asks for the four words to be PRESENT. On its own that still fails
        # this summary, but as a count mismatch that names no word; paired with a comparison over the four words
        # it knows, it passes -- and a verdict added in native/src/chara_detail/factor_switch_verdict.h but not in
        # FACTOR_SWITCH_VERDICTS would go uncounted by every declaration while the four still compare equal.
        result,
    )

    # 5. What an undeclared case asserts: nothing, today (whether a default applies is not decided).
    result = run.check_run(case(), completed(factor_switch_verdicts=verdicts(same=2, empty=1, unreadable=1)))
    check(
        "an undeclared case is not judged on its verdicts",
        result is None,
        # Pins the current contract, not a preference: a default would be a manifest-wide expectation, which is
        # the user's decision. Changing that decision is expected to change this check.
        result,
    )
    result = run.check_run(case(), completed(factor_switch_verdicts=None))
    check("an undeclared case does not require the key", result is None, result)

    # 6. A malformed declaration is refused before a pipeline runs, never read as partial.
    for label, declaration in (
        ("a missing verdict", {"same": 0, "different": 1, "empty": 0}),
        ("an unknown verdict", {**verdicts(), "unread": 0}),
        ("a negative count", verdicts(different=-1)),
        ("a boolean count", {**verdicts(), "same": False}),
        ("a float count", {**verdicts(), "different": 1.0}),
        ("a list", [0, 1, 0, 0]),
        ("null", None),
    ):
        check(
            f"a declaration with {label} is refused",
            raises_value_error(declaration),
            # Excludes: accepting a partial declaration, which asserts nothing -- by omission -- about the verdict
            # left out; and `null` passing for "not stated".
            declaration,
        )

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
        return 1
    print("\nall run-judge checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
