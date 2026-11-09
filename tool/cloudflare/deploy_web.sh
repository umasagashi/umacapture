#!/usr/bin/env bash
# ============================================================================
# Deploy the Flutter web app. Two independent choices pick what is deployed:
#
#   --target   where it goes
#     production (default)  https://umacapture.com (the top level of the config)
#     staging               https://umacapture-web-staging.umasagashi.workers.dev
#                           (env.staging of the config)
#   --sharing  whether the Worker (logins, record sharing, file sync and its
#              hourly run) comes with the assets
#     on (default)  server/wrangler.jsonc: the Worker answers /r/*, /u/* and /api/*
#                   and every path that matches no file, with its D1
#     off           server/wrangler.assets-only.jsonc: no Worker script at all,
#                   so those paths get the static 404. This is how logins,
#                   sharing and sync are all switched off together with the
#                   assets of the current HEAD.
#
# Invariant, for every combination: what is uploaded is build/web/ as built
# from the committed HEAD in THIS run. A previous build/web/ is never reused,
# and a dirty working tree stops the script before it builds, so deploy.json's
# git_sha names the source of every byte served.
#
# Stages (a stage marked with a choice runs for that choice only):
#   0 preflight (tools, clean tree, credentials), then `npm ci` in server/ so
#     the wrangler run below is the one pinned in server/package-lock.json,
#     never whatever wrangler is on PATH
#   1 build: tool/build_web.sh --source-maps (refuses to build unless web/
#     matches tool/web_deps.json, including the wasm source digest)
#   2 [production] source maps: tool/upload_web_sourcemaps.sh. This SENDS the
#     maps to Sentry and rewrites build/web/ in place (debug ids), so it runs
#     before the tree is fingerprinted and uploaded. Staging sends nothing to
#     Sentry. Either way the maps are excluded from the deployment by
#     web/.assetsignore.
#   3 name tables and page fonts:
#     [sharing on] the Worker reads its name tables from the target's own D1,
#     where tool/cloudflare/publish_modules.sh appends them with every module
#     set, so this script neither builds nor bundles them.
#     tool/cloudflare/load_share_tables.py --read-to reads them back from that
#     D1 and stops the run, before anything is deployed, when D1 records no
#     load: a Worker there would answer every name lookup with a 500. With
#     sharing off no Worker is deployed, so nothing looks a name up and D1 is
#     not read.
#     Then, for either choice, tool/cloudflare/build_page_fonts.py writes the
#     public pages' font files into build/web/site/fonts/ (the files
#     web/site/site.css names): subsets of the pinned M PLUS Rounded 1c, cut to
#     the pages' wording and, with sharing on, the names read back from D1.
#   4 write build/web/deploy.json (git_sha, build time, wasm sha256, and
#     "name_tables": "d1", which says that any Worker of this version reads its
#     name tables from D1)
#   5 wrangler deploy --dry-run (config and asset collection, no upload)
#   6 confirmation gate ('yes')          <- --dry-run stops here;
#                                           --yes answers it without a prompt
#   7 wrangler deploy
#   8 verify through the public URL: deploy.json matches, "/" carries
#     COOP/COEP, a source map answers 404, and /r/0000000000 answers 404 from
#     the side the --sharing choice expects: the Worker's 404 carries
#     X-Robots-Tag: noindex, the static 404 carries no X-Robots-Tag
#
# --dry-run still runs stages 1 to 3, because stage 5 needs a real tree; for
# production stage 2 therefore still uploads source maps to Sentry.
#
# Rolling back does not go through this script: `wrangler rollback <version-id>
# --name <worker>` with the id of the version to return to, never without one
# (see docs/web-deploy.md). It needs no build, no Sentry and no clean tree.
# Never roll back to a version with the Worker whose deploy.json lacks
# "name_tables": "d1": its Worker resolves names through tables bundled when it was deployed, which
# can be shorter than D1's, so records shared under D1's tables would not be
# readable. D1 is not rolled back. A version deployed with --sharing off has no
# Worker and reads no names, so returning to one stays a way to stop sharing.
#
# Run from Git Bash at the repository root:
#   export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"   # production only
#   bash tool/cloudflare/deploy_web.sh [--target production|staging] [--sharing on|off] [--dry-run] [--yes]
# Cloudflare credentials come from tool/cloudflare/.env (see .env.example).
#
# NOTE: `set -x` is deliberately never enabled, so no token is ever printed.
# ============================================================================
set -euo pipefail

