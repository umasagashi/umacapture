#!/usr/bin/env bash
# Build the Flutter web bundle, but only from a web/ tree that still matches its pins.
#
# WHY THIS EXISTS
#   `flutter build web` copies web/ verbatim into build/web/. Everything under web/wasm/ is
#   gitignored, so tampering with a byte there is invisible to git, needs no commit, and does
#   not re-run codegen: the tampered bytes would ship next to a committed
#   assets/web_license_info.json still asserting they are unmodified upstream. Codegen and the
#   pre-commit hook both close the door on the *commit* path; this closes it on the build path.
#
# USE THIS INSTEAD OF `flutter build web`. Every argument is forwarded untouched, so the
# usual flags work:
#
#   tool/build_web.sh
#   tool/build_web.sh --source-maps
#
# --pwa-strategy=none is injected (see below), so it no longer has to be passed; passing it
# explicitly is still accepted, and any OTHER value is refused.
#
# It deliberately does NOT run build_runner: regenerating the disclosure as part of the build
# would let the build define its own truth. The artifact must already exist, say `verified`,
# and describe the tree on disk -- so a drifted tree fails here instead of shipping.
#
# Override the toolchain via the DART / FLUTTER env vars if FVM lives elsewhere.
set -euo pipefail

DART="${DART:-.fvm/flutter_sdk/bin/dart}"
FLUTTER="${FLUTTER:-.fvm/flutter_sdk/bin/flutter}"

# No --warn-stale-source-digest here, deliberately. tool/hooks/pre-commit passes it so that a
# native/ change can be committed from a machine with no emsdk; this script is the opposite
# situation -- it is about to put the pinned recognition core into a shippable bundle, so a
# module older than the native/ sources in this tree must stop the build, not warn about it.
if ! "$DART" run tool/check_web_pins.dart --licenses --require-verified; then
  echo "" >&2
  echo "✖ Refusing to build: web/ does not match tool/web_deps.json (see above)." >&2
  echo "  Restore the pinned bytes with:" >&2
  echo "    uv run tool/fetch_web_deps.py" >&2
  echo "  or, if the change is deliberate, update the pins and regenerate the disclosure:" >&2
  echo "    $DART run build_runner build --force-jit" >&2
  echo "  If the failure is a build.sources digest, neither applies: rebuild the module" >&2
  echo "  (native/wasm/build.sh), copy it into web/wasm/ and repin (see native/wasm/README.md)." >&2
  exit 1
fi

# No PWA service worker, ever. web/flutter_bootstrap.js is what actually guarantees none is
# REGISTERED (it calls _flutter.loader.load() with no serviceWorkerSettings, whatever this flag
# says); this pins the other half. A Flutter service worker at scope "/" replays cached responses
# without the COOP/COEP headers coi-serviceworker.js injects, which breaks cross-origin isolation
# -- and with it SharedArrayBuffer, which the -pthread recognition core requires -- on a later
# visit.
#
# What --pwa-strategy=none actually does (flutter_tools 3.44.4, ServiceWorkerStrategy.none):
# build/web/flutter_service_worker.js is still EMITTED, with an empty body. So the flag makes the
# file inert rather than absent -- belt to the bootstrap's braces: nothing references it, and a
# registration that somehow happened anyway would install a worker that caches nothing.
# The option is also deprecated as of this SDK and prints a warning on every build
# (flutter/flutter#156910); it is still passed because "inert" is a stronger guarantee than
# "unreferenced", and the day it is removed the emitted worker goes away with it.
#
# An explicit --pwa-strategy=none is accepted (it is what this script would add anyway); any
# other value is refused rather than silently honoured.
pwa_strategy="--pwa-strategy=none"
for arg in "$@"; do
  case "$arg" in
    --pwa-strategy=none)
      pwa_strategy=""
      ;;
    --pwa-strategy=*)
      echo "✖ Refusing to build: $arg. This bundle must ship without a Flutter service worker" >&2
      echo "  (see web/flutter_bootstrap.js and the coi-serviceworker note in web/index.html)." >&2
      exit 1
      ;;
    --pwa-strategy)
      echo "✖ Refusing to build: pass --pwa-strategy=none (or nothing at all); the space-separated" >&2
      echo "  form cannot be checked here, and only 'none' is allowed." >&2
      exit 1
      ;;
  esac
done

exec "$FLUTTER" build web ${pwa_strategy:+"$pwa_strategy"} "$@"
