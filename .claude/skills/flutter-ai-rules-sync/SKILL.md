---
name: flutter-ai-rules-sync
description: >-
  Install or update Flutter's official AI rules into this repo, pruned to remove
  anything that conflicts with this project's conventions. Vendors the upstream
  rules file from flutter/flutter into .claude/rules/flutter-ai-rules.md
  (auto-loaded by Claude Code), re-surveys it against the current project state
  for conflicts, then deletes/rewrites the conflicting passages so only
  project-safe guidance remains. Use when the user wants to install, refresh,
  re-sync, or switch the size variant of the official Flutter/Dart AI rules.
---

# Sync Flutter's official AI rules (pruned to fit this project)

Vendors Flutter's official AI rules into `.claude/rules/flutter-ai-rules.md`,
then removes the parts that contradict this repo. Files under `.claude/rules/`
are auto-loaded into every session, so this file is in effect for every task —
conflicting upstream guidance must be gone, not merely annotated.

Guiding principle — **prune, don't annotate**:

- Keep only the upstream guidance that is *not* problematic for this project.
- Resolve each conflict by **deleting** the offending passage, or **rewriting**
  it to be correct, whichever leaves the cleaner result. Prefer deletion when a
  project-side authority (`.claude/CLAUDE.md`, `.claude/rules/`) already covers
  the correct behavior — don't duplicate it here (duplication drifts).
- **Do not add project-specific notes/bullets to this file** (no "(project) …",
  no "ignore the above"). Positive project rules belong in `.claude/CLAUDE.md`
  and `.claude/rules/`. This file is purely "upstream minus the conflicts".
- Otherwise keep the fetched body verbatim, so upstream updates diff cleanly.

## Source

Upstream lives in the `flutter/flutter` repo under `docs/rules/`, served raw at:

```
https://raw.githubusercontent.com/flutter/flutter/refs/heads/main/docs/rules/<variant>
```

## Variants

Pick by the `args` the user passed (default = `full`). Map to the upstream file:

| arg            | upstream file  | approx size         |
| -------------- | -------------- | ------------------- |
| `full` (def.)  | `rules.md`     | ~31k chars (~8k tk) |
| `10k`          | `rules_10k.md` | ~9k chars           |
| `4k`           | `rules_4k.md`  | ~3.5k chars         |
| `1k`           | `rules_1k.md`  | ~0.8k chars         |

Larger = more guidance but more per-session context cost (it is always loaded).

## Step 1 — Fetch

1. Resolve the variant from `args` (default `full`) to its upstream filename.
2. Fetch the raw URL for that file.
3. Write `.claude/rules/flutter-ai-rules.md` = the provenance header below,
   followed by the fetched body. Normalize line endings to LF. Use UTF-8
   **without BOM**.

Provenance header (substitute `<url>` and `<variant-file>`):

```
<!--
  Vendored from Flutter's official AI rules, then PRUNED: passages that conflict
  with this repo's conventions are deleted or rewritten, so only project-safe
  guidance remains. Nothing project-specific is added here — positive project
  rules live in .claude/CLAUDE.md and .claude/rules/.
  DO NOT EDIT BY HAND — the fetch and the pruning are reproduced by the
  `flutter-ai-rules-sync` skill, which overwrites this file and re-surveys for
  conflicts on every run.
  Source: <url>
  Update:  run the `flutter-ai-rules-sync` skill (re-fetch + re-survey + prune).
  Variant: <variant-file>. To switch, run the skill with a variant arg.
-->
```

## Step 2 — Re-survey conflicts against the CURRENT project state

**Do not blindly re-apply last time's edits.** Conflicts drift in both
directions: the project's conventions change (new packages, dropped tools,
changed build flags) and upstream rewrites its rules (new sections, reworded
guidance). Each sync must re-derive the conflict set from scratch.

1. **Read the current project conventions** — the source of truth for "what is
   correct here":
   - `.claude/CLAUDE.md` (and `~/.claude/CLAUDE.md`)
   - every file under `.claude/rules/` (except this generated one)
   - `pubspec.yaml` — `dependencies` / `dev_dependencies` (state management,
     routing, serialization, codegen, lint, etc.) and the SDK constraints
   - `analysis_options.yaml` if present
2. **Read the freshly-fetched upstream body** end to end.
3. **Flag every passage that conflicts**, i.e. upstream that would lead the agent
   to do something this project forbids or does differently. Typical conflict
   classes (check each against the CURRENT project — membership changes over time):
   - **Tooling / SDK invocation** — bare `flutter`/`dart` vs. this repo's policy.
   - **Build / codegen commands** — flags or commands that differ from what
     `.claude/CLAUDE.md` mandates.
   - **Architecture mandates** — upstream picking a package/approach that
     competes with one already adopted here (state management, routing, DI,
     serialization, etc.).
   - **Test commands / tooling** — fallbacks that bypass the project's tools.
   - **Examples** that recommend or `pub add` a package that competes with an
     adopted one (vs. merely optional packages, which are not conflicts).
