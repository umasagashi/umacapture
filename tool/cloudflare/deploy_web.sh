#!/usr/bin/env bash
# ============================================================================
# Deploy the Flutter web app to https://umacapture.com as a static-assets-only
# Worker (server/wrangler.assets-only.jsonc). No Worker script is uploaded.
#
# Invariant: what is uploaded is build/web/ as built from the committed HEAD
# in THIS run. A previous build/web/ is never reused, and a dirty working tree
# stops the script before it builds, so deploy.json's git_sha names the source
# of every byte served.
#
# Stages:
#   0 preflight (tools, clean tree, credentials for Cloudflare and Sentry)
#   1 build: tool/build_web.sh --source-maps (refuses to build unless web/
#     matches tool/web_deps.json, including the wasm source digest)
#   2 source maps: tool/upload_web_sourcemaps.sh. This SENDS the maps to Sentry
#     and rewrites build/web/ in place (debug ids), so it runs before the tree
#     is fingerprinted and uploaded. The maps themselves are excluded from the
#     deployment by web/.assetsignore.
#   3 write build/web/deploy.json (git_sha, build time, wasm sha256)
#   4 wrangler deploy --dry-run (config and asset collection, no upload)
#   5 confirmation gate ('yes')          <- --dry-run stops here;
#                                           --yes answers it without a prompt
#   6 wrangler deploy
#   7 verify through the public URL: deploy.json matches, "/" carries
#     COOP/COEP, a source map and an unknown path both answer 404
#
# --dry-run still runs stages 1 and 2, because stage 4 needs a real tree;
# stage 2 therefore still uploads source maps to Sentry. Rolling back is
# `wrangler rollback -c server/wrangler.assets-only.jsonc` (see
# docs/web-deploy.md).
#
# Run from Git Bash at the repository root:
#   export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"
#   bash tool/cloudflare/deploy_web.sh [--dry-run] [--yes]
# Cloudflare credentials come from tool/cloudflare/.env (see .env.example).
#
# NOTE: `set -x` is deliberately never enabled, so no token is ever printed.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PUBLIC_ROOT="https://umacapture.com"
WRANGLER_CONFIG="server/wrangler.assets-only.jsonc"
WEB_DIR="build/web"
ENV_FILE="$SCRIPT_DIR/.env"
# The edge may take a moment to switch versions; retry a mismatching
# deploy.json for this long before failing.
VERIFY_WAIT_SECONDS=120
RETRY_INTERVAL_SECONDS=10

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) fail "usage: $0 [--dry-run] [--yes]" ;;
  esac
done

cd "$REPO_ROOT"

# ---- 0 preflight -------------------------------------------------------------
step "0 preflight"
for tool in git curl sha256sum wrangler; do
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
[[ -n "${SENTRY_AUTH_TOKEN:-}" ]] || fail "SENTRY_AUTH_TOKEN is not set (stage 2 uploads source maps)"
GIT_SHA="$(git rev-parse HEAD)"
echo "    HEAD $GIT_SHA, wrangler $(wrangler --version 2>/dev/null | tail -1)"

# ---- 1 build -----------------------------------------------------------------
step "1 build"
rm -rf "$WEB_DIR"
bash tool/build_web.sh --source-maps

# ---- 2 source maps -----------------------------------------------------------
step "2 upload source maps to Sentry"
bash tool/upload_web_sourcemaps.sh

# ---- 3 deploy.json -----------------------------------------------------------
step "3 deploy.json"
WASM_SHA="$(sha_of "$WEB_DIR/wasm/umacapture_core.wasm")"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{\n  "git_sha": "%s",\n  "built_at": "%s",\n  "wasm_sha256": "%s"\n}\n' \
  "$GIT_SHA" "$BUILT_AT" "$WASM_SHA" > "$WEB_DIR/deploy.json"
DEPLOY_SHA="$(sha_of "$WEB_DIR/deploy.json")"
cat "$WEB_DIR/deploy.json"

# ---- 4 dry run ---------------------------------------------------------------
step "4 wrangler deploy --dry-run"
wrangler deploy -c "$WRANGLER_CONFIG" --dry-run

# ---- 5 confirmation gate -----------------------------------------------------
step "5 confirm"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "    --dry-run: stopping before any upload to Cloudflare."
  exit 0
fi
if [[ "$ASSUME_YES" != 1 ]]; then
  read -r -p "    Publish $GIT_SHA to $PUBLIC_ROOT? Type 'yes': " answer
  [[ "$answer" == "yes" ]] || fail "aborted"
fi

# ---- 6 deploy ----------------------------------------------------------------
step "6 wrangler deploy"
wrangler deploy -c "$WRANGLER_CONFIG"

# ---- 7 verify ----------------------------------------------------------------
step "7 verify via $PUBLIC_ROOT"
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

step "done: $GIT_SHA is live at $PUBLIC_ROOT"
