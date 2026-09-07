#!/usr/bin/env bash
# Tests for tool/hooks/pre-commit's color-literal gate.
#
#   bash tool/hooks/test_pre_commit.sh
#
# Every case runs the real hook script in a throwaway git repository created under
# $TMPDIR, so the repository you are sitting in is never staged, never committed to
# and never left with its gate disabled. $DART is pointed at a stub: the web-pin and
# `dart format` gates run ahead of the colour gate and are not what is under test
# here, and stubbing them is what lets this file run anywhere bash and git do,
# without an SDK.
#
# The point of the file is the third outcome. `grep` answers 0 for "matched", 1 for
# "matched nothing" and 2 for "I could not run"; the gate used to end its grep with
# `|| true`, which said "matched nothing" to all three. A `color_pattern` that
# stopped compiling therefore turned the gate off silently -- grep printed its
# complaint, the hook exited 0, and every commit still looked clean. `broken_pattern`
# below is that state, reproduced on a copy of the hook, and it must now be refused.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
hook="$repo_root/tool/hooks/pre-commit"

failures=0
cases=0

fail() {
  echo "  FAIL: $*" >&2
  failures=$((failures + 1))
}

# A scratch repository with one commit, a stub SDK, and the hook copied in. Echoes
# its path. Callers stage what they like and then run `run_hook`.
make_repo() {
  local dir
  dir="$(mktemp -d)"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email hook-test@example.invalid
  git -C "$dir" config user.name "hook test"
  git -C "$dir" config core.autocrlf false
  mkdir -p "$dir/lib/src/gui" "$dir/bin"
  printf 'void main() {}\n' > "$dir/lib/seed.dart"
  git -C "$dir" add lib/seed.dart
  git -C "$dir" commit -q -m seed
  # Stands in for .fvm/flutter_sdk/bin/dart: accepts `run tool/check_web_pins.dart`
  # and `format`, and reports success for both. It also appends its own argument
  # list to dart-calls.log (relative to $dir, which run_hook cd's into) so a case
  # can assert that a given path was actually handed to `dart format`, not just
  # that the hook's overall exit code was some particular value. This does not
  # change the stub's exit-0 behaviour, so it has no effect on any existing case.
  cat > "$dir/bin/dart-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> dart-calls.log
exit 0
STUB
  chmod +x "$dir/bin/dart-stub"
  cp "$hook" "$dir/bin/pre-commit"
  echo "$dir"
}

# run_hook <repo> [hook-file] -> prints combined output, returns the hook's status.
run_hook() {
  local dir="$1"
  local script="${2:-$dir/bin/pre-commit}"
  (cd "$dir" && DART="$dir/bin/dart-stub" bash "$script" 2>&1)
}

# Rewrites color_pattern in a copy of the hook so it is no longer a valid POSIX ERE.
# `\bColor\((0` leaves a group open; GNU grep answers exit 2 and "Unmatched ( or \(".
break_pattern() {
  local dir="$1"
  sed -E "s|^color_pattern=.*|color_pattern='\\\\bColor\\\\((0'|" \
    "$dir/bin/pre-commit" > "$dir/bin/pre-commit-broken"
  grep -q "^color_pattern='" "$dir/bin/pre-commit-broken" \
    || fail "break_pattern did not rewrite color_pattern -- the test itself is stale"
}

check() {
  local name="$1" expected="$2" actual="$3" output="$4"
  cases=$((cases + 1))
  if [ "$actual" -eq "$expected" ]; then
    echo "ok   $name"
  else
    echo "not ok  $name" >&2
    fail "$name: expected exit $expected, got $actual"
    printf '%s\n' "$output" | sed 's/^/       | /' >&2
  fi
}

# --- 1. a staged Dart file with no colour literal is accepted ------------------
d="$(make_repo)"
printf 'import "x.dart";\nWidget b() => Text(style: t.bodyLarge);\n' > "$d/lib/ok.dart"
git -C "$d" add lib/ok.dart
out="$(run_hook "$d")"; st=$?
check "clean added lines pass" 0 "$st" "$out"
rm -rf "$d"

