#!/usr/bin/env bash
# ============================================================================
# Stub test for tool/cloudflare/deploy_web.sh. Touches nothing outside a
# temporary directory: each scenario runs a copy of the script inside a
# throwaway git repository, with fake `wrangler` (installed by a fake `npm ci`),
# `curl` and `uv` first on PATH, and fake tool/build_web.sh and
# tool/upload_web_sourcemaps.sh committed in the repository. Every fake
# records its call in $STUB_LOG.
#
# Hosts are directories under $STUB_WEB/<host>/. The fake `wrangler deploy`
# copies build/web/ to umacapture.com, or to the staging workers.dev host when
# given `--env staging`; `--dry-run` copies nothing. The fake `curl` answers a
# GET from the host directory (200 with the file, 404 without it) and sends
# COOP/COEP with every 200.
#
# Asserts:
#   (1) production: source maps go to Sentry, the assets-only config is
#       deployed to umacapture.com, no tables are built, and deploy.json has
#       no tables entry
#   (2) staging: nothing goes to Sentry (and no Sentry token is needed), the
#       tables are built, server/wrangler.jsonc is deployed with --env staging,
#       verification reads the staging host, deploy.json names the module
#       archive, and the deployed tables become the baseline
#   (3) staging --dry-run: no deploy without --dry-run, and the baseline is
#       left alone
#   (4) production --dry-run: no deploy without --dry-run (stage 2 still runs)
#   (5) staging where the table builder records no source sha256: the run
#       stops before anything is deployed
#
# Run from Git Bash:  bash tool/cloudflare/test/deploy_web_test.sh
# Needs git and sha256sum.
# ============================================================================
set -euo pipefail

SCRIPT_REL="tool/cloudflare/deploy_web.sh"
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASSED=0
FAILED=0
pass() { echo "  ok: $*"; PASSED=$((PASSED + 1)); }
flunk() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else flunk "$name"; fi; }

STAGING_HOST="umacapture-web-staging.umasagashi.workers.dev"
MODULE_SHA="$(printf 'a%.0s' {1..64})"

# ---- A repository holding the script and fake build steps, committed ---------
TEMPLATE="$ROOT/template"
mkdir -p "$TEMPLATE/tool/cloudflare" "$TEMPLATE/server/src"
cp "$SRC_ROOT/$SCRIPT_REL" "$TEMPLATE/$SCRIPT_REL"
cat > "$TEMPLATE/tool/build_web.sh" <<'SH'
echo "build_web $*" >> "$STUB_LOG"
mkdir -p build/web/wasm
printf 'wasm' > build/web/wasm/umacapture_core.wasm
printf '<html></html>' > build/web/index.html
SH
cat > "$TEMPLATE/tool/upload_web_sourcemaps.sh" <<'SH'
echo "sentry upload" >> "$STUB_LOG"
SH
printf '{}\n' > "$TEMPLATE/server/package.json"
printf '/build/\n/server/node_modules/\n/server/src/tables.generated.json\n/tool/cloudflare/.deploy-backup/\n/tool/cloudflare/.env\n' \
  > "$TEMPLATE/.gitignore"
git -C "$TEMPLATE" init -q
git -C "$TEMPLATE" config core.autocrlf false
git -C "$TEMPLATE" add -A
git -C "$TEMPLATE" -c user.name=stub -c user.email=stub@example.com commit -q -m fixture
printf 'CLOUDFLARE_API_TOKEN=stub-token\nCLOUDFLARE_ACCOUNT_ID=stub-account\n' > "$TEMPLATE/tool/cloudflare/.env"

# ---- Stubs ------------------------------------------------------------------
BIN="$ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/wrangler" <<'SH'
#!/usr/bin/env bash
echo "wrangler $*" >> "$STUB_LOG"
[[ "$1" == --version ]] && { echo "4.113.0"; exit 0; }
[[ "$1" == deploy ]] || exit 2
host=umacapture.com
prev=""
for a in "$@"; do
  [[ "$a" == --dry-run ]] && exit 0
  [[ "$prev" == --env && "$a" == staging ]] && host="umacapture-web-staging.umasagashi.workers.dev"
  prev="$a"
done
rm -rf "$STUB_WEB/$host"
mkdir -p "$STUB_WEB/$host"
cp -R build/web/. "$STUB_WEB/$host/"
SH
cat > "$BIN/npm" <<SH
#!/usr/bin/env bash
echo "npm \$*" >> "\$STUB_LOG"
mkdir -p node_modules/.bin
cp "$BIN/wrangler" node_modules/.bin/wrangler
SH
cat > "$BIN/uv" <<SH
#!/usr/bin/env bash
echo "uv \$*" >> "\$STUB_LOG"
out=""; source_out=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in --out) out="\$2"; shift ;; --source-out) source_out="\$2"; shift ;; esac
  shift
