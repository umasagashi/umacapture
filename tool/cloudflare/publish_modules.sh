#!/usr/bin/env bash
# ============================================================================
# Publish a recognizer module archive (modules.zip) on data.umacapture.com, a
# static-assets-only Worker (server/wrangler.data.jsonc). Every run assembles
# the whole served tree in build/data-site/ and deploys it:
#   umacapture/version_info.json      the pointer clients read first
#   umacapture/modules.zip            the permanent "latest" alias
#   umacapture/modules/<sha256>.zip   content-addressed archives: the new one,
#                                     plus every one the live deploy.json lists
#   umacapture/news.md, sentry_*.json copied from server/data-site/
#   _headers                          copied from server/data-site/
#   deploy.json                       git_sha, built_at, phase, pointer_sha256,
#                                     zips [{sha256, size, published_at}]
#
# Invariant: the pointer only ever names an archive already verified through
# the public URL. It is enforced by two deploys: phase 1 serves the new archive
# beside the CURRENT pointer and alias, and is verified by a public GET of the
# new archive; only then does phase 2 switch the pointer and the alias together.
# A phase 2 that cannot be verified is answered by deploying phase 1 again.
#
# Archives already published stay published: a client may hold a pointer it
# read earlier and fetch the archive it names later, so every archive the live
# deploy.json lists is fetched back from the public URL, checked against its
# content address and listed size, and carried into the new tree. One that
# cannot be fetched or does not match stops the run before anything is
# deployed. A live host with no deploy.json (404 only; the R2 bucket this host
# replaces never had one) inherits the archive its live pointer names, alone.
# An inherited archive published more than RETENTION_DAYS ago is dropped,
# except the one this run serves (the current version), the one the live
# pointer names, and the most recently published other one (the previous
# version, even when this run republishes the live archive), which stay
# whatever their age. One
# whose published_at cannot be read is kept, with a warning.
#
# Stages:
#   0 preflight (tools, the deployed paths committed and clean, _headers CORS
#     rule, credentials, archive layout and entry names, pointer JSON)
#   1 live state: pointer and deploy.json, the inherited archives, the backup
#   2 assemble the phase 1 and phase 2 trees
#   3 wrangler deploy --dry-run, confirmation gate ('yes')
#                                          <- --dry-run stops here;
#                                             --yes answers it without a prompt
#   4 phase 1: deploy, verify deploy.json and the new archive
#     (skipped when the live pointer already names this archive)
#   5 phase 2: deploy, verify deploy.json, pointer and alias; on failure
#     deploy phase 1 again and verify it
#   6 summary
#
# Reading and verifying may target different hosts: DATA_READ_ROOT is where the
# live pointer, deploy.json and archives are read from, DATA_VERIFY_ROOT is the
# host the deploy lands on (both default to https://data.umacapture.com), so a
# parallel host can be filled from the one still in service.
#
# Rolling back is publishing an older modules.zip with this same script; the
# faster `wrangler rollback -c server/wrangler.data.jsonc` has to go back two
# versions, since one publish deploys twice.
#
# Run from Git Bash:  bash tool/cloudflare/publish_modules.sh [<modules.zip>] [--dry-run] [--yes]
# Without a zip, the archive the live pointer names is fetched from
# DATA_READ_ROOT, checked against its sha256 and size, and re-published: the
# pointer stays byte for byte the same and only the static files change (a
# news-only update).
# --yes skips only the stage 3 prompt, for a caller that has already decided to
# publish (umasagashi-trainer's deploy); every other check is unchanged. With
# --dry-run as well, --dry-run wins: stage 3 still stops before any deploy.
# Run it from a terminal: a wrangler whose stdout is not a TTY overwrites an
# existing DNS record for a custom domain without asking.
# Credentials come from tool/cloudflare/.env (copy .env.example first).
# Do not run two instances at once; there is no lock.
#
# NOTE: `set -x` is deliberately never enabled anywhere in this script, so the
# API token is never printed to the terminal or a log.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---- Fixed configuration ---------------------------------------------------
WRANGLER_CONFIG="server/wrangler.data.jsonc"
SITE_SOURCE="server/data-site"
TREE="build/data-site"
# The paths whose committed bytes are deployed; any change or untracked file
# under them stops the run, so deploy.json's git_sha names what is served.
DEPLOYED_PATHS=("$SITE_SOURCE" "$WRANGLER_CONFIG" "tool/cloudflare")
KEY_PREFIX="umacapture"
POINTER_KEY="$KEY_PREFIX/version_info.json"
ALIAS_KEY="$KEY_PREFIX/modules.zip"
CORS_PROBE_ORIGIN="https://example.com"
SHA_RE='^[0-9a-f]{64}$'

