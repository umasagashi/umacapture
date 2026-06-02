# Git workflow

Rules for any git / GitHub work in this repository. Commit or push **only when
the user explicitly asks**.

## Branching

- Never commit or push directly to `develop` (the default / main branch).
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

## Generated files and line endings

- This repo uses `core.autocrlf=true`, so generated files written with LF would
  otherwise show up as spurious, content-identical diffs after each codegen run.
- Codegen outputs are pinned to `eol=lf` in `.gitattributes`
  (`*.mapper.dart`, `*.gr.dart`, `lib/generated/assets.dart`,
  `lib/distribution_info.dart`, `assets/license_info.json`,
  `assets/version_info.json`). When new generated outputs appear, pin them the
  same way instead of committing EOL-only churn.
- Avoid `git add --renormalize .` across the whole repo: it re-stages unrelated
  files whose committed EOLs differ from the working tree. Limit it to specific
  paths, or verify the staged set before continuing.

## Don't reference repository-excluded content

- Commit messages and PR descriptions must not reference paths that are not part
  of the repository — gitignored files and local-only notes such as `.notes/`.
  Describe the rationale inline instead.
