#!/usr/bin/env bash
# ============================================================================
# Publish a recognizer module archive (modules.zip) to R2 as
#   umacapture/modules/<sha256>.zip   immutable, content-addressed
#   umacapture/modules.zip            the permanent "latest" alias
#   umacapture/version_info.json      the pointer clients read first
#
# Invariant: the pointer is only rewritten after every object it names has been
# verified through the PUBLIC URL by a GET whose body hashes to the expected
# sha256. HEAD is never used to verify: the edge answers HEAD from R2 while
# serving a stale cached body to GET, so a HEAD check passes over a stale zip.
# The invariant is enforced by control flow: stage 6 is only reachable after
# stages 4 and 5 verified, and there is no option to skip a verification.
#
# The public URL of a new versioned key is never requested before it is put:
# the edge caches a 404 for minutes, which would fail the verification after it.
#
# Stages:
#   0 preflight (tools, credentials, archive layout and entry names,
#     sha256/size, pointer JSON, CORS policy)
#   1 back up the current pointer and alias from R2
#   2 confirmation gate ('yes')            <- --dry-run stops here;
#                                             --yes answers it without a prompt
#   3 put the versioned zip (skipped if already present with the same bytes)
#   4 verify the versioned zip via a public GET
#   5 put the alias, verify via a public GET (restore the backup on failure)
#   6 put the pointer, verify via a public GET (on failure restore BOTH the
#     pointer and the alias from the backup, so an old client that reads the
#     pointer and then the alias never sees the old pointer next to the new alias)
#   7 summary
#
# Rolling back is publishing an older modules.zip with this same script.
# Versioned zips are never deleted here.
#
# Run from Git Bash:  bash tool/cloudflare/publish_modules.sh <modules.zip> [--dry-run] [--yes]
# --yes skips only the stage 2 prompt, for a caller that has already decided to
# publish (umasagashi-trainer's deploy); every other check is unchanged. With
# --dry-run as well, --dry-run wins: stage 2 still stops before any write.
# Credentials come from tool/cloudflare/.env (copy .env.example first).
# Do not run two instances at once; there is no lock.
#
# NOTE: `set -x` is deliberately never enabled anywhere in this script, so the
# API token is never printed to the terminal or a log.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Fixed configuration ---------------------------------------------------
BUCKET="umasagashi-data"
PUBLIC_ROOT="https://data.umacapture.com"
KEY_PREFIX="umacapture"
POINTER_KEY="$KEY_PREFIX/version_info.json"
ALIAS_KEY="$KEY_PREFIX/modules.zip"
VERSIONED_CACHE_CONTROL="public, max-age=31536000, immutable"
MUTABLE_CACHE_CONTROL="no-cache"
CONTENT_DISPOSITION='attachment; filename="modules.zip"'
CORS_PROBE_ORIGIN="https://example.com"
CORS_FILE="$SCRIPT_DIR/cors.json"

# Overridable only so the stub test can point at its own files and not wait
# minutes; neither changes what is verified.
ENV_FILE="${PUBLISH_ENV_FILE:-$SCRIPT_DIR/.env}"
BACKUP_ROOT="${PUBLISH_BACKUP_ROOT:-$SCRIPT_DIR/.publish-backup}"
# Longer than the edge's 3-minute default TTL for a cached 404.
NOT_FOUND_WAIT_SECONDS="${PUBLISH_NOT_FOUND_WAIT_SECONDS:-300}"
RETRY_INTERVAL_SECONDS="${PUBLISH_RETRY_INTERVAL_SECONDS:-15}"

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d '[:space:]'; }

usage() { fail "usage: $0 <path/to/modules.zip> [--dry-run] [--yes]"; }

ZIP=""
DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -*) usage ;;
    *) [[ -z "$ZIP" ]] || usage; ZIP="$arg" ;;
  esac
done
[[ -n "$ZIP" ]] || usage

r2_get() { wrangler r2 object get "$BUCKET/$1" --file "$2" --remote >/dev/null; }
r2_put() {
  local key="$1" file="$2" type="$3" cache="$4"
  shift 4
  wrangler r2 object put "$BUCKET/$key" --file "$file" --content-type "$type" \
    --cache-control "$cache" "$@" --remote --force >/dev/null
}

# public_get <key> <body-out> <headers-out> -> prints the HTTP status.
# Sends an Origin header so the same response also shows whether CORS applies.
public_get() {
  curl -sS -o "$2" -D "$3" -w '%{http_code}' -H "Origin: $CORS_PROBE_ORIGIN" \
    "$PUBLIC_ROOT/$1" || echo "000"
}

