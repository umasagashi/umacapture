#!/usr/bin/env bash
# Upload the web build's JavaScript source maps to Sentry so release stack
# traces de-minify in the dashboard (otherwise frames arrive as `minified:aeK`).
#
# BUILD FIRST -- Flutter 3.44.4 does not emit source maps by default, so a plain
# `flutter build web` produces no `.map` and this script will refuse to run. Build
# through tool/build_web.sh, never `flutter build web` directly: it gates the build
# on web/ still matching tool/web_deps.json (see that script's header):
#
#   tool/build_web.sh --pwa-strategy=none --source-maps
#   export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"
#   tool/upload_web_sourcemaps.sh
#
# The release string is read from assets/version_info.json (`version`) and must
# match the bare release the SDK sets at runtime (options.release = <version>,
# no prefix, no dist). Source maps uploaded under any other release -- or with a
# dist -- will not symbolicate.
#
# IMPORTANT: it is `sourcemaps inject` -- a separate subcommand this script runs
# just before the upload -- that writes debug IDs into build/web. `sourcemaps
# upload` does *not* inject anything on its own (sentry-cli 3.6.0). `inject`
# rewrites the files in place: every .js gains a `//# debugId=` comment plus a
# small `_sentryDebugIds` snippet, and each .map gains the matching `debugId`.
#
# The injected build/web tree is therefore the one that must be deployed. Deploy
# a freshly built (un-injected) tree instead and Sentry has nothing but the
# release plus the artifact URL to match on; that name-only match never verifies
# the contents, so any drift between the uploaded and the served tree lands as
# `js_invalid_sourcemap_location` on the event.
#
# Org/project coordinates come from .sentryclirc; the auth token must come from
# the environment (never stored in the repo).
set -euo pipefail

SENTRY_CLI="${SENTRY_CLI:-sentry-cli}"
WEB_DIR="${WEB_DIR:-build/web}"
VERSION_FILE="${VERSION_FILE:-assets/version_info.json}"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "error: SENTRY_AUTH_TOKEN is not set." >&2
  echo "  export SENTRY_AUTH_TOKEN=\"\$(tr -d ' \\t\\r\\n' < ~/.sentry_token)\"" >&2
  exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
  echo "error: not found: $VERSION_FILE" >&2
  exit 1
fi

# Read the bare release string (e.g. 0.2.1) that the SDK stamps onto events.
RELEASE="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -1)"
if [ -z "$RELEASE" ]; then
  echo "error: could not parse \"version\" from $VERSION_FILE" >&2
  exit 1
fi

if [ ! -d "$WEB_DIR" ] || [ ! -f "$WEB_DIR/main.dart.js.map" ]; then
  echo "error: $WEB_DIR has no main.dart.js.map -- build with source maps first:" >&2
  echo "  tool/build_web.sh --pwa-strategy=none --source-maps" >&2
  exit 1
fi

map_count="$(find "$WEB_DIR" -name '*.map' | wc -l | tr -d ' ')"

echo "==> uploading source maps for release $RELEASE ($map_count .map files under $WEB_DIR)"

# Ensure the release exists so the upload associates cleanly. `sourcemaps
# upload` auto-creates it too, but creating it explicitly is idempotent and
# makes the association obvious in the summary below.
"$SENTRY_CLI" releases new "$RELEASE"

# Stamp debug IDs into the build. This is a separate subcommand -- `sourcemaps
# upload` will not do it -- and skipping it leaves Sentry matching maps by
# release plus artifact URL alone, which is what produces
# `js_invalid_sourcemap_location` once the served tree drifts from the uploaded
# one.
echo "==> injecting debug IDs into $WEB_DIR (rewrites the .js and .map in place)"
"$SENTRY_CLI" sourcemaps inject "$WEB_DIR"

# An injection that silently did nothing would still upload "successfully" and
# leave symbolication on the fragile name-based path, so check the bundle
# entry point really carries an id now.
if ! grep -q -e '//# debugId=' -e '_sentryDebugIds' "$WEB_DIR/main.dart.js"; then
  echo "error: $WEB_DIR/main.dart.js carries no debug ID after 'sourcemaps inject'." >&2
  echo "       Sentry could only match maps by name, which breaks as soon as the" >&2
  echo "       deployed tree differs from the uploaded one." >&2
  exit 1
fi

