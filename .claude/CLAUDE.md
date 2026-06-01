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
