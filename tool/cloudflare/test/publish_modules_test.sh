#!/usr/bin/env bash
# ============================================================================
# Stub test for tool/cloudflare/publish_modules.sh. Touches nothing outside a
# temporary directory: fake `wrangler` and `curl` are put first on PATH, record
# every call, and serve R2 objects from a local directory.
#
# The fake edge answers GET from $STUB_EDGE/<key> when a scenario pins a stale
# body there, and from the fake R2 otherwise; HEAD always answers from R2, with
# the R2 object's Content-Length. That is the measured behaviour of the real
# edge (HEAD fresh, GET stale), so a verification that used HEAD -- its status
# or its Content-Length -- would pass over a stale body here too.
# access-control-allow-origin is "*" unless STUB_ACAO overrides it ("echo"
# answers with the request's Origin).
#
# Asserts:
#   (1) happy path puts versioned -> alias -> pointer, in that order
#   (2) stale versioned GET: the pointer is never put
#   (3) stale alias GET: the pointer is never put; the alias is restored from
#       backup and the restore is verified by a later GET
#   (4) mismatched pointer GET: the pointer AND the alias are restored from
#       backup, each followed by a verifying GET
#   (5) no public URL is requested before the first put; --dry-run writes nothing
#   (6) CORS: only "*" or the probe Origin lets the pointer be put
#   (7) unsafe zip entry names are refused before anything touches R2
#   (8) the happy-path archive is one the app's install refusal accepts
#   (9) a pointer put that exits non-zero takes the same restore path as a
#       mismatched pointer GET, and says so when the restore cannot be verified
#  (10) an alias put that exits non-zero takes the same restore path as a
#       stale alias GET, and says so when the restore cannot be verified
#  (11) --yes publishes with no 'yes' typed; without it that input aborts;
#       --yes --dry-run still writes nothing
#
# Run from Git Bash:  bash tool/cloudflare/test/publish_modules_test.sh
# Needs python (to build the test archives), jq, unzip, sha256sum.
# ============================================================================
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/publish_modules.sh"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASSED=0
FAILED=0
pass() { echo "  ok: $*"; PASSED=$((PASSED + 1)); }
flunk() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else flunk "$name"; fi; }

# ---- Fixtures ---------------------------------------------------------------
make_zip() { # make_zip <out> <recognizer_version> <payload>
  python - "$1" "$2" "$3" <<'PY'
import json, sys, zipfile
out, version, payload = sys.argv[1:]
info = {"format_version": "1.0.0", "region": "JPN", "application_version": "0.0.10",
        "minimum_version": "2025-08-24T11:00:00+0900", "recognizer_version": version}
with zipfile.ZipFile(out, "w") as z:
    z.writestr("modules/version_info.json", json.dumps(info, indent=2))
    z.writestr("modules/recognizer/payload.bin", payload)
PY
}
FIX="$ROOT/fixtures"
mkdir -p "$FIX"
make_zip "$FIX/old.zip" "2026-07-21T11:00:00+0900" "old"
make_zip "$FIX/new.zip" "2026-09-18T11:00:00+0900" "new"
unzip -p "$FIX/old.zip" modules/version_info.json > "$FIX/old_pointer.json"
NEW_SHA="$(sha256sum "$FIX/new.zip" | cut -d' ' -f1)"
printf 'CLOUDFLARE_API_TOKEN=stub-token\nCLOUDFLARE_ACCOUNT_ID=stub-account\n' > "$FIX/.env"

# ---- Stubs ------------------------------------------------------------------
BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/wrangler" <<'SH'
#!/usr/bin/env bash
# wrangler r2 object {get|put} <bucket>/<key> --file <f> [...]
op="$3"; key="${4#*/}"; file=""
shift 4
while [[ $# -gt 0 ]]; do [[ "$1" == "--file" ]] && file="$2"; shift; done
case "$op" in
  get)
    echo "wrangler get $key" >> "$STUB_LOG"
    [[ -f "$STUB_R2/$key" ]] || { echo "not found" >&2; exit 1; }
    cp "$STUB_R2/$key" "$file" ;;
  put)
    echo "wrangler put $key $file" >> "$STUB_LOG"
    # A put of STUB_PUT_FAIL_KEY exits non-zero for its first STUB_PUT_FAIL_TIMES
    # calls and writes nothing, standing for an API or network error whose
    # outcome the publisher cannot see.
    if [[ "${STUB_PUT_FAIL_KEY:-}" == "$key" ]]; then
      failed="$(cat "$STUB_LOG.putfail" 2>/dev/null || echo 0)"
      if (( failed < ${STUB_PUT_FAIL_TIMES:-1} )); then
        echo $((failed + 1)) > "$STUB_LOG.putfail"
        echo "stub: put refused" >&2
        exit 1
      fi
    fi
    mkdir -p "$(dirname "$STUB_R2/$key")"
    cp "$file" "$STUB_R2/$key" ;;
  *) echo "wrangler unexpected $op" >> "$STUB_LOG"; exit 2 ;;
