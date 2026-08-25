#!/usr/bin/env bash
# ============================================================================
# Stage 1 of the R2 migration: create the bucket, connect the custom domain,
# set CORS, upload the 5 distribution files, and verify.
#
# This stage changes no URL a released app resolves: it only stands up
# https://data.umacapture.com/umacapture/* alongside the existing origin, and the
# old https://umasagashi.com/data/umacapture/* URLs are untouched until stage 2
# (r2_stage2_redirect.sh) installs the redirect rule.
#
# It is NOT, however, free of side effects on the production bucket. Steps 3 and 4
# REPLACE the whole CORS policy of the existing 'umasagashi-data' bucket and
# OVERWRITE five live objects with whatever the old origin serves at that moment,
# so they sit behind the same 'yes' gate the sibling scripts use.
#
# See .notes/analysis/wasm_poc5/r2_setup_runbook.md (Step-by-step 1-5).
#
# Run from Git Bash:  bash tool/cloudflare/r2_stage1_setup.sh
# Credentials come from tool/cloudflare/.env (copy .env.example first).
#
# NOTE: `set -x` is deliberately never enabled anywhere in this script, so the
# API token is never printed to the terminal or a log.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Fixed configuration (must match r2_setup_runbook.md) ------------------
BUCKET="umasagashi-data"
LOCATION="apac"
STORAGE_CLASS="Standard"
# The R2 bucket keeps its original name (umasagashi-data); only the public
# custom domain and its owning zone move to the new umacapture.com domain.
# OLD_ORIGIN stays on umasagashi.com -- it is the legacy source we copy from.
CUSTOM_DOMAIN="data.umacapture.com"
ZONE_NAME="umacapture.com"
OLD_ORIGIN="https://umasagashi.com/data/umacapture"
KEY_PREFIX="umacapture"
CACHE_CONTROL="public, max-age=14400, must-revalidate"
MODULES_ZIP_BYTES=10308164

# file name -> Content-Type
declare -A CONTENT_TYPES=(
  ["modules.zip"]="application/zip"
  ["news.md"]="text/markdown; charset=utf-8"
  ["version_info.json"]="application/json"
  ["sentry_rate_limit.json"]="application/json"
  ["sentry_sample.json"]="application/json"
)

CF_API="https://api.cloudflare.com/client/v4"

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

# ---- Load credentials ------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE not found. Copy .env.example to .env and fill in the values."
set -a
# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"
set +a
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "CLOUDFLARE_API_TOKEN is empty in $ENV_FILE."
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || fail "CLOUDFLARE_ACCOUNT_ID is empty in $ENV_FILE."
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
AUTH_HEADER="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

# ---- 1. Create the bucket (skip if it already exists) ----------------------
step "1. Bucket '$BUCKET'"
buckets_json="$(curl -sf -H "$AUTH_HEADER" \
  "$CF_API/accounts/$CLOUDFLARE_ACCOUNT_ID/r2/buckets")" \
  || fail "could not list R2 buckets (check the token's Workers R2 Storage scope)."
if echo "$buckets_json" | jq -e --arg b "$BUCKET" '.result.buckets[]? | select(.name == $b)' >/dev/null; then
  echo "    already exists -- skipping create."
else
  echo "    creating (location hint: $LOCATION, storage class: $STORAGE_CLASS)..."
  wrangler r2 bucket create "$BUCKET" --location "$LOCATION" --storage-class "$STORAGE_CLASS"
fi

# ---- 2. Connect the custom domain -----------------------------------------
step "2. Custom domain '$CUSTOM_DOMAIN'"
zone_json="$(curl -sf -H "$AUTH_HEADER" "$CF_API/zones?name=$ZONE_NAME")" \
  || fail "zone lookup failed (check the token's Zone > Zone > Read scope)."
ZONE_ID="$(echo "$zone_json" | jq -r '.result[0].id // empty')"
[[ -n "$ZONE_ID" ]] || fail "could not resolve zone id for $ZONE_NAME."
echo "    zone id resolved."
if wrangler r2 bucket domain list "$BUCKET" 2>/dev/null | grep -q "$CUSTOM_DOMAIN"; then
  echo "    already connected -- skipping."
else
  echo "    connecting (DNS CNAME is created automatically)..."
  wrangler r2 bucket domain add "$BUCKET" \
    --domain "$CUSTOM_DOMAIN" --zone-id "$ZONE_ID" --force
fi

