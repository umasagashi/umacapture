#!/usr/bin/env bash
# ============================================================================
# Stub test for tool/cloudflare/publish_modules.sh. Touches nothing outside a
# temporary directory: each scenario runs a copy of the script inside a
# throwaway git repository that holds the deployed paths (server/data-site/,
# server/wrangler.data.jsonc, tool/cloudflare/), with fake `npm` and `curl`
# first on PATH. The fake `npm ci` installs the fake `wrangler` as
# server/node_modules/.bin/wrangler, the pinned one the script runs; the
# `wrangler` on PATH only logs "PATH wrangler" and fails. Every fake records
# every call.
#
# Hosts are directories under $STUB_WEB/<host>/. The fake `wrangler deploy`
# replaces the deploy host's directory (STUB_DEPLOY_HOST, default
# data.umacapture.com) with build/data-site/; `--dry-run` copies nothing. The
# fake `curl` answers a GET from the host directory: 200 with the file, 404
# without it. access-control-allow-origin is "*" on /umacapture/* unless
# STUB_ACAO overrides it ("echo" answers with the request's Origin).
# Fault injection: STUB_FAIL_URL answers STUB_FAIL_CODE ("000" = curl itself
# fails); STUB_CORRUPT_URL serves its body with one byte appended; the deploy
# numbers in STUB_DEPLOY_FAIL exit non-zero and change nothing; those in
# STUB_DEPLOY_CORRUPT are served without their deploy.json.
#
# Every world starts as the R2 bucket the Worker replaces: a pointer, the
# archive it names, the alias, a legacy archive no pointer names, and no
# deploy.json.
#
# Asserts:
#   (1) the new archive is verified on the public URL before any deploy that
#       changes the pointer; a phase 1 that fails leaves the pointer unchanged;
#       a re-publish of the live archive deploys once
#   (2) a phase 2 that fails (deploy or verification) deploys phase 1 again and
#       verifies it, and says so when that fails too
#   (5) --dry-run deploys nothing
#   (6) CORS: only "*" or the probe Origin lets the pointer change, and a
#       _headers without the /umacapture/* ACAO rule is refused up front
#   (7) unsafe zip entry names are refused before any request
#   (8) the happy-path archive is one the app's install refusal accepts
#  (11) --yes publishes with no 'yes' typed; without it that input aborts;
#       --yes --dry-run still deploys nothing
#  (12) every archive the live deploy.json lists is carried into the new tree,
#       with its published_at, so two publishes in a row keep the first archive
#  (13) an inherited archive that cannot be fetched or does not match, or a
#       live pointer naming an archive the list lacks, deploys nothing
#  (14) first publish (deploy.json 404): only the archive the live pointer
#       names is inherited; a deploy.json answering 5xx or failing outright is
#       not taken for a first publish
#  (15) reading and verifying on different hosts: the live state is read from
#       DATA_READ_ROOT and the deploy verified on DATA_VERIFY_ROOT
#  (16) a change or untracked file under the deployed paths, or a change to
#       the npm ci inputs (server/package-lock.json), stops the run
#       before any request; one elsewhere does not
#  (17) deploy.json records git_sha, pointer_sha256 and the zips; the backup
#       holds the live pointer, the archive it names and the new pointer
#  (18) with no zip, the archive the live pointer names is re-published: one
#       deploy, the pointer byte for byte the same, the static files updated;
#       a live archive that does not match the pointer deploys nothing; an
#       empty argument is not taken for a missing zip
#  (19) an inherited archive published more than 30 days ago is dropped,
#       except the previous version; one 29 days old, or with no
#       published_at, is kept
#  (20) the previous version is the most recently published archive other
#       than the one served, also when the live archive is re-published (no
#       zip, or the same zip given): it stays past 30 days, an older one goes
#
# Run from Git Bash:  bash tool/cloudflare/test/publish_modules_test.sh
# Needs python (to build the test archives), git, jq, unzip, sha256sum.
# ============================================================================
set -euo pipefail

SCRIPT_REL="tool/cloudflare/publish_modules.sh"
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
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
sha() { sha256sum "$1" | cut -d' ' -f1; }
FIX="$ROOT/fixtures"
mkdir -p "$FIX"
make_zip "$FIX/old.zip" "2026-07-21T11:00:00+0900" "old"
make_zip "$FIX/new.zip" "2026-09-18T11:00:00+0900" "new"
make_zip "$FIX/newer.zip" "2026-10-01T11:00:00+0900" "newer"
make_zip "$FIX/legacy.zip" "2026-07-01T11:00:00+0900" "legacy"
OLD_SHA="$(sha "$FIX/old.zip")"
NEW_SHA="$(sha "$FIX/new.zip")"
NEWER_SHA="$(sha "$FIX/newer.zip")"
LEGACY_SHA="$(sha "$FIX/legacy.zip")"
unzip -p "$FIX/old.zip" modules/version_info.json \
  | jq --arg s "$OLD_SHA" --argjson n "$(wc -c < "$FIX/old.zip")" \
    '. + {module_archive: {path: ("modules/" + $s + ".zip"), sha256: $s, size: $n}}' > "$FIX/old_pointer.json"