DATA_READ_ROOT="${DATA_READ_ROOT:-https://data.umacapture.com}"
DATA_VERIFY_ROOT="${DATA_VERIFY_ROOT:-https://data.umacapture.com}"
# Overridable only so the stub test can point at its own files and not wait;
# none changes what is verified.
ENV_FILE="${PUBLISH_ENV_FILE:-$SCRIPT_DIR/.env}"
BACKUP_ROOT="${PUBLISH_BACKUP_ROOT:-$SCRIPT_DIR/.publish-backup}"
# The edge may take a moment to switch versions; retry a mismatching
# deploy.json for this long before failing.
VERIFY_WAIT_SECONDS="${PUBLISH_VERIFY_WAIT_SECONDS:-120}"
RETRY_INTERVAL_SECONDS="${PUBLISH_RETRY_INTERVAL_SECONDS:-10}"
RETENTION_DAYS=30

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }
size_of() { wc -c < "$1" | tr -d '[:space:]'; }

usage() { fail "usage: $0 [<path/to/modules.zip>] [--dry-run] [--yes]"; }

ZIP=""
DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -*) usage ;;
    # An empty argument is a caller's unset variable, not a request to
    # re-publish the live archive; only leaving the zip out asks for that.
    "") usage ;;
    *) [[ -z "$ZIP" ]] || usage; ZIP="$arg" ;;
  esac
done
REPUBLISH_LIVE=0
[[ -n "$ZIP" ]] || REPUBLISH_LIVE=1
# Absolute, since the script runs from the repository root.
[[ -f "$ZIP" ]] && ZIP="$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"

# fetch <url> <body-out> <headers-out> -> prints the HTTP status ("000" when
# curl itself fails: DNS, TLS, connection). Sends an Origin header so the same
# response also shows whether CORS applies.
fetch() {
  local code
  code="$(curl -sS -o "$2" -D "$3" -w '%{http_code}' -H "Origin: $CORS_PROBE_ORIGIN" \
    -H 'Cache-Control: no-cache' "$1")" || code="000"
  printf '%s' "$code"
}

# matches_file <url> <expected sha256> <expected size> <work dir>: GETs the URL
# and succeeds only on a 200 whose body has that sha256 and size. Leaves the
# response headers in <work dir>/headers. Sets VERIFY_ERROR.
matches_file() {
  local url="$1" want_sha="$2" want_size="$3" dir="$4" code
  code="$(fetch "$url" "$dir/body" "$dir/headers")"
  VERIFY_ERROR=""
  if [[ "$code" != "200" ]]; then
    VERIFY_ERROR="$url: HTTP $code"
  elif [[ "$(sha_of "$dir/body")" != "$want_sha" ]]; then
    VERIFY_ERROR="$url: body sha256 $(sha_of "$dir/body") != expected $want_sha"
  elif [[ "$(size_of "$dir/body")" != "$want_size" ]]; then
    VERIFY_ERROR="$url: body size $(size_of "$dir/body") != expected $want_size"
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
  [[ "$value" == "*" || "$value" == "$CORS_PROBE_ORIGIN" ]] && return 0
  VERIFY_ERROR="access-control-allow-origin is '$value', not '*' or $CORS_PROBE_ORIGIN"
  return 1
}

