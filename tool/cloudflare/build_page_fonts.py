# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.60.1", "brotli==1.1.0"]
# ///
"""Cut the public pages' font files out of the pinned M PLUS Rounded 1c.

    uv run tool/cloudflare/build_page_fonts.py --web-out build/web [--tables <tables.json>]

web/site/site.css is the one place that says which font files the public pages read: every
@font-face of "M PLUS Rounded 1c" names a weight and a url. This script writes exactly those files,
the url resolved against the stylesheet's own location under --web-out, each a woff2 subset of the
pinned TTF of that weight (web/og/fonts/, see tool/web_deps.json). A weight with no pinned TTF, or a
stylesheet with no such @font-face, stops the script with exit 1 and writes nothing.

The subset holds every character of:
  - the pages' own wording: every web/**/*.html, and server/src/*.mjs, where the Worker builds its
    pages. Whole files are read, markup and code included, so a new page or a moved string is
    covered without naming it here; the extra Latin letters cost nothing;
  - with --tables, every name in the share Worker's tables, which the record pages print: the file
    tool/cloudflare/load_share_tables.py --read-to writes from the target's D1. Without it
    (deploy_web.sh --sharing off, no Worker) only the wording;
  - a fixed base: printable ASCII, hiragana, katakana, CJK punctuation and the fullwidth forms.
A character the font has no glyph for is left out, and the browser draws it with the next font in
the stylesheet's --font list; the script prints how many there were.

The name table is kept whole, so each subset carries the font's copyright and its OFL licence
description (name IDs 0, 13 and 14), as the OFL asks of every copy. A subset is a Modified Version
under the OFL; the font declares no Reserved Font Name, so it keeps its name.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont

REPO_ROOT = Path(__file__).resolve().parents[2]
FAMILY = "M PLUS Rounded 1c"
STYLESHEET = Path("web/site/site.css")
# The pinned TTF of each weight the stylesheet may ask for (tool/web_deps.json).
SOURCES = {
    400: Path("web/og/fonts/MPLUSRounded1c-Regular.ttf"),
    700: Path("web/og/fonts/MPLUSRounded1c-Bold.ttf"),
}
WORDING = [(Path("web"), "**/*.html"), (Path("server/src"), "*.mjs")]
BASE = (
    [chr(c) for c in range(0x20, 0x7F)]
    + [chr(c) for c in range(0x3000, 0x3100)]  # CJK symbols and punctuation, hiragana, katakana
    + [chr(c) for c in range(0xFF01, 0xFF5F)]  # fullwidth forms
)

FONT_FACE = re.compile(r"@font-face\s*\{(.*?)\}", re.S)
DECLARATION = re.compile(r"([a-z-]+)\s*:\s*([^;]+);?")
URL = re.compile(r"""url\(\s*["']?([^"')]+)["']?\s*\)""")


def faces(css: str) -> dict[int, str]:
    """weight -> url of every @font-face of FAMILY in `css`."""
    found: dict[int, str] = {}
    for block in FONT_FACE.findall(css):
        props = {name: value.strip() for name, value in DECLARATION.findall(block)}
        if props.get("font-family", "").strip("\"'") != FAMILY:
            continue
        url = URL.search(props.get("src", ""))
        if url is None:
            raise SystemExit(f"{STYLESHEET}: an @font-face of {FAMILY} has no url()")
        found[int(props.get("font-weight", "400"))] = url.group(1)
    return found


def characters(root: Path, tables: Path | None) -> str:
    chars = set(BASE)
    for directory, pattern in WORDING:
        for path in sorted((root / directory).glob(pattern)):
            chars |= set(path.read_text(encoding="utf-8"))
    if tables is not None:
        for names in json.loads(tables.read_text(encoding="utf-8"))["names"].values():
            for name in names:
                if isinstance(name, str):
                    chars |= set(name)
    return "".join(sorted(c for c in chars if c.isprintable() or c == " "))


def cut(source: Path, text: str) -> tuple[TTFont, int]:
    # recalcTimestamp=False keeps head.modified as the TTF has it, so the same inputs give the same
    # bytes on every deploy.
    font = TTFont(source, recalcTimestamp=False)
    cmap = font.getBestCmap()
    missing = sum(1 for c in text if ord(c) not in cmap)
    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.name_legacy = True
    subsetter = subset.Subsetter(options)
    subsetter.populate(text=text)
    subsetter.subset(font)
    font.flavor = "woff2"
    return font, missing


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--web-out", type=Path, required=True, help="the built web root (build/web)")
    parser.add_argument("--tables", type=Path, help="the share Worker's name tables, as read back from D1")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    wanted = faces((args.root / STYLESHEET).read_text(encoding="utf-8"))
    if not wanted:
        raise SystemExit(f"{STYLESHEET} declares no @font-face of {FAMILY}")
    unknown = sorted(set(wanted) - set(SOURCES))
    if unknown:
        raise SystemExit(f"{STYLESHEET} asks for {FAMILY} weight {unknown}, which has no pinned TTF")

    text = characters(args.root, args.tables)
    fonts = []
    for weight, url in sorted(wanted.items()):
        font, missing = cut(args.root / SOURCES[weight], text)
        out = (args.web_out / STYLESHEET.relative_to("web")).parent / url
        fonts.append((font, out, weight, missing))
    for font, out, weight, missing in fonts:
        out.parent.mkdir(parents=True, exist_ok=True)
        font.save(out)
        print(f"{out}: weight {weight}, {len(text)} characters, {missing} without a glyph, {out.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
