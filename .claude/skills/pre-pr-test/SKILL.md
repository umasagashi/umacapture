---
name: pre-pr-test
description: >-
  Use as the final check before a pull request is opened, once, and only when the user explicitly
  asks for it (directly, or through a delegation that states the user asked for this run). Do not use
  it on your own initiative to check work in progress, a stage of a plan, or a completion condition.
  A request to "run all the tests" that is not that final pre-PR check does not trigger it: ask
  whether the pre-PR check is meant.
---

# Pre-PR test suite

Five stages. This skill owns **which stages a diff needs, which commands to run and in what
order, and how to report them**. What each tool means lives in its own document, and is pointed
to rather than repeated:

| topic | source of truth |
| --- | --- |
| building and running the native CLI, vcvars, the Git Bash `cmd` traps | `.claude/skills/native-cli-dev/SKILL.md` |
| what "verified" means for a `native/src` change, reading ctest per case, a changed golden | `.claude/skills/native-change-verification/SKILL.md` |
| first-time toolchain and dependency setup | `.claude/skills/project-setup/SKILL.md` |
| the live capture harness: parts, prerequisites, exit codes, reason codes, scenarios | `docs/live-capture-harness.md` |
| what CI runs | `.github/workflows/ci.yml` |
| which test files CI runs, and where (the VM shards and the browser suites) | `tool/test_selection.dart` |
| which platforms, capture forms and inputs the product promises | `.claude/rules/supported-scope.md` |

Rules that hold across every stage:

* **Build everything you run in this session, from the current working tree**
  (`.claude/CLAUDE.md`, *Never reuse a build artifact you did not build this session*). An `.exe`
  whose mtime predates this session is stale by definition.
* **Do not rewind the working tree with git** (`git checkout` / `restore` / `stash` on a path).
  CI's license step ends with `git checkout -- assets`; do not copy that line locally.
* **Do not touch `testdata/`** beyond what the harness itself writes under `testdata/harness/`
  (`.claude/rules/test-material.md`). Never empty `testdata/harness/runs/`.
* **Only one of anything GUI at a time.** Stages 4 and 5 run strictly one scenario after another.

## 1. Choose the stages

List the files the PR changes:

```bash
git fetch origin develop
git diff --stat origin/develop...HEAD
git diff --name-only origin/develop...HEAD | awk -F/ '{print (NF>2 ? $1"/"$2"/" : (NF==2 ? $1"/" : $1))}' | sort | uniq -c
```

The grouping prints a top-level file as itself (`pubspec.yaml`) and anything deeper as its first
one or two directory levels with a trailing `/` (`test/`, `lib/src/`), so a hundred changed tests
are one line. Read `lib/src/` against the `lib/` rows below with the `--stat` list.

Then take the union of the rows every changed path hits. **R** = required, **r** = recommended
(skipping it is allowed, and the report says it was skipped and why), blank = owes nothing.

| changed path | 1 | 2 | 3 | 4 | 5 | why |
| --- | --- | --- | --- | --- | --- | --- |
| anything | R | R¹ | r | | | stage 1 is what CI will run anyway, and it is cheaper to fail here than on the PR. ¹ The always-required part of stage 2 is `flutter build windows` and `check_web_pins --require-verified`: CI never builds the Windows runner (no `build windows` in `.github/workflows/`), and the other takes seconds |
| `native/src/`, `native/vendor/`, `native/wasm/` | R | R (+ wasm rebuild) | R | R | r | CI skips every golden case (it never builds `umacapture_cli`, and has no clips), so stage 3 is the only place a recognition change is judged. `tool/web_deps.json` digests these three roots, so the recognition core must be rebuilt and compared against its pin. The same core runs in the live Windows path, which stage 3 cannot reach (`docs/live-capture-harness.md`, *The gap it fills*). Stage 5 becomes R when the change can move the factor tab, the duplicate probe (`Factor probe:` lines) or record identity |
| `native/test/integration/`, `native/CMakeLists.txt`, `assets/config/`, a new model set | R | R | R | r | | the golden suite's inputs and registration. `assets/config/` is also what the app loads, so stage 4 is recommended |
| `windows/runner/` | R | R | | R | r | the Windows capture producer and the method channel exist only in the live path |
| `lib/` — capture page, capture state, settings that reach the native start config, platform controller | R | R | | R | r | the Dart↔native boundary and UI-driven start/stop are exercised only by the harness |
| `lib/` — record store, duplicate refusal, factor enhancement, merge, parent links (`lib/src/chara_detail/`, `lib/src/gui/chara_detail/`, `lib/src/gui/capture.dart`) | R | R | | R | R | C1–C6 are the only automated cover of these in a running app |
| other `lib/`, `test/` | R | R | | r | | stage 1's `flutter test` is the cover; stage 4 is the cheap end-to-end smoke |
| `test_driver/`, `tool/live_capture_test/`, `native/tool/mimic_player/` | R | R | | R | R | the instrument itself changed. Also run the harness's pure tests (§5.1), after a `mimic_player.cpp` change the player's fidelity check (`docs/live-capture-harness.md`, *Parts*), and after an `app_drive_run.py` change to the merge or the per-clip signals the matching falsification in §5.6 |
| `web/`, `tool/*.mjs` | R | R | | | | stage 1 runs the node tests. Nothing here runs a browser against the real wasm: see §8 |
| `tool/cloudflare/` | R | R (publish test) | | | | `tool/cloudflare/test/publish_modules_test.sh` is not in CI |
| `docs/`, `.claude/` only | R | | | | | nothing executable changed |

