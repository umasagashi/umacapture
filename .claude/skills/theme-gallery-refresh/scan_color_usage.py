# /// script
# requires-python = ">=3.11"
# ///
"""Scan lib/ for color usage feeding the in-app theme gallery.

Run from the repo root:  uv run .claude/skills/theme-gallery-refresh/scan_color_usage.py

Emits four blocks used to refresh lib/src/gui/theme_gallery.dart:
  1. ColorScheme role usage  -> by file, with occurrence counts (drives _roleUsages
     and which roles are "used" vs shown dimmed).
  2. ThemeData color usage    -> dividerColor / cardColor / etc. (_themeDataUsages).
  3. Translucent / blend sites -> withValues(alpha:), alphaBlend, Color.lerp
     (the "Translucent composites" and token sections).
  4. Hardcoded color literals  -> Color(0x...) and Colors.* (semantic / chart /
     code-highlight sections).

The gallery itself (theme_gallery.dart) is excluded so it does not count its own
swatch definitions.
"""

import os
import re
from collections import defaultdict

ROOT = os.path.join(os.getcwd(), "lib")
SKIP_FILES = {"theme_gallery.dart"}
GENERATED_SUFFIXES = (".g.dart", ".gr.dart", ".mapper.dart")

role_re = re.compile(r"colorScheme\.([A-Za-z0-9_]+)")
themed_re = re.compile(
    r"\.(scaffoldBackgroundColor|cardColor|canvasColor|dividerColor|shadowColor|disabledColor|hintColor)\b"
)
blend_re = re.compile(r"(withValues\(alpha:|withOpacity\(|Color\.alphaBlend|Color\.lerp)")
literal_re = re.compile(r"(Color\(0x[0-9A-Fa-f]{6,8}\)|Colors\.[A-Za-z]+(?:\.shade\d+)?)")


def iter_dart_files():
    for dirpath, _, files in os.walk(ROOT):
        for fn in files:
            if not fn.endswith(".dart") or fn.endswith(GENERATED_SUFFIXES) or fn in SKIP_FILES:
                continue
            yield fn, os.path.join(dirpath, fn)


def main():
    roles = defaultdict(lambda: defaultdict(int))
    themed = defaultdict(lambda: defaultdict(int))
    blends = []
    literals = []

    for fn, path in iter_dart_files():
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
        for i, line in enumerate(lines, start=1):
            for m in role_re.finditer(line):
                roles[m.group(1)][fn] += 1
            for m in themed_re.finditer(line):
                themed[m.group(1)][fn] += 1
            if blend_re.search(line):
                blends.append(f"{fn}:{i}: {line.strip()}")
            for m in literal_re.finditer(line):
                literals.append(f"{fn}:{i}: {m.group(1)}")

    def dump_counts(title, data):
        print(f"\n## {title}")
        for key in sorted(data, key=lambda k: -sum(data[k].values())):
            files = sorted(data[key].items(), key=lambda kv: (-kv[1], kv[0]))
            joined = ", ".join(f"{fn} x{c}" if c > 1 else fn for fn, c in files)
            print(f"- {key}: {joined}")

    dump_counts("ColorScheme roles (by file)", roles)
    dump_counts("ThemeData colors (by file)", themed)

    print("\n## Translucent / blend sites")
    for entry in blends:
        print(f"- {entry}")

    print("\n## Hardcoded color literals")
    for entry in literals:
        print(f"- {entry}")


if __name__ == "__main__":
    main()
