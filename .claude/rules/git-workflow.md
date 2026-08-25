# Git workflow

Rules for any git / GitHub work in this repository. Commit or push **only when
the user explicitly asks**.

## Branching

- Never commit or push directly to `develop` (the default / main branch).
- **If a non-`develop` branch is already checked out, work on it — do not create
  a new branch on your own.** A branch that is already prepared is the intended
  workspace; assume the current work belongs there unless the user says otherwise.
  Only create a new branch when you are on `develop`, or when the user explicitly
  asks for one.
- When a new branch is genuinely needed, **base it on the currently checked-out
  branch**, not on `develop`, unless the user says otherwise (the current branch
  may carry unmerged work the new task builds on).
- Before making changes that will be committed, create a feature branch first
  (e.g. `feature/<topic>`, `fix/<topic>`), then commit there.
- Open pull requests against `develop`.

## Commit / PR messages via the Bash tool

- Pass multi-line commit messages and PR bodies with a **bash here-document**,
  e.g. `git commit -F - <<'EOF' … EOF` and `gh pr create --body-file - <<'EOF' … EOF`.
- Do **not** use PowerShell syntax inside the Bash tool — in particular the
  PowerShell here-string `@'…'@`. It is passed through literally and leaves stray
  `@` lines in the message. (The shell shown in the environment is PowerShell,
  but the Bash tool runs bash.)
- Keep all repository artifacts in English per the language policy, including
  commit messages and PR titles/descriptions.

## PR title and body style

Match the repo convention (see recent merged PRs):

- **Title — Conventional Commits** `type(scope): summary`. The permitted types are
  the ones the Conventional Commits spec defines — `feat`, `fix`, `docs`, `style`,
  `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert` — and not a census of
  what the log happens to contain: a hand-kept census reads as a prohibition the
  first time someone legitimately uses a type nobody had used yet. Every one of
  them except `revert` already appears in this repository's history. Scope is optional, kebab-case,
  and names the area (`chara-detail`, `native`, `sentry`, …). The summary is
  lowercase, imperative, and has no trailing period.
- **Body — Markdown with `##` sections.** Lead with `## Summary` (1–2 sentences on
  what changed and why), then the detail (`## What changed` with **bold**-led
  bullets, or numbered `### 1. …` subsections for a multi-part PR), and close with
  `## Testing` stating what was run and the result. Add `## Risk / scope`,
  `## Design notes`, or `## Follow-up` only when they carry real information.
- Use `code` for identifiers and paths and **bold** for each point's key term;
  keep it skimmable. End the body with the
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)` footer.

## Generated files and line endings

- This repo uses `core.autocrlf=true`, so generated files written with LF would
  otherwise show up as spurious, content-identical diffs after each codegen run.
- Codegen outputs are pinned to `eol=lf` in `.gitattributes`. **That file is the
  list**; read it there rather than trusting a copy — an enumeration repeated here
  goes stale the first time an output is added, and it already had (it named six
  entries while `.gitattributes` carried eight, missing both
  `assets/web_license_info.json` and `assets/additional_license_info.json`). When a
  new generated output appears, add the `eol=lf` line for it in `.gitattributes`
  instead of committing EOL-only churn.
- Avoid `git add --renormalize .` across the whole repo: it re-stages unrelated
  files whose committed EOLs differ from the working tree. Limit it to specific
  paths, or verify the staged set before continuing.

## Don't reference repository-excluded content

- Commit messages and PR descriptions must not reference paths that are not part
  of the repository — gitignored files and local-only notes such as `.notes/`.
  Describe the rationale inline instead.
