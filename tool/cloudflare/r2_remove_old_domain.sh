#!/usr/bin/env bash
# ============================================================================
# Remove the interim data.umasagashi.com custom domain from the R2 bucket.
#
# During an earlier plan the bucket was going to be fronted by
# data.umasagashi.com. The chosen public custom domain is now
# data.umacapture.com (see r2_stage1_setup.sh). If data.umasagashi.com was ever
# connected to the bucket, run this ONCE, AFTER data.umacapture.com is connected
# and verified, to detach the stale domain.
#
# This only detaches a custom domain from the R2 bucket; it does not delete the
# bucket, its objects, or the umacapture.com domain. Safe to no-op if the domain
# was never connected.
#
# See testdata/evidence/wasm_poc5/r2_setup_runbook.md.
#
# Run from Git Bash:  bash tool/cloudflare/r2_remove_old_domain.sh
#
# NOTE: `set -x` is deliberately never enabled, so the API token is never logged.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUCKET="umasagashi-data"
OLD_CUSTOM_DOMAIN="data.umasagashi.com"

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

# ---- Skip if not connected -------------------------------------------------
# "Could not ask" must never collapse into "there is nothing there" -- the same rule
# r2_stage2_redirect.sh states over its ruleset read, and it applies here for the
# mirror-image reason: this script's whole output is a claim that a public hostname is
# NO LONGER serving the bucket, and the operator acts on that claim by not looking
# again. Piping wrangler straight into `grep -q` hands the exit status to grep and
# throws the diagnosis away with `2>/dev/null`, so an expired token, a missing R2
# scope, a network blip, or wrangler not being installed at all (127) each produce
# empty output, print "nothing to remove", and exit 0 with the domain still attached.
#
# So: run it once, keep both streams, and branch on ITS status. Only a successful
# listing may be read for presence or absence.
step "Checking whether $OLD_CUSTOM_DOMAIN is connected to '$BUCKET'"
domain_list="$(mktemp)"
trap 'rm -f "$domain_list"' EXIT
if ! wrangler r2 bucket domain list "$BUCKET" >"$domain_list" 2>&1; then
  echo "--- wrangler output ---" >&2
  cat "$domain_list" >&2
  echo "-----------------------" >&2
  fail "could not list the custom domains of '$BUCKET'.
       Refusing to report on $OLD_CUSTOM_DOMAIN either way: a failed listing is not
       evidence that the domain is detached, and reporting it as such would leave a
       public hostname serving the bucket while the operator believes it is gone.
       Check that wrangler is installed and that the token carries the R2 read scope,
       then retry."
fi
if ! grep -q "$OLD_CUSTOM_DOMAIN" "$domain_list"; then
  echo "    $OLD_CUSTOM_DOMAIN is not connected -- nothing to remove."
  exit 0
fi
echo "    connected -- will remove."

# ---- Confirmation gate -----------------------------------------------------
echo
echo "About to DETACH the custom domain '$OLD_CUSTOM_DOMAIN' from R2 bucket '$BUCKET'."
echo "Make sure data.umacapture.com is already connected and verified first."
read -r -p "Type 'yes' to proceed: " reply
[[ "$reply" == "yes" ]] || fail "aborted (no changes made)."

# ---- Remove ----------------------------------------------------------------
step "Removing $OLD_CUSTOM_DOMAIN"
wrangler r2 bucket domain remove "$BUCKET" --domain "$OLD_CUSTOM_DOMAIN" --force
echo "    done."
echo
echo "$OLD_CUSTOM_DOMAIN detached. The bucket is now served only via"
echo "data.umacapture.com. Objects and the bucket itself are unchanged."