# --- 2. a newly added colour literal is rejected -------------------------------
d="$(make_repo)"
printf 'const c = Color(0xFF112233);\n' > "$d/lib/bad.dart"
git -C "$d" add lib/bad.dart
out="$(run_hook "$d")"; st=$?
check "added Color(0x… is rejected" 1 "$st" "$out"
cases=$((cases + 1))
if printf '%s' "$out" | grep -q 'raw color literals'; then
  echo "ok   rejection names the rule"
else
  echo "not ok  rejection names the rule" >&2
  fail "rejection did not mention the colour rule"
fi
rm -rf "$d"

# --- 3. Colors.transparent is structural and stays allowed ---------------------
d="$(make_repo)"
printf 'const c = Colors.transparent;\n' > "$d/lib/clear.dart"
git -C "$d" add lib/clear.dart
out="$(run_hook "$d")"; st=$?
check "Colors.transparent passes" 0 "$st" "$out"
rm -rf "$d"

# --- 4. the allowlisted theme file may hold the canonical literals -------------
d="$(make_repo)"
printf 'const c = Color(0xFF112233);\n' > "$d/lib/src/gui/theme_extensions.dart"
git -C "$d" add lib/src/gui/theme_extensions.dart
out="$(run_hook "$d")"; st=$?
check "allowlisted file passes" 0 "$st" "$out"
rm -rf "$d"

# --- 5. THE REGRESSION: a color_pattern that does not compile must stop the -----
#        commit, not be read as "no colour literals found".
d="$(make_repo)"
break_pattern "$d"
printf 'const c = Color(0xFF112233);\n' > "$d/lib/bad.dart"
git -C "$d" add lib/bad.dart
out="$(run_hook "$d" "$d/bin/pre-commit-broken")"; st=$?
check "an uncompilable color_pattern refuses the commit" 1 "$st" "$out"
cases=$((cases + 1))
if printf '%s' "$out" | grep -q 'could not run'; then
  echo "ok   the refusal says the check could not run"
else
  echo "not ok  the refusal says the check could not run" >&2
  fail "a broken pattern was refused, but not for the stated reason: $out"
fi
rm -rf "$d"

# --- 6. …and it must do so even when nothing colour-like is staged, because -----
#        "no hits" is exactly the answer the broken gate used to fake.
d="$(make_repo)"
break_pattern "$d"
printf 'void f() {}\n' > "$d/lib/plain.dart"
git -C "$d" add lib/plain.dart
out="$(run_hook "$d" "$d/bin/pre-commit-broken")"; st=$?
check "an uncompilable color_pattern is caught on a clean diff too" 1 "$st" "$out"
rm -rf "$d"

# --- 7. the shell semantics the gate used to rely on ---------------------------
#        Not a test of the hook: a standing record of why case 5 exists, so the
#        collapse stays visible even after the line that performed it is gone.
cases=$((cases + 1))
legacy="$(grep -E '\bColor\((0' <<< 'const c = Color(0xFF112233);' || true)"
legacy_status=$?
if [ "$legacy_status" -eq 0 ] && [ -z "$legacy" ]; then
  echo "ok   '|| true' still reports success-and-no-hits for an uncompilable ERE"
else
  echo "not ok  '|| true' collapse" >&2
  fail "expected status 0 with empty output from the legacy form, got $legacy_status / '$legacy'"
fi

# --- 8. git failing to list the staged files must not read as "nothing staged" --
d="$(make_repo)"
printf 'const c = Color(0xFF112233);\n' > "$d/lib/bad.dart"
git -C "$d" add lib/bad.dart
printf 'not an index\n' > "$d/broken-index"
out="$(cd "$d" && GIT_INDEX_FILE="$d/broken-index" DART="$d/bin/dart-stub" bash "$d/bin/pre-commit" 2>&1)"
st=$?
check "an unreadable index refuses the commit" 1 "$st" "$out"
rm -rf "$d"

