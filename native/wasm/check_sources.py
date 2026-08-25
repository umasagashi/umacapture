# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Mechanical drift checks for the Wasm build's two hand-maintained copies of the pipeline.

Nothing about either copy is enforced by the compiler, and neither shows up as a build failure until somebody
happens to run build.sh:

1.  *The source list.* ``build.sh`` names the ``.cpp`` that go into the module, a third copy after
    ``native/CMakeLists.txt`` and ``windows/runner/CMakeLists.txt``. A new pipeline source that nobody adds
    here is simply absent from the Wasm module. So ``build.sh`` also names the files it deliberately leaves
    out (``EXCLUDED_SOURCES``, each with a reason), and this script requires the two lists together to cover
    ``native/src`` **and** ``native/wasm`` exactly. A new ``.cpp`` under either is then in neither list, and
    that fails. Both roots are partitioned, not just ``native/src``: the module's own bridge sources are named
    by hand in the same array, and one left out of it takes its ``EMSCRIPTEN_BINDINGS`` block with it.

2.  *The recognizer twin.* ``native/wasm/wasm_recognizer_models.cpp`` replaces
    ``native/src/chara_detail/chara_detail_recognizer_models.cpp`` -- same constructors, JS-bridged predictors
    instead of in-process onnxruntime. Adding, removing, or re-signing a recognizer constructor on the desktop
    side compiles fine on Windows and breaks (or silently under-implements) the Wasm build. This script
    compares the out-of-line constructor definitions of the two files and requires them to be identical.

3.  *The manifest's view of the same exclusions.* ``tool/web_deps.json`` pins the built module against a
    digest of the sources it came from (``build.sources``), and that digest deliberately skips the same
    ``.cpp`` files ``EXCLUDED_SOURCES`` skips -- otherwise editing a CLI-only source would report the Wasm pin
    as stale. That is a second copy of the exclusion list, in another file and another language, so this
    script requires the two to be equal.

Run it standalone (no toolchain needed, so it is CI-callable on any runner that has ``uv``)::

    uv run native/wasm/check_sources.py

``build.sh`` runs it before compiling, so a hand build fails on drift too.

Scope, stated plainly: check 2 compares constructor signatures *verbatim* after whitespace normalisation --
parameter names included -- because the two files are meant to be literal mirrors. A parameter renamed on one
side is reported, and the fix is to rename it on the other. It does not compare the enclosing namespaces
(both files nest the definitions identically) and it does not look inside the constructor bodies, which are
the part that is meant to differ.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WASM_DIR = REPO_ROOT / "native" / "wasm"
BUILD_SH = WASM_DIR / "build.sh"
WEB_DEPS = REPO_ROOT / "tool" / "web_deps.json"
NATIVE_SRC = REPO_ROOT / "native" / "src"
DESKTOP_MODELS = NATIVE_SRC / "chara_detail" / "chara_detail_recognizer_models.cpp"
WASM_MODELS = WASM_DIR / "wasm_recognizer_models.cpp"

# build.sh addresses its sources through these two variables; resolve them the same way it does.
PATH_VARS = {
    "${NATIVE_DIR}": (REPO_ROOT / "native").as_posix(),
    "${SCRIPT_DIR}": WASM_DIR.as_posix(),
}

# The directories check 1 partitions: every ``.cpp`` under one of them must be in SOURCES or in
# EXCLUDED_SOURCES. ``native/wasm`` belongs here as much as ``native/src`` does -- the module's OWN sources are
# also named by hand in build.sh, and splitting the 1000-line ``wasm_api.cpp`` is the likeliest way to add one.
# A wasm source nobody adds to SOURCES does not fail to build: it simply is not compiled in, and its
# ``EMSCRIPTEN_BINDINGS`` block goes with it, so the JS side falls through its `typeof Module.x !== 'function'`
# path and the module under-implements its own contract silently. The pin's digest notices the new file (its
# roots include ``native/wasm``), but the pin only says "rebuild"; it does not say "you left this out".
PARTITIONED_ROOTS = (NATIVE_SRC, WASM_DIR)


def fail(lines: list[str]) -> None:
    for line in lines:
        print(line, file=sys.stderr)