# wait_for_deploy_json <file>: the verify host serves exactly this deploy.json,
# retried for VERIFY_WAIT_SECONDS while the edge switches versions.
wait_for_deploy_json() {
  local want_sha want_size deadline
  want_sha="$(sha_of "$1")"
  want_size="$(size_of "$1")"
  deadline=$(( $(date +%s) + VERIFY_WAIT_SECONDS ))
  while ! matches_file "$DATA_VERIFY_ROOT/deploy.json" "$want_sha" "$want_size" "$WORK/verify"; do
    [[ "$(date +%s)" -lt "$deadline" ]] || return 1
    echo "    deploy.json not yet the new version ($VERIFY_ERROR), retrying in ${RETRY_INTERVAL_SECONDS}s..."
    sleep "$RETRY_INTERVAL_SECONDS"
  done
}

# ---- 0. Preflight ----------------------------------------------------------
step "0. Preflight"
for tool in wrangler jq unzip sha256sum curl git; do
  command -v "$tool" >/dev/null || fail "'$tool' not found on PATH."
done
cd "$REPO_ROOT"
for path in "${DEPLOYED_PATHS[@]}"; do
  [[ -e "$path" ]] || fail "$path does not exist."
done
dirty="$(git status --porcelain --untracked-files=all -- "${DEPLOYED_PATHS[@]}")"
[[ -z "$dirty" ]] || fail "uncommitted or untracked files under the deployed paths; commit or remove them first:
$dirty"
GIT_SHA="$(git rev-parse HEAD)"
# The probe origin stands in for the web app, which reads this host
# cross-origin; Workers Static Assets adds no CORS header unless _headers does.
awk '
  /^[^ \t]/ { in_rule = ($0 == "/umacapture/*") ; next }
  in_rule && tolower($0) ~ /^[ \t]+access-control-allow-origin:[ \t]*\*[ \t]*$/ { found = 1 }
  END { exit !found }
' "$SITE_SOURCE/_headers" \
  || fail "$SITE_SOURCE/_headers does not give /umacapture/* 'Access-Control-Allow-Origin: *'; the web app could not read this host."
[[ "$REPUBLISH_LIVE" == 1 || -f "$ZIP" ]] || fail "$ZIP not found."
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
mkdir -p "$WORK/verify" "$WORK/zips" "$WORK/phase1" "$WORK/phase2"

LIVE_POINTER="$WORK/phase1/version_info.json"
LIVE_POINTER_SHA=""
# read_live_pointer: fetches the live pointer into LIVE_POINTER and reads the
# archive it names into LIVE_ARCHIVE_{SHA,SIZE,PATH}.
read_live_pointer() {
  local code
  code="$(fetch "$DATA_READ_ROOT/$POINTER_KEY" "$LIVE_POINTER" "$WORK/verify/headers")"
  [[ "$code" == "200" ]] || fail "could not fetch the live pointer $DATA_READ_ROOT/$POINTER_KEY: HTTP $code. Nothing was deployed."
  LIVE_POINTER_SHA="$(sha_of "$LIVE_POINTER")"
  LIVE_ARCHIVE_SHA="$(jq -r '.module_archive.sha256 // empty' "$LIVE_POINTER" 2>/dev/null | tr -d '\r')" || true
  LIVE_ARCHIVE_SIZE="$(jq -r '.module_archive.size // empty' "$LIVE_POINTER" 2>/dev/null | tr -d '\r')" || true
  LIVE_ARCHIVE_PATH="$(jq -r '.module_archive.path // empty' "$LIVE_POINTER" 2>/dev/null | tr -d '\r')" || true
  [[ "$LIVE_ARCHIVE_SHA" =~ $SHA_RE && "$LIVE_ARCHIVE_SIZE" =~ ^[1-9][0-9]*$ \
    && "$LIVE_ARCHIVE_PATH" == "modules/$LIVE_ARCHIVE_SHA.zip" ]] \
    || fail "the live pointer does not name an archive as modules/<sha256>.zip with a size. Nothing was deployed."
}
# No zip given: the archive the live pointer names becomes the zip under
# publication, so every check below applies to it as to a zip passed in.
if [[ "$REPUBLISH_LIVE" == 1 ]]; then
  echo "    no zip given: re-publishing the archive the live pointer names"
  read_live_pointer
  ZIP="$WORK/live_archive.zip"
  matches_file "$DATA_READ_ROOT/$KEY_PREFIX/$LIVE_ARCHIVE_PATH" "$LIVE_ARCHIVE_SHA" "$LIVE_ARCHIVE_SIZE" "$WORK/verify" \
    || fail "the archive the live pointer names does not match it: $VERIFY_ERROR. Nothing was deployed."
  mv "$WORK/verify/body" "$ZIP"