esac
SH
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
method=GET; body=/dev/null; headers=""; fmt=""; url=""; origin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -I|--head) method=HEAD ;;
    -o) body="$2"; shift ;;
    -D) headers="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H) [[ "$2" == Origin:* ]] && origin="${2#Origin: }"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "curl $method $url" >> "$STUB_LOG"
key="${url#https://*/}"
src="$STUB_R2/$key"
[[ "$method" == GET && -f "$STUB_EDGE/$key" ]] && src="$STUB_EDGE/$key"
if [[ -f "$src" ]]; then code=200; length="$(wc -c < "$src" | tr -d ' ')"; else code=404; length=0; fi
acao="${STUB_ACAO:-*}"
[[ "$acao" == echo ]] && acao="$origin"
if [[ -n "$headers" ]]; then
  printf 'HTTP/1.1 %s\r\ncontent-length: %s\r\naccess-control-allow-origin: %s\r\n\r\n' \
    "$code" "$length" "$acao" > "$headers"
fi
if [[ "$method" == GET && "$code" == 200 ]]; then cp "$src" "$body"; else : > "$body"; fi
[[ -n "$fmt" ]] && printf '%s' "$code"
exit 0
SH
chmod +x "$BIN/wrangler" "$BIN/curl"

# ---- Scenario runner --------------------------------------------------------
# run_scenario <name> [--dry-run]; a scenario's setup pins stale edge bodies
# into $STUB_EDGE before calling it. Sets RC, LOG, OUT.
new_world() {
  WORLD="$ROOT/$1"
  export STUB_R2="$WORLD/r2" STUB_EDGE="$WORLD/edge" STUB_LOG="$WORLD/calls.log"
  mkdir -p "$STUB_R2/umacapture" "$STUB_EDGE/umacapture/modules"
  : > "$STUB_LOG"
  cp "$FIX/old_pointer.json" "$STUB_R2/umacapture/version_info.json"
  cp "$FIX/old.zip" "$STUB_R2/umacapture/modules.zip"
}
run_scenario() {
  set +e
  printf '%s\n' "${REPLY_UNDER_TEST-yes}" | PATH="$BIN:$PATH" \
    PUBLISH_ENV_FILE="$FIX/.env" PUBLISH_BACKUP_ROOT="$WORLD/backup" \
    PUBLISH_NOT_FOUND_WAIT_SECONDS=0 PUBLISH_RETRY_INTERVAL_SECONDS=0 \
    bash "$SCRIPT" "${ZIP_UNDER_TEST:-$FIX/new.zip}" "$@" > "$WORLD/out.txt" 2>&1
  RC=$?
  set -e
  LOG="$STUB_LOG"
  OUT="$WORLD/out.txt"
}

VKEY="umacapture/modules/$NEW_SHA.zip"
AKEY="umacapture/modules.zip"
PKEY="umacapture/version_info.json"
line_of() { grep -n -m1 -F -- "$1" "$LOG" | cut -d: -f1; }
never() { ! grep -q -F -- "$1" "$LOG"; }
same() { cmp -s "$1" "$2"; }
quiet() { "$@" >/dev/null; }
# (5): the first public request comes after the first put.
no_public_before_put() {
  local first_curl first_put
  first_curl="$(grep -n -m1 '^curl ' "$LOG" | cut -d: -f1)"
  first_put="$(grep -n -m1 '^wrangler put ' "$LOG" | cut -d: -f1)"
  [[ -z "$first_curl" ]] || { [[ -n "$first_put" ]] && (( first_curl > first_put )); }
}
# restored_then_verified <key>: the key is put twice, the second from the
# backup, and a public GET of the key follows that second put.
restored_then_verified() {
  local puts last_put last_get
  puts="$(grep -n -F "wrangler put $1 " "$LOG")"
  [[ "$(wc -l <<<"$puts")" == 2 ]] || return 1
  tail -n1 <<<"$puts" | grep -q '/backup/' || return 1
  last_put="$(tail -n1 <<<"$puts" | cut -d: -f1)"
  last_get="$(grep -n -F "curl GET https://data.umacapture.com/$1" "$LOG" | tail -n1 | cut -d: -f1)"
  [[ -n "$last_get" ]] && (( last_get > last_put ))
}
dump_on_failure() { [[ "$FAILED" == "$1" ]] || { echo "  --- output ---"; cat "$OUT"; echo "  --- calls ---"; cat "$LOG"; }; }

echo "(1)(5) happy path"
new_world happy; f0=$FAILED; run_scenario
check "exits 0" [ "$RC" = 0 ]
check "puts versioned, alias, pointer in that order" \
  [ "$(grep '^wrangler put ' "$LOG" | cut -d' ' -f3 | tr '\n' ' ')" = "$VKEY $AKEY $PKEY " ]
check "each put is followed by a public GET of that key before the next put" \
  bash -c "(( \$(grep -n -m1 -F 'curl GET https://data.umacapture.com/$VKEY' '$LOG' | cut -d: -f1) < \$(grep -n -m1 -F 'wrangler put $AKEY' '$LOG' | cut -d: -f1) )) && (( \$(grep -n -m1 -F 'curl GET https://data.umacapture.com/$AKEY' '$LOG' | cut -d: -f1) < \$(grep -n -m1 -F 'wrangler put $PKEY' '$LOG' | cut -d: -f1) ))"
check "never uses HEAD" never "curl HEAD"
check "(5) no public request before the first put" no_public_before_put
check "pointer carries module_archive for the new zip" \
  quiet jq -e --arg s "$NEW_SHA" --argjson n "$(wc -c < "$FIX/new.zip")" \
  '.module_archive == {path: ("modules/" + $s + ".zip"), sha256: $s, size: $n} and .recognizer_version == "2026-09-18T11:00:00+0900"' \
  "$STUB_R2/$PKEY"
check "alias holds the new bytes" same "$STUB_R2/$AKEY" "$FIX/new.zip"
dump_on_failure "$f0"

echo "(1) re-publishing the same archive skips the versioned put"
f0=$FAILED; : > "$STUB_LOG"; run_scenario
check "exits 0" [ "$RC" = 0 ]
check "no second put of the versioned key" never "wrangler put $VKEY"
dump_on_failure "$f0"

echo "(2) stale versioned GET"
new_world stale_versioned; f0=$FAILED
cp "$FIX/old.zip" "$STUB_EDGE/$VKEY"
run_scenario
check "exits non-zero" [ "$RC" != 0 ]
check "the pointer is never put" never "wrangler put $PKEY"
check "the alias is never put" never "wrangler put $AKEY"
check "R2 pointer unchanged" same "$STUB_R2/$PKEY" "$FIX/old_pointer.json"
dump_on_failure "$f0"

echo "(3) stale alias GET"
new_world stale_alias; f0=$FAILED
cp "$FIX/old.zip" "$STUB_EDGE/$AKEY"
run_scenario
check "exits non-zero" [ "$RC" != 0 ]
check "the pointer is never put" never "wrangler put $PKEY"
check "the last alias put comes from the backup" \
  bash -c "grep -F 'wrangler put $AKEY' '$LOG' | tail -n1 | grep -q '/backup/'"
check "R2 alias restored to the old bytes" same "$STUB_R2/$AKEY" "$FIX/old.zip"
check "the restored alias is verified by a GET after the restore put" restored_then_verified "$AKEY"
check "message names the stale alias" grep -q "stale alias" "$OUT"
dump_on_failure "$f0"

echo "(4) mismatched pointer GET"
new_world stale_pointer; f0=$FAILED
cp "$FIX/old_pointer.json" "$STUB_EDGE/$PKEY"
run_scenario
check "exits non-zero" [ "$RC" != 0 ]
check "the pointer is restored from the backup, then verified by a GET" restored_then_verified "$PKEY"
check "R2 pointer restored to the old bytes" same "$STUB_R2/$PKEY" "$FIX/old_pointer.json"
check "the alias is restored from the backup, then verified by a GET" restored_then_verified "$AKEY"
check "R2 alias restored to the old bytes" same "$STUB_R2/$AKEY" "$FIX/old.zip"
check "the pointer is restored before the alias" \
  bash -c "(( \$(grep -n -F 'wrangler put $PKEY' '$LOG' | tail -n1 | cut -d: -f1) < \$(grep -n -F 'wrangler put $AKEY' '$LOG' | tail -n1 | cut -d: -f1) ))"
check "message reports both restored" grep -q "previous pointer and alias were restored and verified" "$OUT"
dump_on_failure "$f0"

echo "(6) CORS"
for acao in "*" echo; do
  new_world "cors_ok_${acao//\*/star}"; f0=$FAILED; STUB_ACAO="$acao" run_scenario
  check "ACAO '$acao': exits 0" [ "$RC" = 0 ]
  check "ACAO '$acao': the pointer is put" grep -q -F "wrangler put $PKEY" "$LOG"
  dump_on_failure "$f0"
done
new_world cors_other; f0=$FAILED; STUB_ACAO="https://other.example" run_scenario
check "ACAO for another origin: exits non-zero" [ "$RC" != 0 ]
check "ACAO for another origin: the pointer is never put" never "wrangler put $PKEY"
check "ACAO for another origin: the alias is never put" never "wrangler put $AKEY"
dump_on_failure "$f0"

echo "(7) unsafe zip entry names"
make_raw_zip() { # make_raw_zip <out> <extra entry name>, names written verbatim
  python - "$1" "$2" <<'PY'
import sys, zipfile
out, extra = sys.argv[1:]
info = '{"format_version": "1.0.0", "region": "JPN", "application_version": "0.0.10", ' \
       '"minimum_version": "2025-08-24T11:00:00+0900", "recognizer_version": "2026-09-18T11:00:00+0900"}'
with zipfile.ZipFile(out, "w") as z:
    z.writestr("modules/version_info.json", info)
    zi = zipfile.ZipInfo("placeholder")
    zi.filename = extra  # bypass ZipInfo's separator normalisation
    z.writestr(zi, "x")
PY
}
i=0
for name in 'modules/../evil' 'modules/a/../../evil' 'modules/./x' 'modules//x' \
            'modules/..' 'modules/a\evil' 'modules/..\evil' 'modules/c:evil'; do
  i=$((i + 1))
  make_raw_zip "$FIX/unsafe_$i.zip" "$name"
  new_world "unsafe_$i"; f0=$FAILED; ZIP_UNDER_TEST="$FIX/unsafe_$i.zip" run_scenario --dry-run
  check "'$name': exits non-zero" [ "$RC" != 0 ]
  check "'$name': refused as an unsafe entry name" grep -q "unsafe entry names" "$OUT"
  check "'$name': no R2 call at all" never "wrangler"
  dump_on_failure "$f0"
done
make_raw_zip "$FIX/safe_dir.zip" 'modules/sub/'
new_world safe_dir; f0=$FAILED; ZIP_UNDER_TEST="$FIX/safe_dir.zip" run_scenario --dry-run
check "a directory entry 'modules/sub/' is accepted" [ "$RC" = 0 ]
dump_on_failure "$f0"

echo "(8) the happy-path archive is installable by the app"
f0=$FAILED
# lib/src/core/version_check.dart refuses an archive that does not carry both
# halves of a module: modules/version_info.json, and at least one file two or
# more segments below modules/. A fixture the script publishes but the app
# refuses would make every scenario above green without any of them showing
# that what was published can be installed.
holds_module_payload() { # holds_module_payload <zip>
  local entries
  entries="$(unzip -Z1 "$1")"
  grep -qx 'modules/version_info.json' <<<"$entries" \
    && grep -qE '^modules/[^/]+/.*[^/]$' <<<"$entries"
}
check "the published fixture carries version_info.json and a nested file" \
  holds_module_payload "$FIX/new.zip"
check "the backup fixture does too" holds_module_payload "$FIX/old.zip"
dump_on_failure "$f0"

echo "(9) the pointer put itself fails"
new_world put_fail_pointer; f0=$FAILED
STUB_PUT_FAIL_KEY="$PKEY" run_scenario
check "exits non-zero" [ "$RC" != 0 ]
check "the failed put is reported, not swallowed" grep -q "the put failed" "$OUT"
check "the pointer is restored from the backup, then verified by a GET" restored_then_verified "$PKEY"
check "R2 pointer holds the old bytes" same "$STUB_R2/$PKEY" "$FIX/old_pointer.json"
check "the alias is restored from the backup, then verified by a GET" restored_then_verified "$AKEY"
check "R2 alias restored to the old bytes" same "$STUB_R2/$AKEY" "$FIX/old.zip"
check "message reports both restored" grep -q "previous pointer and alias were restored and verified" "$OUT"
dump_on_failure "$f0"

echo "(9) the pointer put fails and the restore cannot be verified"
new_world put_fail_unrecoverable; f0=$FAILED
# The edge keeps serving something that is neither pointer, so no put of that
# key can be verified -- the restore included.
cp "$FIX/new.zip" "$STUB_EDGE/$PKEY"
STUB_PUT_FAIL_KEY="$PKEY" STUB_PUT_FAIL_TIMES=99 run_scenario
check "exits non-zero" [ "$RC" != 0 ]
check "the restore failure is named" grep -q "the restore ALSO failed verification" "$OUT"
check "manual recovery is demanded" grep -q "NEEDS MANUAL RECOVERY" "$OUT"
check "the inconsistency old clients would see is spelled out" \
  grep -q "install a module set the pointer does not describe" "$OUT"
dump_on_failure "$f0"

echo "(10) the alias put itself fails"
new_world put_fail_alias; f0=$FAILED
STUB_PUT_FAIL_KEY="$AKEY" run_scenario
check "exits non-zero" [ "$RC" != 0 ]
check "the failed put is reported, not swallowed" grep -q "the put failed" "$OUT"
check "the pointer is never put" never "wrangler put $PKEY"
check "the alias is restored from the backup, then verified by a GET" restored_then_verified "$AKEY"
check "R2 alias holds the old bytes" same "$STUB_R2/$AKEY" "$FIX/old.zip"
check "message reports the alias restored"   grep -q "previous alias was restored and verified" "$OUT"
dump_on_failure "$f0"

echo "(10) the alias put fails and the restore cannot be verified"
new_world put_fail_alias_unrecoverable; f0=$FAILED
# The edge keeps serving bytes that are not the backup, so no put of the alias
# can be verified -- the restore included.
cp "$FIX/new.zip" "$STUB_EDGE/$AKEY"
STUB_PUT_FAIL_KEY="$AKEY" STUB_PUT_FAIL_TIMES=99 run_scenario
check "exits non-zero" [ "$RC" != 0 ]
check "the pointer is never put" never "wrangler put $PKEY"
check "the restore failure is named" grep -q "the restore ALSO failed verification" "$OUT"
check "manual recovery is demanded" grep -q "NEEDS MANUAL RECOVERY" "$OUT"
check "the inconsistency old clients would see is spelled out"   grep -q "install a module set the pointer does not describe" "$OUT"
dump_on_failure "$f0"

echo "(5) --dry-run"
new_world dry; f0=$FAILED; run_scenario --dry-run
check "exits 0" [ "$RC" = 0 ]
check "no put" never "wrangler put"
check "no public request" never "curl "
check "only R2 reads of the pointer and alias" \
  [ "$(tr '\n' ' ' < "$LOG")" = "wrangler get $PKEY wrangler get $AKEY " ]
check "R2 unchanged" bash -c "cmp -s '$STUB_R2/$PKEY' '$FIX/old_pointer.json' && cmp -s '$STUB_R2/$AKEY' '$FIX/old.zip' && [ \$(find '$STUB_R2' -type f | wc -l) = 2 ]"
check "prints the versioned key" grep -qF "$VKEY" "$OUT"
dump_on_failure "$f0"

echo "(11) --yes"
# The input is an empty line, so only --yes can get past stage 2.
new_world no_reply; f0=$FAILED; REPLY_UNDER_TEST="" run_scenario
check "without --yes: exits non-zero" [ "$RC" != 0 ]
check "without --yes: no put" never "wrangler put"
dump_on_failure "$f0"
new_world assume_yes; f0=$FAILED; REPLY_UNDER_TEST="" run_scenario --yes
check "--yes: exits 0" [ "$RC" = 0 ]
check "--yes: puts versioned, alias, pointer in that order" \
  [ "$(grep '^wrangler put ' "$LOG" | cut -d' ' -f3 | tr '\n' ' ')" = "$VKEY $AKEY $PKEY " ]
dump_on_failure "$f0"
new_world assume_yes_dry; f0=$FAILED; REPLY_UNDER_TEST="" run_scenario --yes --dry-run
check "--yes --dry-run: exits 0" [ "$RC" = 0 ]
check "--yes --dry-run: no put" never "wrangler put"
dump_on_failure "$f0"

echo
echo "passed: $PASSED, failed: $FAILED"
[[ "$FAILED" == 0 ]]