# verify_public <key> <expected sha256> <expected size> <work dir>
# GETs the public URL, retrying a 404 for up to NOT_FOUND_WAIT_SECONDS, and
# succeeds only if the body hashes to the expected sha256. Sets VERIFY_ERROR.
verify_public() {
  local key="$1" want_sha="$2" want_size="$3" dir="$4"
  local body="$dir/body" headers="$dir/headers" code deadline
  deadline=$(( $(date +%s) + NOT_FOUND_WAIT_SECONDS ))
  while :; do
    code="$(public_get "$key" "$body" "$headers")"
    [[ "$code" == "404" && "$(date +%s)" -lt "$deadline" ]] || break
    echo "    $key: HTTP 404, retrying in ${RETRY_INTERVAL_SECONDS}s..."
    sleep "$RETRY_INTERVAL_SECONDS"
  done
  VERIFY_ERROR=""
  if [[ "$code" != "200" ]]; then
    VERIFY_ERROR="HTTP $code"
  elif [[ "$(sha_of "$body")" != "$want_sha" ]]; then
    VERIFY_ERROR="body sha256 $(sha_of "$body") ($(size_of "$body") bytes) != expected $want_sha"
  elif [[ "$(size_of "$body")" != "$want_size" ]]; then
    VERIFY_ERROR="body size $(size_of "$body") != expected $want_size"
  fi
  [[ -z "$VERIFY_ERROR" ]]
}

cors_header() {
  tr -d '\r' < "$1" | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}'
}

# cors_authorizes <headers file>: the response lets a browser at
# CORS_PROBE_ORIGIN read it, i.e. the header is "*" or exactly the Origin sent.
# Any other value (another origin, a list) makes the browser block the web app.
cors_authorizes() {
  local value
  value="$(cors_header "$1")"
  [[ "$value" == "*" || "$value" == "$CORS_PROBE_ORIGIN" ]]
}

# restore_verified <key> <backup file> <content type>: puts the backup back with
# the alias/pointer's mutable Cache-Control and verifies it through a public
# GET. Sets VERIFY_ERROR on failure.
restore_verified() {
  local key="$1" file="$2" type="$3"
  echo "    restoring $key from $file" >&2
  r2_put "$key" "$file" "$type" "$MUTABLE_CACHE_CONTROL"
  verify_public "$key" "$(sha_of "$file")" "$(size_of "$file")" "$WORK"
}

# ---- 0. Preflight ----------------------------------------------------------
step "0. Preflight"
for tool in wrangler jq unzip sha256sum curl; do
  command -v "$tool" >/dev/null || fail "'$tool' not found on PATH."
done
# The probe origin stands in for the web app, so the bucket's CORS policy (the
# one r2_stage1_setup.sh applies) must authorize it; otherwise an echo of it
# would prove nothing about the web app.
jq -e --arg o "$CORS_PROBE_ORIGIN" \
  '[.rules[].allowed.origins[]] | any(. == "*" or . == $o)' "$CORS_FILE" >/dev/null \
  || fail "$CORS_FILE does not allow $CORS_PROBE_ORIGIN, so the CORS probe would not stand for the web app."
[[ -f "$ZIP" ]] || fail "$ZIP not found."
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE not found. Copy .env.example to .env and fill in the values."
set -a
# shellcheck disable=SC1090,SC1091
source "$ENV_FILE"
set +a
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "CLOUDFLARE_API_TOKEN is empty in $ENV_FILE."
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || fail "CLOUDFLARE_ACCOUNT_ID is empty in $ENV_FILE."
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

entries="$(unzip -Z1 "$ZIP")" || fail "$ZIP is not a readable zip."
outside="$(grep -v '^modules/' <<<"$entries" || true)"
[[ -z "$outside" ]] || fail "$ZIP has entries outside modules/: $(head -n 3 <<<"$outside" | tr '\n' ' ')"
# Clients join each entry name below their module directory segment by segment,
# so a name must neither escape it nor carry another separator: no "." / ".." /
# empty segment (a trailing "/" marks a directory and is fine), no backslash,
# no drive colon, no control character.
unsafe="$(grep -E '(^|/)\.{1,2}(/|$)|//|\\|:|[[:cntrl:]]' <<<"$entries" || true)"
[[ -z "$unsafe" ]] || fail "$ZIP has unsafe entry names: $(head -n 3 <<<"$unsafe" | tr '\n' ' ')"
grep -qx 'modules/version_info.json' <<<"$entries" || fail "$ZIP has no modules/version_info.json."
unzip -p "$ZIP" modules/version_info.json > "$WORK/inner.json"
jq -e 'type == "object"' "$WORK/inner.json" >/dev/null || fail "modules/version_info.json is not a JSON object."
jq -e 'has("module_archive") | not' "$WORK/inner.json" >/dev/null \
  || fail "modules/version_info.json already carries module_archive."

DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:?[0-9]{2}|Z)$'
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$'
RECOGNIZER_VERSION="$(jq -r '.recognizer_version // empty' "$WORK/inner.json")"
MINIMUM_VERSION="$(jq -r '.minimum_version // empty' "$WORK/inner.json")"
APPLICATION_VERSION="$(jq -r '.application_version // empty' "$WORK/inner.json")"
[[ "$RECOGNIZER_VERSION" =~ $DATE_RE ]] || fail "recognizer_version '$RECOGNIZER_VERSION' is not a date."
[[ "$MINIMUM_VERSION" =~ $DATE_RE ]] || fail "minimum_version '$MINIMUM_VERSION' is not a date."
[[ "$APPLICATION_VERSION" =~ $SEMVER_RE ]] || fail "application_version '$APPLICATION_VERSION' is not semver."

SHA="$(sha_of "$ZIP")"
SIZE="$(size_of "$ZIP")"
ARCHIVE_PATH="modules/$SHA.zip"
VERSIONED_KEY="$KEY_PREFIX/$ARCHIVE_PATH"
POINTER="$WORK/pointer.json"
jq --arg path "$ARCHIVE_PATH" --arg sha "$SHA" --argjson size "$SIZE" \
  '. + {module_archive: {path: $path, sha256: $sha, size: $size}}' "$WORK/inner.json" > "$POINTER"
POINTER_SHA="$(sha_of "$POINTER")"
POINTER_SIZE="$(size_of "$POINTER")"
echo "    archive: $ZIP ($SIZE bytes, sha256 $SHA)"
echo "    recognizer_version: $RECOGNIZER_VERSION"
echo "    pointer JSON:"
sed 's/^/      /' "$POINTER"

# ---- 1. Back up the current pointer and alias ------------------------------
step "1. Back up the current pointer and alias from R2"
BACKUP="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
r2_get "$POINTER_KEY" "$BACKUP/version_info.json" || fail "could not fetch $POINTER_KEY from R2."
r2_get "$ALIAS_KEY" "$BACKUP/modules.zip" || fail "could not fetch $ALIAS_KEY from R2."
cp "$POINTER" "$BACKUP/new_version_info.json"
OLD_RECOGNIZER_VERSION="$(jq -r '.recognizer_version // "(none)"' "$BACKUP/version_info.json" 2>/dev/null || echo "(unreadable)")"
echo "    backed up to $BACKUP"
echo "    recognizer_version: $OLD_RECOGNIZER_VERSION (current) -> $RECOGNIZER_VERSION (this archive)"
if [[ "$OLD_RECOGNIZER_VERSION" > "$RECOGNIZER_VERSION" ]]; then
  echo "    NOTE: this is a ROLLBACK to an older recognizer_version."
fi

# ---- 2. Confirmation gate --------------------------------------------------
step "2. Plan"
echo "    create (if absent): $BUCKET/$VERSIONED_KEY"
echo "    overwrite:          $BUCKET/$ALIAS_KEY"
echo "    overwrite:          $BUCKET/$POINTER_KEY"
if [[ "$DRY_RUN" == 1 ]]; then
  echo
  echo "Dry run: stopping before any write. Nothing in R2 was changed."
  exit 0
fi
if [[ "$ASSUME_YES" == 1 ]]; then
  echo "    --yes: publishing without a prompt."
else
  read -r -p "Type 'yes' to publish: " reply
  [[ "$reply" == "yes" ]] || fail "aborted (nothing in R2 was changed)."
fi

# ---- 3. Versioned zip ------------------------------------------------------
step "3. Versioned zip $VERSIONED_KEY"
# Existence is checked through the R2 API, never the public URL (404 caching).
if r2_get "$VERSIONED_KEY" "$WORK/existing.zip" 2>/dev/null; then
  [[ "$(sha_of "$WORK/existing.zip")" == "$SHA" ]] \
    || fail "$VERSIONED_KEY exists with different bytes; the content address is broken. Nothing was changed."
  echo "    already present with the same bytes -- skipping put."
else
  r2_put "$VERSIONED_KEY" "$ZIP" application/zip "$VERSIONED_CACHE_CONTROL" \
    --content-disposition "$CONTENT_DISPOSITION"
  echo "    put."
fi

# ---- 4. Verify the versioned zip -------------------------------------------
step "4. Verify $PUBLIC_ROOT/$VERSIONED_KEY"
verify_public "$VERSIONED_KEY" "$SHA" "$SIZE" "$WORK" \
  || fail "versioned zip failed verification: $VERIFY_ERROR. The pointer was not changed."
cors_authorizes "$WORK/headers" \
  || fail "access-control-allow-origin on the versioned zip is '$(cors_header "$WORK/headers")', not '*' or $CORS_PROBE_ORIGIN. The pointer was not changed."