fi

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
RECOGNIZER_VERSION="$(jq -r '.recognizer_version // empty' "$WORK/inner.json" | tr -d '\r')"
MINIMUM_VERSION="$(jq -r '.minimum_version // empty' "$WORK/inner.json" | tr -d '\r')"
APPLICATION_VERSION="$(jq -r '.application_version // empty' "$WORK/inner.json" | tr -d '\r')"
[[ "$RECOGNIZER_VERSION" =~ $DATE_RE ]] || fail "recognizer_version '$RECOGNIZER_VERSION' is not a date."
[[ "$MINIMUM_VERSION" =~ $DATE_RE ]] || fail "minimum_version '$MINIMUM_VERSION' is not a date."
[[ "$APPLICATION_VERSION" =~ $SEMVER_RE ]] || fail "application_version '$APPLICATION_VERSION' is not semver."

SHA="$(sha_of "$ZIP")"
SIZE="$(size_of "$ZIP")"
ARCHIVE_PATH="modules/$SHA.zip"
VERSIONED_KEY="$KEY_PREFIX/$ARCHIVE_PATH"
POINTER="$WORK/phase2/version_info.json"
jq --arg path "$ARCHIVE_PATH" --arg sha "$SHA" --argjson size "$SIZE" \
  '. + {module_archive: {path: $path, sha256: $sha, size: $size}}' "$WORK/inner.json" > "$POINTER"
POINTER_SHA="$(sha_of "$POINTER")"
POINTER_SIZE="$(size_of "$POINTER")"
# Leaving the zip out promises an unchanged pointer, so a rebuilt pointer that
# differs from the live bytes stops the run.
[[ "$REPUBLISH_LIVE" == 0 ]] || cmp -s "$POINTER" "$LIVE_POINTER" \
  || fail "the pointer rebuilt from the live archive differs from the live pointer. Nothing was deployed."
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "    HEAD $GIT_SHA"
echo "    read from $DATA_READ_ROOT, deploy verified on $DATA_VERIFY_ROOT"
echo "    archive: $ZIP ($SIZE bytes, sha256 $SHA)"
echo "    recognizer_version: $RECOGNIZER_VERSION"
echo "    pointer JSON:"
sed 's/^/      /' "$POINTER"

# ---- 1. Live state -----------------------------------------------------------
step "1. Live state on $DATA_READ_ROOT"
[[ -n "$LIVE_POINTER_SHA" ]] || read_live_pointer
OLD_RECOGNIZER_VERSION="$(jq -r '.recognizer_version // "(none)"' "$LIVE_POINTER" | tr -d '\r')"

