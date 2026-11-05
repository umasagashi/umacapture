# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.60.1", "brotli==1.1.0"]
# ///
"""The public pages' font subsets keep the font's copyright and licence, run as the deploy runs it.

    uv run tool/cloudflare/test/test_build_page_fonts.py

The OFL asks every copy of the font to carry its copyright notice and licence; a subset that drops
the name table ships M PLUS Rounded 1c to every visitor without them. The case builds two synthetic
TTFs (no real glyphs) in a temporary repository root next to a copy of web/site/site.css, runs the
script as a subprocess with --root and --web-out pointing there, and reads the files it wrote at
the paths the stylesheet names. Nothing outside the temporary directory is read or written.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

SCRIPT = Path(__file__).resolve().parents[1] / "build_page_fonts.py"
STYLESHEET = Path(__file__).resolve().parents[3] / "web" / "site" / "site.css"
NOTICES = {
    0: "Copyright 2016 The Rounded M+ Project Authors.",
    13: "This Font Software is licensed under the SIL Open Font License, Version 1.1.",
    14: "http://scripts.sil.org/OFL",
}
# One character only the pages say, one only the tables hold: neither is in the script's base set.
PAGE_CHAR, TABLE_CHAR = "試", "馬"


def synthetic_ttf(path: Path, style: str) -> None:
    chars = [" ", "A", PAGE_CHAR, TABLE_CHAR, "龍"]
    names = [".notdef"] + [f"g{i}" for i in range(len(chars))]
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({ord(c): f"g{i}" for i, c in enumerate(chars)})
    glyphs = {}
    for name in names:
        pen = TTGlyphPen(None)
        pen.moveTo((100, 0))
        pen.lineTo((100, 700))
        pen.lineTo((600, 700))
        pen.closePath()
        glyphs[name] = pen.glyph()
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({name: (700, 100) for name in names})
    fb.setupHorizontalHeader(ascent=880, descent=-120)
    fb.setupNameTable(
        {
            "copyright": NOTICES[0],
            "familyName": "Synthetic Rounded",
            "styleName": style,
            "licenseDescription": NOTICES[13],
            "licenseInfoURL": NOTICES[14],
        }
    )
    fb.setupOS2()
    fb.setupPost()
    fb.save(str(path))


class BuildPageFontsTest(unittest.TestCase):
    def test_every_subset_keeps_the_copyright_and_licence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            (root / "web" / "site").mkdir(parents=True)
            shutil.copy(STYLESHEET, root / "web" / "site" / "site.css")
            (root / "web" / "og" / "fonts").mkdir(parents=True)
            synthetic_ttf(root / "web" / "og" / "fonts" / "MPLUSRounded1c-Regular.ttf", "Regular")
            synthetic_ttf(root / "web" / "og" / "fonts" / "MPLUSRounded1c-Bold.ttf", "Bold")
            (root / "web" / "notice").mkdir()
            (root / "web" / "notice" / "index.html").write_text(f"<p>{PAGE_CHAR}</p>", encoding="utf-8")
            tables = Path(tmp) / "tables.json"
            tables.write_text(json.dumps({"names": {"character.character": [TABLE_CHAR]}}), encoding="utf-8")
            web_out = Path(tmp) / "build" / "web"

            run = subprocess.run(
                [sys.executable, str(SCRIPT), "--root", str(root), "--web-out", str(web_out), "--tables", str(tables)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(run.returncode, 0, run.stderr)

            written = sorted((web_out / "site" / "fonts").glob("*.woff2"))
            self.assertEqual(len(written), 2, written)
            for path in written:
                font = TTFont(path)
                names = {r.nameID: r.toUnicode() for r in font["name"].names if r.platformID == 3}
                for name_id, text in NOTICES.items():
                    self.assertEqual(names.get(name_id), text, f"{path.name} name ID {name_id}")
                cmap = font.getBestCmap()
                # The subset was cut to the inputs, not copied whole.
                self.assertIn(ord(PAGE_CHAR), cmap, path.name)
                self.assertIn(ord(TABLE_CHAR), cmap, path.name)
                self.assertNotIn(ord("龍"), cmap, path.name)


if __name__ == "__main__":
    unittest.main()
