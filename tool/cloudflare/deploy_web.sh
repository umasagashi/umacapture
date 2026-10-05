#!/usr/bin/env bash
# ============================================================================
# Deploy the Flutter web app to one of two targets:
#
#   production (default)  https://umacapture.com, as a static-assets-only
#                         Worker (server/wrangler.assets-only.jsonc). No Worker
#                         script is uploaded.
#   staging               https://umacapture-web-staging.umasagashi.workers.dev,
#                         the same assets together with the record-sharing
#                         Worker and its staging D1 (server/wrangler.jsonc,
#                         env.staging).
#
# Invariant, for both targets: what is uploaded is build/web/ as built from the
# committed HEAD in THIS run. A previous build/web/ is never reused, and a
# dirty working tree stops the script before it builds, so deploy.json's
# git_sha names the source of every byte served.
#
# Stages (a stage marked with a target runs for that target only):
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
#   3 [staging] name tables: tool/cloudflare/build_share_tables.py writes
#     server/src/tables.generated.json from the module archive the live
#     pointer names, checked append-only against the baseline
#     tool/cloudflare/.deploy-backup/tables.json; the Worker bundles it
#   4 write build/web/deploy.json (git_sha, build time, wasm sha256, and for
#     staging the sha256 of the module archive the tables were built from)
#   5 wrangler deploy --dry-run (config and asset collection, no upload)
#   6 confirmation gate ('yes')          <- --dry-run stops here;
#                                           --yes answers it without a prompt
#   7 wrangler deploy
#   8 verify through the public URL: deploy.json matches, "/" carries
#     COOP/COEP, a source map and an unknown path both answer 404
#   9 [staging] promote the deployed tables to the baseline
#
# --dry-run still runs stages 1 to 3, because stage 5 needs a real tree; for
# production stage 2 therefore still uploads source maps to Sentry. Rolling
# back is `wrangler rollback` with the target's config (see docs/web-deploy.md).
#
# Run from Git Bash at the repository root:
#   export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"   # production only
#   bash tool/cloudflare/deploy_web.sh [--target production|staging] [--dry-run] [--yes]
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
TABLES_OUT="server/src/tables.generated.json"
TABLES_BASELINE="tool/cloudflare/.deploy-backup/tables.json"
# The edge may take a moment to switch versions; retry a mismatching
# deploy.json for this long before failing.
VERIFY_WAIT_SECONDS=120
RETRY_INTERVAL_SECONDS=10

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

usage="usage: $0 [--target production|staging] [--dry-run] [--yes]"
TARGET=production
DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) [[ $# -ge 2 ]] || fail "$usage"; TARGET="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) fail "$usage" ;;
  esac
  shift
done

# Everything that differs between the targets is set here and nowhere else.
#   SENTRY_MAPS    upload source maps to Sentry (stage 2)
#   SHARE_TABLES   build the name tables the Worker bundles (stages 3 and 9)
#   WRANGLER_ARGS  config (and environment) handed to every wrangler deploy
case "$TARGET" in
  production)
    PUBLIC_ROOT="https://umacapture.com"
    WRANGLER_ARGS=(-c server/wrangler.assets-only.jsonc)
    SENTRY_MAPS=1
    SHARE_TABLES=0
    ;;
  staging)
    # <worker name>-<env>.<account workers.dev subdomain>.workers.dev
    PUBLIC_ROOT="https://umacapture-web-staging.umasagashi.workers.dev"
    WRANGLER_ARGS=(-c server/wrangler.jsonc --env staging)
    # Staging deployments send nothing to Sentry.
    SENTRY_MAPS=0
    SHARE_TABLES=1
    ;;
  *) fail "$usage" ;;
esac

cd "$REPO_ROOT"

# ---- 0 preflight -------------------------------------------------------------
step "0 preflight ($TARGET)"
tools=(git curl sha256sum npm)
[[ "$SHARE_TABLES" == 1 ]] && tools+=(uv)
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
bash tool/build_web.sh --source-maps

# ---- 2 source maps -----------------------------------------------------------
if [[ "$SENTRY_MAPS" == 1 ]]; then
  step "2 upload source maps to Sentry"
  bash tool/upload_web_sourcemaps.sh
fi

# ---- 3 name tables -----------------------------------------------------------
TABLES_ARCHIVE_SHA=""
if [[ "$SHARE_TABLES" == 1 ]]; then
  step "3 name tables"
  rm -f "$TABLES_OUT"
  tables_source="$(mktemp)"
  uv run tool/cloudflare/build_share_tables.py --previous "$TABLES_BASELINE" --out "$TABLES_OUT" \
    --source-out "$tables_source" || { rm -f "$tables_source"; fail "build_share_tables.py refused to build the tables"; }
  TABLES_ARCHIVE_SHA="$(tr -d '\r\n' < "$tables_source")"
  rm -f "$tables_source"
  [[ "$TABLES_ARCHIVE_SHA" =~ ^[0-9a-f]{64}$ && -f "$TABLES_OUT" ]] \
    || fail "build_share_tables.py did not record the sha256 of the archive it read"
fi

# ---- 4 deploy.json -----------------------------------------------------------
step "4 deploy.json"
WASM_SHA="$(sha_of "$WEB_DIR/wasm/umacapture_core.wasm")"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$SHARE_TABLES" == 1 ]]; then
  printf '{\n  "git_sha": "%s",\n  "built_at": "%s",\n  "wasm_sha256": "%s",\n  "tables_module_sha256": "%s"\n}\n' \
    "$GIT_SHA" "$BUILT_AT" "$WASM_SHA" "$TABLES_ARCHIVE_SHA" > "$WEB_DIR/deploy.json"
else
  printf '{\n  "git_sha": "%s",\n  "built_at": "%s",\n  "wasm_sha256": "%s"\n}\n' \
    "$GIT_SHA" "$BUILT_AT" "$WASM_SHA" > "$WEB_DIR/deploy.json"
fi
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

curl -sS -D "$work/root.headers" -o /dev/null "$PUBLIC_ROOT/"
header() { tr -d '\r' < "$work/root.headers" | awk -F': ' -v h="$1" 'tolower($1)==h{print $2}'; }
[[ "$(header cross-origin-opener-policy)" == "same-origin" ]] || fail "/ lacks COOP: same-origin"
[[ "$(header cross-origin-embedder-policy)" == "require-corp" ]] || fail "/ lacks COEP: require-corp"
echo "    / carries COOP/COEP"

[[ "$(status_of /main.dart.js.map)" == "404" ]] || fail "/main.dart.js.map is served (web/.assetsignore not applied)"
[[ "$(status_of /r/0000000000)" == "404" ]] || fail "/r/0000000000 is not a 404"
echo "    source map and unknown path answer 404"

# ---- 9 baseline --------------------------------------------------------------
# Only tables that are now live become the baseline: a run that stopped earlier
# leaves the previous baseline in place.
if [[ "$SHARE_TABLES" == 1 ]]; then
  step "9 promote the deployed tables to $TABLES_BASELINE"
  mkdir -p "$(dirname "$TABLES_BASELINE")"
  cp "$TABLES_OUT" "$TABLES_BASELINE"
fi

step "done: $GIT_SHA is live at $PUBLIC_ROOT"
