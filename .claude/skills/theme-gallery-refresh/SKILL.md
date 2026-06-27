---
name: theme-gallery-refresh
description: >-
  Refresh the in-app debug theme gallery (lib/src/gui/theme_gallery.dart) so it
  matches the current code. Use when the user wants to update, regenerate, or
  re-sync the theme/color gallery, after colors are added/removed/recolored, or
  when the gallery's swatches, usage descriptions, "used vs unused" marks, or
  translucent-composite list have gone stale. Rescans lib/ for ColorScheme role
  usage, hardcoded color literals, and alpha/blend sites, then updates the
  gallery's data tables and relaunches the app to verify.
---

# Refreshing the theme gallery

The theme gallery is a debug-only dialog defined in
`lib/src/gui/theme_gallery.dart` and opened from Settings → **Debug → Theme
gallery** (a `kDebugMode`-guarded tile in `lib/src/gui/settings.dart`). It is the
single source of truth for the app's palette during the theme review.

Most of what it shows is **live** (it reads the real `ColorScheme` / `ThemeData`
at runtime), but three things are **hand-maintained snapshots** of the code and
drift as the code changes. This skill re-derives those snapshots and patches the
file.

## What is a snapshot (and must be refreshed)

1. `_roleUsages` — map of `ColorScheme` role → one-line description of what it is
   used for. Its **keys also decide which roles count as "used"**: a role absent
   from the map renders dimmed with a "not used" note (`_unusedNote`). So adding
   first/last use of a role changes both its description and its used/unused mark.
2. `_themeDataUsages` — same idea for `ThemeData` colors (dividerColor, etc.).
3. The hand-written entries in `_BlendSection` (translucent composites) — each
   lists an overlay/base and a usage description.

What is **live and needs no editing**: the swatch colors/hex, the
`_ColorSchemeSection` role list (it already enumerates the full standard role
set), the tint-token values, and `_SemanticSection` / `_ChartSection` /
`_CodeHighlightSection` (these now read the `AppSemanticColors` /
`AppChartColors` / `CodeHighlightColors` extensions directly, so they update
themselves when `lib/src/gui/theme_extensions.dart` changes).

## Steps

1. **Scan.** From the repo root, run the bundled scanner (Python via `uv`, per
   the project's Python convention):

   ```bash
   uv run .claude/skills/theme-gallery-refresh/scan_color_usage.py
   ```

   It prints four blocks: ColorScheme role usage by file (with `xN` counts),
   ThemeData color usage, translucent/blend sites (`file:line`), and hardcoded
   color literals (`file:line`).

2. **Diff against the gallery.** Open `lib/src/gui/theme_gallery.dart` and compare:
   - Every role in the scan's "ColorScheme roles" block should have a `_roleUsages`
     entry. Roles **new** to the scan need an entry (write a concrete, one-line
     "what it's used for" description — read the cited files to phrase it, do not
     guess). Roles that **dropped out** of the scan should be removed from
     `_roleUsages` so they flip to the dimmed "not used" state.
   - Same for `_themeDataUsages` vs the "ThemeData colors" block.
   - Cross-check `_BlendSection` against the "Translucent / blend sites" block:
     add swatches for new `withValues(alpha:)` / `alphaBlend` overlays, drop ones
     that disappeared, and keep each `_BlendSwatch`'s `overlay` / `base` /
     `baseLabel` matching how the code actually composes the color.
   - The semantic / chart / code-highlight sections are **live** — they read the
     `ThemeExtension`s. New non-scheme colors belong in
     `lib/src/gui/theme_extensions.dart` (add a token + register it in
     `app_widget.dart`); the gallery then shows them automatically. Remaining raw
     literals in the "Hardcoded color literals" scan block are migration debt for
     a later slice, not gallery edits.

3. **Write descriptions, not file lists.** The right column is a human-readable
   "what it's used for" sentence (English, per the repo language policy), not a
   list of files. Use the scan's file hits only to *locate* the usage and read the
   surrounding code, then summarize. Keep it to one line.

4. **Verify.** Format and analyze just the file (the Dart MCP `analyze` hangs;
   use the CLI with the temp-data-home workaround):

   ```bash
   DART_DATA_HOME="$(mktemp -d)" .fvm/flutter_sdk/bin/dart format lib/src/gui/theme_gallery.dart
   DART_DATA_HOME="$(mktemp -d)" .fvm/flutter_sdk/bin/dart analyze lib/src/gui/theme_gallery.dart
   ```

5. **Show it.** Relaunch the debug app so the user can eyeball the result (kill any
   running instance first, since the build locks the exe):

   ```bash
   taskkill //F //IM umacapture.exe 2>/dev/null
   DART_DATA_HOME="$(mktemp -d)" .fvm/flutter_sdk/bin/flutter run -d windows --debug
   ```

   Then open Settings → Debug → Theme gallery. Toggle the app theme mode and
   reopen to check light vs dark; the dialog title shows the current brightness.

## Notes

- No code generation is involved — the gallery is plain Dart, so `build_runner`
  is not needed.
- The gallery is `kDebugMode`-only; it never ships in release builds.
- Keep the descriptions terse and concrete. If a role/literal is genuinely unused,
  let it fall through to the dimmed "not used" state rather than inventing a use.
- The scanner deliberately skips `theme_gallery.dart` itself and generated files
  (`*.g.dart`, `*.gr.dart`, `*.mapper.dart`).
