# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Writes the web app's icons from the app's own icon, unchanged.

The web app shows the same mark as the Windows app. Its sources are the app icon
(assets/image/app_icon.png, 256x256) and the Windows icon (windows/runner/resources/app_icon.ico),
whose smaller frames were drawn for their size rather than scaled down from the 256 one. So each
output is either the 256 PNG byte for byte, or one ico frame as it is: nothing is resized,
recoloured or padded.

    web/site/logo.png       the 256 PNG; the page headers and the OGP card draw it
    web/icons/Icon-256.png  the 256 PNG; the manifest's large icon
    web/icons/Icon-192.png  the ico's 192 frame; the manifest's small icon and apple-touch-icon
    web/favicon.png         the ico's 32 frame

Rerun after the app icon changes, then redraw web/og/default.png (og/scripts/render_default.mjs):

    uv run tool/build_web_icons.py
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
APP_PNG = ROOT / "assets" / "image" / "app_icon.png"
APP_ICO = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
WEB = ROOT / "web"

COPIES = ("site/logo.png", "icons/Icon-256.png")
FRAMES = {"icons/Icon-192.png": 192, "favicon.png": 32}


def ico_frame(size: int) -> bytes:
    with Image.open(APP_ICO) as ico:
        sizes = ico.info.get("sizes", set())
        if (size, size) not in sizes:
            sys.exit(f"{APP_ICO} has no {size}x{size} frame (it has {sorted(sizes)})")
        frame = ico.ico.getimage((size, size)).convert("RGBA")
    if frame.size != (size, size):
        sys.exit(f"{APP_ICO}: the {size} frame decoded as {frame.size}")
    out = io.BytesIO()
    frame.save(out, format="PNG", optimize=True)
    return out.getvalue()


def main() -> None:
    png = APP_PNG.read_bytes()
    with Image.open(io.BytesIO(png)) as image:
        if image.size != (256, 256):
            sys.exit(f"{APP_PNG} is {image.size}, not 256x256")
    outputs = {path: png for path in COPIES}
    outputs.update({path: ico_frame(size) for path, size in FRAMES.items()})
    for path, data in outputs.items():
        target = WEB / path
        target.write_bytes(data)
        print(f"wrote {target.relative_to(ROOT).as_posix()} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