# collect_inherited: the one place that decides which published archives the
# new tree carries. Writes "<sha256>\t<size>\t<published_at>" lines to
# $WORK/inherited.tsv and every archive, checked against its name and listed
# size, to $WORK/zips/<sha256>.zip. Fails the run on any archive it cannot
# fetch or match, and on a live pointer naming an archive outside the list.
# Drops the archives past RETENTION_DAYS before fetching any.
collect_inherited() {
  local code sha size published_at published_s now_s
  code="$(fetch "$DATA_READ_ROOT/deploy.json" "$WORK/live_deploy.json" "$WORK/verify/headers")"
  case "$code" in
    200)
      jq -r '.zips[] | [.sha256, (.size | tostring), .published_at] | @tsv' "$WORK/live_deploy.json" \
        2>/dev/null | tr -d '\r' > "$WORK/inherited.tsv" \
        || fail "the live deploy.json has no readable zips list. Nothing was deployed."
      echo "    live deploy.json lists $(wc -l < "$WORK/inherited.tsv" | tr -d ' ') archive(s)"
      ;;
    404)
      # The first publish onto this host: the R2 bucket it replaces carries no
      # deploy.json, and the only archive a client can still be sent to is the
      # one the live pointer names. Its publication time is unknown, so it is
      # stamped with this run's, which can only keep it longer.
      printf '%s\t%s\t%s\n' "$LIVE_ARCHIVE_SHA" "$LIVE_ARCHIVE_SIZE" "$NOW" > "$WORK/inherited.tsv"
      echo "    no live deploy.json (HTTP 404): first publish here, inheriting only the archive the live pointer names"
      ;;
    *)
      fail "could not fetch the live $DATA_READ_ROOT/deploy.json: HTTP $code. Only a 404 means a first publish. Nothing was deployed."
      ;;
  esac
  cut -f1 "$WORK/inherited.tsv" | grep -x "$LIVE_ARCHIVE_SHA" >/dev/null \
    || fail "the live pointer names $LIVE_ARCHIVE_SHA, which the live deploy.json does not list. Nothing was deployed."
  now_s="$(date -u -d "$NOW" +%s)"
  # The previous version is the most recently published archive other than
  # the one this run serves. On a republish of the live archive the live
  # pointer names the current version, so the pointer alone cannot name it.
  # Entries with an unreadable published_at take no part (they are kept below).
  local prev_s=-1
  while IFS=$'\t' read -r sha size published_at; do
    [[ "$sha" != "$SHA" && "$published_at" =~ $DATE_RE ]] \
      && published_s="$(date -u -d "$published_at" +%s 2>/dev/null)" \
      && (( published_s > prev_s )) && prev_s="$published_s"
  done < "$WORK/inherited.tsv"
  : > "$WORK/retained.tsv"
  while IFS=$'\t' read -r sha size published_at; do
    # The current version (this run's), the live pointer's and the previous
    # version are kept whatever their age.
    [[ "$published_at" =~ $DATE_RE ]] && published_s="$(date -u -d "$published_at" +%s 2>/dev/null)" || published_s=-2
    if [[ "$sha" != "$LIVE_ARCHIVE_SHA" && "$sha" != "$SHA" ]] && (( published_s != prev_s )); then
      # Dropping an archive cannot be undone for a client still holding a
      # pointer to it, so an unreadable date keeps it rather than guessing.
      if [[ ! "$published_at" =~ $DATE_RE ]] || ! published_s="$(date -u -d "$published_at" +%s 2>/dev/null)"; then
        echo "    WARNING: $sha has no readable published_at ('$published_at'); kept" >&2
      elif (( now_s - published_s > RETENTION_DAYS * 86400 )); then
        echo "    dropped $sha (published $published_at, more than $RETENTION_DAYS days ago)"
        continue
      fi
    fi
    printf '%s\t%s\t%s\n' "$sha" "$size" "$published_at" >> "$WORK/retained.tsv"
  done < "$WORK/inherited.tsv"
  mv "$WORK/retained.tsv" "$WORK/inherited.tsv"
  while IFS=$'\t' read -r sha size published_at; do
    [[ "$sha" =~ $SHA_RE && "$size" =~ ^[1-9][0-9]*$ ]] \
      || fail "the live deploy.json lists a malformed archive entry '$sha $size $published_at'. Nothing was deployed."
    matches_file "$DATA_READ_ROOT/$KEY_PREFIX/modules/$sha.zip" "$sha" "$size" "$WORK/verify" \
      || fail "inherited archive does not match its name and listed size: $VERIFY_ERROR. Nothing was deployed."
    mv "$WORK/verify/body" "$WORK/zips/$sha.zip"
    echo "    inherited $sha ($size bytes, published $published_at)"
  done < "$WORK/inherited.tsv"
}
collect_inherited

BACKUP="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
cp "$LIVE_POINTER" "$BACKUP/version_info.json"
cp "$WORK/zips/$LIVE_ARCHIVE_SHA.zip" "$BACKUP/modules.zip"
cp "$POINTER" "$BACKUP/new_version_info.json"
echo "    backed up the live pointer and the archive it names to $BACKUP"
echo "    recognizer_version: $OLD_RECOGNIZER_VERSION (current) -> $RECOGNIZER_VERSION (this archive)"
if [[ "$OLD_RECOGNIZER_VERSION" > "$RECOGNIZER_VERSION" ]]; then
  echo "    NOTE: this is a ROLLBACK to an older recognizer_version."