def read_bash_array(text: str, name: str) -> list[str]:
    """Extracts the entries of a ``NAME=( ... )`` array from a bash script, dropping comments."""
    match = re.search(rf"^{re.escape(name)}=\((.*?)^\)", text, re.MULTILINE | re.DOTALL)
    if match is None:
        raise SystemExit(f"check_sources: {BUILD_SH} has no {name}=( ... ) array")
    entries = []
    for raw_line in match.group(1).splitlines():
        line = raw_line.split("#", 1)[0].strip().strip('"')
        if line:
            entries.append(line)
    return entries


def resolve(entry: str) -> Path:
    for var, value in PATH_VARS.items():
        entry = entry.replace(var, value)
    return Path(entry)


def check_source_list() -> list[str]:
    text = BUILD_SH.read_text(encoding="utf-8")
    sources = [resolve(e) for e in read_bash_array(text, "SOURCES")]
    excluded = [resolve(e) for e in read_bash_array(text, "EXCLUDED_SOURCES")]

    errors: list[str] = []
    for path in sources + excluded:
        if not path.is_file():
            errors.append(f"  build.sh lists a file that does not exist: {rel(path)}")

    listed = {p.resolve() for p in sources if is_partitioned(p)}
    excluded_set = {p.resolve() for p in excluded}
    for path in sorted(listed & excluded_set):
        errors.append(f"  listed in both SOURCES and EXCLUDED_SOURCES: {rel(path)}")

    on_disk = {p.resolve() for root in PARTITIONED_ROOTS for p in root.rglob("*.cpp")}
    for path in sorted(on_disk - listed - excluded_set):
        errors.append(
            f"  {rel(path)} is in neither SOURCES nor EXCLUDED_SOURCES in native/wasm/build.sh."
            " Add it to SOURCES if the Wasm module needs it, or to EXCLUDED_SOURCES with the reason it does"
            " not."
        )
    for path in sorted((listed | excluded_set) - on_disk):
        if path.is_file():  # outside the partitioned roots (there are none today); nothing to compare it to
            continue
        errors.append(f"  build.sh lists a file that no longer exists: {rel(path)}")
    return errors


def is_partitioned(path: Path) -> bool:
    return any(is_under(path, root) for root in PARTITIONED_ROOTS)


def is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    return True


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


# An out-of-line constructor definition: a qualifier chain whose last two identifiers are equal, e.g.
# `StatusHeaderRecognizer::StatusHeaderRecognizer(` or
# `RaceRecordRecognizer::RaceBlockModelSet::RaceBlockModelSet(`.
#
# THE INDENTATION IS TOLERATED, AND WHAT IT MISSES IS REPORTED. This used to anchor at column 0. Both files
# happen to define everything there today, so nothing was wrong -- but the failure mode was the wrong way
# round: a definition wrapped in an indented `namespace { ... }` block became invisible on BOTH sides at once,
# the two sets stayed equal, and check 2 announced "in sync" for a pair it had stopped comparing. A check that
# guards against a silently under-implemented Wasm build must not fail open, so the anchor now allows leading
# whitespace, and the unanchored probe below re-reads the file to prove the anchored pass missed nothing --
# whatever the next formatting change looks like, rather than only the one variant that was anticipated.
CTOR_RE = re.compile(r"^[ \t]*((?:[A-Za-z_]\w*::)*)([A-Za-z_]\w*)::\2\s*\(", re.MULTILINE)
CTOR_PROBE_RE = re.compile(r"((?:[A-Za-z_]\w*::)*)([A-Za-z_]\w*)::\2\s*\(")


def _ctor_name(match: re.Match[str]) -> str:
    return f"{match.group(1)}{match.group(2)}::{match.group(2)}"


