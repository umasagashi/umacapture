# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Self-test for run.py --coverage, the alarm that polices the golden suite's own coverage.

WHY THIS EXISTS AS A TEST OF ITS OWN. `integration_golden_coverage` is the single thing standing
between "this machine exercises fewer golden cases than it used to" and a quiet row of ***Skipped
lines. It cannot check itself: it is registered against the real machine's clips and the real,
gitignored `coverage_baseline.json`, so exercising its failure paths there would mean damaging the
record it protects. Everything it decides, though, is decided from file *existence* -- it runs no
pipeline, needs no cli, no clips and no ONNX models -- so its whole decision table can be driven
against a synthetic manifest in a temporary directory. That also makes this the one integration
test that actually runs in CI instead of skipping.

The defect it pins (measured on the pre-fix code, 2026-08-22): a baseline file that existed but
could not be parsed was read as "no record", so the run rewrote it from the current set and exited
0. The identical loss of one clip therefore exited 1 with an intact baseline and 0 with a truncated
one, and the high-water mark dropped 3 -> 2 with no output distinguishable from a first run.

Every check below states the wrong implementation it excludes. Nothing here touches anything
outside its own TemporaryDirectory.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUN_PY = HERE / "run.py"

CASE_NAMES = ["alpha", "beta", "gamma"]


