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
  Do not add raw `Colors.*`, `Color(0x…)`, or ad-hoc `withValues(alpha:)` /
  `withOpacity(…)`.
- The same pre-commit hook rejects **newly added** color literals outside an
  allowlist (`theme_extensions.dart`, `theme_gallery.dart`). It scans added lines
  only, so pre-existing literals awaiting migration are grandfathered until their
  lines are touched. The debug theme gallery (Settings → Debug → Theme gallery,
  `kDebugMode` only) visualizes the full palette and remaining literal debt.
