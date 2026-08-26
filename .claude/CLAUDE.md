# Project conventions

## Language policy

- **Chat / conversation with the user:** use the user's language (Japanese).
- **Everything else is written in English**, including:
  - Code comments and identifiers
  - Documentation (`docs/`, READMEs, design notes, etc.)
  - Commit messages and pull request titles/descriptions
  - Any other repository artifacts

Runtime/user-facing strings (e.g. localized UI text under `assets/translations/`) are exempt; they follow the app's localization, not this policy.

## Build / codegen

- The pinned Flutter SDK is managed via FVM at `.fvm/flutter_sdk` (call `.fvm/flutter_sdk/bin/flutter` / `.../dart`).
- Run code generation with `dart run build_runner build --force-jit`. The `--force-jit` flag is required because a transitive native build hook (`objective_c`, via `package_info_plus`) is incompatible with build_runner's default AOT compilation.
- The Dart MCP server (`dart` in `.mcp.json`) does **not** run code generation — it exposes no `build_runner` tool, and its `pub` tool only edits `pubspec`. After adding a codegen package or editing annotated sources (`dart_mappable`, `auto_route`), run `build_runner` manually with the command above. Do not assume the MCP tools regenerate outputs.

## Never reuse a build artifact you did not build this session

- **Do not run, measure, diagnose, or draw conclusions from any executable (or
  other build output) that was not produced by a build in the current session.**
  This applies to **both** the native CLI (`native/cmake-build-*/umacapture_cli.exe`)
  and the Flutter Windows app (`build/windows/.../*.exe`), and to any stitched /
  captured artifacts they emit.
- Before the first run of a session — and after any source change, `git`
  checkout / pull / stash, or branch switch — **rebuild from the current working
  tree** and run only that fresh binary. A pre-existing binary can be stale: built
  from an older commit, another branch, or an uncommitted state, so its output
  does not reflect the code under review.
- If provenance is ever in doubt (e.g. an `.exe` whose mtime predates recent
  commits), treat it as stale and rebuild rather than trusting it. When it
  matters, cross-check the artifact's build time against `git log` dates.
- Rationale: reusing a stale `umacapture_cli.exe` (built before a merged tail-trim
  fix) once produced misleading factor-tab output and sent a whole diagnosis
  chasing a bug that no longer existed on `HEAD`.

## App conventions (Dart)

`.claude/rules/flutter-ai-rules.md` is vendored upstream Flutter guidance with the conflicting
passages pruned out. These are the project's own answers where it now stays silent.

- **Layout.** There is no `lib/features/`. The tree is `lib/main.dart` plus
  `lib/src/{app,core,gui,chara_detail,preference,addon}`. Put new code in the area it belongs to;
  do not start a feature folder.
- **State and DI.** Riverpod 3 throughout (`flutter_riverpod: ^3.0.0`). Dependencies arrive through
  providers and `ref`, not hand-passed constructors. `ChangeNotifier` does still appear as a plain
  notification channel between widgets (`Widget selector(ChangeNotifier onDecided)` in
  `lib/src/chara_detail/spec/base.dart`) — that is neither app state nor the DI mechanism.
- **Logging.** Route diagnostics through `logger` (`lib/src/core/app_logger.dart`), not
  `dart:developer`'s `log()`. `app_logger` is the only place a Sentry breadcrumb is built — its
  `debugBreadcrumbSink` comment states that **every** `logger.d/i/w/e/wtf` line becomes one — and the
  only place the filesystem-path scrub (`<app>` / `<redacted>`) runs. A `dart:developer` line is
  therefore a diagnostic missing from every crash report, and a path nothing redacted. (Two calls in
  `lib/src/core/sound_player.dart` predate this and carry no stated reason; they are not the pattern
  to copy.)
- **Assertions.** `package:checks` is not a dependency. Tests assert with `expect(...)` from
  `flutter_test` / `package:test`.
- **Theme construction.** The app theme is built with `flex_color_scheme` — `FlexThemeData.light` /
  `.dark` in `lib/src/gui/app_widget.dart` — not `ColorScheme.fromSeed`, which appears nowhere in
  `lib/`. Light and dark are both built there and selected by `ThemeMode`. This is the construction
  site only; **which** colour a widget reads still follows the `## Colors` rules below.

## Formatting

- The repo complies with standard `dart format`; run it freely. The page width
  is pinned to **120 columns** via `analysis_options.yaml` (`formatter.page_width`),
  so `dart format` produces no whole-file churn. Do not hand-format against the
  legacy "short" style.
- A pre-commit hook (`tool/hooks/pre-commit`) rejects unformatted staged Dart
  files. Enable it once per clone with `git config core.hooksPath tool/hooks`.
- A historical reformat commit is listed in `.git-blame-ignore-revs`; `git blame`
  skips it when `blame.ignoreRevsFile` is configured.

## Colors

- New code reads colors from the theme — `ColorScheme` roles via
  `Theme.of(context).colorScheme`, or the `AppSemanticColors` / `AppChartColors` /
  `CodeHighlightColors` `ThemeExtension`s in `lib/src/gui/theme_extensions.dart`.
  Do not add raw colour literals in **any** spelling: `Colors.*`, `Color(0x…)`
  (or `0X…`, or a decimal ARGB), and the component constructors —
  `Color.fromARGB` / `Color.fromRGBO` / `Color.from`, and `HSLColor.fromAHSL` /
  `HSVColor.fromAHSV`. Naming only the first two is what let `Color.fromARGB`
  through both this rule and the hook that enforces it.
- Alpha **on a theme role** is fine when the design calls for it
  (`colorScheme.scrim.withValues(alpha: .3)`, state-layer overlays, glows);
  alpha on a **literal** is not (and is caught via the literal itself).
- `Colors.transparent` is allowed (it means "no color"; there is no theme role
  for it).
- The same pre-commit hook rejects **newly added** color literals outside an
  allowlist (`theme_extensions.dart`, `theme_gallery.dart`). It scans added lines
  only, so pre-existing literals awaiting migration are grandfathered until their
  lines are touched. The debug theme gallery (Settings → Debug → Theme gallery,
  `kDebugMode` only) visualizes the full palette and remaining literal debt.

## "Visualise it" means show the real pixels

When asked to visualise something — 「可視化して」/「図で見せて」/「見せて」 — the ask
is for **evidence**, not for an illustration.

- **Show an image of the actual artefact**: an extracted video frame, a magnified
  crop of the pixels in question, a screenshot of the running app, a diff of two
  real renders. It has to come from the data being discussed.
- **A schematic diagram is not an answer.** A chart drawn from numbers that were
  already reported restates the claim instead of testing it: if the numbers were
  misread, the chart is wrong in exactly the same way and looks just as
  convincing. A diagram may accompany the image, never replace it.
- **The image has to be able to contradict the claim.** Look at it before showing
  it, and if it disagrees, correct the claim — that is the whole point.
- **Magnify with nearest-neighbour** when individual pixels matter; smoothing
  invents pixels that were never measured.
- **Give the path.** Save under `.notes/analysis/<topic>/` (gitignored) and state
  it so the file can be opened directly.