class Env:
    """A synthetic machine: a fake cli, a modules dir, one clip per case, a private baseline."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.data = root / "data"
        self.modules = root / "modules"
        self.cli = root / "cli.exe"
        self.baseline = root / "baseline.json"
        self.cases = root / "cases.json"
        self.data.mkdir()
        self.modules.mkdir()
        self.cli.write_bytes(b"")
        self.cases.write_text(
            json.dumps({"cases": [{"name": name, "video": f"{name}.mp4"} for name in CASE_NAMES]}),
            encoding="utf-8",
        )
        for name in CASE_NAMES:
            (self.data / f"{name}.mp4").write_bytes(b"")

    def coverage(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(RUN_PY),
                "--coverage",
                "--cli",
                str(self.cli),
                "--cases",
                str(self.cases),
                "--data-dir",
                str(self.data),
                "--modules-dir",
                str(self.modules),
                "--baseline",
                str(self.baseline),
                *extra,
            ],
            capture_output=True,
            text=True,
        )

    def drop_clip(self, name: str) -> None:
        (self.data / f"{name}.mp4").unlink()


FAILURES: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"PASS {name}")
    else:
        FAILURES.append(name)
        print(f"FAIL {name}: {detail}")


def establish(env: Env) -> None:
    """Record a baseline over the full synthetic set. Also the fresh-clone path."""
    result = env.coverage()
    check(
        "an absent baseline is recorded, not failed",
        result.returncode == 0 and "coverage baseline recorded" in result.stdout,
        # Excludes: treating "no baseline yet" as unreadable. That would make the FIRST run red on
        # every clone and every new build tree, since the file is gitignored.
        f"exit={result.returncode} out={result.stdout!r}",
    )


def main() -> int:
    # 1. The alarm works at all (positive control for every "exit 1" check below).
    with tempfile.TemporaryDirectory(prefix="uma_cov_") as tmp:
        env = Env(Path(tmp))
        establish(env)
        recorded = env.baseline.read_text(encoding="utf-8")
        env.drop_clip("gamma")
        result = env.coverage()
        check(
            "a lost clip against an intact baseline fails and names the case",
            result.returncode == 1 and "coverage shrank" in result.stdout and "gamma" in result.stdout,
            # Excludes: an alarm that never fires. Without this, every check below could pass on a
            # build where --coverage always returns 1.
            f"exit={result.returncode} out={result.stdout!r}",
        )
        check(
            "a refused shrink leaves the intact baseline exactly as it found it",
            env.baseline.read_text(encoding="utf-8") == recorded,
            # Excludes: failing loudly but still lowering the mark. Check 2 states that exclusion for
            # the DAMAGED baseline only, and a damaged one is refused while it is being read -- so
            # nothing there constrains the main path, where the file parses and the run then decides
            # whether to write. This is that path: the mark is 3 cases and must still be 3.
            f"before={recorded!r} after={env.baseline.read_text(encoding='utf-8')!r}",
        )
        again = env.coverage()
        check(
            "the shrink alarm keeps firing until the clip comes back",
            again.returncode == 1 and "gamma" in again.stdout,
            # The same exclusion, stated as the consequence rather than as the file's bytes: a gate
            # that lowers the mark is green on the SECOND run, which turns a permanently uncovered
            # case into a one-shot annoyance the developer clears by running ctest twice.
            f"exit={again.returncode} out={again.stdout!r}",
        )

    # 2. THE REGRESSION. The same loss, with the baseline truncated mid-write, must not go green.
    with tempfile.TemporaryDirectory(prefix="uma_cov_") as tmp:
        env = Env(Path(tmp))
        establish(env)
        env.drop_clip("gamma")
        env.baseline.write_text('{ "runn', encoding="utf-8")
        result = env.coverage()
        check(
            "a truncated baseline fails instead of being rewritten from the current set",
            result.returncode == 1 and "unreadable" in result.stdout,
            # Excludes: `except (JSONDecodeError, ...): return None`, i.e. reading a damaged record
            # as "no record". That is the pre-fix code, and it exits 0 here.
            f"exit={result.returncode} out={result.stdout!r}",
        )
        check(
            "a refused run leaves the damaged baseline exactly as it found it",
            env.baseline.read_text(encoding="utf-8") == '{ "runn',
            # Excludes: failing loudly but still lowering the mark, which would make the SECOND run
            # green and the failure a one-shot annoyance rather than a gate.
            f"baseline={env.baseline.read_text(encoding='utf-8')!r}",
        )

    # 3. A structurally wrong baseline is unreadable too, not silently coerced.
    with tempfile.TemporaryDirectory(prefix="uma_cov_") as tmp:
        env = Env(Path(tmp))
        establish(env)
        env.drop_clip("gamma")
        env.baseline.write_text(json.dumps({"runnable": "alpha"}), encoding="utf-8")
        result = env.coverage()
        check(
            "a non-list 'runnable' fails instead of being read character by character",
            result.returncode == 1 and "unreadable" in result.stdout,
            # Excludes: `[str(name) for name in recorded]`, which turned "alpha" into five one-letter
            # case names -- a baseline that can never intersect the real set, i.e. green forever.
            f"exit={result.returncode} out={result.stdout!r}",
        )
        env.baseline.write_text(json.dumps({"cases": CASE_NAMES}), encoding="utf-8")
        result = env.coverage()
        check(
            "a baseline with no 'runnable' key fails",
            result.returncode == 1 and "unreadable" in result.stdout,
            # Excludes: KeyError swallowed as "no record".
            f"exit={result.returncode} out={result.stdout!r}",
        )

    # 4. The intended escape hatch still exists, and only on request.
    with tempfile.TemporaryDirectory(prefix="uma_cov_") as tmp:
        env = Env(Path(tmp))
        establish(env)
        env.drop_clip("gamma")
        env.baseline.write_text('{ "runn', encoding="utf-8")
        result = env.coverage("--accept-coverage")
        recorded = json.loads(env.baseline.read_text(encoding="utf-8"))["runnable"]
        check(
            "--accept-coverage rewrites an unreadable baseline from the current set",
            result.returncode == 0 and recorded == sorted(CASE_NAMES[:2]),
            # Excludes: a refusal with no way out, which would leave a genuinely corrupted file
            # wedging the suite -- the very thing the swallow was written to avoid.
            f"exit={result.returncode} recorded={recorded!r}",
        )

    # 5. An unprovisioned machine (CI) still skips, and never writes a baseline.
    with tempfile.TemporaryDirectory(prefix="uma_cov_") as tmp:
        env = Env(Path(tmp))
        for name in CASE_NAMES:
            env.drop_clip(name)
        result = env.coverage()
        check(
            "no runnable case skips (77) and writes no baseline",
            result.returncode == 77 and not env.baseline.exists(),
            # Excludes: an asset-less run recording an empty high-water mark over a real one.
            f"exit={result.returncode} baseline_exists={env.baseline.exists()}",
        )
        env.cli.unlink()
        result = env.coverage()
        check(
            "an unbuilt cli skips (77)",
            result.returncode == 77,
            # Excludes: turning CI red, where the ONNX-linked cli is deliberately not built.
            f"exit={result.returncode} out={result.stdout!r}",
        )

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
        return 1
    print("\nall coverage-policy checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
