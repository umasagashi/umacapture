# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Self-test for run.py's per-run judges: check_run (the claims it decides from the summary line alone) and
check_probe_factors (the strict onFactorProbe check for the early duplicate probe's payload).

WHY THIS EXISTS AS A TEST OF ITS OWN. A golden case exercises a claim only against the numbers the real corpus
happens to produce, and a claim that silently stopped comparing stays green on every case whose declaration is
right. The factor switch verdicts are the sharpest instance for check_run: a declaration that matches the run
passes whether or not the judge reads it, so only a DISAGREEING declaration can show the judge is still looking
-- and the real manifest must never carry one. check_probe_factors has the same shape for its own claim: it
must actually fail a probe that disagrees with the golden record at an index inside the layout's
self-factor-count threshold (not merely one that is too short or too long), and it must actually fail a probe
that agrees on everything it sent but, when the core states its read ended below that threshold, does not
match the golden record's own self-factor count. Both judges are exercised with hand-built input: a
CompletedProcess for check_run, and a CompletedProcess plus a temporary golden fixture for check_probe_factors
-- so no cli, clip or model is needed and this runs in CI.

Every check below states the wrong implementation it excludes. The check_run section touches no file; the
check_probe_factors section writes its golden fixtures under a TemporaryDirectory it also cleans up.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
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


def factor(id_: int, star: int) -> dict:
    """One `factors.self` entry, in the shape both the golden files and onFactorProbe carry it."""
    return {"id": id_, "star": star}


def golden_file(directory: Path, *selves: list[dict]) -> Path:
    """Write a golden manifest (one record per `selves` entry) under `directory` and return its path.

    `run.golden_path()` resolves a case's `golden` value as `run.HERE / golden`, and for an ABSOLUTE
    operand `Path.__truediv__` ignores the left side entirely (pathlib: "if the argument is an
    absolute path, the previous path is ignored") -- so handing it this fixture's absolute path
    reaches the fixture regardless of where run.py's own HERE is, with no monkeypatching needed.
    """
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "golden.json"
    path.write_text(json.dumps([{"factors": {"self": list(self_)}} for self_ in selves]), encoding="utf-8")
    return path


def probe_case(golden: Path, **extra: object) -> dict:
    """A case every OTHER claim of check_probe_factors accepts (an absolute, existing golden), so the
    probe comparison is the only thing that can fail it."""
    return {"name": "synthetic_probe", "expect_probe_matches_golden_self": True, "golden": str(golden), **extra}


ABSENT = object()
"""Marks a probe field that is left off the line entirely -- not the same message as a JSON `null`."""


def probe_completed(*probes: list[dict], below_threshold: object) -> subprocess.CompletedProcess[str]:
    """A completed process whose stdout carries one onFactorProbe line per entry in `probes`.

    `below_threshold` is required so that no case gets a flag by default -- the thing under test is that
    the judge takes it from the line; pass ABSENT to leave the field out. `record_type` and the numeric
    `match_threshold` are no longer on the wire at all: the message carries only `factors`,
    `below_threshold`, and (unused by this check) `cue_owed`.

    Written with `separators=(",", ":")` (no space after ':'), matching the CLI's actual compact
    on-wire JSON -- PROBE_MARKER is `'{"type":"onFactorProbe"'` with no space, and a json.dumps using
    the default separators would not be found as that substring.
    """
    lines = []
    for factors in probes:
        message: dict = {"type": "onFactorProbe", "factors": factors}
        if below_threshold is not ABSENT:
            message["below_threshold"] = below_threshold
        lines.append(json.dumps(message, separators=(",", ":")))
    stdout = "\n".join(lines) + ("\n" if lines else "")
    return subprocess.CompletedProcess(args=[], returncode=run.CLI_EXIT_OK, stdout=stdout, stderr="")


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

    # 7. check_probe_factors -- the STRICT onFactorProbe check. Nothing here is read out of the product and
    # nothing pins a shipped value (the native config tests do that). There is no numeric threshold on the
    # wire at all any more: `factors` arrives already capped to the factor-tab layout's self-factor-count
    # threshold (the core trims before sending), and `below_threshold` is the core's own statement of whether
    # that cap or the list's own end produced the length sent. `small_count` / `large_count` below are two
    # arbitrary sizes fixtures use to build lists of different lengths; neither is a shipped value.
    small_count, large_count = 10, 14

    with tempfile.TemporaryDirectory(prefix="uma_it_probe_check_") as tmp:
        tmp_path = Path(tmp)

        # 7a. POSITIVE CONTROL. Every element the probe sent agrees with the golden self list, and
        # below_threshold is false -- the ordinary continuing-list case, which owes no count requirement at
        # all: passes regardless of how the length compares to anything. Every failure below is the strict
        # comparison's own.
        own_a = [factor(i, 1) for i in range(large_count + 2)]
        result = run.check_probe_factors(
            probe_case(golden_file(tmp_path / "a", own_a)),
            probe_completed(own_a, below_threshold=False),
        )
        check("a probe that agrees on every element, below_threshold false, passes", result is None, result)

        # 7a2. WITHIN-CAP DISAGREEMENT IS STILL CAUGHT. This change dropped coverage for a disagreement
        # PAST the layout's self-factor-count threshold (7b, removed below), but a disagreement AT AN
        # INDEX INSIDE the threshold is exactly the defect class this file's own module docstring names
        # as the reason check_probe_factors exists at all, and every other fixture in this section uses
        # the same list verbatim as both the probe and the golden source, so none of them can ever
        # disagree. This one deliberately can.
        own_a2 = [factor(i, 1) for i in range(small_count)]
        probe_a2 = list(own_a2)
        probe_a2[4] = factor(9999, 9)  # index 4 is inside the cap (small_count); only this element differs
        result = run.check_probe_factors(
            probe_case(golden_file(tmp_path / "a2", own_a2)),
            probe_completed(probe_a2, below_threshold=False),
        )
        check(
            "a within-cap element disagreement fails, and the message names the index",
            result is not None and "index 4" in result,
            # Excludes: a judge whose element-wise agreement check was deleted or weakened to a length/
            # count comparison -- it would pass this silently, since probe_a2 and own_a2 have equal length.
            result,
        )

        # 7b [removed, no replacement]. The old fixture modeled a probe LONGER than the layout's
        # self-factor-count threshold whose trailing element (past the threshold) disagreed with the
        # golden record. Under the new contract `factors` on the wire never carries more than the
        # threshold to begin with -- the core trims before sending -- so there is no real onFactorProbe
        # this scenario could model any more, and the coverage it gave (catching a defect at an index
        # past the threshold) has no substitute in this file. This is an accepted, deliberate loss of
        # coverage, not an oversight.

        # 7c. below_threshold TRUE, agrees on everything sent, and the golden record's own self-factor
        # count equals the probe's length: passes. The old matching rule (leading-run agreement against
        # the threshold, with no count check) could never reach this case at all: it required the leading
        # run to reach the threshold, so a record with fewer self-factors than the threshold never
        # matched under it. The count check added here is what lets such a record match.
        own_c = [factor(i, 1) for i in range(small_count - 1)]
        result = run.check_probe_factors(
            probe_case(golden_file(tmp_path / "c", own_c)),
            probe_completed(own_c, below_threshold=True),
        )
        check(
            "a probe that agrees on everything, below_threshold true, with a matching golden count, passes",
            result is None,
            result,
        )

        # 7c (continued). below_threshold TRUE, agrees on everything the probe sent, but the golden record
        # has MORE self-factors than the probe read: fails. The other half of the same gap -- a probe that
        # merely stopped early because the character has fewer self-factors than the cap must not match a
        # longer record on a prefix that says nothing about the count.
        own_c2 = [factor(i, 1) for i in range(small_count + 2)]
        probe_c2 = own_c2[: small_count - 1]
        result = run.check_probe_factors(
            probe_case(golden_file(tmp_path / "c2", own_c2)),
            probe_completed(probe_c2, below_threshold=True),
        )
        check(
            "a probe that agrees on everything sent, below_threshold true, against a longer golden record, fails",
            result is not None and "would not fire" in result,
            # Excludes: a judge that reads full agreement on the elements sent as sufficient by itself,
            # without also checking below_threshold's count requirement.
            result,
        )

        # 7d. THE FLAG ON THE LINE IS WHAT DECIDES. One golden record, one probe that is a strict prefix of
        # it (so the golden record is longer than the probe either way) -- only `below_threshold` differs
        # between the two runs, so only a judge that reads it can pass the first and fail the second.
        own_d = [factor(i, 1) for i in range(small_count + 2)]
        probe_d = own_d[:small_count]
        golden_d = golden_file(tmp_path / "d", own_d)
        result = run.check_probe_factors(probe_case(golden_d), probe_completed(probe_d, below_threshold=False))
        check(
            "a prefix that agrees on everything sent passes when the probe states below_threshold false",
            result is None,
            # Excludes: a judge that always requires the count to match, which this scenario would fail.
            result,
        )
        result = run.check_probe_factors(probe_case(golden_d), probe_completed(probe_d, below_threshold=True))
        check(
            "the same prefix fails when the probe states below_threshold true (the golden record is longer)",
            result is not None and "would not fire" in result,
            # Excludes: a judge that ignores below_threshold outright, or one with no count requirement ever.
            result,
        )

        # 7e. NO FLAG ON THE LINE, NO VERDICT. The probe agrees on every element it sent, which passes
        # under either boolean value of below_threshold (there is no length to compare against any more) --
        # so only refusing on a missing or malformed field can fail this.
        own_e = [factor(i, 1) for i in range(large_count + 2)]
        golden_e = golden_file(tmp_path / "e", own_e)
        result = run.check_probe_factors(probe_case(golden_e), probe_completed(own_e, below_threshold=False))
        check(
            "positive control for 7e: the same probe with a stated below_threshold passes",
            result is None,
            # Excludes: the refusals below being the comparison's rather than the missing field's.
            result,
        )
        for label, value in [
            ("absent", ABSENT),
            ("null", None),
            ("a string", "true"),
            ("a float", 1.0),
            ("an int", 1),
            ("a list", [True]),
        ]:
            result = run.check_probe_factors(probe_case(golden_e), probe_completed(own_e, below_threshold=value))
            check(
                f"a probe whose below_threshold is {label} is refused",
                result is not None and "no boolean below_threshold" in result,
                # Excludes: a judge that falls back to a default flag -- every plausible one passes this
                # probe, since it agrees on every element it sent regardless of the flag's value.
                result,
            )

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
        return 1
    print("\nall run-judge checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
