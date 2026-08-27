#!/usr/bin/env bash
# ============================================================================
# !!! PRODUCTION IMPACT -- READ BEFORE RUNNING !!!
#
# Stage 2 of the R2 migration. This installs a live Cloudflare dynamic redirect
# rule on the umasagashi.com zone that forwards
#
#     https://umasagashi.com/data/umacapture/*
#         -> https://data.umacapture.com/umacapture/${1}
#
# The rule is installed on the umasagashi.com zone (where the legacy URLs live);
# only the redirect TARGET points at the new umacapture.com custom domain.
#
# EVERY already-released desktop build hardcodes the legacy URL and will start
# following this redirect immediately. Only run this AFTER r2_stage1_setup.sh has
# succeeded and all 5 files verify at data.umacapture.com.
#
# Default status code is 302 (not cached by clients) for the initial rollout.
# Once stable, re-run with --promote-301 to switch to a cacheable 301.
#
# ROLLBACK: delete the rule in the dashboard (Rules > Redirect Rules) or via the
# Rulesets API. The origin still serves the old URLs directly until the apex is
# cut over to Pages, so removing the rule restores the prior state immediately.
#
# See testdata/evidence/wasm_poc5/r2_setup_runbook.md (Staged migration, Stage 2/3).
#
# Run from Git Bash:  bash tool/cloudflare/r2_stage2_redirect.sh [--promote-301]
#
# NOTE: `set -x` is deliberately never enabled, so the API token is never logged.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ZONE_NAME is the zone the rule is installed on: it must stay umasagashi.com,
# because that is where the legacy hardcoded URLs live. Only TARGET_URL moves to
# the new umacapture.com custom domain.
ZONE_NAME="umasagashi.com"
PHASE="http_request_dynamic_redirect"
RULE_REF="umacapture_data_r2_redirect"
MATCH_URL="https://umasagashi.com/data/umacapture/*"
TARGET_URL='https://data.umacapture.com/umacapture/${1}'
PROBE_PATH="/data/umacapture/modules.zip"
MODULES_ZIP_BYTES=10308164
CF_API="https://api.cloudflare.com/client/v4"

STATUS_CODE=302

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }
# Dumps an API response to stderr. `jq` first so errors are readable; the raw body
# otherwise (it may not be JSON at all -- a proxy error page, or nothing). The
# trailing newline keeps the following `fail` line from being glued onto the body.
dump_response() { jq '.' "$1" >&2 2>/dev/null || { cat "$1"; echo; } >&2; }

# ---- Args ------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --promote-301) STATUS_CODE=301 ;;
    -h|--help)
      echo "usage: bash r2_stage2_redirect.sh [--promote-301]"
      echo "  (no args) install/update the redirect rule as a 302"
      echo "  --promote-301  install/update it as a cacheable 301"
      exit 0 ;;
    *) fail "unknown argument: $arg (see --help)" ;;
  esac
done

# ---- Confirmation gate -----------------------------------------------------
echo "About to install/update a $STATUS_CODE dynamic redirect on the LIVE zone '$ZONE_NAME':"
echo "    $MATCH_URL"
echo "        -> $TARGET_URL"
echo "This affects every released desktop app. Rollback = delete the rule."
read -r -p "Type 'yes' to proceed: " reply
[[ "$reply" == "yes" ]] || fail "aborted (no changes made)."

# ---- Load credentials ------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/.env"
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE not found. Copy .env.example to .env and fill in the values."
set -a
# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"
set +a
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "CLOUDFLARE_API_TOKEN is empty in $ENV_FILE."
export CLOUDFLARE_API_TOKEN
AUTH_HEADER="Authorization: Bearer $CLOUDFLARE_API_TOKEN"

# ---- Resolve zone id -------------------------------------------------------
step "Resolving zone id for $ZONE_NAME"
zone_json="$(curl -sf -H "$AUTH_HEADER" "$CF_API/zones?name=$ZONE_NAME")" \
  || fail "zone lookup failed (check the token's Zone > Zone > Read scope)."
ZONE_ID="$(echo "$zone_json" | jq -r '.result[0].id // empty')"
[[ -n "$ZONE_ID" ]] || fail "could not resolve zone id for $ZONE_NAME."
echo "    ok."

# ---- Read the existing phase entrypoint ruleset ----------------------------
# The PUT further down replaces the WHOLE phase entrypoint, so whatever this read
# returns is the only thing standing between an unrelated production redirect rule
# and deletion. "Could not read" must therefore never collapse into "there is
# nothing there": a 5xx, a DNS blip, a captive proxy, or a token missing the read
# half of the Single-Redirect scope would otherwise deploy a ruleset containing
# only our rule and wipe the rest of the live zone.
#
# So: capture the HTTP status and accept exactly two outcomes -- 200 with
# success:true (keep every rule except a previous copy of ours, matched by ref, so
# re-runs are idempotent), or 404, the documented "no ruleset for this phase yet"
# response. Anything else aborts before the PUT.
#
# `set -e` cannot substitute for this: a command substitution evaluated inside
# `[[ ... ]]` does not trigger it, which is how the failure used to pass silently.
step "Reading current '$PHASE' entrypoint ruleset"
response_body="$(mktemp)"
trap 'rm -f "$response_body"' EXIT
if ! http_code="$(curl -s -o "$response_body" -w '%{http_code}' -H "$AUTH_HEADER" \
  "$CF_API/zones/$ZONE_ID/rulesets/phases/$PHASE/entrypoint")"; then
  fail "the request for the current '$PHASE' entrypoint did not complete (curl error).
       Refusing to continue: the deploy step replaces the entire ruleset, so continuing
       here could delete unrelated redirect rules on $ZONE_NAME."