# ---- Confirmation gate (steps 1-2 are create-if-absent; 3-4 are not) --------
# Everything above is idempotent and additive. From here on the script rewrites
# state that the production bucket already has, so confirm once before it does.
echo
echo "About to modify the LIVE R2 bucket '$BUCKET':"
echo "    step 3: REPLACE its entire CORS policy with $SCRIPT_DIR/cors.json"
echo "    step 4: OVERWRITE these objects under '$KEY_PREFIX/' with the current"
echo "            contents of $OLD_ORIGIN/*:"
echo "            ${!CONTENT_TYPES[*]}"
echo "The uploaded bytes are whatever the old origin serves right now; only"
echo "modules.zip is size-checked ($MODULES_ZIP_BYTES bytes)."
read -r -p "Type 'yes' to proceed: " reply
[[ "$reply" == "yes" ]] || fail "aborted (no changes made to the bucket's CORS policy or objects)."

# ---- 3. CORS ---------------------------------------------------------------
step "3. CORS policy"
wrangler r2 bucket cors set "$BUCKET" --file "$SCRIPT_DIR/cors.json" --force
echo "    applied from cors.json."

# ---- 4. Download the 5 files from the origin, then upload to R2 ------------
step "4. Fetch 5 files from origin and upload under '$KEY_PREFIX/'"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

for name in "${!CONTENT_TYPES[@]}"; do
  src="$OLD_ORIGIN/$name"
  dst="$TMPDIR/$name"
  echo "    download: $src"
  curl -fsSL -o "$dst" "$src" || fail "download failed: $src"
  size="$(wc -c < "$dst" | tr -d '[:space:]')"
  [[ "$size" -gt 0 ]] || fail "downloaded $name is empty."
  if [[ "$name" == "modules.zip" && "$size" -ne "$MODULES_ZIP_BYTES" ]]; then
    fail "modules.zip size $size != expected $MODULES_ZIP_BYTES."
  fi
  echo "      ok ($size bytes)"
done

for name in "${!CONTENT_TYPES[@]}"; do
  ct="${CONTENT_TYPES[$name]}"
  echo "    upload: $KEY_PREFIX/$name  (Content-Type: $ct)"
  wrangler r2 object put "$BUCKET/$KEY_PREFIX/$name" \
    --file "$TMPDIR/$name" \
    --content-type "$ct" \
    --cache-control "$CACHE_CONTROL" \
    --remote --force
done

# ---- 5. Verify via the custom domain --------------------------------------
step "5. Verify https://$CUSTOM_DOMAIN/$KEY_PREFIX/modules.zip"
probe_url="https://$CUSTOM_DOMAIN/$KEY_PREFIX/modules.zip"

# The custom domain can take a few minutes to leave "Initializing"; retry.
code=""
for attempt in $(seq 1 12); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$probe_url" || true)"
  [[ "$code" == "200" ]] && break
  echo "    attempt $attempt: HTTP $code (domain may still be initializing) -- waiting 15s..."
  sleep 15
done
[[ "$code" == "200" ]] || fail "custom domain did not return 200 (last: HTTP $code)."

headers="$(curl -sI "$probe_url")"
clen="$(echo "$headers" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')"
[[ "$clen" == "$MODULES_ZIP_BYTES" ]] \
  || fail "content-length $clen != expected $MODULES_ZIP_BYTES."
echo "    HTTP 200, content-length $clen -- ok."

cors_hdr="$(curl -sI -H 'Origin: https://example.com' "$probe_url" \
  | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')"
[[ -n "$cors_hdr" ]] \
  || fail "no access-control-allow-origin header with an Origin request -- CORS not applied."
echo "    access-control-allow-origin: $cors_hdr -- ok."

# Confirm the other four are reachable too.
for name in news.md version_info.json sentry_rate_limit.json sentry_sample.json; do
  u="https://$CUSTOM_DOMAIN/$KEY_PREFIX/$name"
  c="$(curl -s -o /dev/null -w '%{http_code}' "$u" || true)"
  [[ "$c" == "200" ]] || fail "$u returned HTTP $c."
  echo "    $name: 200 ok."
done

echo
echo "Stage 1 complete. R2 is serving all 5 files at https://$CUSTOM_DOMAIN/$KEY_PREFIX/"
echo "The old $OLD_ORIGIN/* URLs are untouched. Proceed to r2_stage2_redirect.sh"
echo "only when you are ready to route the legacy URLs to R2."
