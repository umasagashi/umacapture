# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Serve a built Flutter web bundle with real cross-origin isolation headers.

The wasm recognition core needs ``SharedArrayBuffer``, which the browser only
grants to a cross-origin-isolated document. ``flutter run -d web-server`` does
not send COOP/COEP, so debug runs fall back to the vendored
``web/coi-serviceworker.js`` shim. This server sends the real headers instead,
which both matches production hosting and makes the shim a no-op, so it is the
right way to smoke-test a release bundle locally.

Usage (from anywhere; paths default to this repo)::

    uv run tool/serve_web_coi.py                 # serves <repo>/build/web on 8097
    uv run tool/serve_web_coi.py --port 8123
    uv run tool/serve_web_coi.py --root some/dir --host 0.0.0.0

Every response carries ``Cache-Control: no-store`` and no validator, and any
conditional request headers are dropped, so the browser can never serve a stale
copy or get a ``304``. That is not a nicety: ``flutter build web`` copies
``web/worker.js`` into the bundle **preserving its source mtime**, so a browser
holding a newer cached copy would never revalidate, and the page would run one
build's worker against another build's Dart side. That failure is silent, and it
has already invalidated real measurements - the only tell was the worker
rejecting a message type its newer counterpart sends.

Prerequisites:

* ``uv`` must be on PATH (see the ``project-setup`` skill). No third-party
  packages are needed - everything below is stdlib.
* The bundle must already exist. Build it first with
  ``.fvm/flutter_sdk/bin/flutter build web`` (add ``--wasm`` for the wasm
  renderer); this script never builds anything.

Local preview configurations (``.claude/launch.json``)
------------------------------------------------------

That file is deliberately free of machine-specific absolute paths, so it can be
committed. Both entries are launched through ``cmd.exe`` with the repo root as
the working directory, which constrains how they may be written:

``web-dev`` (port 8140)
    Runs ``.fvm\\flutter_sdk\\bin\\flutter.bat run -d web-server``. The
    executable is a **repo-relative path spelled with backslashes** - forward
    slashes make ``cmd`` read the first ``/segment`` as a switch and fail with
    "'.fvm' is not recognized as an internal or external command". Requires the
    FVM-pinned SDK to be provisioned (``.fvm/`` is gitignored; run ``fvm
    install``). No PATH entries are needed. Cross-origin isolation comes from
    the vendored ``web/coi-serviceworker.js`` shim, not from real headers.

``web-release`` (port 8097)
    Runs ``uv run tool/serve_web_coi.py`` - this script. ``uv`` is resolved
    from PATH, so it must be installed for the current user. Do **not** use
    ``bash`` as an entry point here: on a stock Windows PATH ``bash`` resolves
    to ``C:\\Windows\\System32\\bash.exe`` (WSL) long before Git Bash, which
    would run the script inside a Linux filesystem view.
"""

import argparse
import http.server
import pathlib
import socketserver

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_ROOT = REPO_ROOT / "build" / "web"


class CrossOriginIsolatedHandler(http.server.SimpleHTTPRequestHandler):
    """Static handler for the built bundle.

    Adds the COOP/COEP/CORP trio to every response and makes every response
    uncacheable and unvalidatable (see the module docstring).
    """

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".wasm": "application/wasm",
        ".json": "application/json",
    }

    def send_head(self):
        # Drop the conditional-request headers before the base class can honour
        # them. Together with the suppressed validators below this guarantees a
        # full 200 with fresh bytes on every request: a 304 here would hand the
        # browser back its stale copy of exactly the files that change most
        # (worker.js, main.dart.js), which is the cache-poisoning failure this
        # server exists to make impossible.
        for header in ("If-Modified-Since", "If-None-Match", "If-Unmodified-Since", "If-Range"):
            del self.headers[header]
        return super().send_head()

    def send_header(self, keyword, value):
        # Suppress the validators themselves, so nothing is left for a browser
        # (or an intermediary) to revalidate against.
        if keyword.lower() in ("last-modified", "etag"):
            return
        super().send_header(keyword, value)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # Same-origin would be enough today, but cross-origin keeps the bundle
        # embeddable from a differently-originated page without another edit.
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        # Never cache: see the module docstring. `no-store` covers both the HTTP
        # cache and the back/forward cache's reuse of a stored response.
        self.send_header("Cache-Control", "no-store, must-revalidate")
        super().end_headers()


class ReusableThreadingTCPServer(socketserver.ThreadingTCPServer):
    """Threading server that survives a quick restart on the same port.

    ``allow_reuse_address`` has to be set before ``server_bind`` runs, so it is
    a class attribute rather than an assignment on the instance.
    """

    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=pathlib.Path, default=DEFAULT_ROOT, help="directory to serve")
    parser.add_argument("--host", default="127.0.0.1", help="address to bind")
    parser.add_argument("--port", type=int, default=8097, help="port to bind")
    args = parser.parse_args()

    root = args.root.resolve()
    if not (root / "index.html").is_file():
        raise SystemExit(
            f"no index.html under {root}\n"
            "Build the bundle first: .fvm/flutter_sdk/bin/flutter build web [--wasm]"
        )

    def handler(*handler_args, **handler_kwargs):
        return CrossOriginIsolatedHandler(*handler_args, directory=str(root), **handler_kwargs)

    with ReusableThreadingTCPServer((args.host, args.port), handler) as httpd:
        print(f"serving {root} at http://{args.host}:{args.port} (cross-origin isolated, no-store)", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