fi
case "$http_code" in
  200)
    jq -e '.success == true' "$response_body" >/dev/null 2>&1 || {
      dump_response "$response_body"
      fail "the '$PHASE' entrypoint read returned HTTP 200 but success != true.
       Refusing to continue: the deploy step replaces the entire ruleset."
    }
    existing_rules="$(jq --arg ref "$RULE_REF" \
      '[.result.rules[]? | select(.ref != $ref)]' "$response_body")"
    # Retain the pre-change ruleset outside the temp dir so a rollback is one PUT.
    RULESET_BACKUP="$(mktemp -t "cf-${PHASE}-entrypoint-backup-XXXXXX")"
    cp "$response_body" "$RULESET_BACKUP"
    echo "    found $(echo "$existing_rules" | jq 'length') unrelated rule(s) to preserve."
    echo "    pre-change ruleset saved to $RULESET_BACKUP (rollback: PUT its .result back)."
    ;;
  404)
    existing_rules='[]'
    echo "    no entrypoint ruleset yet (HTTP 404) -- it will be created."
    ;;
  *)
    dump_response "$response_body"
    fail "could not read the current '$PHASE' entrypoint (HTTP $http_code).
       Refusing to continue: the deploy step replaces the entire ruleset, so continuing
       here could delete unrelated redirect rules on $ZONE_NAME. Check the token's
       Zone > Dynamic Redirect (or Config Rules) READ scope and retry."
    ;;
esac

# ---- Build our rule and PUT the merged rule set ----------------------------
# Wildcard match on the full URI; ${1} in the static target value is replaced
# with whatever the trailing * captured.
new_rule="$(jq -n \
  --arg ref "$RULE_REF" \
  --arg expr "(http.request.full_uri wildcard \"$MATCH_URL\")" \
  --arg target "$TARGET_URL" \
  --argjson status "$STATUS_CODE" '
  {
    ref: $ref,
    description: "Forward legacy umacapture module URLs to R2 (data.umacapture.com).",
    expression: $expr,
    action: "redirect",
    action_parameters: {
      from_value: {
        target_url: { value: $target },
        status_code: $status,
        preserve_query_string: true
      }
    }
  }')"
body="$(jq -n --argjson existing "$existing_rules" --argjson rule "$new_rule" \
  '{ rules: ($existing + [$rule]) }')"

step "Deploying $STATUS_CODE redirect rule (ref=$RULE_REF)"
resp="$(curl -s -X PUT \
  -H "$AUTH_HEADER" -H "Content-Type: application/json" \
  --data "$body" \
  "$CF_API/zones/$ZONE_ID/rulesets/phases/$PHASE/entrypoint")"
if [[ "$(echo "$resp" | jq -r '.success')" != "true" ]]; then
  echo "$resp" | jq '.errors' >&2
  fail "ruleset PUT failed."
fi
echo "    deployed."

# ---- Verify ----------------------------------------------------------------
probe="https://$ZONE_NAME$PROBE_PATH"

step "Verify redirect hop (no -L): expect $STATUS_CODE + Location"
hop_code="$(curl -s -o /dev/null -w '%{http_code}' "$probe" || true)"
location="$(curl -sI "$probe" | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}')"
echo "    HTTP $hop_code"
echo "    Location: ${location:-<none>}"
[[ "$hop_code" == "$STATUS_CODE" ]] || fail "expected $STATUS_CODE at the hop, got $hop_code."
[[ "$location" == https://data.umacapture.com/umacapture/* ]] \
  || fail "Location does not point at the R2 custom domain."

step "Verify final response (curl -sIL): expect 200 + content-length $MODULES_ZIP_BYTES"
final_code="$(curl -s -L -o /dev/null -w '%{http_code}' "$probe" || true)"
final_clen="$(curl -sIL "$probe" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{v=$2} END{print v}')"
echo "    final HTTP $final_code, content-length ${final_clen:-<none>}"
[[ "$final_code" == "200" ]] || fail "final response was HTTP $final_code, expected 200."
[[ "$final_clen" == "$MODULES_ZIP_BYTES" ]] \
  || fail "final content-length $final_clen != expected $MODULES_ZIP_BYTES."

echo
echo "Stage 2 complete: $MATCH_URL now redirects ($STATUS_CODE) to R2."
if [[ "$STATUS_CODE" == "302" ]]; then
  echo "When stable, re-run with --promote-301 to switch to a cacheable 301."
fi
echo "Also trigger a module-update check in an actual released desktop build to"
echo "confirm it downloads normally through the redirect."