echo "    GET body sha256 and size match; CORS authorizes $CORS_PROBE_ORIGIN."

# ---- 5. Alias --------------------------------------------------------------
step "5. Alias $ALIAS_KEY"
# The put and the public check are one publish outcome, so both failures reach
# the restore below. A put that exits non-zero may have its response lost rather
# than refused, so whether the alias was written is unknown; leaving it there
# beside the still-old pointer is the same split state a stale GET leaves, from
# the other key.
ALIAS_ERROR=""
ALIAS_REMEDY=""
if ! r2_put "$ALIAS_KEY" "$ZIP" application/zip "$MUTABLE_CACHE_CONTROL"; then
  ALIAS_ERROR="the put failed, so R2 may or may not hold the new alias"
  ALIAS_REMEDY="Re-run once R2 accepts the write."
elif ! verify_public "$ALIAS_KEY" "$SHA" "$SIZE" "$WORK"; then
  ALIAS_ERROR="$VERIFY_ERROR"
  ALIAS_REMEDY="The edge still serves a stale alias. Purge $PUBLIC_ROOT/$ALIAS_KEY, or wait until the stale copy's max-age has passed, then re-run."
fi
if [[ -n "$ALIAS_ERROR" ]]; then
  echo "    alias failed verification: $ALIAS_ERROR" >&2
  restore_verified "$ALIAS_KEY" "$BACKUP/modules.zip" application/zip \
    || fail "alias publish failed ($ALIAS_ERROR), and the restore ALSO failed verification ($VERIFY_ERROR). NEEDS MANUAL RECOVERY: a client that reads $PUBLIC_ROOT/$POINTER_KEY and downloads $PUBLIC_ROOT/$ALIAS_KEY can now install a module set the pointer does not describe. Restore $PUBLIC_ROOT/$ALIAS_KEY from $BACKUP/modules.zip by hand before anyone updates. The pointer was not changed."
  fail "alias publish failed ($ALIAS_ERROR); the previous alias was restored and verified. $ALIAS_REMEDY The pointer was not changed."
fi
echo "    GET body sha256 and size match."

# ---- 6. Pointer ------------------------------------------------------------
step "6. Pointer $POINTER_KEY"
# The put and the public check are one publish outcome, so both failures reach
# the restore below. A put that exits non-zero leaves exactly the split state a
# stale GET does -- old pointer, new alias -- and its response may be lost
# rather than refused, so whether the pointer was written is unknown either way.
POINTER_ERROR=""
if ! r2_put "$POINTER_KEY" "$POINTER" application/json "$MUTABLE_CACHE_CONTROL"; then
  POINTER_ERROR="the put failed, so R2 may or may not hold the new pointer"
elif ! verify_public "$POINTER_KEY" "$POINTER_SHA" "$POINTER_SIZE" "$WORK"; then
  POINTER_ERROR="$VERIFY_ERROR"
fi
if [[ -n "$POINTER_ERROR" ]]; then
  echo "    pointer failed verification: $POINTER_ERROR" >&2
  # The pointer first, since it decides a client's version; then the alias,
  # which stage 5 already moved. Both are attempted even if one fails.
  unrestored=""
  restore_verified "$POINTER_KEY" "$BACKUP/version_info.json" application/json \
    || unrestored+=" $PUBLIC_ROOT/$POINTER_KEY ($VERIFY_ERROR)"
  restore_verified "$ALIAS_KEY" "$BACKUP/modules.zip" application/zip \
    || unrestored+=" $PUBLIC_ROOT/$ALIAS_KEY ($VERIFY_ERROR)"
  [[ -z "$unrestored" ]] \
    || fail "pointer publish failed ($POINTER_ERROR), and the restore ALSO failed verification for:$unrestored. NEEDS MANUAL RECOVERY: a client that reads $PUBLIC_ROOT/$POINTER_KEY and downloads $PUBLIC_ROOT/$ALIAS_KEY can now install a module set the pointer does not describe. Restore both from $BACKUP by hand before anyone updates."
  fail "pointer publish failed ($POINTER_ERROR); the previous pointer and alias were restored and verified."
fi
echo "    GET body matches the published pointer byte for byte."

# ---- 7. Summary ------------------------------------------------------------
step "7. Published"
echo "    recognizer_version: $RECOGNIZER_VERSION"
echo "    $PUBLIC_ROOT/$VERSIONED_KEY"
echo "    sha256 $SHA, $SIZE bytes"
echo "    backup: $BACKUP"
echo "    to roll back, publish the previous archive with this script:"
echo "      bash tool/cloudflare/publish_modules.sh $BACKUP/modules.zip"