# wrangler reports usage metrics to Cloudflare unless told not to. This
# variable takes precedence over the `send_metrics` key and over the consent
# stored in wrangler's user config, for every wrangler run below.
export WRANGLER_SEND_METRICS=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WEB_DIR="build/web"
ENV_FILE="$SCRIPT_DIR/.env"
SERVER_DIR="server"
WRANGLER="$REPO_ROOT/$SERVER_DIR/node_modules/.bin/wrangler"
# The name tables stage 3 reads back from D1, for the page fonts. Relative, so the Windows Python
# reads the same path; build/ is ignored and outside the uploaded build/web/.
TABLES_READ="build/share_tables.json"
# The edge may take a moment to switch versions; retry a mismatching
# deploy.json for this long before failing.
VERIFY_WAIT_SECONDS=120
RETRY_INTERVAL_SECONDS=10

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

usage="usage: $0 [--target production|staging] [--sharing on|off] [--dry-run] [--yes]"
TARGET=production
SHARING=on
DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) [[ $# -ge 2 ]] || fail "$usage"; TARGET="$2"; shift ;;
    --sharing) [[ $# -ge 2 ]] || fail "$usage"; SHARING="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) fail "$usage" ;;
  esac
  shift
done

# Everything that differs between the choices is set here and nowhere else. The target and the
# sharing choice are independent: each sets its own variables, and only the line after them
# (WRANGLER_ARGS) combines the two.
#   PUBLIC_ROOT      where stage 8 verifies
#   SENTRY_MAPS      upload source maps to Sentry (stage 2)
#   BUILD_ARGS       extra arguments for the web build (stage 1)
#   ENV_ARGS         the config environment the target lives in
#   CONFIG           the wrangler config of the sharing choice
#   SHARE_TABLES     read the name tables back from the target's D1 (stage 3)
#   NOT_FOUND_FROM   what stage 8 expects to answer /r/0000000000 with a 404, and
#   NOT_FOUND_ROBOTS the X-Robots-Tag that tells it apart: the Worker's own 404 says noindex
#                    (server/src/worker.mjs), the static 404 says nothing
case "$TARGET" in
  production)
    PUBLIC_ROOT="https://umacapture.com"
    SENTRY_MAPS=1
    # The app's built-in sharing origin is production's.
    BUILD_ARGS=()
    ENV_ARGS=()
    ;;
  staging)
    # <worker name>-<env>.<account workers.dev subdomain>.workers.dev
    PUBLIC_ROOT="https://umacapture-web-staging.umasagashi.workers.dev"
    # Staging deployments send nothing to Sentry.
    SENTRY_MAPS=0
    # Point the app's record sharing at this deployment's own origin, not production.
    BUILD_ARGS=("--dart-define=UMACAPTURE_SHARING_ORIGIN=$PUBLIC_ROOT")
    ENV_ARGS=(--env staging)
    ;;
  *) fail "$usage" ;;
esac
case "$SHARING" in
  on)
    CONFIG=server/wrangler.jsonc
    SHARE_TABLES=1
    NOT_FOUND_FROM="the sharing and sync Worker"
    NOT_FOUND_ROBOTS=noindex
    ;;
  off)
    CONFIG=server/wrangler.assets-only.jsonc
    SHARE_TABLES=0
    NOT_FOUND_FROM="the static assets"
    NOT_FOUND_ROBOTS=""
    ;;
  *) fail "$usage" ;;
esac
WRANGLER_ARGS=(-c "$CONFIG" ${ENV_ARGS[@]+"${ENV_ARGS[@]}"})

cd "$REPO_ROOT"

# ---- 0 preflight -------------------------------------------------------------
step "0 preflight ($TARGET, sharing $SHARING)"
tools=(git curl sha256sum npm node uv)
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || fail "$tool not found on PATH"
done
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean; commit or remove changes first"
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE missing (copy .env.example)"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "CLOUDFLARE_API_TOKEN is empty in $ENV_FILE"
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || fail "CLOUDFLARE_ACCOUNT_ID is empty in $ENV_FILE"
if [[ "$SENTRY_MAPS" == 1 ]]; then
  [[ -n "${SENTRY_AUTH_TOKEN:-}" ]] || fail "SENTRY_AUTH_TOKEN is not set (stage 2 uploads source maps)"
fi
GIT_SHA="$(git rev-parse HEAD)"
(cd "$SERVER_DIR" && npm ci --no-audit --no-fund)
[[ -x "$WRANGLER" ]] || fail "$WRANGLER missing after npm ci"
echo "    HEAD $GIT_SHA, wrangler $("$WRANGLER" --version 2>/dev/null | tail -1)"

# ---- 1 build -----------------------------------------------------------------
step "1 build"
rm -rf "$WEB_DIR"
bash tool/build_web.sh --source-maps ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

# ---- 2 source maps -----------------------------------------------------------
if [[ "$SENTRY_MAPS" == 1 ]]; then
  step "2 upload source maps to Sentry"
  bash tool/upload_web_sourcemaps.sh
fi

