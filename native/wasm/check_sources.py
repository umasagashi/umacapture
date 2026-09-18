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

2.  *The predictor factory.* The recognizers' constructors and decoders are shared code
    (``native/src/chara_detail/chara_detail_recognizer.cpp``); what each platform supplies is
    ``makePredictor``, declared in ``native/src/chara_detail/recognizer_prediction.h`` and defined, with one
    explicit instantiation per decoder, in ``native/src/chara_detail/chara_detail_recognizer_models.cpp``
    (desktop, in-process onnxruntime) and ``native/wasm/wasm_recognizer_models.cpp`` (Wasm, JS bridge). A
    decoder instantiated on the desktop side only compiles and links on Windows and breaks the Wasm link, which
    CI never runs. This script requires both definitions to instantiate exactly the decoders the header
    declares, with the declaration's parameter list, and requires neither file to define a constructor: a
    constructor copied back into one of them would be a second, unchecked copy of the shared one.

3.  *The manifest's view of the same exclusions.* ``tool/web_deps.json`` pins the built module against a
    digest of the sources it came from (``build.sources``), and that digest deliberately skips the same
    ``.cpp`` files ``EXCLUDED_SOURCES`` skips -- otherwise editing a CLI-only source would report the Wasm pin
    as stale. That is a second copy of the exclusion list, in another file and another language, so this
    script requires the two to be equal.

Run it standalone (no toolchain needed, so it is CI-callable on any runner that has ``uv``)::

    uv run native/wasm/check_sources.py

``build.sh`` runs it before compiling, so a hand build fails on drift too.

Scope, stated plainly: check 2 compares the explicit instantiations as text, after whitespace normalisation,
with the header's ``extern template`` declarations. It does not compare the enclosing namespaces (all three
files nest them identically), and it does not look inside the two ``makePredictor`` bodies, which are the part
that is meant to differ. The test target's fake definition (under ``native/test/``) is not compared here: CI
links it, so a decoder it lacks fails there.
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
PREDICTOR_HEADER = NATIVE_SRC / "chara_detail" / "recognizer_prediction.h"
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


# One left-to-right scan: whichever of these starts first wins, so a "/*" inside a line comment or a string
# literal is text, and a "//" inside a string literal is text. A two-pass strip (block comments first) reads
# such a "/*" as the start of a comment and deletes every line up to the next "*/", hiding whatever stands
# between them from both probes below. Comments become empty; literals are kept, because the probes read the
# code around them. Raw string literals (R"(...)") are not handled: these sources contain none.
_COMMENT_OR_LITERAL_RE = re.compile(r"""//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'""", re.DOTALL)


def _strip_comments_replace(match: re.Match[str]) -> str:
    token = match.group(0)
    if token.startswith("//"):
        return ""
    if token.startswith("/*"):
        return " " + "\n" * token.count("\n")
    return token


def strip_comments(text: str) -> str:
    return _COMMENT_OR_LITERAL_RE.sub(_strip_comments_replace, text)


# An out-of-line constructor definition: a qualifier chain whose last two identifiers are equal, e.g.
# `StatusHeaderRecognizer::StatusHeaderRecognizer(` or
# `RaceRecordRecognizer::RaceBlockModelSet::RaceBlockModelSet(`. Unanchored, so neither indentation nor a
# wrapping namespace block can hide one: check 2 requires it to find nothing in either platform file.
CTOR_PROBE_RE = re.compile(r"((?:[A-Za-z_]\w*::)*)([A-Za-z_]\w*)::\2\s*\(")

# An explicit instantiation of makePredictor, up to its terminating semicolon. The header holds explicit
# instantiation *declarations* (`extern template ...`); the platform files hold the definitions.
#
# FAIL CLOSED ON WHAT THE PATTERN CANNOT READ. The probe finds every `makePredictor<` that follows a `template`
# keyword within one statement; one the anchored pattern did not capture stops the run, so a new spelling makes
# the check refuse to answer instead of comparing a subset.
INSTANTIATION_RE = re.compile(
    r"^[ \t]*(extern[ \t]+)?template[ \t]+PredictorFor<(\w+)>[ \t]+makePredictor<(\w+)>\s*(\([^;]*\))\s*;",
    re.MULTILINE,
)
INSTANTIATION_PROBE_RE = re.compile(r"\btemplate\b[^;{}]*?\bmakePredictor\s*<")