Stage 3 is conditional because the golden suite drives only `umacapture_cli`, which is built from
`native/` and reads `assets/config/` and the ONNX modules: a Dart-only diff cannot move it. It is
still recommended on every PR because it is cheap (§4) and because `integration_golden_coverage`
notices clips that have gone missing from this machine.

Write the selection down before running anything: stage, R/r/skip, and the path that decided it.

## 2. Stage 1 — what CI runs

Run the Flutter and Dart commands from the **PowerShell** tool, not Git Bash (§7, trap 1).
Measured on 2026-09-27 with the stages run one after another and nothing else of the run alongside.
A run in which another native build and ctest shared the CPU took up to about five times as long
on some steps (analyze 219 s, `flutter test` 507 s, build_runner 92 s).

| # | command | pass | measured |
| --- | --- | --- | --- |
| 1.1 | `.fvm/flutter_sdk/bin/dart run build_runner build --force-jit` | exit 0 | 12 s |
| 1.2 | `git status --short` right after 1.1 | no generated file changed and no new generated file appeared (codegen is fresh). CI's `Check generated outputs are committed` step fails on either under `lib/` and `test/` | — |
| 1.3 | `.fvm/flutter_sdk/bin/flutter analyze --no-fatal-infos` | exit 0, no error or warning | 45 s |
| 1.4 | `.fvm/flutter_sdk/bin/dart format --output=none --set-exit-if-changed lib test tool` | exit 0 | 3 s |
| 1.5 | `.fvm/flutter_sdk/bin/flutter test -j 4 --reporter github test` | exit 0, 0 failed | 409 s |
| 1.6 | `.fvm/flutter_sdk/bin/dart test --platform chrome --reporter expanded $files` (Git Bash, `$files` from the note below) | exit 0, 0 failed, and the number of distinct test files the log names equals the number extracted | 18 s |
| 1.7 | `.fvm/flutter_sdk/bin/flutter build web --release --pwa-strategy=none` | exit 0, `Built build\web`, and `build/web/main.dart.js`'s mtime is after the step started | 127 s |
| 1.8 | `bash tool/hooks/test_pre_commit.sh` | exit 0 | 6 s |
| 1.9 | `node tool/test_web_frame_shaping.mjs`, `test_web_live_content.mjs`, `test_web_capture_session.mjs`, `test_web_video_import.mjs`, `test_web_video_frame_grab.mjs`, `test_web_video_demux.mjs` (all under `tool/`) | each exits 0 | 6 s for all six |

* **1.6 `$files`**: take the list from `tool/test_selection.dart browser`, the same command CI's
  `Run browser tests` step runs. It selects every test file whose library carries
  `@TestOn('browser')`, so a `*_web_test.dart` without that annotation is not a browser suite
  (`test/record_loader_web_test.dart` runs on the VM). A non-zero exit means the selection's own
  check failed, which is a finding. `package:test` launches Chrome headless, so this step opens no
  window. Do not copy the list by hand: on 2026-09-27 a hand copy dropped one of ten files and the
  run reported 41 tests instead of 50 with exit 0, which nothing flagged. Take it and count both
  ends:

  ```bash
  files=$(.fvm/flutter_sdk/bin/dart tool/test_selection.dart browser) || echo "selection failed"
  echo "$files" | wc -l                                   # 10 on 2026-09-30
  .fvm/flutter_sdk/bin/dart test --platform chrome --reporter expanded $files > browser.log 2>&1
  grep -oE 'test/[A-Za-z0-9_/]+_test\.dart' browser.log | sort -u | wc -l   # must equal the line above
  ```

  Measured 2026-09-27 at `0aa3813e`: 10 extracted, 10 in the log, `+50: All tests passed!`.
  Strip `app.asar` from `PATH` first when running under Paseo (§7, trap 1).