4. Also note **conflicts that disappeared** (upstream dropped it, or the project
   changed to match) — those need no edit, but mention them in the report.

### Known conflicts as of the last sync (REFERENCE ONLY — re-verify, don't trust)

This is a snapshot to speed up the survey, **not** an authoritative patch list.
Confirm each still exists in the new upstream AND still conflicts with the
current project, and look for conflicts not on this list.

- **SDK invocation:** upstream "Adding/Removing Dependencies" bullets fall back to
  bare `flutter pub add` / `dart pub remove`. Project pins the SDK via FVM
  (`.claude/CLAUDE.md`). → Deleted the bare-command fallbacks; kept "use the
  `pub` tool". (FVM rule already lives in CLAUDE.md, so not restated here.)
- **State management:** upstream "Built-in Solutions" (prefer built-in, avoid
  third-party) and "Provider" (use the `provider` package) bullets. Project uses
  `flutter_riverpod ^3.0.0`. → Deleted both bullets; kept the architecture-neutral
  Streams/Futures/ValueNotifier/ChangeNotifier/MVVM/manual-DI bullets.
- **Routing:** upstream "### Routing" recommends `go_router` with a setup example
  + auth-redirect bullet, and the overview "Navigation" bullet lists
  "`auto_route` or `go_router`". Project uses `auto_route`. → Deleted the
  go_router bullets, kept the built-in `Navigator` bullet, and trimmed the
  overview bullet to `auto_route`.
- **Code generation:** upstream run command
  `dart run build_runner build --delete-conflicting-outputs`. Project mandates
  `dart run build_runner build --force-jit` via the FVM dart (`.claude/CLAUDE.md`).
  → Deleted the upstream "Running Build Runner" command block (CLAUDE.md governs
  the exact command); also dropped the `json_serializable` example (repo uses
  `dart_mappable`/`auto_route`).
- **Tests:** upstream fallback `flutter test`. → Reduced to "use the `run_tests`
  tool".
- **Non-conflicts left intact:** the `google_fonts` example is an optional
  suggestion that competes with nothing the project mandates — keep it.

## Step 3 — Prune

Apply the deletions/rewrites for the conflicts found in Step 2, following the
guiding principle (delete or rewrite; never add project notes). Re-normalize to
LF, UTF-8 without BOM.

## Step 4 — Report

Tell the user:
- variant used and resulting char count;
- whether the upstream body changed vs. the previous sync (diff ignoring header);
- the conflict set this run: **removed/rewritten**, **newly appeared**,
  **disappeared since last sync**, and **deliberately-kept non-conflicts**.

## Reference command (Windows / PowerShell — Step 1 only)

Step 1 (fetch + header) can be scripted; Steps 2–3 are done with the editor.
Replace `rules.md` with the chosen variant file.

```powershell
$file = "rules.md"   # or rules_10k.md / rules_4k.md / rules_1k.md
$url  = "https://raw.githubusercontent.com/flutter/flutter/refs/heads/main/docs/rules/$file"
$body = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
$header = @"
<!--
  Vendored from Flutter's official AI rules, then PRUNED: passages that conflict
  with this repo's conventions are deleted or rewritten, so only project-safe
  guidance remains. Nothing project-specific is added here — positive project
  rules live in .claude/CLAUDE.md and .claude/rules/.
  DO NOT EDIT BY HAND — the fetch and the pruning are reproduced by the
  ``flutter-ai-rules-sync`` skill, which overwrites this file and re-surveys for
  conflicts on every run.
  Source: $url
  Update:  run the ``flutter-ai-rules-sync`` skill (re-fetch + re-survey + prune).
  Variant: $file. To switch, run the skill with a variant arg.
-->

"@
$out = $header + ($body -replace "`r`n","`n")
$enc = New-Object System.Text.UTF8Encoding $false   # UTF-8, no BOM
[System.IO.File]::WriteAllText((Resolve-Path ".").Path + "\.claude\rules\flutter-ai-rules.md", $out, $enc)
```

## Notes

- Do **not** edit `.claude/rules/flutter-ai-rules.md` by hand; it is overwritten
  on the next sync. Project-specific rules go in `.claude/CLAUDE.md` or other
  `.claude/rules/*.md`; the pruning logic lives in this skill (Steps 2–3).
- The repo uses `core.autocrlf=true`. To avoid EOL-only churn on this
  regenerated file, consider pinning it `eol=lf` in `.gitattributes`
  (alongside the codegen outputs already pinned there).
- Per the project git-workflow rules, only commit when the user explicitly asks,
  and never commit directly to `develop`.
