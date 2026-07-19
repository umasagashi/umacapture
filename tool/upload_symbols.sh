#!/usr/bin/env bash
# Upload this build's debug information to Sentry so native crashes symbolicate
# *and* stack-walk correctly. Run it from the repo root right after
# flutter_distributor (or `flutter build windows --release`) produced the exe,
# and before anything cleans build/. See the `release` skill, step 9.5.
#
#   export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"
#   tool/upload_symbols.sh
#
# Four files go up, in two pairs:
#
#   * PDBs (umacapture.pdb, flutter_windows.dll.pdb) carry symbol names, files
#     and line numbers.
#   * The PE binaries themselves (umacapture.exe, flutter_windows.dll) carry the
#     unwind tables, which live in the `.pdata` section and are *not* in a PDB.
#
# Uploading only the PDBs is the failure this script exists to prevent. Sentry
# then reports `unwind_status: missing` and walks the crash stack by scanning
# memory for plausible return addresses, so every frame arrives fully named and
# annotated while the call chain itself is wrong (`trust: scan`). That looks like
# a good stack trace and silently misdirects the whole diagnosis -- it already
# did once, on the 0.2.1 shutdown crash.
#
# Org/project coordinates come from .sentryclirc; the auth token must come from
# the environment. Override paths via the env vars below (e.g. to upload an
# older build that is still lying around).
set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-build/windows/x64/runner/Release}"
ENGINE_DIR="${ENGINE_DIR:-.fvm/flutter_sdk/bin/cache/artifacts/engine/windows-x64-release}"
SENTRY_CLI="${SENTRY_CLI:-sentry-cli}"

APP_PDB="$RUNNER_DIR/umacapture.pdb"
APP_EXE="$RUNNER_DIR/umacapture.exe"
ENGINE_PDB="$ENGINE_DIR/flutter_windows.dll.pdb"
ENGINE_DLL="$ENGINE_DIR/flutter_windows.dll"

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "error: SENTRY_AUTH_TOKEN is not set." >&2
  echo "  export SENTRY_AUTH_TOKEN=\"\$(tr -d ' \\t\\r\\n' < ~/.sentry_token)\"" >&2
  exit 1
fi

missing=0
for f in "$APP_PDB" "$APP_EXE" "$ENGINE_PDB" "$ENGINE_DLL"; do
  if [ ! -f "$f" ]; then
    echo "error: not found: $f" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "hint: build first, and do not clean build/ before uploading." >&2
  exit 1
fi

# Fail before uploading if a binary cannot actually contribute what we need. A
# PE without unwind info, or an exe whose Debug ID is absent (the /DEBUG link
# flags in windows/runner/CMakeLists.txt regressed), would upload "successfully"
# and still leave crashes unreadable.
for pe in "$APP_EXE" "$ENGINE_DLL"; do
  info="$("$SENTRY_CLI" debug-files check "$pe")"
  if ! grep -q 'unwind' <<<"$info"; then
    echo "error: $pe carries no unwind info; uploading it would be pointless." >&2
    echo "$info" >&2
    exit 1
  fi
  if ! grep -q 'Debug ID:' <<<"$info"; then
    echo "error: $pe has no Debug ID -- symbols will never match this build." >&2
    echo "check the /DEBUG link flags in windows/runner/CMakeLists.txt." >&2
    exit 1
  fi
done

echo "==> uploading 2 PDBs + 2 PE binaries"
"$SENTRY_CLI" debug-files upload --include-sources \
  "$APP_PDB" "$ENGINE_PDB" "$APP_EXE" "$ENGINE_DLL"

# `upload` prints UPLOADED only for files Sentry did not already have, so a
# re-run legitimately reports nothing. Ask the API what the server actually holds
# for each debug id instead of trusting the upload output. (`sentry-cli
# debug-files find` is no help here -- it searches the local disk, not Sentry, so
# it would match the very file we just handed it.)
ORG="$(sed -n 's/^org=//p' .sentryclirc | head -1)"
PROJECT="$(sed -n 's/^project=//p' .sentryclirc | head -1)"

echo "==> verifying unwind info is present server-side"
for pe in "$APP_EXE" "$ENGINE_DLL"; do
  debug_id="$("$SENTRY_CLI" debug-files check "$pe" | sed -n 's/.*Debug ID: *//p' | head -1)"
  dsyms="$(curl -sf -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" \
    "https://sentry.io/api/0/projects/$ORG/$PROJECT/files/dsyms/?debug_id=$debug_id")"
  if ! grep -q '"unwind"' <<<"$dsyms"; then
    echo "error: Sentry holds no unwind-capable object for $(basename "$pe")" >&2
    echo "       ($debug_id). Native stacks from this build would be guesswork." >&2
    exit 1
  fi
  echo "  ok: $(basename "$pe") $debug_id"
done

echo "==> done"
