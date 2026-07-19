---
name: sentry-issues
description: >-
  Fetch and inspect this app's Sentry error reports from the command line via
  the Sentry REST API. Use whenever the user wants to check, look at, triage, or
  pull umacapture's Sentry issues, crash reports, or error logs — e.g. "check
  Sentry", "what errors are users hitting", "show the latest crashes", "is there
  anything new on release X", or when they want the full stack trace / tags /
  context of a specific issue. Covers the production project (the debug project
  no longer receives events), the release-version filter, and the difference
  between readable Dart exceptions and unsymbolicated native crashes.
---

# Inspecting umacapture's Sentry issues

The app reports errors to Sentry (configured in `lib/src/core/sentry_util.dart`).
This skill pulls those reports over the REST API so you can triage them here
instead of opening the web UI. There is no Sentry MCP connector installed; the
REST API plus an auth token is the supported path.

## Project coordinates

These are baked into the helper script, but keep them visible for ad-hoc calls:

| What | Value |
|---|---|
| Region | `sentry.io` (US) |
| Org id | `1367286` |
| **release** project (production, `kReleaseMode`) | `6670477` |
| **debug** project (legacy, no longer reported to) | `6668087` |

The numeric ids work directly in API paths, so no org/project *slug* lookup is
needed. Default to the **release** project — that's where real users' errors land.
As of the "disable error reporting in debug builds" change, debug builds skip
Sentry initialization entirely, so the debug project receives no new events; only
its historical issues remain.

## Default scope: latest release build only

Unless the user asks otherwise, **only fetch issues for the latest release
build**. Old versions accumulate stale issues that users on the current build can
no longer hit, so an unscoped list is mostly noise and misleads triage. The helper
script does this automatically: `list` resolves the newest release from Sentry's
releases endpoint (newest-first by creation date) and applies `release:<version>`,
switching to an all-time window so a fresh build isn't hidden by the 14d default.

Widen the scope only when the user explicitly wants it:

- `--all-releases` — every version (the raw, unscoped list).
- `--release <version>` — pin one specific version.
- an explicit `release:` token inside `--query` — treated as the user's choice and
  left untouched.

## Auth token

Every call needs a Sentry auth token. It is **not** in the repo. By convention it
lives at `~/.sentry_token` (a single line, outside the repository, gitignored by
virtue of being in `$HOME`). Reading it from a file keeps the secret out of the
command line and shell history.

- If the file is missing or empty, ask the user to create one: Sentry → Settings →
  Auth Tokens, scopes `event:read` + `project:read` (add `org:read` only if you
  need org-wide queries). Read-only is enough for everything in this skill.
