# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Serve `build/web` for a local playtest of the web app.

`python -m http.server` cannot serve this build. It has no mapping for `.mjs`,
so it answers `text/plain`, and `worker.js` imports two ES modules
(`frame_shaping.mjs`, `video_import.mjs`). Strict MIME checking rejects those,
the wasm worker never initialises, and the app reports the failure as
"設定の適用に失敗しました" -- a toast about the capture pipeline, which reads
like an app defect rather than a serving defect.

Usage (from the repository root):

    uv run tool/serve_web_build.py                     # http://localhost:8080/
    uv run tool/serve_web_build.py --port 8081
    uv run tool/serve_web_build.py --coi off           # rely on coi-serviceworker.js

The wasm core needs SharedArrayBuffer, which the browser withholds unless the
document is cross-origin isolated. The build ships `coi-serviceworker.js` to
install COOP/COEP from a service worker on the second load, but that fails
outright in some browsing contexts ("An unknown error occurred when fetching the
script"), and when it does the worker reports
`crossOriginIsolated is false; SharedArrayBuffer unavailable` and capture is
dead -- again surfacing as the "設定の適用に失敗しました" toast rather than as
anything pointing at the server. So this server sends the headers itself by
default and the service worker becomes redundant.

The embedder policy defaults to `credentialless` rather than `require-corp`
because `require-corp` also blocks cross-origin subresources that do not opt in,
and on first run this app pulls its recognition modules from
data.umacapture.com, which is not ours to add CORP headers to. Use
`--coi require-corp` to reproduce a stricter deployment.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import mimetypes
import socketserver
from pathlib import Path

# The two the standard library gets wrong or omits. `.wasm` is registered on
# recent Pythons but not on all of them, and a wrong answer here fails the same
# way `.mjs` does.
EXTRA_TYPES = {
    ".mjs": "text/javascript",
    ".js": "text/javascript",
    ".wasm": "application/wasm",
    ".json": "application/json",
}


class Handler(http.server.SimpleHTTPRequestHandler):
    coi = "credentialless"

    def end_headers(self) -> None:
        # A playtest wants the bytes that are on disk, not the ones from the
        # last run: the whole point is to exercise a build made just now. Note
        # this cannot undo a stale entry cached by an earlier, wrong server --
        # for that the browser needs a hard reload or a different port.
        self.send_header("Cache-Control", "no-store")
        if self.coi != "off":
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", self.coi)
        super().end_headers()

    def log_message(self, format: str, *args: object) -> None:
        # Keep 404s and 5xx, drop the 200 flood: a Flutter build is hundreds of
        # assets and the interesting lines scroll away otherwise.
        status = str(args[1]) if len(args) > 1 else ""
        if status.startswith(("4", "5")):
            super().log_message(format, *args)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--directory", default="build/web")
    parser.add_argument(
        "--coi",
        choices=("credentialless", "require-corp", "off"),
        default="credentialless",
        help="cross-origin isolation: the embedder policy to send, or 'off' to leave it to coi-serviceworker.js",
    )
    args = parser.parse_args()

    root = Path(args.directory).resolve()
    if not (root / "index.html").is_file():
        parser.error(f"{root} does not look like a Flutter web build (no index.html). Run `flutter build web` first.")

    for suffix, kind in EXTRA_TYPES.items():
        mimetypes.add_type(kind, suffix)

    Handler.coi = args.coi
    handler = functools.partial(Handler, directory=str(root))

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("127.0.0.1", args.port), handler) as httpd:
        print(f"serving {root} at http://localhost:{args.port}/  (coi={args.coi})", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("stopped", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