* **1.9's six scripts** are the `node tool/test_web_*.mjs` lines of `ci.yml`, split over two
  steps. Take them from there the same way rather than from the table:
  `grep -oE 'tool/test_web_[a-z_]+\.mjs' .github/workflows/ci.yml` (6 on 2026-09-27), and run
  each one.
* **1.7: check that `main.dart.js` was rewritten**, the same check as 2.1. On 2026-09-27 at
  `e8209def` two consecutive runs with unchanged inputs each printed `Compiling lib\main.dart for
  the Web... 109 s` and rewrote the file, so no skip was observed; but before those runs the
  file dated 18:03 while `index.html` dated 22:34, which nothing explained, so the mtime is the
  pass condition rather than exit 0. Strip `app.asar` from `PATH` under Paseo (§7, trap 1):
  otherwise the step exits 1 at once with `Unable to find git in your PATH`.
* **1.1 runs first** because analyze, test and both builds read its outputs.
* **CI's license step** (`check_web_pins.dart --licenses --ci-artifact`) is **not run locally**.
  The flag asserts the artifact a CI tree produces, where emsdk is absent and the recognition core
  is not provisioned; in a fully provisioned local tree it fails by design (the tool's own doc
  comment: "meaningless in a fully provisioned local tree"). If someone runs it anyway, the
  expected output is `says 'verified', not 'partially_provisioned'` with exit 1, and it is not a
  finding. The local equivalent is 2.4.

## 3. Stage 2 — what CI never runs

| # | command | pass | measured |
| --- | --- | --- | --- |
| 2.1 | `.fvm/flutter_sdk/bin/flutter build windows --release` (PowerShell) | exit 0, `Built build\windows\x64\runner\Release\umacapture.exe`, and the exe's mtime is after the step started | 125 s |
| 2.3a | `uv run native/wasm/check_sources.py` | exit 0, `in sync` | < 1 s |
| 2.3b | `SKIP_SOURCE_CHECK=1 bash native/wasm/build.sh` (Git Bash) | exit 0 | 115 s |
| 2.3c | `sha256sum` of `umacapture_core.js` and `umacapture_core.wasm` in the directory `build.sh` names on its `Done. Artifacts in <dir>:` line (`$BUILD_DIR` in the script, whose default lies outside the repository), against `grep -A1 '^    "wasm/umacapture_core' tool/web_deps.json`. That line is near the end, not the last: an `ls -la` of the two artifacts follows it | both hashes equal their pin | — |
| 2.4 | `.fvm/flutter_sdk/bin/dart run tool/check_web_pins.dart --licenses --require-verified` | exit 0, `N pinned file(s) verified, 0 not provisioned` | 2 s |
| 2.5 | `bash tool/cloudflare/test/publish_modules_test.sh` | exit 0, 0 failed | 40 s |

Measured as stage 1 (§2), in the same run; 2.1 was measured on 2026-09-27 at `0aa3813e` after the
deletion below.

* **2.1: exit 0 does not mean it relinked**, as in §5.2. On 2026-09-27 the command exited 0 in 23 s
  and left an exe from before the session in place. Delete
  `build/windows/x64/runner/Release/umacapture.exe` and
  `build/windows/x64/runner/umacapture.dir/Release/*.obj` (build outputs) before the build, then
  check that the exe's mtime is after the step started.

* **2.3 is required only when `native/src`, `native/vendor` or `native/wasm` changed** (§1). Run
  the drift check 2.3a on its own first and build with `SKIP_SOURCE_CHECK=1`: `build.sh` sources
  `emsdk_env.sh` and then tests `command -v uv`, and on this machine sourcing emsdk drops uv from
  PATH, so the in-script check fails with exit 1 although uv is installed. Running 2.3a separately
  keeps the check; it only moves it.
* **2.3c, not 2.4, is the rebuild comparison.** `build.sh` writes outside `web/`, so 2.4 checks the
  bytes already provisioned in `web/wasm/`, not the ones just built. A hash that differs from its
  pin is a finding: the committed module is not what the current sources build. Equal hashes mean
  something only for bytes 2.3b rebuilt, and it cannot skip: `build.sh` has no up-to-date check —
  it runs `em++ -c` on every source and then links, under `set -euo pipefail`, so exit 0 means all
  eleven objects and both artifacts were rewritten (2026-09-27, `e8209def`: 11 `[cc]` lines, both
  mtimes after the start, hashes equal to the pin). If `BUILD_DIR` is overridden, hash the
  directory the `Done.` line names, not the default one. Do not repin here;
  what a repin involves is in `.claude/skills/native-change-verification/SKILL.md` §7.