def constructor_signatures(path: Path) -> dict[str, str]:
    text = strip_comments(path.read_text(encoding="utf-8"))
    signatures: dict[str, str] = {}
    for match in CTOR_RE.finditer(text):
        name = _ctor_name(match)
        params = read_balanced(text, match.end() - 1)
        if params is None:
            raise SystemExit(f"check_sources: unbalanced parameter list for {name} in {rel(path)}")
        signatures[name] = normalise(params)

    # Fail closed on anything the anchored pattern could not see. Reaching this is not "the file is wrong": it
    # is "this script can no longer read the file", which has to stop the run rather than quietly compare a
    # subset. Widen CTOR_RE to cover the new spelling.
    unreachable = sorted({_ctor_name(m) for m in CTOR_PROBE_RE.finditer(text)} - set(signatures))
    if unreachable:
        raise SystemExit(
            f"check_sources: {rel(path)} defines constructors this script cannot parse, so the twin comparison"
            f" would silently skip them: {', '.join(unreachable)}"
        )
    return signatures


def read_balanced(text: str, open_index: int) -> str | None:
    """Returns the text between ``text[open_index]`` ('(') and its matching ')'."""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1 : i]
    return None


def normalise(params: str) -> str:
    params = re.sub(r"\s+", " ", params).strip()
    params = re.sub(r"\s*([,&*<>])\s*", r"\1", params)
    return params


def check_recognizer_twin() -> list[str]:
    desktop = constructor_signatures(DESKTOP_MODELS)
    wasm = constructor_signatures(WASM_MODELS)
    errors: list[str] = []
    for name in sorted(set(desktop) - set(wasm)):
        errors.append(f"  {name} is defined in {rel(DESKTOP_MODELS)} but not in {rel(WASM_MODELS)}")
    for name in sorted(set(wasm) - set(desktop)):
        errors.append(f"  {name} is defined in {rel(WASM_MODELS)} but not in {rel(DESKTOP_MODELS)}")
    for name in sorted(set(desktop) & set(wasm)):
        if desktop[name] != wasm[name]:
            errors.append(
                f"  {name} has a different signature in the two files:\n"
                f"    {rel(DESKTOP_MODELS)}: ({desktop[name]})\n"
                f"    {rel(WASM_MODELS)}: ({wasm[name]})"
            )
    if not desktop:
        errors.append(f"  no constructor definitions found in {rel(DESKTOP_MODELS)} -- the check parsed nothing")
    return errors


def check_manifest_exclusions() -> list[str]:
    """Requires every in-tree pin's ``build.sources.exclude`` to name exactly ``EXCLUDED_SOURCES``."""
    if not WEB_DEPS.is_file():
        return [f"  {rel(WEB_DEPS)} is missing, so the Wasm pin's source digest cannot be cross-checked"]
    manifest = json.loads(WEB_DEPS.read_text(encoding="utf-8"))
    excluded = read_bash_array(BUILD_SH.read_text(encoding="utf-8"), "EXCLUDED_SOURCES")
    expected = sorted(rel(resolve(entry)) for entry in excluded)

    errors: list[str] = []
    for key, entry in manifest["files"].items():
        if entry.get("origin") != "in-tree":
            continue
        sources = entry.get("build", {}).get("sources")
        if sources is None:
            errors.append(
                f"  web/{key} is origin 'in-tree' but has no build.sources block in {rel(WEB_DEPS)};"
                " without it nothing compares the pinned artifact with the sources it was built from"
            )
            continue
        actual = sorted(sources.get("exclude", []))
        if actual != expected:
            errors.append(
                f"  web/{key}'s build.sources.exclude in {rel(WEB_DEPS)} does not match"
                " EXCLUDED_SOURCES in native/wasm/build.sh:\n"
                f"    build.sh:      {expected}\n"
                f"    web_deps.json: {actual}"
            )
    return errors


def main() -> int:
    failures = 0

    errors = check_source_list()
    if errors:
        failures += 1
        fail(["native/wasm/build.sh no longer describes native/src and native/wasm:"] + errors)

    errors = check_recognizer_twin()
    if errors:
        failures += 1
        fail(
            [
                "the Wasm recognizer TU has drifted from its desktop twin"
                " (wasm_recognizer_models.cpp must define the same constructors as"
                " chara_detail_recognizer_models.cpp):"
            ]
            + errors
        )

    errors = check_manifest_exclusions()
    if errors:
        failures += 1
        fail(["the Wasm pin's source-digest selection has drifted from native/wasm/build.sh:"] + errors)

    if failures:
        return 1
    print("check_sources: source list, recognizer twin and manifest exclusions are in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
