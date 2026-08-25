<!--
  Vendored from Flutter's official AI rules, then PRUNED: passages that conflict
  with this repo's conventions are deleted or rewritten, so only project-safe
  guidance remains. Nothing project-specific is added here — positive project
  rules live in .claude/CLAUDE.md and .claude/rules/.
  DO NOT EDIT BY HAND — the fetch and the pruning are reproduced by the
  `flutter-ai-rules-sync` skill, which overwrites this file and re-surveys for
  conflicts on every run.
  Source: https://raw.githubusercontent.com/flutter/flutter/refs/heads/main/docs/rules/rules_4k.md
  Update:  run the `flutter-ai-rules-sync` skill (re-fetch + re-survey + prune).
  Variant: rules_4k.md. To switch, run the skill with a variant arg.
-->

# AI Rules for Flutter

## Persona & Tools
* **Role:** Expert Flutter Developer. Focus: Beautiful, performant, maintainable code.
* **Explanation:** Explain Dart features (null safety, streams, futures) for new users.
* **Tools:** ALWAYS run `dart_format`. Use `dart_fix` for cleanups. Use `analyze_files` with `flutter_lints` to catch errors early.
* **Dependencies:** Add with the `pub` tool. Use `pub_dev_search` for discovery. Explain why a package is needed.

## Architecture & Structure
* **Entry:** Standard `lib/main.dart`.
* **Layers:** Presentation (Widgets), Domain (Logic), Data (Repo/API).
* **SOLID:** Strictly enforced.
* **State Management:**
  * **Pattern:** Separate UI state (ephemeral) from App state.

## Code Style & Quality
* **Naming:** `PascalCase` (Types), `camelCase` (Members), `snake_case` (Files).
* **Conciseness:** Functions <20 lines. Avoid verbosity.
* **Null Safety:** NO `!` operator. Use `?` and flow analysis (e.g. `if (x != null)`).
* **Async:** Use `async/await` for Futures. Catch all errors with `try-catch`.
* **Logging:** NEVER use `print`.

## Flutter Best Practices
* **Build Methods:** Keep pure and fast. No side effects. No network calls.
* **Isolates:** Use `compute()` for heavy tasks like JSON parsing.
* **Lists:** `ListView.builder` or `SliverList` for performance.
* **Immutability:** `const` constructors everywhere validation. `StatelessWidget` preference.
* **Composition:** Break complex builds into private `class MyWidget extends StatelessWidget`.

## Visual Design (Material 3)
* **Aesthetics:** Premium, custom look. "Wow" the user. Avoid default blue.
* **Modes:** Support Light & Dark modes (`ThemeMode.system`).
* **Typography:** `google_fonts`. Define a consistent Type Scale.
* **Layout:** `LayoutBuilder` for responsiveness. `OverlayPortal` for popups.
* **Components:** Use `ThemeExtension` for custom tokens (colors/sizes).

## Testing
* **Tools:** Use the `run_tests` tool. `flutter_test` (Widget), `integration_test` (E2E).
* **Mocks:** Prefer Fakes. Use `mockito` sparingly.
* **Pattern:** Arrange-Act-Assert.

## Accessibility (A11Y)
* **Contrast:** 4.5:1 minimum for text.
* **Semantics:** Label all interactive elements specifically.
* **Scale:** Test dynamic font sizes (up to 200%).
* **Screen Readers:** Verify with TalkBack/VoiceOver.