printf 'CLOUDFLARE_API_TOKEN=stub-token\nCLOUDFLARE_ACCOUNT_ID=stub-account\n' > "$FIX/.env"

# A repository holding exactly what the script deploys, committed.
TEMPLATE="$ROOT/template"
mkdir -p "$TEMPLATE/tool/cloudflare" "$TEMPLATE/server"
cp "$SRC_ROOT/$SCRIPT_REL" "$TEMPLATE/$SCRIPT_REL"
cp -R "$SRC_ROOT/server/data-site" "$TEMPLATE/server/"
cp "$SRC_ROOT/server/wrangler.data.jsonc" "$SRC_ROOT/server/package.json" "$SRC_ROOT/server/package-lock.json" \
  "$TEMPLATE/server/"
printf '/build/\n/server/node_modules/\n/tool/cloudflare/.publish-backup/\n' > "$TEMPLATE/.gitignore"
git -C "$TEMPLATE" init -q
git -C "$TEMPLATE" config core.autocrlf false
git -C "$TEMPLATE" add -A
git -C "$TEMPLATE" -c user.name=stub -c user.email=stub@example.com commit -q -m fixture

# ---- Stubs ------------------------------------------------------------------
BIN="$ROOT/bin"
FAKE_WRANGLER="$ROOT/fake/wrangler"
mkdir -p "$BIN" "$ROOT/fake"
cat > "$FAKE_WRANGLER" <<'SH'
#!/usr/bin/env bash
echo "wrangler $*" >> "$STUB_LOG"
[[ "$1" == --version ]] && { echo "4.113.0"; exit 0; }
[[ "$1" == deploy ]] || exit 2
for a in "$@"; do [[ "$a" == --dry-run ]] && exit 0; done
n=$(( $(cat "$STUB_LOG.deploys" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_LOG.deploys"
tree="$PWD/build/data-site"
echo "deploy $n pointer=$(sha256sum "$tree/umacapture/version_info.json" | cut -d' ' -f1)" >> "$STUB_LOG"
for f in ${STUB_DEPLOY_FAIL:-}; do [[ "$f" == "$n" ]] && { echo "stub: deploy refused" >&2; exit 1; }; done
host="$STUB_WEB/${STUB_DEPLOY_HOST:-data.umacapture.com}"
rm -rf "$host"
mkdir -p "$host"
cp -R "$tree/." "$host/"
rm -f "$host/_headers"
for f in ${STUB_DEPLOY_CORRUPT:-}; do [[ "$f" == "$n" ]] && rm -f "$host/deploy.json"; done
exit 0
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
rest="${url#https://}"
host="${rest%%/*}"
path="/${rest#*/}"
src="$STUB_WEB/$host$path"
if [[ -n "${STUB_FAIL_URL:-}" && "$url" == "$STUB_FAIL_URL" ]]; then
  code="$STUB_FAIL_CODE"
  if [[ "$code" == 000 ]]; then
    [[ -n "$fmt" ]] && printf '000'
    echo "curl: (35) stub TLS failure" >&2
    exit 35
  fi
elif [[ -f "$src" ]]; then code=200; else code=404; fi
acao=""
if [[ "$path" == /umacapture/* ]]; then
  acao="${STUB_ACAO-*}"
  [[ "$acao" == echo ]] && acao="$origin"
fi
if [[ -n "$headers" ]]; then
  { printf 'HTTP/1.1 %s\r\n' "$code"
    [[ -n "$acao" ]] && printf 'access-control-allow-origin: %s\r\n' "$acao"
    printf '\r\n'; } > "$headers"
fi
if [[ "$method" == GET && "$code" == 200 ]]; then
  cp "$src" "$body"
  [[ -n "${STUB_CORRUPT_URL:-}" && "$url" == "$STUB_CORRUPT_URL" ]] && printf 'x' >> "$body"
else
  : > "$body"
fi
[[ -n "$fmt" ]] && printf '%s' "$code"
exit 0
SH
cat > "$BIN/npm" <<SH
#!/usr/bin/env bash
echo "npm \$*" >> "\$STUB_LOG"
mkdir -p node_modules/.bin
cp "$FAKE_WRANGLER" node_modules/.bin/wrangler
SH
cat > "$BIN/wrangler" <<'SH'
#!/usr/bin/env bash
echo "PATH wrangler $*" >> "$STUB_LOG"
exit 1
SH
chmod +x "$FAKE_WRANGLER" "$BIN/npm" "$BIN/wrangler" "$BIN/curl"

# ---- Scenario runner --------------------------------------------------------
LIVE="https://data.umacapture.com"
PKEY="umacapture/version_info.json"
AKEY="umacapture/modules.zip"
vkey() { echo "umacapture/modules/$1.zip"; }

# new_world <name>: a fresh repository and a host that looks like the R2 bucket.
new_world() {
  WORLD="$ROOT/$1"
  REPO="$WORLD/repo"
  export STUB_WEB="$WORLD/web" STUB_LOG="$WORLD/calls.log"
  mkdir -p "$WORLD"
  cp -R "$TEMPLATE" "$REPO"
  EDGE="$STUB_WEB/data.umacapture.com"
  mkdir -p "$EDGE/umacapture/modules"
  cp "$FIX/old_pointer.json" "$EDGE/$PKEY"
  cp "$FIX/old.zip" "$EDGE/$AKEY"
  cp "$FIX/old.zip" "$EDGE/$(vkey "$OLD_SHA")"
  cp "$FIX/legacy.zip" "$EDGE/$(vkey "$LEGACY_SHA")"
  cp "$REPO/server/data-site/umacapture/news.md" "$EDGE/umacapture/news.md"
  : > "$STUB_LOG"
}
# run_scenario [args...]: publishes ZIP_UNDER_TEST (default new.zip; "none"
# passes no zip, "empty" an empty argument). Sets RC, LOG, OUT.
run_scenario() {
  local zip_args=("${ZIP_UNDER_TEST:-$FIX/new.zip}")
  case "${ZIP_UNDER_TEST:-}" in
    none) zip_args=() ;;
    empty) zip_args=("") ;;
  esac
  : > "$STUB_LOG"
  rm -f "$STUB_LOG.deploys"
  set +e
  printf '%s\n' "${REPLY_UNDER_TEST-yes}" | PATH="$BIN:$PATH" \
    PUBLISH_ENV_FILE="$FIX/.env" PUBLISH_BACKUP_ROOT="$WORLD/backup" \
    PUBLISH_VERIFY_WAIT_SECONDS=0 PUBLISH_RETRY_INTERVAL_SECONDS=0 \
    bash "$REPO/$SCRIPT_REL" ${zip_args[@]+"${zip_args[@]}"} "$@" > "$WORLD/out.txt" 2>&1
  RC=$?
  set -e
  LOG="$STUB_LOG"
  OUT="$WORLD/out.txt"
}

never() { ! grep -q -F -- "$1" "$LOG"; }
same() { cmp -s "$1" "$2"; }
quiet() { "$@" >/dev/null; }
deploys() { grep -c '^deploy ' "$LOG" || true; }
# deploy_pointer <n>: the sha256 of the pointer the n-th deploy carried.
deploy_pointer() { grep "^deploy $1 " "$LOG" | sed 's/.*pointer=//'; }
line_of() { grep -n -m1 -F -- "$1" "$LOG" | cut -d: -f1; }
# tree_digest <dir>: names and contents, to show a host did not change.
tree_digest() { (cd "$1" && find . -type f | sort | xargs sha256sum) | sha256sum | cut -d' ' -f1; }
listed_zips() { jq -r '[.zips[].sha256] | sort | join(" ")' "$1" | tr -d '\r'; }
sorted() { tr ' ' '\n' <<<"$*" | sort | tr '\n' ' ' | sed 's/ $//'; }
no_requests() { never "curl " && never "wrangler deploy"; }
dump_on_failure() { [[ "$FAILED" == "$1" ]] || { echo "  --- output ---"; cat "$OUT"; echo "  --- calls ---"; cat "$LOG"; }; }

OLD_POINTER_SHA="$(sha "$FIX/old_pointer.json")"

echo "(1)(14)(17) happy path from the R2-shaped host"
new_world happy; f0=$FAILED; run_scenario --yes
check "exits 0" [ "$RC" = 0 ]
check "deploys twice" [ "$(deploys)" = 2 ]
check "(1) phase 1 carries the live pointer unchanged" [ "$(deploy_pointer 1)" = "$OLD_POINTER_SHA" ]
check "(1) the new archive is GET-verified between the two deploys" \
  bash -c "a=\$(grep -n '^deploy 1 ' '$LOG' | cut -d: -f1); b=\$(grep -n '^deploy 2 ' '$LOG' | cut -d: -f1); \
    g=\$(grep -n -F 'curl GET $LIVE/$(vkey "$NEW_SHA")' '$LOG' | tail -n1 | cut -d: -f1); \
    [ -n \"\$g\" ] && (( a < g && g < b ))"
check "(1) phase 2 carries the new pointer" [ "$(deploy_pointer 2)" = "$(sha "$EDGE/$PKEY")" ]
check "never uses HEAD" never "curl HEAD"
check "pointer carries module_archive for the new zip" \
  quiet jq -e --arg s "$NEW_SHA" --argjson n "$(wc -c < "$FIX/new.zip")" \
  '.module_archive == {path: ("modules/" + $s + ".zip"), sha256: $s, size: $n} and .recognizer_version == "2026-09-18T11:00:00+0900"' \
  "$EDGE/$PKEY"
check "alias holds the new bytes" same "$EDGE/$AKEY" "$FIX/new.zip"
check "the new archive is served" same "$EDGE/$(vkey "$NEW_SHA")" "$FIX/new.zip"
check "(14) the archive the live pointer named is still served" same "$EDGE/$(vkey "$OLD_SHA")" "$FIX/old.zip"
check "(14) first publish: the legacy archive is not inherited" [ ! -e "$EDGE/$(vkey "$LEGACY_SHA")" ]
check "(14) first publish: deploy.json lists exactly the live pointer's archive and the new one" \
  [ "$(listed_zips "$EDGE/deploy.json")" = "$(sorted "$OLD_SHA" "$NEW_SHA")" ]
check "the static files come from server/data-site" \
  same "$EDGE/umacapture/sentry_sample.json" "$REPO/server/data-site/umacapture/sentry_sample.json"
check "_headers is part of the deployed tree" [ -f "$REPO/build/data-site/_headers" ]
check "(17) deploy.json records git_sha, pointer_sha256, phase 2 and published_at" \
  quiet jq -e --arg g "$(git -C "$REPO" rev-parse HEAD)" --arg p "$(sha "$EDGE/$PKEY")" \
  '.git_sha == $g and .pointer_sha256 == $p and .phase == 2 and (.built_at | type == "string")
   and all(.zips[]; (.published_at | type == "string") and (.size > 0))' "$EDGE/deploy.json"
BK="$(find "$WORLD/backup" -mindepth 1 -maxdepth 1 -type d | head -n1)"
check "(17) backup: the live pointer" same "$BK/version_info.json" "$FIX/old_pointer.json"
check "(17) backup: the archive it named" same "$BK/modules.zip" "$FIX/old.zip"
check "(17) backup: the new pointer" same "$BK/new_version_info.json" "$EDGE/$PKEY"
check "the deploy uses the data config" grep -q -F "wrangler deploy -c server/wrangler.data.jsonc" "$LOG"
check "nothing tracked was rewritten" bash -c "[ -z \"\$(git -C '$REPO' status --porcelain)\" ]"
dump_on_failure "$f0"

echo "(1) re-publishing the live archive deploys once"
f0=$FAILED; run_scenario --yes
check "exits 0" [ "$RC" = 0 ]
check "one deploy" [ "$(deploys)" = 1 ]
check "pointer unchanged in content" same "$EDGE/$PKEY" "$BK/new_version_info.json"
dump_on_failure "$f0"

echo "(1) the new archive fails verification in phase 1"
new_world phase1_bad; f0=$FAILED
STUB_CORRUPT_URL="$LIVE/$(vkey "$NEW_SHA")" run_scenario --yes
check "exits non-zero" [ "$RC" != 0 ]
check "only phase 1 was deployed" [ "$(deploys)" = 1 ]
check "the served pointer is the old one" same "$EDGE/$PKEY" "$FIX/old_pointer.json"
check "the served alias is the old one" same "$EDGE/$AKEY" "$FIX/old.zip"
check "message says the pointer was not changed" grep -q "new archive failed verification.*The pointer was not changed" "$OUT"
dump_on_failure "$f0"

echo "(1) the phase 1 deploy fails"
new_world phase1_deploy_fail; f0=$FAILED; before="$(tree_digest "$EDGE")"
STUB_DEPLOY_FAIL=1 run_scenario --yes
check "exits non-zero" [ "$RC" != 0 ]
check "no second deploy" [ "$(deploys)" = 1 ]
check "the host is unchanged" [ "$(tree_digest "$EDGE")" = "$before" ]
dump_on_failure "$f0"

echo "(2) phase 2 is served without its deploy.json"
new_world phase2_bad; f0=$FAILED; STUB_DEPLOY_CORRUPT=2 run_scenario --yes
check "exits non-zero" [ "$RC" != 0 ]
check "phase 1 is deployed again" [ "$(deploys)" = 3 ]
check "the third deploy carries the old pointer" [ "$(deploy_pointer 3)" = "$OLD_POINTER_SHA" ]
check "the served pointer is the old one" same "$EDGE/$PKEY" "$FIX/old_pointer.json"
check "the served alias is the old one" same "$EDGE/$AKEY" "$FIX/old.zip"
check "the return is verified by a GET of the pointer after the third deploy" \
  bash -c "(( \$(grep -n '^deploy 3 ' '$LOG' | cut -d: -f1) < \$(grep -n -F 'curl GET $LIVE/$PKEY' '$LOG' | tail -n1 | cut -d: -f1) ))"
check "message reports phase 1 restored" grep -q "phase 1 was deployed again and verified" "$OUT"
dump_on_failure "$f0"

echo "(2) the phase 2 deploy itself fails"
new_world phase2_deploy_fail; f0=$FAILED; STUB_DEPLOY_FAIL=2 run_scenario --yes
check "exits non-zero" [ "$RC" != 0 ]
check "the failed deploy is reported" grep -q "the deploy failed" "$OUT"
check "phase 1 is deployed again" [ "$(deploys)" = 3 ]
check "message reports phase 1 restored" grep -q "phase 1 was deployed again and verified" "$OUT"
dump_on_failure "$f0"

echo "(2) phase 2 fails and phase 1 cannot be verified either"
new_world phase2_unrecoverable; f0=$FAILED; STUB_DEPLOY_CORRUPT="2 3" run_scenario --yes
check "exits non-zero" [ "$RC" != 0 ]
check "the failed return is named" grep -q "returning to phase 1 ALSO failed" "$OUT"
check "manual recovery by wrangler rollback is demanded" \
  grep -q "NEEDS MANUAL RECOVERY: pick the version just before this publish began from \`server/node_modules/.bin/wrangler deployments list -c server/wrangler.data.jsonc\`, run \`server/node_modules/.bin/wrangler rollback <version-id> -c server/wrangler.data.jsonc\`" "$OUT"
dump_on_failure "$f0"

echo "(6) CORS"
new_world cors_echo; f0=$FAILED; STUB_ACAO=echo run_scenario --yes
check "ACAO echoing the Origin: exits 0" [ "$RC" = 0 ]
dump_on_failure "$f0"
for acao in "https://other.example" ""; do
  new_world "cors_bad_${#acao}"; f0=$FAILED; STUB_ACAO="$acao" run_scenario --yes
  check "ACAO '$acao': exits non-zero" [ "$RC" != 0 ]
  check "ACAO '$acao': the pointer never changes" bash -c "! grep -q '^deploy 2 ' '$LOG'"
  check "ACAO '$acao': the served pointer is the old one" same "$EDGE/$PKEY" "$FIX/old_pointer.json"
  dump_on_failure "$f0"
done
new_world cors_headers; f0=$FAILED
grep -v -i 'access-control-allow-origin' "$REPO/server/data-site/_headers" > "$WORLD/h" || true
cp "$WORLD/h" "$REPO/server/data-site/_headers"
git -C "$REPO" -c user.name=stub -c user.email=stub@example.com commit -q -am "drop ACAO"
run_scenario --yes
check "_headers without the ACAO rule: exits non-zero" [ "$RC" != 0 ]
check "_headers without the ACAO rule: refused for it" grep -q "does not give /umacapture/\*" "$OUT"
check "_headers without the ACAO rule: no request at all" no_requests
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
new_world unsafe
i=0
for name in 'modules/../evil' 'modules/a/../../evil' 'modules/./x' 'modules//x' \
            'modules/..' 'modules/a\evil' 'modules/..\evil' 'modules/c:evil'; do
  i=$((i + 1))
  make_raw_zip "$FIX/unsafe_$i.zip" "$name"
  f0=$FAILED; ZIP_UNDER_TEST="$FIX/unsafe_$i.zip" run_scenario --dry-run
  check "'$name': exits non-zero" [ "$RC" != 0 ]
  check "'$name': refused as an unsafe entry name" grep -q "unsafe entry names" "$OUT"
  check "'$name': no request at all" no_requests
  dump_on_failure "$f0"
done
make_raw_zip "$FIX/safe_dir.zip" 'modules/sub/'
f0=$FAILED; ZIP_UNDER_TEST="$FIX/safe_dir.zip" run_scenario --dry-run
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
check "the live fixture does too" holds_module_payload "$FIX/old.zip"
dump_on_failure "$f0"

echo "(12) two publishes in a row keep every archive"
new_world inherit; f0=$FAILED; run_scenario --yes
first_published="$(jq -r --arg s "$NEW_SHA" '.zips[] | select(.sha256 == $s) | .published_at' "$EDGE/deploy.json" | tr -d '\r')"
ZIP_UNDER_TEST="$FIX/newer.zip" run_scenario --yes
check "second publish exits 0" [ "$RC" = 0 ]
check "the first publish's archive is still served" same "$EDGE/$(vkey "$NEW_SHA")" "$FIX/new.zip"
check "the archive inherited on the first publish is still served" same "$EDGE/$(vkey "$OLD_SHA")" "$FIX/old.zip"
check "deploy.json lists all three" \
  [ "$(listed_zips "$EDGE/deploy.json")" = "$(sorted "$OLD_SHA" "$NEW_SHA" "$NEWER_SHA")" ]
check "an inherited archive keeps its published_at" \
  [ "$(jq -r --arg s "$NEW_SHA" '.zips[] | select(.sha256 == $s) | .published_at' "$EDGE/deploy.json" | tr -d '\r')" = "$first_published" ]
check "every inherited archive is GET-checked on the live host" \
  bash -c "grep -q -F 'curl GET $LIVE/$(vkey "$OLD_SHA")' '$LOG' && grep -q -F 'curl GET $LIVE/$(vkey "$NEW_SHA")' '$LOG'"
dump_on_failure "$f0"

echo "(13) inherited archives that do not hold"
for fault in missing corrupt unlisted; do
  new_world "inherit_$fault"; f0=$FAILED; run_scenario --yes
  case "$fault" in
    missing) rm "$EDGE/$(vkey "$OLD_SHA")" ;;
    corrupt) export STUB_CORRUPT_URL="$LIVE/$(vkey "$OLD_SHA")" ;;
    unlisted) jq --arg s "$NEW_SHA" '.zips |= map(select(.sha256 != $s))' "$EDGE/deploy.json" > "$WORLD/d"
              cp "$WORLD/d" "$EDGE/deploy.json" ;;
  esac
  before="$(tree_digest "$EDGE")"
  ZIP_UNDER_TEST="$FIX/newer.zip" run_scenario --yes
  unset STUB_CORRUPT_URL
  check "$fault: exits non-zero" [ "$RC" != 0 ]
  check "$fault: nothing deployed, not even a dry run" never "wrangler deploy"
  check "$fault: the host is unchanged" [ "$(tree_digest "$EDGE")" = "$before" ]
  dump_on_failure "$f0"
done
check "missing: the failed fetch is named" grep -q "inherited archive does not match.*HTTP 404" "$WORLD/../inherit_missing/out.txt"
check "corrupt: the sha256 mismatch is named" grep -q "inherited archive does not match.*sha256" "$WORLD/../inherit_corrupt/out.txt"
check "unlisted: the unlisted pointer archive is named" grep -q "does not list" "$WORLD/../inherit_unlisted/out.txt"

echo "(14) a deploy.json that fails is not a first publish"
for code in 503 000; do
  new_world "deploy_json_$code"; f0=$FAILED; before="$(tree_digest "$EDGE")"
  STUB_FAIL_URL="$LIVE/deploy.json" STUB_FAIL_CODE="$code" run_scenario --yes
  check "HTTP $code: exits non-zero" [ "$RC" != 0 ]
  check "HTTP $code: refused as not a 404" grep -q "HTTP $code. Only a 404 means a first publish" "$OUT"
  check "HTTP $code: nothing deployed" never "wrangler deploy"
  check "HTTP $code: the host is unchanged" [ "$(tree_digest "$EDGE")" = "$before" ]
  dump_on_failure "$f0"
done

echo "(15) read from one host, deploy and verify on another"
new_world split; f0=$FAILED; before="$(tree_digest "$EDGE")"
NEXT="$STUB_WEB/data-next.umacapture.com"
DATA_VERIFY_ROOT="https://data-next.umacapture.com" STUB_DEPLOY_HOST="data-next.umacapture.com" run_scenario --yes
check "exits 0" [ "$RC" = 0 ]
check "the read host is unchanged" [ "$(tree_digest "$EDGE")" = "$before" ]
check "the verify host serves the new pointer" \
  quiet jq -e --arg s "$NEW_SHA" '.module_archive.sha256 == $s' "$NEXT/$PKEY"
check "the verify host serves the inherited archive" same "$NEXT/$(vkey "$OLD_SHA")" "$FIX/old.zip"
check "the live state is read from the read host" grep -q -F "curl GET $LIVE/deploy.json" "$LOG"
check "nothing is read from the verify host before the first deploy" \
  bash -c "(( \$(grep -n -m1 'data-next' '$LOG' | cut -d: -f1) > \$(grep -n -m1 '^deploy 1 ' '$LOG' | cut -d: -f1) ))"
check "the new archive is verified on the verify host" \
  grep -q -F "curl GET https://data-next.umacapture.com/$(vkey "$NEW_SHA")" "$LOG"
dump_on_failure "$f0"

echo "(16) the deployed paths must be committed"
for dirt in modified untracked_site untracked_tool lockfile; do
  new_world "dirty_$dirt"; f0=$FAILED
  case "$dirt" in
    modified) printf 'edited\n' >> "$REPO/server/data-site/umacapture/news.md" ;;
    lockfile) printf '\n' >> "$REPO/server/package-lock.json" ;;
    untracked_site) printf 'x\n' > "$REPO/server/data-site/umacapture/extra.txt" ;;
    untracked_tool) printf 'x\n' > "$REPO/tool/cloudflare/notes.txt" ;;
  esac
  run_scenario --yes
  check "$dirt: exits non-zero" [ "$RC" != 0 ]
  check "$dirt: refused for the deployed paths" grep -q "uncommitted or untracked files under the deployed paths" "$OUT"
  check "$dirt: no request at all" no_requests
  dump_on_failure "$f0"
done
new_world dirty_elsewhere; f0=$FAILED
mkdir -p "$REPO/lib" && printf 'x\n' > "$REPO/lib/wip.dart"
run_scenario --dry-run
check "an untracked file outside the deployed paths does not stop a run" [ "$RC" = 0 ]
dump_on_failure "$f0"

echo "(5) --dry-run"
new_world dry; f0=$FAILED; before="$(tree_digest "$EDGE")"; run_scenario --dry-run
check "exits 0" [ "$RC" = 0 ]
check "no deploy" [ "$(deploys)" = 0 ]
check "only a wrangler dry run" \
  [ "$(grep '^wrangler deploy ' "$LOG" | tr '\n' ' ')" = "wrangler deploy -c server/wrangler.data.jsonc --dry-run " ]
check "the host is unchanged" [ "$(tree_digest "$EDGE")" = "$before" ]
check "prints the versioned key" grep -qF "$(vkey "$NEW_SHA")" "$OUT"
dump_on_failure "$f0"

echo "(11) --yes"
# The input is an empty line, so only --yes can get past stage 3.
new_world no_reply; f0=$FAILED; REPLY_UNDER_TEST="" run_scenario
check "without --yes: exits non-zero" [ "$RC" != 0 ]
check "without --yes: no deploy" [ "$(deploys)" = 0 ]
dump_on_failure "$f0"
new_world assume_yes; f0=$FAILED; REPLY_UNDER_TEST="" run_scenario --yes
check "--yes: exits 0" [ "$RC" = 0 ]
check "--yes: deploys phase 1 then phase 2" [ "$(deploys)" = 2 ]
dump_on_failure "$f0"
new_world assume_yes_dry; f0=$FAILED; REPLY_UNDER_TEST="" run_scenario --yes --dry-run
check "--yes --dry-run: exits 0" [ "$RC" = 0 ]
check "--yes --dry-run: no deploy" [ "$(deploys)" = 0 ]
dump_on_failure "$f0"

echo "(18) no zip: re-publish the live archive"
new_world republish; f0=$FAILED; run_scenario --yes
cp "$EDGE/$PKEY" "$WORLD/pointer_before"
zips_before="$(listed_zips "$EDGE/deploy.json")"
printf 'news update\n' >> "$REPO/server/data-site/umacapture/news.md"
git -C "$REPO" -c user.name=stub -c user.email=stub@example.com commit -q -am "news"
ZIP_UNDER_TEST=none run_scenario --yes
check "exits 0" [ "$RC" = 0 ]
check "one deploy" [ "$(deploys)" = 1 ]
check "the pointer is byte for byte the same" same "$EDGE/$PKEY" "$WORLD/pointer_before"
check "the updated news is served" same "$EDGE/umacapture/news.md" "$REPO/server/data-site/umacapture/news.md"
check "the same archives are listed" [ "$(listed_zips "$EDGE/deploy.json")" = "$zips_before" ]
dump_on_failure "$f0"
new_world republish_dry; f0=$FAILED; run_scenario --yes; before="$(tree_digest "$EDGE")"
ZIP_UNDER_TEST=none run_scenario --dry-run
check "--dry-run: exits 0" [ "$RC" = 0 ]
check "--dry-run: no deploy" [ "$(deploys)" = 0 ]
check "--dry-run: the host is unchanged" [ "$(tree_digest "$EDGE")" = "$before" ]
dump_on_failure "$f0"
new_world republish_corrupt; f0=$FAILED; run_scenario --yes; before="$(tree_digest "$EDGE")"
STUB_CORRUPT_URL="$LIVE/$(vkey "$NEW_SHA")" ZIP_UNDER_TEST=none run_scenario --yes
check "live archive not matching the pointer: exits non-zero" [ "$RC" != 0 ]
check "live archive not matching the pointer: refused for it" \
  grep -q "the archive the live pointer names does not match it.*sha256" "$OUT"
check "live archive not matching the pointer: nothing deployed, not even a dry run" never "wrangler deploy"
check "live archive not matching the pointer: the host is unchanged" [ "$(tree_digest "$EDGE")" = "$before" ]
dump_on_failure "$f0"
new_world empty_arg; f0=$FAILED; ZIP_UNDER_TEST=empty run_scenario --yes
check "an empty argument: exits non-zero" [ "$RC" != 0 ]
check "an empty argument: usage" grep -q "usage:" "$OUT"
check "an empty argument: no request at all" no_requests
dump_on_failure "$f0"

echo "(19) retention of inherited archives"
days_ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }
hours_ago() { date -u -d "@$(( $(date -u +%s) - $1 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ; }
# After new.zip is published, old.zip is two versions back; publishing
# newer.zip makes new.zip the previous version.
for age in 31 29 missing; do
  new_world "retain_$age"; f0=$FAILED; run_scenario --yes
  if [[ "$age" == missing ]]; then
    jq --arg s "$OLD_SHA" '.zips |= map(if .sha256 == $s then del(.published_at) else . end)' \
      "$EDGE/deploy.json" > "$WORLD/d"
  else
    # new.zip, the live version, is published after old.zip in both cases, so
    # old.zip is never the previous version (the most recently published
    # archive other than newer.zip) and only its age decides whether it stays.
    # 743 hours is just inside old.zip's 31 days, 24 hours is well inside its 29.
    jq --arg o "$OLD_SHA" --arg t "$(days_ago "$age")" --arg n "$NEW_SHA" \
      --arg p "$(hours_ago $(( age == 31 ? 31 * 24 - 1 : 24 )))" \
      '.zips |= map(if .sha256 == $o then .published_at = $t elif .sha256 == $n then .published_at = $p else . end)' \
      "$EDGE/deploy.json" > "$WORLD/d"
  fi
  cp "$WORLD/d" "$EDGE/deploy.json"
  ZIP_UNDER_TEST="$FIX/newer.zip" run_scenario --yes
  check "$age: exits 0" [ "$RC" = 0 ]
  case "$age" in
    31)
      check "31 days: the archive is no longer served" [ ! -e "$EDGE/$(vkey "$OLD_SHA")" ]
      check "31 days: deploy.json lists only the previous and the current" \
        [ "$(listed_zips "$EDGE/deploy.json")" = "$(sorted "$NEW_SHA" "$NEWER_SHA")" ]
      check "31 days: the dropped archive is named" grep -q "dropped $OLD_SHA" "$OUT"
      check "31 days: the dropped archive is not fetched" never "curl GET $LIVE/$(vkey "$OLD_SHA")"
      check "31 days but the previous version: still served" same "$EDGE/$(vkey "$NEW_SHA")" "$FIX/new.zip"
      ;;
    29)
      check "29 days: still served" same "$EDGE/$(vkey "$OLD_SHA")" "$FIX/old.zip"
      check "29 days: deploy.json lists all three" \
        [ "$(listed_zips "$EDGE/deploy.json")" = "$(sorted "$OLD_SHA" "$NEW_SHA" "$NEWER_SHA")" ]
      ;;
    missing)
      check "no published_at: still served" same "$EDGE/$(vkey "$OLD_SHA")" "$FIX/old.zip"
      check "no published_at: a warning names it" grep -q "WARNING: $OLD_SHA has no readable published_at" "$OUT"
      ;;
  esac
  dump_on_failure "$f0"
done

echo "(20) the previous version by published_at"
# W (legacy) 50 days ago, X (old) 40, Y (new) 35 and live. A re-publish of Y
# keeps X, the version before it; W is three versions back and goes.
# Publishing Z (newer) makes Y the previous version, and X goes too.
for how in none same newer; do
  new_world "previous_$how"; f0=$FAILED; run_scenario --yes
  jq --arg w "$LEGACY_SHA" --argjson ws "$(wc -c < "$FIX/legacy.zip")" --arg wt "$(days_ago 50)" \
    --arg x "$OLD_SHA" --arg xt "$(days_ago 40)" --arg y "$NEW_SHA" --arg yt "$(days_ago 35)" \
    '.zips |= (map(if .sha256 == $x then .published_at = $xt elif .sha256 == $y then .published_at = $yt else . end)
               + [{sha256: $w, size: $ws, published_at: $wt}])' "$EDGE/deploy.json" > "$WORLD/d"
  cp "$WORLD/d" "$EDGE/deploy.json"
  case "$how" in
    none) ZIP_UNDER_TEST=none run_scenario --yes ;;
    same) ZIP_UNDER_TEST="$FIX/new.zip" run_scenario --yes ;;
    newer) ZIP_UNDER_TEST="$FIX/newer.zip" run_scenario --yes ;;
  esac
  check "$how: exits 0" [ "$RC" = 0 ]
  check "$how: three versions back is dropped" grep -q "dropped $LEGACY_SHA" "$OUT"
  if [[ "$how" == newer ]]; then
    check "$how: the old previous version is dropped" [ ! -e "$EDGE/$(vkey "$OLD_SHA")" ]
    check "$how: deploy.json lists the previous and the current" \
      [ "$(listed_zips "$EDGE/deploy.json")" = "$(sorted "$NEW_SHA" "$NEWER_SHA")" ]
  else
    check "$how: the version before the live one is still served" same "$EDGE/$(vkey "$OLD_SHA")" "$FIX/old.zip"
    check "$how: deploy.json lists the previous and the live" \
      [ "$(listed_zips "$EDGE/deploy.json")" = "$(sorted "$OLD_SHA" "$NEW_SHA")" ]
  fi
  dump_on_failure "$f0"
done

echo
echo "passed: $PASSED, failed: $FAILED"
[[ "$FAILED" == 0 ]]