* 2.5 works inside a `mktemp -d` sandbox with stubbed `wrangler` and `curl`; it contacts nothing.

## 4. Stage 3 — native ctest, golden and dual-decode

Configure a **new** build directory for this run — `native/cmake-build-<tag>`, gitignored by
`native/.gitignore` — so that nothing in it predates the session. Do not reuse
`native/cmake-build-release` or any other existing directory for this stage.

Write a build script into the new directory (it is gitignored there; under `native/` itself it
would show as untracked) and launch it from the **PowerShell** tool. Resolve the vcvars path with
`vswhere` as `native-cli-dev` describes; on this machine it is VS 18 Community.

```bat
@echo off
set VSLANG=1033
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d C:\Projects\umacapture\native
cmake -G Ninja -S . -B cmake-build-<tag> -DCMAKE_BUILD_TYPE=Release || exit /b 1
cmake --build cmake-build-<tag> || exit /b 1
```

```powershell
New-Item -ItemType Directory -Force native\cmake-build-<tag>
# write the script above to native\cmake-build-<tag>\build.cmd, then:
cmd /c C:\Projects\umacapture\native\cmake-build-<tag>\build.cmd
ctest --test-dir C:\Projects\umacapture\native\cmake-build-<tag> -N
ctest --test-dir C:\Projects\umacapture\native\cmake-build-<tag> -R "^(umacapture_tests|umacapture_ffv1_tests)$" --output-on-failure
ctest --test-dir C:\Projects\umacapture\native\cmake-build-<tag> -E "^(umacapture_tests|umacapture_ffv1_tests)$" --output-on-failure
```

The default targets are `umacapture_cli`, `umacapture_tests`, `umacapture_ffv1_tests` and
`umacapture_mimic_player`; the golden runners get `--cli`, the assets, the modules
(`sandbox/modules/`) and the clips (`testdata/clips/golden/`) from `native/CMakeLists.txt`, so
nothing is passed by hand. The player built here is **not** the one stages 4–5 run (§5.2).

**Confirm the build actually ran**: the ninja step count is non-zero (95/95 on 2026-09-27, 91
compiles and 4 links) and every `.exe` mtime is after the session started.

Measured on 2026-09-27 in the run of §2: build 73 s, the two doctest binaries 42 s, everything else
306 s — about 7 minutes in total. The shared-CPU run took about 8.3 minutes (configure 5 s,
build 86 s, doctest 54 s, the rest 354 s).

**Reading it** — per case, never the summary line
(`native-change-verification` §1, and `.claude/rules/platform-parity.md`, *Test gap*):

* Take the registered count from `ctest -N` and check that PASS + FAIL + Skipped adds up to it.
  Do not carry a count over from an earlier run: `native/test/integration/cases.json` grows.
* **Every Skipped line needs its reason matched against `cases.json`.** A dual-decode case skips,
  by design, when the case is `"mode": "replay"` (FFV1 has no YUV matrix to vary) or states
  `"expect_records": 0`. Any other skip — above all an `integration_golden.*` skip, which means a
  missing clip or model — is reported by name as a coverage loss.
* `integration_golden.<name>` exists only for a case with a `golden` or `expect_records` key; a
  case with neither is covered by `integration_dual_decode.<name>` alone. Not finding a golden
  line for it is correct.
* `integration_golden_coverage` fails when this machine can run fewer cases than it could before.
* **A golden FAIL is a finding. Never regenerate a golden to make it pass**
  (`native-change-verification` §2). Report the case, the diff and the commit under test.

## 5. Stages 4 and 5 — the live capture harness

These stages launch the Windows app and the mimic player as visible windows. The app calls
`windowManager.focus()` at start-up (`lib/main.dart`), and the player is an ordinary top-level
window, so **a run takes the keyboard focus from whoever is using the PC, repeatedly, for the
length of the stage.** Nothing in the harness can run them without that.

### 5.0 Permission — before any build or launch in this section

This PC is shared with the user, and a focus-stealing run is not something to start silently.

1. **If you are a subagent**: run stages 4–5 only if your delegation states, for this run, that
   the user has allowed the app and the player to be launched (or that the user is away). If it
   does not, stop after stage 3 and report stages 4–5 as *pending the user's permission*.
2. **If you are talking to the user**: ask before you start. Say that two windows will open and
   take the focus repeatedly, for about the duration in §5.5, and that the PC should be left alone
   meanwhile; ask whether to run now or when they are away. Their answer covers this run only.
3. Once allowed, do not interact with the windows yourself, and do not start anything else that
   opens a window until the stage is over.

### 5.1 Pre-flight (read-only, no window)

Run all of these before building; each must hold:

