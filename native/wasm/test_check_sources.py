# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Self-test for check_sources.py's comment/string stripping (strip_comments) and the two probes that read
its output: CTOR_PROBE_RE (an out-of-line constructor definition) and instantiations() (which raises on a
duplicate explicit makePredictor<Decoder> instantiation).

WHY THIS EXISTS AS A TEST OF ITS OWN. strip_comments feeds both probes check_predictor_factory runs over
chara_detail_recognizer_models.cpp and wasm_recognizer_models.cpp, and today's tree carries none of the
constructs that would expose a stripping defect: a hand-built input is the only way to drive one. A two-pass
strip that removes block comments (`/\\*.*?\\*/`) before line
comments reads a "/*" inside a line comment or a string literal as an unterminated block comment and deletes
every line up to the next "*/", carrying an out-of-line constructor or a duplicated instantiation out of the
probes' input along with it. Each check below states the wrong (two-pass) implementation it excludes, and
each is exercised with hand-built text: no clip, model or cli is needed and this runs in CI.
"""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

_spec = importlib.util.spec_from_file_location("check_sources", HERE / "check_sources.py")
assert _spec is not None and _spec.loader is not None
check_sources = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_sources)

FAILURES: list[str] = []


def check(name: str, condition: bool, detail: object = "") -> None:
    if condition:
        print(f"PASS {name}")
    else:
        FAILURES.append(name)
        print(f"FAIL {name}: {detail}")


def ctor_names(text: str) -> set[str]:
    """What check_predictor_factory's constructor probe sees after strip_comments."""
    stripped = check_sources.strip_comments(text)
    return {check_sources._ctor_name(m) for m in check_sources.CTOR_PROBE_RE.finditer(stripped)}


def instantiated_decoders(text: str) -> dict[str, str]:
    """What instantiations() reads from `text` as if it were a platform models file (extern=False)."""
    with tempfile.TemporaryDirectory(prefix="uma_check_sources_test_") as tmp:
        path = Path(tmp) / "models.cpp"
        path.write_text(text, encoding="utf-8")
        return check_sources.instantiations(path, extern=False)


def main() -> int:
    # Case A: a line comment that happens to contain "/*", with a real out-of-line constructor and a block
    # comment further down. A two-pass strip reads the "/*" in the line comment as a block-comment start and
    # deletes everything up to the block comment's "*/", carrying the constructor away with it.
    case_a = (
        "// Models are looked up as modules/*.onnx by the JS side.\n"
        "Foo::Foo(int x) {}\n"
        "/* end of file note */\n"
    )
    check(
        "A: a ctor after a line comment containing '/*' is found",
        ctor_names(case_a) == {"Foo::Foo"},
        # Excludes: a two-pass strip, which reads the line comment's "/*" as a block-comment start and deletes
        # through the trailing "/* end of file note */", taking the ctor line with it.
        ctor_names(case_a),
    )

    # Case D: the same shape, but the "/*" sits inside a string literal (not a comment) instead of a line
    # comment. A correct strip must leave string contents alone.
    case_d = (
        'static const char *kGlob = "modules/*.onnx";\n'
        "Foo::Foo(int x) {}\n"
        "/* end */\n"
    )
    check(
        "D: a ctor after a string literal containing '/*' is found",
        ctor_names(case_d) == {"Foo::Foo"},
        # Excludes: a two-pass strip, which reads the string literal's "/*" as a block-comment start (strings
        # are not a distinct token to a strip that only removes /* .. */ and // .. \n) and deletes through the
        # trailing "/* end */", taking the ctor line with it.
        ctor_names(case_d),
    )

    # Case E: a line comment containing "/*", followed by a duplicated explicit instantiation, followed by a
    # block comment. instantiations() must see BOTH copies and raise on the duplicate.
    case_e = (
        "// modules/*\n"
        "template PredictorFor<IndexDecoder> makePredictor<IndexDecoder>(const std::string &path);\n"
        "template PredictorFor<IndexDecoder> makePredictor<IndexDecoder>(const std::string &path);\n"
        "/* x */\n"
    )
    try:
        instantiated_decoders(case_e)
        raised = None
    except SystemExit as exc:
        raised = str(exc)
    check(
        "E: a duplicated instantiation after a line comment containing '/*' is caught",
        raised is not None and "instantiates makePredictor<IndexDecoder> twice" in raised,
        # Excludes: a two-pass strip, which reads the line comment's "/*" as a block-comment start and deletes
        # through the trailing "/* x */", carrying both instantiation lines away with it -- so instantiations()
        # sees neither copy and never raises.
        raised,
    )

    # Negative controls: none of these carry a constructor a probe should ever report, and strip_comments must
    # stay quiet on all four.

    # Case F: the constructor is entirely inside a block comment.
    case_f = "/* Foo::Foo(int x) {} */\n"
    check("F: a ctor entirely inside a block comment is not found", ctor_names(case_f) == set(), ctor_names(case_f))

    # Case G: the constructor is entirely inside a line comment.
    case_g = "// Foo::Foo(int x) {}\n"
    check("G: a ctor entirely inside a line comment is not found", ctor_names(case_g) == set(), ctor_names(case_g))

    # Case H: a line comment containing an apostrophe (a possible char-literal opener) followed by "/*". The
    # apostrophe must not be read as the start of a char literal that swallows the rest of the line, and the
    # whole line must strip to nothing -- not to a truncated remainder that a later probe could misparse.
    case_h = "// the recognizer's runner /* here */\n"
    check(
        "H: an apostrophe in a line comment does not start a char literal",
        check_sources.strip_comments(case_h) == "\n",
        check_sources.strip_comments(case_h),
    )
    check("H: no ctor is found either", ctor_names(case_h) == set(), ctor_names(case_h))

    # Case I: a string literal containing "//". The "//" inside the string must not be read as a line-comment
    # start -- the whole literal, including its closing quote and the statement's semicolon, must survive
    # unstripped.
    case_i = 'static const char *kNote = "a // b /* c */ d";\n'
    check(
        "I: a string literal containing '//' is left untouched",
        check_sources.strip_comments(case_i) == case_i,
        # Excludes both a two-pass strip (which reads the string's "/* c */" as a real block comment and
        # removes it, then reads the remaining "// b ... d\";" as a line comment and removes the rest of the
        # line including the closing quote and semicolon) and a one-pass strip that blanks string literals
        # instead of keeping them: normalise() compares instantiations' parameter lists as text, so a blanked
        # string in a default argument would desync the header's declaration from a platform's definition.
        check_sources.strip_comments(case_i),
    )

    # Baseline: the real three files this check reads (recognizer_prediction.h, chara_detail_recognizer_models.cpp,
    # wasm_recognizer_models.cpp) carry none of the above constructs, so strip_comments must report zero errors
    # on them. This case does NOT exercise a strip that blanks string literals instead of keeping them: measured,
    # it stays green under that defect too, because none of the three files' compared instantiation parameter
    # lists contains a string literal. Case I above is the sole detector of that defect.
    check(
        "baseline: the real predictor-factory files report no drift",
        check_sources.check_predictor_factory() == [],
        check_sources.check_predictor_factory(),
    )

    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed: {', '.join(FAILURES)}")
        return 1
    print("\nall check_sources strip_comments checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