def _ctor_name(match: re.Match[str]) -> str:
    return f"{match.group(1)}{match.group(2)}::{match.group(2)}"


def instantiations(path: Path, *, extern: bool) -> dict[str, str]:
    """Maps each decoder ``makePredictor`` is explicitly instantiated for to its normalised parameter list."""
    text = strip_comments(path.read_text(encoding="utf-8"))
    found: dict[str, str] = {}
    spans: list[tuple[int, int]] = []
    for match in INSTANTIATION_RE.finditer(text):
        spans.append(match.span())
        decoder = match.group(3)
        if bool(match.group(1)) != extern:
            wrong = "an explicit instantiation definition" if extern else "an extern template declaration"
            raise SystemExit(f"check_sources: {rel(path)} holds {wrong} of makePredictor<{decoder}>")
        if match.group(2) != decoder:
            raise SystemExit(
                f"check_sources: {rel(path)} instantiates makePredictor<{decoder}> returning"
                f" PredictorFor<{match.group(2)}>"
            )
        if decoder in found:
            raise SystemExit(f"check_sources: {rel(path)} instantiates makePredictor<{decoder}> twice")
        found[decoder] = normalise(match.group(4))

    unread = [m.start() for m in INSTANTIATION_PROBE_RE.finditer(text) if not any(a <= m.start() < b for a, b in spans)]
    if unread:
        line = text.count("\n", 0, unread[0]) + 1
        raise SystemExit(
            f"check_sources: {rel(path)} instantiates makePredictor in a form this script cannot parse (first at"
            f" line {line} of the comment-stripped text), so the comparison would silently skip it."
            " Widen INSTANTIATION_RE."
        )
    return found


def normalise(params: str) -> str:
    params = re.sub(r"\s+", " ", params).strip()
    params = re.sub(r"\s*([,&*<>()])\s*", r"\1", params)
    return params


def check_predictor_factory() -> list[str]:
    declared = instantiations(PREDICTOR_HEADER, extern=True)
    errors: list[str] = []
    if not declared:
        errors.append(
            f"  no extern template makePredictor declarations found in {rel(PREDICTOR_HEADER)}"
            " -- the check parsed nothing"
        )
    for path in (DESKTOP_MODELS, WASM_MODELS):
        defined = instantiations(path, extern=False)
        for decoder in sorted(set(declared) - set(defined)):
            errors.append(
                f"  {rel(path)} does not instantiate makePredictor<{decoder}>, which"
                f" {rel(PREDICTOR_HEADER)} declares"
            )
        for decoder in sorted(set(defined) - set(declared)):
            errors.append(
                f"  {rel(path)} instantiates makePredictor<{decoder}>, which {rel(PREDICTOR_HEADER)}"
                " does not declare"
            )
        for decoder in sorted(set(declared) & set(defined)):
            if declared[decoder] != defined[decoder]:
                errors.append(
                    f"  makePredictor<{decoder}> has a different parameter list in {rel(path)}:\n"
                    f"    {rel(PREDICTOR_HEADER)}: {declared[decoder]}\n"
                    f"    {rel(path)}: {defined[decoder]}"
                )
        text = strip_comments(path.read_text(encoding="utf-8"))
        for name in sorted({_ctor_name(m) for m in CTOR_PROBE_RE.finditer(text)}):
            errors.append(
                f"  {rel(path)} defines the constructor {name}; the recognizers' constructors belong in the"
                " shared chara_detail_recognizer.cpp, and this file defines only makePredictor"
            )
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

    errors = check_predictor_factory()
    if errors:
        failures += 1
        fail(
            [
                "a platform definition of makePredictor has drifted from recognizer_prediction.h"
                " (chara_detail_recognizer_models.cpp and wasm_recognizer_models.cpp must each instantiate"
                " exactly the declared decoders, and define no recognizer constructor):"
            ]
            + errors
        )

    errors = check_manifest_exclusions()
    if errors:
        failures += 1
        fail(["the Wasm pin's source-digest selection has drifted from native/wasm/build.sh:"] + errors)

    if failures:
        return 1
    print("check_sources: source list, predictor factory and manifest exclusions are in sync")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