```powershell
tasklist /FI "IMAGENAME eq umacapture.exe"          # "No tasks are running" -- see below
tasklist /V /FI "WINDOWTITLE eq umamusume"          # "No tasks are running" -- see below
netstat -ano | findstr ":57391"                     # no output (findstr exits 1)
```

* **No `umacapture.exe` running.** The app is single-instance: a second launch finds the named
  mutex, brings the existing window to the front and exits (`windows/runner/main.cpp`). The run
  fails and the user's window is raised. If the user's app is open, ask them to close it; never
  kill a process this run did not start.
* **No window titled `umamusume`.** That is the real game (or a player left over from an earlier
  run); the app captures the first window it finds with that identity, and the player
  impersonates exactly that.
* **Port 57391 free.** It is the VM Service port the harness pins (`app_drive_run.py`, `--port`),
  and one more reason two scenarios can never run side by side (they also share the scratch root
  `testdata/harness/appdrive_root`).
* The clips, sidecars and goldens every scenario names exist, and the ONNX modules are at
  `%APPDATA%/umasagashi/umacapture/modules` (`docs/live-capture-harness.md`, *Prerequisites*).
* The harness's pure tests pass — no clip, player or app involved:
  `PYTHONDONTWRITEBYTECODE=1 uv run tool/live_capture_test/test_stops_validation.py` (Git Bash; the
  variable keeps the run from writing a `__pycache__` into `tool/live_capture_test/`).

### 5.2 Build both binaries (this session)

* **The driver-enabled app** (PowerShell): `.fvm/flutter_sdk/bin/flutter build windows --debug -t
  test_driver/app.dart`. The release bundle from 2.1 cannot be driven, and `scenario_run.py` never
  builds; it exits 2 when the bundle is missing, which is not the same as it being current.
  * **Exit 0 does not mean it relinked.** On 2026-09-27 the command exited 0 in 20 s and left the
    exe of an earlier session in place. Delete `build/windows/x64/runner/Debug/umacapture.exe` and
    `build/windows/x64/runner/umacapture.dir/Debug/*.obj` (build outputs) before the build, then
    check that the exe has an mtime after the session started.
  * **`LNK1163` (invalid COMDAT selection)** on a freshly compiled `chara_detail_recognizer.obj`
    failed the link once in five builds on 2026-09-27. Deleting that `.obj` under
    `build/windows/x64/runner/umacapture.dir/Debug/` and building again linked. The cause was not
    determined.
* **The player**: the harness runs it from the hard-wired directory `native/cmake-build-release`
  (`BUILD` in `app_drive_run.py`, and `run_mimic.cmd`), so it is rebuilt **in place** there, not in
  the fresh directory of stage 3. That directory's `CMakeFiles/rules.ninja` carries the Japanese
  `msvc_deps_prefix`, so ninja may not know which headers the player depends on (§7, trap 5) and an
  incremental build can skip a needed recompile. Force it with a script launched through `cmd`
  (§7, traps 1–2), the vcvars matching the cache (trap 4):

  ```bat
  @echo off
  set VSLANG=1033
  call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" -vcvars_ver=14.51 >nul
  cd /d C:\Projects\umacapture\native\cmake-build-release
  cmake . || exit /b 1
  ninja -t clean umacapture_mimic_player
  cmake --build . --target umacapture_mimic_player -- -v
  ```

  The verbose output shows `[1/2]` compiling `tool\mimic_player\mimic_player.cpp` and `[2/2]` the
  link; a build that does not compile `mimic_player.cpp` did not rebuild the player. Then check that
  `umacapture_mimic_player.exe` has an mtime after the session started.

### 5.3 Run, in this order

One scenario at a time, each with a tag no earlier run used (e.g.
`prepr-<yyyymmdd>-<scenario>`; append `-r2` for the re-run):

```bash
uv run tool/live_capture_test/scenario_run.py tool/live_capture_test/scenarios/<scenario>.json --tag <tag>
```

**Stage 4** — the pre-existing single-clip scenarios:

The `capture.status` column is `clips[i].capture.status` in `app_result_<tag>.json`, spelled as the
app reports it (`alreadyCaptured`; a scenario's `expect.status` writes `already_captured`).

| order | scenario | expected | `capture.status` |
| --- | --- | --- | --- |
| 4.1 | `player_standard_5` | exit 0, `PASS player_standard_5: 1 record(s) match …` | `succeeded` |
| 4.2 | `falsify_wrong_golden` | exit 1, `FAIL …: record mismatch (…)` over a real record-to-record diff, and no per-clip finding | `succeeded` |
| 4.3 | `falsify_truncated_input` | **exit 2**, one finding `ERROR …: clip 0: [outcome_unobserved]` (last capture state `capturing`), `"match": false` and `"harness_status": "no-record"` in `scenario_result_<tag>.json`. This exit 2 is the expected result: it is **not** re-run | none (`capture` is null) |

4.3 passes on exit 2 because what it guards is that a run whose input stopped inside the scene is
not a pass; that a record diff is caught is 4.2's job. A clip stopped inside the scene has no
capture outcome, and a missing observation is not promoted to a product mismatch.

**Stage 5** — the multi-clip scenarios, the positive cases first. Each falsification expects exactly
the codes listed on clip 1, and its records still match the golden (the last line reads
`FAIL <name>: N per-clip finding(s) above; the K record(s) match <golden>`):

| order | scenario | expected | `capture.status` (clip 0 / 1) |
| --- | --- | --- | --- |
| 5.1–5.4 | `c1_hopstep_pre_then_post`, `c2_cinderella_pre_then_post`, `c3_cross_hopstep_pre_cinderella_post`, `c4_parent_cinderella_pre_then_hopstep_pre` | exit 0 | `succeeded` / `succeeded` |
| 5.5 | `c5_same_clip_twice` | exit 0 | `succeeded` / `alreadyCaptured` |
| 5.6 | `c6_merge_hopstep` | exit 0; `clips[1].merge.completed` true | `succeeded` / `succeeded` |
| 5.7 | `falsify_c1_expects_no_candidate` | exit 1, `[candidate_unexpected]` only | `succeeded` / `succeeded` |
| 5.8 | `falsify_c3_expects_candidate` | exit 1, `[candidate_mismatch]` only | `succeeded` / `succeeded` |
| 5.9 | `falsify_c4_wrong_slot` | exit 1, `[link_mismatch]` only | `succeeded` / `succeeded` |
| 5.10 | `falsify_c5_expects_succeeded` | exit 1, **both** `[status_mismatch]` and `[probe_mismatch]`; either alone is not a pass | `succeeded` / `alreadyCaptured` |

In C6, `clips[1].merge.holds` of 2 or 3 with `completed: true` is the harness pressing the apply
button again after the button ignored a press while still disabled (`docs/live-capture-harness.md`,
*Merging*); it is not a finding. On 2026-09-27 three green C6 runs took 2, 2 and 1 holds.

What each one plays and asserts: `docs/live-capture-harness.md`, *The committed multi-clip
scenarios*. The expected reason codes are listed there as well as in each file's `description`.

**Waiting.** A multi-clip scenario may run up to its `run_timeout_seconds` (900 s), longer than one
tool call's 600 s ceiling. Run it with `run_in_background`, redirecting output to a log that ends
with the exit code (`...; echo "EXIT=$?"`), and poll that log for the `EXIT=` line inside one call
with an explicit timeout. A subagent keeps polling until the line appears; it does not end its turn
while a scenario runs.

To run a stage as one background loop, give it a stop point between scenarios: the loop checks for
a stop file before starting the next one. Killing the loop's own PID does not stop the scenario in
flight — its `uv` child survives and runs to the end — so the stop file is the clean way to halt.
Write the loop's logs to a directory of your own, not under `testdata/`:

```bash
export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'app\.asar' | paste -sd: -)"
export PYTHONDONTWRITEBYTECODE=1
for sc in "$@"; do
  [ -e "$LOG_DIR/STOP" ] && { echo "STOPPED before $sc" >> "$LOG_DIR/summary.txt"; break; }
  tag="prepr-<yyyymmdd>-$sc"; s=$(date +%s)
  uv run tool/live_capture_test/scenario_run.py tool/live_capture_test/scenarios/$sc.json --tag $tag > "$LOG_DIR/$tag.log" 2>&1
  rc=$?
  echo "$sc tag=$tag exit=$rc dur=$(( $(date +%s)-s ))s" >> "$LOG_DIR/summary.txt"
done
echo ALLDONE >> "$LOG_DIR/summary.txt"
```

### 5.4 Reading the result

| exit | meaning | what to do |
| --- | --- | --- |
| 0 | records match the golden, every clip's capture outcome was observed, and every per-clip expectation holds | PASS |
| 1 | a valid run contradicted the golden or an expectation | FAIL for a positive case — report the diff and every `FAIL` line with its reason code. For a falsification, it passes only if the codes printed are the ones it names |
| 2 | not a verdict: the run could not be judged | re-run once, below — unless the table in §5.3 expects exit 2 (4.3) |

* **Exit 2 is re-run exactly once**, the whole scenario, with a new tag; every run starts from an
  empty scratch store and fresh settings. A second exit 2 is reported as **unverified** —
  neither passed nor failed — with the reasons both runs printed. Never retry a third time.
* **The printed lines**: `FAIL <name>: clip <i>: [<code>] …` is an exit-1 finding and
  `ERROR <name>: clip <i>: [<code>] …` an inconclusive one. A synchronisation breach found in the
  run as a whole prints as `ERROR <name>: …` **with no reason code** (for example `tab(s) [0, 1, 2]
  were released by a scroll-ready marker seen before the clip armed its signals`), and such a run
  may print no `[sync_invalid]` line at all: that code is the per-clip form of the same check.
  These lines do not always start a line of the log: one can follow a JSON dump that ends with no
  newline (4.3's `ERROR …: clip 0: [outcome_unobserved]` came right after a `}`), so search with
  `grep -E '(FAIL|ERROR) '`, not `grep '^ERROR'`.
* **Read the codes, not only the exit.** A falsification's exit 1 alone proves nothing: another
  reason code means a different check fired, and exit 2 means nothing was judged
  (`docs/live-capture-harness.md`, *Reason codes*). The same holds for 4.3's exit 2 — it passes
  only with `outcome_unobserved` as its one finding.
* **A falsification is only readable next to a green positive.** If its positive sibling did not
  exit 0, report the falsification as not interpretable, whatever it printed.
* **Report each clip's `capture.status`** next to the exit. Exit 0 already requires every one to be
  non-null (a null is `outcome_unobserved`, exit 2); the report states which outcome it was.
* The verdict and artefacts are in `testdata/harness/runs/` (`scenario_result_<tag>.json`,
  `app_result_<tag>.json`, the logs). Leave them there. They are UTF-8, while Python on this machine
  defaults to cp932: a script that reads them passes `encoding="utf-8"`.
* After the stage, `tasklist` again: no `umacapture.exe` and no `umamusume` window may remain. The
  pre-flight guaranteed that none was the user's, so any survivor is this run's to stop, by PID.

### 5.5 Duration

Measured on 2026-09-27, one scenario at a time with no other stage running alongside (whether the
user was at the PC is not known).

| stage | measured |
| --- | --- |
| 5.2 builds | player 9–10 s; driver app 116–142 s with the exe and runner objects deleted first (four builds) |
| stage 4 | 102 s: 29 s, 29 s and 44 s |
| stage 5 | about 13 minutes for the ten scenarios (784 s in one pass, 55–103 s each across the day's green runs; C6 98–103 s) |

Stages 4 and 5 hold the focus for about 15 minutes; with the builds before them, about 17. A clip whose outcome is
never observed waits out its `record_wait_seconds` (120 s) before the finding, so a scenario far
slower than these figures is worth reading for that first.

### 5.6 When the harness itself changed — falsify by a temporary edit

Not part of a routine run. When a diff changes `tool/live_capture_test/app_drive_run.py` in one of
the parts below, break that part on purpose, run the named scenario, and check that the harness
refuses it. Each one is only readable next to a green run of the same positive scenario in the same
session (§5.4).

| part | temporary edit in `app_drive_run.py` | scenario | expected |
| --- | --- | --- | --- |
| the merge hold (`perform_merge`) | replace `driver.hold(MERGE_APPLY_KEY, MERGE_HOLD_SECONDS)` with `driver.by_key("tap", MERGE_APPLY_KEY, timeout_ms=TILE_WAIT_MS)` | `c6_merge_hopstep` | exit 1: `[merge_incomplete]` on clip 1 and a record mismatch (2 records), harness status `ok`; `clips[1].merge` has `holds: 3`, `completed: false` |
| the per-clip signals (`arm_clip`) | drop `self.signals = ClipSignals()` from `arm_clip`, so the second clip reuses the first clip's signals | `c5_same_clip_twice` | exit 2 with the run-level `ERROR …: tab(s) … were released by a scroll-ready marker seen before the clip armed its signals` (§5.4), holds with `marker_after_arm: false` in the summary |

The file is CRLF, so edit it with Python's binary IO rather than `sed` (§7, trap 7). Before the
edit, copy it byte for byte outside the repository; after the run, copy it back, compare
`sha256sum` of the working-tree path (not of the backup directory) with the copy, check that
`git status --short` is what it was before, and run the pure tests (§5.1) again. Keep the edited
file beside the backup, so the falsification can be repeated.

## 6. Report

One table per stage, then the findings.

| stage | step | result | counts | Skipped (by name, with reason) | duration | completion |
| --- | --- | --- | --- | --- | --- | --- |

* **counts**: passed / failed / skipped as the tool printed them, and for ctest the registered total
  from `-N`. **completion**: finished, timed out, re-run, or not started — and why.
* Say which stages §1 selected and which were skipped, with the path that decided it.
* Every FAIL is a finding with the command, the failing case, the diff or log excerpt and the
  commit under test (`git log --oneline -1`). Do not fix, regenerate or repin inside this skill.
* Durations are wall clock and say whether anything else shared the machine.
* State what the run did not cover (§8).

## 7. Environment traps on this machine

1. **Paseo puts `…/Paseo/resources/app.asar/node_modules/…` on Git Bash's PATH, and the PATH
   `cmd.exe` receives is cut off at that entry.** Measured 2026-09-27: `cmd //c 'echo %PATH%' | wc -c`
   printed 226 with the entry and 3154 without it. System32 is in the lost part, so from Git Bash
   `dart.bat` / `flutter.bat` fail (`PowerShell executable not found`; the pre-commit hook has been
   seen to report a false `web/ does not match tool/web_deps.json` for the same reason), and a vcvars script launched through
   `cmd` loses `rc.exe` and fails the link with `RC Pass 1 … no such file or directory`. Either work
   from the PowerShell tool, or strip the entry first in every Git Bash call:

   ```bash
   export PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'app\.asar' | paste -sd: -)"
   ```

   Stages 4–5 run `uv` from Git Bash; strip the entry there too. The harness needs it: with the
   entry left in, `scenario_run.py` cannot spawn the harness's own `uv run` child —
   `subprocess.Popen` raises `FileNotFoundError: [WinError 2]` and the run exits 1 before the app
   starts.
2. **`cmd /c` from Git Bash** also needs `MSYS2_ARG_CONV_EXCL='*'` or `cmd //c`, or it silently runs
   nothing and returns 0 (`native-cli-dev`, *Trap: launching `cmd` from Git Bash silently does
   nothing*).
3. **`native/wasm/build.sh` loses `uv`** after sourcing `emsdk_env.sh` (§3, 2.3).
4. **The vcvars must match the toolset the CMake cache recorded** — VS 18, MSVC 14.51.36231 for
   `native/cmake-build-release`. Another vcvars produces unresolved symbols that look like a code
   problem (`docs/live-capture-harness.md`, *Prerequisites*).
5. **A Japanese `cl` prints its include notes in Japanese**, and a ninja that does not recognise
   them records no header dependencies, so a header-only edit rebuilds nothing and a green result
   measured nothing new. Configure fresh directories with `VSLANG=1033` (§4) and force the player
   rebuild (§5.2). To check a directory, run `ninja -t deps` inside the vcvars shell: any
   `#deps 0` entry for a source that includes headers means the dependencies were lost
   (outside vcvars `ninja` is not on PATH and prints nothing, which is not a pass). A healthy
   directory prints one `<object>: #deps N, deps mtime … (VALID)` line per object with no
   `#deps 0`.
6. **PowerShell `Start-Job` does not outlive the tool call** here; its job dies with the call and
   writes no log. For a detached process use `Start-Process -PassThru` with redirected output, or
   the tool's own `run_in_background`.
7. **`sed -i` in Git Bash strips CR** from the files it edits, and `core.autocrlf=true` hides that
   from `git diff`. Do not use it on tracked files while preparing a run.
8. **PowerShell redirection of a native command writes UTF-16LE.** Logs written with `*>` from the
   PowerShell tool began with the `FF FE` byte-order mark, which `grep` in Git Bash does not read as
   text, and `2>&1` on a native command also wraps each stderr line in a `NativeCommandError`.
   `2>&1 | Out-File -Encoding utf8` writes UTF-8 (with a BOM); redirecting inside
   `cmd /c "… > log 2>&1"` avoids both.

## 8. What this suite does not cover

* **The web build in a browser.** Stage 1's node tests do not load the real wasm, the browser tests
  exercise storage and `dart:js_interop` facts rather than capture, and the harness drives only the
  Windows app. Web screen share and web video import need a browser run by hand.
* **Full-screen capture.** The player is a plain captioned `WS_OVERLAPPEDWINDOW`
  (`mimic_player.cpp`), so the full-screen form of the four promised capture forms is not
  reproduced (inferred from the window style, not measured).
* **Anything not in a recording.** The player replays pixels and sends nothing to a game; a screen
  transition, a tab order or a network stall that no clip contains cannot be produced.
* **The Windows app's look.** The harness asserts records and app state, not rendering; nothing here
  checks layout, theme or text.
* **The Windows video import driver** (dedicated thread, session claim, cancel): the golden suite
  covers `VideoLoader`'s decode only (`.claude/rules/platform-parity.md`, *Test gap*).
* **Release and Profile app bundles** are never compared against record contents; stages 4–5 run
  the debug driver build only.
* **Real GPU capture timing on another machine**: every harness figure is one machine and one window
  position (`docs/live-capture-harness.md`, *Limitations*).