fi

# ---- 2. Assemble -------------------------------------------------------------
step "2. Assemble $TREE"
if [[ -f "$WORK/zips/$SHA.zip" ]]; then
  cmp -s "$WORK/zips/$SHA.zip" "$ZIP" || fail "the live $VERSIONED_KEY differs from $ZIP."
else
  cp "$ZIP" "$WORK/zips/$SHA.zip"
  printf '%s\t%s\t%s\n' "$SHA" "$SIZE" "$NOW" >> "$WORK/inherited.tsv"
fi
# write_deploy_json <phase> <pointer file> <out>
write_deploy_json() {
  jq -n --arg git_sha "$GIT_SHA" --arg built_at "$NOW" --argjson phase "$1" \
    --arg pointer_sha256 "$(sha_of "$2")" --rawfile zips "$WORK/inherited.tsv" \
    '{git_sha: $git_sha, built_at: $built_at, phase: $phase, pointer_sha256: $pointer_sha256,
      zips: [$zips | split("\n")[] | select(length > 0) | split("\t")
             | {sha256: .[0], size: (.[1] | tonumber), published_at: .[2]}]}' > "$3"
}
cp "$WORK/zips/$LIVE_ARCHIVE_SHA.zip" "$WORK/phase1/modules.zip"
write_deploy_json 1 "$LIVE_POINTER" "$WORK/phase1/deploy.json"
cp "$ZIP" "$WORK/phase2/modules.zip"
write_deploy_json 2 "$POINTER" "$WORK/phase2/deploy.json"

rm -rf "$TREE"
mkdir -p "$TREE/$KEY_PREFIX/modules"
cp -R "$SITE_SOURCE/." "$TREE/"
cp "$WORK/zips/"*.zip "$TREE/$KEY_PREFIX/modules/"
# stage_phase <1|2>: puts that phase's pointer, alias and deploy.json in the tree.
stage_phase() {
  cp "$WORK/phase$1/version_info.json" "$TREE/$POINTER_KEY"
  cp "$WORK/phase$1/modules.zip" "$TREE/$ALIAS_KEY"
  cp "$WORK/phase$1/deploy.json" "$TREE/deploy.json"
}
# The live pointer already names this archive (a re-publish): it is verified,
# so phase 1 would change nothing a client reads.
SKIP_PHASE1=0
[[ "$LIVE_ARCHIVE_SHA" == "$SHA" ]] && SKIP_PHASE1=1
stage_phase 2
echo "    archives: $(cut -f1 "$WORK/inherited.tsv" | tr '\n' ' ')"
cat "$WORK/phase2/deploy.json"

# ---- 3. Plan / confirmation gate ---------------------------------------------
step "3. Plan"
wrangler deploy -c "$WRANGLER_CONFIG" --dry-run
if [[ "$SKIP_PHASE1" == 1 ]]; then
  echo "    one deploy: the live pointer already names this archive"
else
  echo "    phase 1: add $VERSIONED_KEY beside the current pointer, verify it"
fi
echo "    phase 2: switch $POINTER_KEY and $ALIAS_KEY to it, verify both"
if [[ "$DRY_RUN" == 1 ]]; then
  echo
  echo "Dry run: stopping before any deploy. Nothing on $DATA_VERIFY_ROOT was changed."
  exit 0
fi
if [[ "$ASSUME_YES" == 1 ]]; then
  echo "    --yes: publishing without a prompt."
else
  read -r -p "Type 'yes' to publish: " reply
  [[ "$reply" == "yes" ]] || fail "aborted (nothing was deployed)."
fi