# Report how much source text will be available, for information only. dart2js
# never writes `sourcesContent` (it has no option to), so whatever Sentry ends
# up showing comes from sentry-cli's default --rewrite resolving each `sources`
# entry against this working tree. Dart SDK URIs (`org-dartlang-sdk:///`) and
# synthetic sources stay unresolved and surface as the harmless
# `js_missing_sources_content` warning -- file and line still resolve. A worse
# ratio than expected means the upload is not running against the same checkout
# and PUB_CACHE as the build.
echo "==> inspecting $WEB_DIR/main.dart.js.map"
if command -v uv >/dev/null 2>&1; then
  # Streamed with ijson: main.dart.js.map runs to hundreds of MB, so a plain
  # json.load() would be both slow and memory-hungry.
  uv run --quiet - "$WEB_DIR/main.dart.js.map" <<'PY' || echo "    warn: could not inspect the source map (continuing)"
# /// script
# requires-python = ">=3.10"
# dependencies = ["ijson>=3.3"]
# ///
"""Report `sourcesContent` coverage of a source map in constant memory."""

import sys

import ijson

sources = contents = missing = 0
with open(sys.argv[1], "rb") as handle:
    for prefix, _event, value in ijson.parse(handle, use_float=True):
        if prefix == "sources.item":
            sources += 1
        elif prefix == "sourcesContent.item":
            contents += 1
            if not value:
                missing += 1

if contents == 0:
    print(f"    sourcesContent: absent ({sources} sources); sentry-cli --rewrite")
    print("    resolves what it can from this checkout during the upload.")
else:
    rate = 100.0 * missing / contents
    print(f"    sourcesContent: {contents} entries for {sources} sources,")
    print(f"    {missing} unresolved ({rate:.1f}%).")
PY
else
  echo "    warn: uv not found; skipping the sourcesContent report"
fi

# Modern debug-id workflow: no --url-prefix, no --dist. The debug IDs injected
# above tie the .map to the .js regardless of the served path.
"$SENTRY_CLI" sourcemaps upload --release "$RELEASE" "$WEB_DIR"

# Verify the artifact bundle actually landed and is associated with this exact
# release. The modern debug-id workflow stores an *artifact bundle* rather than
# per-release files, so `releases files list` (or the legacy release-files API)
# is empty by design; query the artifact-bundles API instead. Org/project come
# from .sentryclirc, as in tool/upload_symbols.sh.
ORG="$(sed -n 's/^org=//p' .sentryclirc | head -1)"
PROJECT="$(sed -n 's/^project=//p' .sentryclirc | head -1)"

echo "==> verifying the artifact bundle landed for release $RELEASE"
bundles="$(curl -sf -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
  "https://sentry.io/api/0/projects/$ORG/$PROJECT/files/artifact-bundles/?query=$RELEASE")"
# Strip all whitespace first, then fixed-string match, so a pretty-printed
# response (space after the JSON colon) still matches. `grep -F` keeps the dots
# in a release like 0.2.1 literal, and the "release":"..." shape stays specific
# enough not to match an unrelated release.
if ! tr -d ' \t\r\n' <<<"$bundles" | grep -qF "\"release\":\"$RELEASE\""; then
  echo "error: Sentry holds no artifact bundle associated with release $RELEASE." >&2
  echo "       response: $bundles" >&2
  exit 1
fi
files="$(sed -n 's/.*"fileCount":\([0-9]*\).*/\1/p' <<<"$bundles" | head -1)"

echo "==> done: release $RELEASE has an artifact bundle with $files files (source maps included)."
echo "    remember: deploy the injected $WEB_DIR exactly as it stands now -- the"
echo "    debug IDs were written into those files, so rebuilding without"
echo "    re-running this script breaks the match."
echo
echo "    BUT LEAVE THE .map FILES BEHIND. Sentry now holds them, and the debug IDs"
echo "    injected above are what match them to the served .js -- so nothing in the"
echo "    symbolication path reads a .map over HTTP. Serving them costs:"
echo "      * Cloudflare Pages caps a single file at 25 MiB, and main.dart.js.map is"
echo "        well past that, so the deploy itself fails;"
echo "      * on R2 it is hundreds of MB of upload and storage per release, for files"
echo "        no client requests."
echo "    Exclude them at upload time rather than deleting them from $WEB_DIR: a"
echo "    re-upload to Sentry after a failed deploy needs the same injected tree."
echo "    e.g.  rclone copy $WEB_DIR <remote> --exclude '*.map'"
echo "     or   find $WEB_DIR -name '*.map' -print   # to review what is being held back"