- Uploading debug symbols (the `release` skill's Phase 2) needs `project:write`.
  The token in `~/.sentry_token` already carries it, so the same file works for
  both reading issues here and uploading PDBs there — no separate token needed.

## Quick start — use the helper script

The script is stdlib-only and runs under `uv run --no-project` (this repo's
convention is to invoke Python through `uv`, never bare `python`). From the repo
root:

```bash
# Default: most-frequent unresolved issues on the LATEST release build only
uv run --no-project .claude/skills/sentry-issues/scripts/sentry_issues.py list

# Newest issues (latest release), with permalinks + numeric ids to drill in
uv run --no-project .claude/skills/sentry-issues/scripts/sentry_issues.py \
  list --sort new --links

# Widen to every release version (the raw, unscoped list)
uv run --no-project .claude/skills/sentry-issues/scripts/sentry_issues.py \
  list --all-releases

# Pin a specific older release
uv run --no-project .claude/skills/sentry-issues/scripts/sentry_issues.py \
  list --release 0.0.10

# Drill into one issue: latest event's meta, tags, contexts, and stack trace
uv run --no-project .claude/skills/sentry-issues/scripts/sentry_issues.py \
  event 7569943159 --top 30
```

Pass `--json` to either subcommand when you need the raw payload to extract
fields the table view omits. Run with `-h` for all options.

## Useful search queries

The `--query` value is standard Sentry issue search:

- `is:unresolved` — open issues (the default).
- `is:unresolved release:0.1.0` — open issues seen in a given app version. Pair
  with `--stats-period ""` so a brand-new release isn't hidden by the 14d window.
- `is:unhandled` — crashes/uncaught errors only.
- `level:fatal` — fatal-level events.
- `firstSeen:-7d` — regressions/new issues from the last week.

`--sort` accepts `freq` (most events), `date` (most recent), `new`, `user`.

## Reading the results

**Two kinds of events, and they read very differently:**

- **Dart exceptions** (most issues) arrive with a real Dart stack trace —
  `package:umacapture/.../file.dart:line`. These are directly actionable; map the
  frame to the source file and investigate. This app does **not** obfuscate, so no
  symbol step is needed.
- **Native crashes** (`platform: native`, `mechanism: minidump`, e.g. an
  `EXCEPTION_ACCESS_VIOLATION`) arrive as raw addresses. Only OS modules
  (`ntdll`, `USER32`, `dxgi`, …) resolve to names automatically via Microsoft's
  public symbol server. As of the PDB-upload change, **`umacapture.exe` and
  `flutter_windows.dll` frames also symbolicate — but only for builds released
  after that change**. The `release` skill's Phase 2 now uploads both PDBs
  (`sentry-cli debug-files upload`), and `windows/runner/CMakeLists.txt` emits a
  `/DEBUG` PDB with a matching CodeView debug-id for the runner + native C++
  backend. Builds from **before** the change (e.g. 0.1.0 and earlier) carry no
  debug-id in the exe at all, so their native app frames can never be
  symbolicated retroactively — no PDB will ever match them. Third-party DLLs
  (`opencv_world4130.dll`, `onnxruntime.dll`) ship without PDBs and stay `?` on
  every build. For those pre-change or third-party frames, read the surrounding
  OS frames to infer *what* the app was doing (window teardown, graphics
  release), not the exact function.

**Symbolicated is not the same as trustworthy — always check `trust`.** Resolving
a name needs a PDB; reconstructing the *call chain* needs unwind tables, which
live in the PE binary, not the PDB. Releases up to and including **0.2.1**
uploaded PDBs only, so their events carry `unwind_status: missing` and Sentry
walks the stack by scanning memory for plausible return addresses. Those frames
come back fully named and file/line-annotated while being **causally wrong** —
sibling calls, stale frames, and unrelated leaf functions get spliced into what
looks like a clean call stack. Before reasoning about any native stack, pull the
raw event (`--json`) and inspect each frame's `trust`:

- `context` — the crashing frame, taken from the register set. Always reliable.
- `cfi` — walked with real unwind data. Reliable.
- `scan` / `fp` — guessed. **Do not treat the ordering as a call relationship.**

Also check `entries[].data.images[].unwind_status` in the `debugmeta` entry and
the `native_missing_dsym` items in the event's `errors` array; both name the
images whose unwind info was unavailable. Since the binary upload was added to
the `release` skill's step 9.5, builds after 0.2.1 should show
`unwind_status: found` for `umacapture.exe` and `flutter_windows.dll`.

**Minidumps are not retained.** The org's `storeCrashReports` is `0`, so the
attachments endpoint 404s for every native event and there is no dump to analyze
locally with `cdb`. It also means an old event cannot be re-symbolicated by
reprocessing after a late symbol upload — fixing symbols only helps events that
arrive afterwards.

**Only two shipped modules can ever symbolicate: `umacapture.exe` and
`flutter_windows.dll`.** If a crash stack runs through anything else in the app
directory, that segment degrades to `trust: scan` and there is no upload that
would fix it — so read those frames as "roughly here", never as a call chain.
This is a known, accepted gap (decided 2026-07-19), not something to re-diagnose:

- **Plugin DLLs built from our own tree** — `window_manager_plugin.dll`,
  `screen_retriever_windows_plugin.dll`, `audioplayers_windows_plugin.dll`,
  `desktop_drop_plugin.dll`, `pasteboard_plugin.dll`,
  `url_launcher_windows_plugin.dll` — plus `sentry.dll`, `crashpad_handler.exe`
  and `crashpad_wer.dll` from the FetchContent'd sentry-native. These *contain*
  `symtab, unwind` but carry an all-zero Debug ID (`Usable: no (missing debug
  identifier, likely stripped)`), so Sentry cannot match an upload to the module
  in the dump. Cause: `/Zi` and `/DEBUG` are set as `target_*` options on the
  runner binary alone (`windows/runner/CMakeLists.txt`), and MSVC's `Release`
  config adds neither by default, so every other CMake target is stripped.
- **Third-party prebuilts** — `opencv_world4130.dll`, `onnxruntime.dll`,
  `dartjni.dll` — ship without PDBs at all.

The fix, if a crash ever actually lands in one of these, is to move `/Zi` and
`/DEBUG` to the Release/Profile globals in `windows/CMakeLists.txt` so every
locally built target emits a Debug ID, then widen `tool/upload_symbols.sh` to
sweep the build tree. It was deliberately not done up front: it needs a full
rebuild to verify the flags reach the FetchContent'd sentry-native, and costs
build time and artifact size for modules that had never appeared in a crash.

Worth knowing for triage: the window-teardown crash on 0.2.1
(`UMACAPTURE-RELEASE-A9`) is exactly the shape that *could* route through
`window_manager_plugin` / `screen_retriever_windows_plugin`. In that event they
were `unwind_status: unused`, i.e. no frame needed them — but if a similar report
appears with those modules in play, the gap above is the reason the middle of the
stack looks incoherent.

**Version tagging is consistent.** Both the Dart side (`assets/version_info.json`)
and the native side (`windows/runner/Runner.rc` `FLUTTER_VERSION`) derive from the
pubspec `version` at build time, so a given build reports the same release on both
paths. If you see two events with different release strings, that's two different
app builds/users — not a tagging bug.

## Ad-hoc curl (when the script doesn't cover it)

```bash
TOKEN=$(tr -d ' \t\r\n' < ~/.sentry_token)
# Resolve the latest release (newest-first), then scope issues to it (all-time):
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/1367286/6670477/releases/?per_page=1"
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/projects/1367286/6670477/issues/?query=is:unresolved%20release:0.1.0&statsPeriod=&sort=freq"
# latest event of an issue:
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://sentry.io/api/0/issues/<ISSUE_ID>/events/latest/"
```

Gotchas worth remembering when going manual:

- **`statsPeriod` only accepts `""`, `"24h"`, `"14d"`.** Anything else (e.g.
  `90d`) returns HTTP 400. For longer ranges, filter by `release:` / `firstSeen:`
  with an empty period instead.
- **`jq` is not installed on this machine.** Parse JSON with
  `uv run --no-project python` (write the response to a file first, then read it
  with a *relative* path — Windows-native Python resolves a Git-Bash `/tmp/...`
  absolute path to the wrong place).
- Event payloads for native crashes are large (~0.5 MB with debug images). Save to
  a file and extract fields rather than dumping inline.