# ---- 4. Phase 1 --------------------------------------------------------------
if [[ "$SKIP_PHASE1" == 0 ]]; then
  step "4. Phase 1: the new archive beside the current pointer"
  stage_phase 1
  wrangler deploy -c "$WRANGLER_CONFIG" \
    || fail "phase 1 deploy failed. The pointer was not changed."
  wait_for_deploy_json "$WORK/phase1/deploy.json" \
    || fail "phase 1 is not served: $VERIFY_ERROR. The pointer was not changed."
  matches_file "$DATA_VERIFY_ROOT/$VERSIONED_KEY" "$SHA" "$SIZE" "$WORK/verify" \
    || fail "the new archive failed verification: $VERIFY_ERROR. The pointer was not changed."
  cors_authorizes "$WORK/verify/headers" \
    || fail "the new archive: $VERIFY_ERROR. The pointer was not changed."
  echo "    deploy.json is phase 1; the new archive's GET body sha256 and size match; CORS authorizes $CORS_PROBE_ORIGIN."
else
  step "4. Phase 1: skipped (the live pointer already names this archive)"
fi

# ---- 5. Phase 2 --------------------------------------------------------------
step "5. Phase 2: pointer and alias"
# verify_phase2: deploy.json, the pointer byte for byte, the alias, CORS.
verify_phase2() {
  wait_for_deploy_json "$WORK/phase2/deploy.json" \
    && matches_file "$DATA_VERIFY_ROOT/$POINTER_KEY" "$POINTER_SHA" "$POINTER_SIZE" "$WORK/verify" \
    && cors_authorizes "$WORK/verify/headers" \
    && matches_file "$DATA_VERIFY_ROOT/$ALIAS_KEY" "$SHA" "$SIZE" "$WORK/verify"
}
# verify_phase1: deploy.json and the current pointer byte for byte.
verify_phase1() {
  wait_for_deploy_json "$WORK/phase1/deploy.json" \
    && matches_file "$DATA_VERIFY_ROOT/$POINTER_KEY" "$LIVE_POINTER_SHA" "$(size_of "$LIVE_POINTER")" "$WORK/verify"
}
stage_phase 2
PHASE2_ERROR=""
if ! wrangler deploy -c "$WRANGLER_CONFIG"; then
  PHASE2_ERROR="the deploy failed, so the host may or may not serve phase 2"
elif ! verify_phase2; then
  PHASE2_ERROR="$VERIFY_ERROR"
fi
if [[ -n "$PHASE2_ERROR" ]]; then
  echo "    phase 2 failed verification: $PHASE2_ERROR" >&2
  ROLLBACK_HINT="NEEDS MANUAL RECOVERY: run \`wrangler rollback -c $WRANGLER_CONFIG\` to the version before this publish (one publish deploys twice) and check $DATA_VERIFY_ROOT/deploy.json."
  [[ "$SKIP_PHASE1" == 0 ]] \
    || fail "phase 2 failed ($PHASE2_ERROR); there is no phase 1 to return to. $ROLLBACK_HINT"
  echo "    deploying phase 1 again" >&2
  stage_phase 1
  wrangler deploy -c "$WRANGLER_CONFIG" && verify_phase1 \
    || fail "phase 2 failed ($PHASE2_ERROR), and returning to phase 1 ALSO failed verification ($VERIFY_ERROR). $ROLLBACK_HINT"
  fail "phase 2 failed ($PHASE2_ERROR); phase 1 was deployed again and verified, so the previous pointer and alias are served."
fi
echo "    deploy.json is phase 2; the pointer matches byte for byte; the alias matches."

# ---- 6. Summary ------------------------------------------------------------
step "6. Published"
echo "    recognizer_version: $RECOGNIZER_VERSION"
echo "    $DATA_VERIFY_ROOT/$VERSIONED_KEY"
echo "    sha256 $SHA, $SIZE bytes"
echo "    git_sha $GIT_SHA"
echo "    backup: $BACKUP"
echo "    to roll back, publish the previous archive with this script:"
echo "      bash tool/cloudflare/publish_modules.sh $BACKUP/modules.zip"
echo "    or, faster, \`wrangler rollback -c $WRANGLER_CONFIG\` -- one publish advances"
echo "    the Worker by two versions, so go back to the one before this publish's phase 1."