done
printf '{"version":"v1","names":{},"gids":{}}' > "\$out"
[[ -n "\${STUB_NO_SOURCE:-}" ]] || echo "$MODULE_SHA" > "\$source_out"
echo "wrote \$out"
SH
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
body=/dev/null; headers=""; fmt=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) body="$2"; shift ;;
    -D) headers="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
echo "curl GET $url" >> "$STUB_LOG"
rest="${url#https://}"
host="${rest%%/*}"
path="/${rest#*/}"
[[ "$path" == / ]] && path=/index.html
src="$STUB_WEB/$host$path"
if [[ -f "$src" ]]; then code=200; cp "$src" "$body"; else code=404; : > "$body"; fi
if [[ -n "$headers" ]]; then
  { printf 'HTTP/1.1 %s\r\n' "$code"
    [[ "$code" == 200 ]] && printf 'cross-origin-opener-policy: same-origin\r\ncross-origin-embedder-policy: require-corp\r\n'
    printf '\r\n'; } > "$headers"
fi
[[ -n "$fmt" ]] && printf '%s' "$code"
exit 0
SH
chmod +x "$BIN/wrangler" "$BIN/npm" "$BIN/uv" "$BIN/curl"

# ---- Scenario runner --------------------------------------------------------
# run_world <name> <args...>: a fresh repository; sets REPO, STUB_LOG, STATUS.
run_world() {
  local world="$ROOT/$1"; shift
  REPO="$world/repo"
  export STUB_WEB="$world/web" STUB_LOG="$world/calls.log"
  mkdir -p "$world"
  : > "$STUB_LOG"
  cp -R "$TEMPLATE" "$REPO"
  set +e
  (cd "$REPO" && PATH="$BIN:$PATH" bash "$SCRIPT_REL" "$@") > "$world/out.log" 2>&1
  STATUS=$?
  set -e
}
called() { grep -qx -- "$1" "$STUB_LOG"; }
called_like() { grep -q -- "$1" "$STUB_LOG"; }
not() { ! "$@"; }

echo "(1) production"
SENTRY_AUTH_TOKEN=stub-sentry run_world prod --yes
check "exit 0" test "$STATUS" -eq 0
check "source maps sent to Sentry" called "sentry upload"
check "assets-only config deployed" called "wrangler deploy -c server/wrangler.assets-only.jsonc"
check "no tables built" not called_like "^uv "
check "verified on umacapture.com" called "curl GET https://umacapture.com/deploy.json"
check "deploy.json has no tables entry" not grep -q tables_module_sha256 "$STUB_WEB/umacapture.com/deploy.json"

echo "(2) staging"
(unset SENTRY_AUTH_TOKEN; run_world staging --target staging --yes; echo "$STATUS" > "$ROOT/staging.status")
STATUS="$(cat "$ROOT/staging.status")"
REPO="$ROOT/staging/repo"; STUB_LOG="$ROOT/staging/calls.log"; STUB_WEB="$ROOT/staging/web"
check "exit 0 without a Sentry token" test "$STATUS" -eq 0
check "nothing sent to Sentry" not called "sentry upload"
check "tables built against the baseline" \
  called_like "^uv run tool/cloudflare/build_share_tables.py --previous tool/cloudflare/.deploy-backup/tables.json --out server/src/tables.generated.json --source-out "
check "staging env deployed" called "wrangler deploy -c server/wrangler.jsonc --env staging"
check "nothing deployed to production" not test -e "$STUB_WEB/umacapture.com"
check "verified on the staging host" called "curl GET https://$STAGING_HOST/deploy.json"
check "deploy.json names the module archive" \
  grep -q "\"tables_module_sha256\": \"$MODULE_SHA\"" "$STUB_WEB/$STAGING_HOST/deploy.json"
check "deployed tables became the baseline" \
  cmp -s "$REPO/server/src/tables.generated.json" "$REPO/tool/cloudflare/.deploy-backup/tables.json"

echo "(3) staging --dry-run"
run_world staging_dry --target staging --dry-run
check "exit 0" test "$STATUS" -eq 0
check "dry run only" called "wrangler deploy -c server/wrangler.jsonc --env staging --dry-run"
check "no real deploy" not called "wrangler deploy -c server/wrangler.jsonc --env staging"
check "baseline untouched" not test -e "$REPO/tool/cloudflare/.deploy-backup/tables.json"

echo "(4) production --dry-run"
SENTRY_AUTH_TOKEN=stub-sentry run_world prod_dry --dry-run
check "exit 0" test "$STATUS" -eq 0
check "source maps still sent" called "sentry upload"
check "no real deploy" not called "wrangler deploy -c server/wrangler.assets-only.jsonc"

echo "(5) staging, the source archive's sha256 not recorded"
STUB_NO_SOURCE=1 run_world staging_no_source --target staging --yes
check "stops" test "$STATUS" -ne 0
check "nothing deployed" not called_like "^wrangler deploy"

echo
echo "passed $PASSED, failed $FAILED"
[[ "$FAILED" -eq 0 ]]