# ---- 3 name tables and page fonts --------------------------------------------
FONT_ARGS=()
if [[ "$SHARE_TABLES" == 1 ]]; then
  step "3 name tables in the $TARGET D1"
  rm -f "$TABLES_READ"
  uv run tool/cloudflare/load_share_tables.py --target "$TARGET" --read-to "$TABLES_READ" \
    || fail "the $TARGET D1 holds no name tables the Worker could read (none loaded, or loaded without their tags); load_share_tables.py says which above"
  [[ -f "$TABLES_READ" ]] || fail "load_share_tables.py did not write $TABLES_READ"
  # The record pages print the names in these tables, so the font covers them too.
  FONT_ARGS=(--tables "$TABLES_READ")
fi
step "3 page fonts"
uv run tool/cloudflare/build_page_fonts.py --web-out "$WEB_DIR" ${FONT_ARGS[@]+"${FONT_ARGS[@]}"} \
  || fail "build_page_fonts.py did not write the public pages' fonts"

# ---- 4 deploy.json -----------------------------------------------------------
step "4 deploy.json"
WASM_SHA="$(sha_of "$WEB_DIR/wasm/umacapture_core.wasm")"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{\n  "git_sha": "%s",\n  "built_at": "%s",\n  "wasm_sha256": "%s",\n  "name_tables": "d1"\n}\n' \
  "$GIT_SHA" "$BUILT_AT" "$WASM_SHA" > "$WEB_DIR/deploy.json"
DEPLOY_SHA="$(sha_of "$WEB_DIR/deploy.json")"
cat "$WEB_DIR/deploy.json"

# ---- 5 dry run ---------------------------------------------------------------
step "5 wrangler deploy --dry-run"
"$WRANGLER" deploy "${WRANGLER_ARGS[@]}" --dry-run

# ---- 6 confirmation gate -----------------------------------------------------
step "6 confirm"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "    --dry-run: stopping before any upload to Cloudflare."
  exit 0
fi
if [[ "$ASSUME_YES" != 1 ]]; then
  read -r -p "    Publish $GIT_SHA to $PUBLIC_ROOT? Type 'yes': " answer
  [[ "$answer" == "yes" ]] || fail "aborted"
fi

# ---- 7 deploy ----------------------------------------------------------------
step "7 wrangler deploy"
"$WRANGLER" deploy "${WRANGLER_ARGS[@]}"

# ---- 8 verify ----------------------------------------------------------------
step "8 verify via $PUBLIC_ROOT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status_of() { curl -sS -o /dev/null -w '%{http_code}' "$PUBLIC_ROOT$1" || echo "000"; }

deadline=$(( $(date +%s) + VERIFY_WAIT_SECONDS ))
while :; do
  code="$(curl -sS -o "$work/deploy.json" -w '%{http_code}' -H 'Cache-Control: no-cache' \
    "$PUBLIC_ROOT/deploy.json" || echo "000")"
  [[ "$code" == "200" && "$(sha_of "$work/deploy.json")" == "$DEPLOY_SHA" ]] && break
  [[ "$(date +%s)" -lt "$deadline" ]] || fail "deploy.json: HTTP $code, body does not match the local one"
  echo "    deploy.json not yet the new version (HTTP $code), retrying in ${RETRY_INTERVAL_SECONDS}s..."
  sleep "$RETRY_INTERVAL_SECONDS"
done
echo "    deploy.json matches"

# header <file> <lowercase name>: the value of that header in a curl -D dump.
header() { tr -d '\r' < "$1" | awk -F': ' -v h="$2" 'tolower($1)==h{print $2}'; }

curl -sS -D "$work/root.headers" -o /dev/null "$PUBLIC_ROOT/"
[[ "$(header "$work/root.headers" cross-origin-opener-policy)" == "same-origin" ]] || fail "/ lacks COOP: same-origin"
[[ "$(header "$work/root.headers" cross-origin-embedder-policy)" == "require-corp" ]] || fail "/ lacks COEP: require-corp"
echo "    / carries COOP/COEP"

[[ "$(status_of /main.dart.js.map)" == "404" ]] || fail "/main.dart.js.map is served (web/.assetsignore not applied)"
echo "    source map answers 404"

# A 404 alone cannot tell the Worker from the static assets: both answer an unknown /r/ id with 404.
# The X-Robots-Tag tells them apart, so a deploy whose Worker did not come up (or did not go away)
# stops here.
code="$(curl -sS -D "$work/record.headers" -o /dev/null -w '%{http_code}' "$PUBLIC_ROOT/r/0000000000" || echo "000")"
[[ "$code" == "404" ]] || fail "/r/0000000000: HTTP $code, not a 404"
robots="$(header "$work/record.headers" x-robots-tag)"
[[ "$robots" == "$NOT_FOUND_ROBOTS" ]] \
  || fail "/r/0000000000 is not answered by $NOT_FOUND_FROM (X-Robots-Tag '$robots', expected '$NOT_FOUND_ROBOTS')"
echo "    /r/0000000000 is the 404 of $NOT_FOUND_FROM"

step "done: $GIT_SHA is live at $PUBLIC_ROOT"