# --- 9. every spelling .claude/CLAUDE.md's `## Colors` section names -----------
#        One case per spelling, driven off a table, because the gate's own history
#        is that a hand-picked subset looks complete: the rule named `Colors.*` and
#        `Color(0x…)` only, and `Color.fromARGB` went through both the rule and
#        this hook. `Color(4278190080)` did the same a second time -- the pattern
#        said `Color\(0`, and a decimal ARGB does not start with a zero.
#
#        A spelling added to the convention must gain a row here. The row is the
#        cheap part; noticing it is missing is not, so keep the two lists ordered
#        the same way the convention lists them.
#        The row counter is not decoration. A `while read` over an emptied table
#        runs zero times and the suite still ends "all N checks passed" -- a check
#        that passes on no input is the same failure this file was written about.
rejected_rows=0
while IFS='|' read -r label sample; do
  [ -z "$label" ] && continue
  d="$(make_repo)"
  printf '%s\n' "$sample" > "$d/lib/bad.dart"
  git -C "$d" add lib/bad.dart
  out="$(run_hook "$d")"; st=$?
  check "rejected: $label" 1 "$st" "$out"
  rejected_rows=$((rejected_rows + 1))
  rm -rf "$d"
done <<'SPELLINGS'
Colors.<swatch>|const c = Colors.red;
Color(0x…)|const c = Color(0xFF112233);
Color(0X…)|const c = Color(0XFF112233);
Color(<decimal ARGB>)|const c = Color(4278190080);
Color(<spaced literal>)|const c = Color( 0xFF112233 );
Color.fromARGB|const c = Color.fromARGB(255, 1, 2, 3);
Color.fromRGBO|const c = Color.fromRGBO(1, 2, 3, 1.0);
Color.from|const c = Color.from(alpha: 1, red: 0, green: 0, blue: 0);
HSLColor.fromAHSL|final c = HSLColor.fromAHSL(1, 0, 0, 0).toColor();
HSVColor.fromAHSV|final c = HSVColor.fromAHSV(1, 0, 0, 0).toColor();
Colors.transparent + alpha|const c = Colors.transparent.withValues(alpha: 1);
SPELLINGS
check "the rejected-spelling table was not empty" 11 "$rejected_rows" ""

# --- 10. and the negative side: things that must NOT be refused ----------------
#         A gate that rejects everything passes case 9 in full. These are the rows
#         that keep it honest -- identifiers that merely contain the word, and the
#         constructors that take colours rather than digits.
allowed_rows=0
while IFS='|' read -r label sample; do
  [ -z "$label" ] && continue
  d="$(make_repo)"
  printf '%s\n' "$sample" > "$d/lib/fine.dart"
  git -C "$d" add lib/fine.dart
  out="$(run_hook "$d")"; st=$?
  check "accepted: $label" 0 "$st" "$out"
  allowed_rows=$((allowed_rows + 1))
  rm -rf "$d"
done <<'ALLOWED'
Colors.transparent|const c = Colors.transparent;
two of them on a line|const l = [Colors.transparent, Colors.transparent];
ColoredBox|const w = ColoredBox(color: x);
AppSemanticColors|final c = AppSemanticColors.of(context).ok;
Color over a variable|final c = Color(myValue);
Color.lerp|final c = Color.lerp(a, b, 0.5);
theme role with alpha|final c = scheme.scrim.withValues(alpha: 0.3);
ALLOWED
check "the accepted-spelling table was not empty" 7 "$allowed_rows" ""

# --- 11. added lines only: an untouched literal stays grandfathered -------------
#         Pre-existing literals are awaiting migration. If the gate read the file
#         instead of the diff, editing any unrelated line of a legacy widget would
#         refuse the commit -- which is how a gate gets switched off for good.
d="$(make_repo)"
printf 'const c = Color(0xFF112233);\nvoid f() {}\n' > "$d/lib/legacy.dart"
git -C "$d" add lib/legacy.dart
git -C "$d" commit -q -m legacy
printf 'const c = Color(0xFF112233);\nvoid f() {\n  g();\n}\n' > "$d/lib/legacy.dart"
git -C "$d" add lib/legacy.dart
out="$(run_hook "$d")"; st=$?
check "an untouched legacy literal does not refuse the commit" 0 "$st" "$out"
rm -rf "$d"

# --- 12. RENAME: a colour literal added at the renamed path must still be caught -
#         `git mv` plus an edit lands as a single `R` diff entry once similarity is
#         above git's default ~50% threshold. `--diff-filter=ACM` never named `R`,
#         so `files` came back empty and the commit exited 0 via the "nothing
#         staged" early return before either gate ran -- reproduced against the
#         real repo in X3's pass-7 audit (`git mv` + one added `Color(0x…)` line,
#         `R096`, `--diff-filter=ACM --name-only` empty). This is that failure
#         mode, reproduced against the hook this file tests.
d="$(make_repo)"
printf 'import "x.dart";\nWidget b() => Text(style: t.bodyLarge);\nWidget c() => Text(style: t.bodyLarge);\n' > "$d/lib/from_name.dart"
git -C "$d" add lib/from_name.dart
git -C "$d" commit -q -m "add a file to rename"
git -C "$d" mv lib/from_name.dart lib/to_name.dart
printf 'const c = Color(0xFF112233);\n' >> "$d/lib/to_name.dart"
git -C "$d" add lib/to_name.dart
status_line="$(git -C "$d" diff --cached --name-status -- lib/from_name.dart lib/to_name.dart | head -1)"
case "$status_line" in
  R*) ;;
  *) fail "rename case did not stage as R (got: '$status_line') -- the test itself is stale" ;;
esac
out="$(run_hook "$d")"; st=$?
check "a colour literal added at a renamed path is rejected" 1 "$st" "$out"
# Non-counted internal check (like break_pattern's self-check above): confirms
# the renamed path was actually handed to the format gate too, not just that the
# colour gate fired. Not a full check of the format gate itself -- the stub
# always exits 0, so it cannot show the format gate would have refused an
# unformatted rename (see "the $DART stub" in the file header / X3's finding).
if ! grep -q 'lib/to_name.dart' "$d/dart-calls.log" 2>/dev/null; then
  fail "the renamed path never reached \$DART format -- the diff-filter fix did not restore the format gate for renames either"
fi
rm -rf "$d"

# --- 13. RENAME, CONTRAST: a pure rename with unchanged content still passes ----
#         Keeps case 12 honest: a fix that rejected every rename outright would
#         pass case 12 for the wrong reason.
d="$(make_repo)"
printf 'import "x.dart";\nWidget b() => Text(style: t.bodyLarge);\n' > "$d/lib/from_clean.dart"
git -C "$d" add lib/from_clean.dart
git -C "$d" commit -q -m "add a file to rename cleanly"
git -C "$d" mv lib/from_clean.dart lib/to_clean.dart
git -C "$d" add lib/to_clean.dart
status_line="$(git -C "$d" diff --cached --name-status -- lib/from_clean.dart lib/to_clean.dart | head -1)"
case "$status_line" in
  R*) ;;
  *) fail "clean rename case did not stage as R (got: '$status_line') -- the test itself is stale" ;;
esac
out="$(run_hook "$d")"; st=$?
check "a pure rename with no colour literal still passes" 0 "$st" "$out"
rm -rf "$d"

echo ""
if [ "$failures" -eq 0 ]; then
  echo "all $cases checks passed"
  exit 0
fi
echo "$failures of $cases checks failed" >&2
exit 1
