---
name: native-cli-dev
description: >-
  Build, run, log, and debug the C++ capture/recognition backend in native/ as a
  standalone CLI (umacapture_cli) from the command line, without CLion. Sets up
  the MSVC toolchain via vcvars64, configures CMake with Ninja (Debug/Release),
  runs the build / capture / screenshot / video / replay / stitch / recognize
  subcommands, explains the spdlog output and which subcommands self-terminate
  vs. run a live event loop, and steps through the binary with the cdb
  command-line debugger. Use when the user wants to build, rebuild, run, inspect
  logs from, or debug the native CLI, regenerate the assets/config/*.json scene
  definitions, record or replay FFV1 capture recordings, or test
  capture/recognition logic outside the Flutter app.
---

# Build, run, and debug the native C++ CLI (umacapture_cli)

`native/` holds the C++ capture + recognition backend. It is normally built into
the Flutter Windows app, but `native/CMakeLists.txt` also defines a standalone
executable target, `umacapture_cli`, so the backend can be exercised in
isolation. This was historically driven from CLion; this skill reproduces the
same build from the command line.

This skill covers **how to build/run/debug** the CLI. For **what the backend
does** — the pipeline architecture, the custom coordinate system, and the
builder workflow behind the `build` subcommand — see
[`docs/native-recognition-backend.md`](../../../docs/native-recognition-backend.md).

The build is **Windows + MSVC only** (it links `windowsapp.lib`, `dwmapi.lib`,
and uses WinRT screen capture). Generator is **Ninja**, compiler is **MSVC
`cl.exe`**, matching the original CLion "Visual Studio" toolchain.

## Prerequisites (already present on this machine)

- **Visual Studio 2022 or newer** with the C++ workload. `vcvars64.bat` provides
  `cl.exe`, and VS ships both `cmake` and `ninja` under
  `Common7\IDE\CommonExtensions\Microsoft\CMake\`. (A system CMake at
  `C:\Program Files\CMake` also works for the **CLI** target once `cl`/`ninja`
  are on PATH.)
  *Reported, measured once on 2026-08-11 and not independently confirmed:*
  building the **Flutter Windows runner** needs the **VS-bundled cmake called by
  full path** — the system cmake first on PATH does not know the generator that
  produced `build/windows/`'s cache and the configure fails. If a runner build
  fails at configure with a generator/cache complaint, try that before assuming
  the cache is corrupt (the other stale-cache remedy is `rm -rf build/windows`).
- **OpenCV 4.13.0** prebuilt at `windows/opencv/build` (referenced absolutely by
  `CMakeLists.txt` via `OpenCV_DIR`).
- **ONNX Runtime 1.27.0** at `windows/onnxruntime` (headers in `include/`,
  `onnxruntime.lib`/`.dll` in `lib/`).
- **FFmpeg n7.1.5 (BtbN LGPL shared)** at `windows/ffmpeg` (headers, import libs,
  and versioned `av*`/`sw*` DLLs). The CLI links `avformat`/`avcodec`/`avutil`
  directly for the FFV1 capture recorder and `replay` reader
  (`src/cv/ffv1_*.{h,cpp}`); the separate `umacapture_ffv1_tests` target links it
  too. The Flutter app target does **not** link it.

These three dependency dirs are **gitignored** (`windows/.gitignore` excludes
`/opencv/`, `/onnxruntime/`, `/ffmpeg/`) because they are large prebuilt
binaries. Provision them into the layout above by running
`uv run tool/fetch_deps.py` (downloads the official prebuilts, hash-verified) --
see the **project-setup** skill for details. A fresh checkout must do this before
the native build can configure (OpenCV is the hard requirement:
`find_package(OpenCV REQUIRED)`; ffmpeg is required to link the CLI and
`umacapture_ffv1_tests`; onnxruntime is only linked by the cli/app targets, not
the test targets). The fourth native dependency, `windows/clip`, is committed to
the repo, so no fetch is needed. CI provisions OpenCV and FFmpeg with the same
script (see `.github/workflows/ci.yml`).

## Key fact: the MSVC environment is mandatory

`cl.exe` and the bundled `ninja` are **not on PATH by default**. Every cmake
command must run inside a shell where `vcvars64.bat` has been sourced first.
Locate the latest VS install with `vswhere` rather than hard-coding a version:

```
"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
```

then call `"<installationPath>\VC\Auxiliary\Build\vcvars64.bat"`.

Because the Bash/PowerShell tools do not persist a sourced batch environment
across calls, the reliable pattern is a **single `.cmd` script** that sources
vcvars and then runs cmake in the same process. PowerShell cannot `call` a
`.bat`, so drive it through `cmd /c` — in the exact form the next section gives,
because the obvious one silently does nothing.

### Trap: launching `cmd` from Git Bash silently does nothing

The Bash tool runs **Git Bash**, whose MSYS2 argument mangling rewrites a bare
`/c` into a Windows path (`C:/`). `cmd` then never sees its switch, opens an
interactive shell instead, reads EOF, and **returns 0 without running the
script** — a failure that looks exactly like a successful build, so the next
measurement runs a stale binary. Measured 2026-08-11 in this repo's shell:

```
cmd /c 'C:\path\to\build.cmd'                          # prints the cmd banner, rc=0, script NOT run
MSYS2_ARG_CONV_EXCL='*' cmd /c 'C:\path\to\build.cmd'  # runs it
cmd //c 'C:\path\to\build.cmd'                         # also runs it (`//c` survives the mangling)
```

Use the `MSYS2_ARG_CONV_EXCL='*'` form with an **absolute Windows path** to the
script. After any `cmd`-driven build, confirm it actually built — look for
compiler/link output, or check the exe's mtime — rather than trusting rc=0.

### Trap: a bare exe name inside a `.cmd` is not resolved from the cwd

This machine sets `NoDefaultCurrentDirectoryInExePath=1`, so cmd does **not**
search the current directory for an executable. A script that `cd`s into the
build dir and then writes `umacapture_cli.exe` bare gets **9009**
("not recognized as an internal or external command") — and because a `.cmd`
exits with the code of its *last* command, the wrapper can still return 0 while
the run that was supposed to produce records never happened. Downstream that
reads as "the clip produced 0 records".

Write `.\umacapture_cli.exe` or an absolute path.
`tool/live_capture_test/run_capture.cmd` already does the former; copy that shape.
Measured 2026-08-11 (bare → 9009, `.\` → 0, same cwd).

## Build steps

Write a temporary build script — e.g. `native/build.cmd` (adjust the VS path from
`vswhere` if needed). Note a stray `.cmd` under `native/` is **not** covered by
`.gitignore` (only `cmake-build-*/` is), so it shows up as untracked — delete it
when done, or write it inside the build dir:

```bat
@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d C:\Projects\umacapture\native
cmake -G Ninja -S . -B cmake-build-release -DCMAKE_BUILD_TYPE=Release
cmake --build cmake-build-release
```

The `...\18\Community\...` path is this machine's current VS install; on a VS 2022
box it would read `...\2022\Community\...`. Resolve it with `vswhere` (above)
rather than copying the literal path.

Run it (see the Git Bash trap above — the `MSYS2_ARG_CONV_EXCL` prefix and the
absolute path are both load-bearing):

```
MSYS2_ARG_CONV_EXCL='*' cmd /c 'C:\Projects\umacapture\native\build.cmd'
```

Notes:
- Use a **fresh** build dir named `cmake-build-*` — `native/.gitignore` ignores
  `cmake-build-*/`, so it won't pollute git (e.g. `cmake-build-release`,
  `cmake-build-debug`). For a debug build pass `-DCMAKE_BUILD_TYPE=Debug` (see
  **Debugging** for what that changes).
- **Do not reuse the original CLion dirs (`cmake-build-debug-visual-studio` /
  `cmake-build-release-visual-studio`) as a cmake build target.** Their
  `CMakeCache.txt` was generated by CLion's bundled cmake and pins a CLion ninja
  path plus a specific MSVC toolset version. Re-running `cmake` over such a dir
  from a plain vcvars shell trips a toolset/cache mismatch and fails configure
  with `Check for working C compiler ... broken` (the cached cl.exe path no
  longer matches the vcvars environment). Configure a new dir instead. (You can
  still *run* the pre-built exe that already sits in a CLion dir — see the
  `recognize`/`stitch` test-input note — just don't reconfigure/rebuild into it.)
- A `POST_BUILD` step auto-copies the matching `opencv_world4130[d].dll`,
  `onnxruntime.dll`, the OpenCV videoio FFmpeg plugin, and the libav runtime
  DLLs next to the exe, so the exe runs from its own build dir without PATH
  changes (see the runtime-DLL note under **Running the CLI**).
- Incremental rebuilds: re-run only `cmake --build <dir>` (still inside vcvars).
- Cleanup gotcha: after a build, `mspdbsrv.exe` / `vctip.exe` linger and lock
  the build dir. Kill them (or just wait) before deleting a build directory.

## Running the CLI

The exe lives at `native/<build-dir>/umacapture_cli.exe`. **Run it with the
build dir as the working directory** — the code reads/writes paths relative to
cwd (`../../assets/config`, `../../sandbox/modules`, `./temp`, `./storage`), and
those `../../` paths resolve to the repo root only from inside `native/<build-dir>/`.

Subcommands (see `src/core/cli.cpp`):

| Subcommand   | Purpose | Example args |
|--------------|---------|--------------|
| `build`      | Regenerate the scene-definition JSONs from the C++ builders, round-trip-verifying each. | `build --assets_dir C:\Projects\umacapture\assets\config` |
| `capture`    | Live capture from the game window on screen (WinRT recorder). `--record` stores every full client frame + timestamp as lossless FFV1 for later `replay`. | `capture [--record out.mkv] [--duration 300] [--stop-file stop.flag]` |
| `screenshot` | Capture a single screenshot from the game window. | `screenshot --output shot.png` |
| `video`      | Run capture against recorded video files. | `video --video_path_list "C:\Projects\umacapture\sandbox\inheritance_only_1.mp4"` |
| `replay`     | Re-feed a recorded FFV1 `.mkv` through pane detection and the recognition pipeline, preserving the original frame timestamps. | `replay --record "C:\...\run.mkv" [--no-calibrate]` |
| `stitch`     | Stitch previously scraped images for one record id. | `stitch --id <uuid>` |
| `recognize`  | Run the recognizer over stitched images. | `recognize --id <uuid> [<uuid> ...]` |

The one-shot pipeline subcommands (`video` / `replay` / `stitch` / `recognize`)
also accept `--assets_dir`, `--modules_dir`, and `--output_dir`; the defaults
reproduce the historical cwd-relative behavior (`../../assets/config`,
`../../sandbox/modules`, `.`), so passing absolute paths makes a run independent
of the working directory.

Example (a harmless smoke test — `--help`, plus `build` into a throwaway dir):

```
cd C:\Projects\umacapture\native\cmake-build-release
umacapture_cli.exe --help
umacapture_cli.exe build --assets_dir .\smoke_assets
```

> **Caution:** pointing `build --assets_dir` at the real
> `C:\Projects\umacapture\assets\config` **overwrites the tracked scene JSONs in
> place.** Only do that when you intend to regenerate them (see the `build`
> section below); for a smoke test write to a throwaway dir as shown.

### Self-termination: only `capture` runs until stopped; the rest exit on their own

`build` and `screenshot` return as soon as they finish. `stitch` / `recognize` /
`video` / `replay` start `NativeApi`'s event loop, submit their work, then block
on the **drain barrier** (`runUntilDrainedThenJoin` in `src/core/cli.cpp`, over
`offlineDrainBarrier` in `src/core/pipeline_drain.h`): it polls each pipeline
stage's own in-flight counter every 10 ms and returns as soon as they are all
empty, with a 5-minute deadline as the failure path. A stage that never drains
becomes a throw, not a quiet short run. (It replaced an older "no notification
for ~10 s" quiet window, which cost every run ten seconds it did not need.)
Then they join the event loop and exit on their own — no need to watch for an
artifact and kill them.

Only `capture` (live screen capture) runs indefinitely by default. Stop it with
Ctrl-C, or — for scripted control — pass `--duration <seconds>` and/or
`--stop-file <path>` (capture ends cleanly when the file appears). All three
stop paths run full teardown, including finalizing an in-progress `--record`
file; a hard `Stop-Process` kill instead leaves the `.mkv` un-finalized, so
avoid it when recording.

Because these exit gracefully, they run full teardown — the event-loop join plus
the `NativeApi` atexit destructor — a path that force-killing them never
exercised. If you change shutdown/teardown or logging, run one to completion and
read its exit code (this path previously crashed at exit by logging through an
already-dropped spdlog logger; fixed in `NativeApi::joinEventLoop`).

#### The exit code is classified, and there is a machine-readable summary line

**"It exited 0" no longer means "it worked", and non-zero no longer means "the
tool is broken."** Every subcommand that starts the pipeline (`capture`,
`video`, `replay`, `stitch`, `recognize`) classifies its exit
(`src/core/cli_run_report.h`):

| code | meaning |
|---|---|
| **0** | ran to the end, and the pipeline reported no `onError` |
| **1** | the subcommand **threw** — bad args, an unopenable clip, a drain that hit its deadline. Nothing about the run can be concluded |
| **2** | ran to the end **and** reported at least one terminal error (e.g. `closed_before_completed`, `stitch_failed`) |

77 is deliberately never returned: ctest reads it as *Skipped*, and
`tool/live_capture_test/run_capture.cmd` passes this process's code through to
its caller. `build` and `screenshot` touch no pipeline, so they have no verdict
and return 0 or 1 only.

The same runs print **one line on stderr** (key set as of
`native/src/core/cli_run_report.h`; the values below are illustrative, not a
recorded run):

```
UMACAPTURE_RUN_SUMMARY {"schema":1,"subcommand":"video","unit":"run","inputs":1,"records":2,"failed":0,"discarded":1,"discarded_incomplete":0,"errors":[],"error_total":0,"unparsed":0,"forwarded_frames":1284,"anchor_unit_min":720,"anchor_unit_max":720,"exit":0}
```

`RunReport::summaryLine` in `native/src/core/cli_run_report.h` is the definition
of that key set — read it there rather than off this example.

`records` is the core's own count read after the drain, `discarded` counts
`onCharaDetailRestarted` (mid-run session resets), and `errors` is the deduped
list of `onError` tags. The last three before `exit` are **the geometry that
reached recognition**: `anchor_unit_min` / `anchor_unit_max` are the intersection
width of the frames the scraper actually scraped (min and max, because the unit
may legitimately move within a run), and `forwarded_frames` is what says whether
those two bounds describe anything at all — a run in which no chara-detail scene
ever committed reports `0` frames and `0..0`, which is an absence and not a
measurement. `native-change-verification` §5 relies on these three keys; they
were **added**, not a schema bump, so a consumer written against an older CLI
finds them absent rather than misread.

The counts are **per invocation, not per clip** — a
`video --video_path_list a b c` run decodes the files as one continuous stream,
so there is no instant at which a per-clip split would be a fact; `inputs` is
reported beside them so a consumer can see that and split the invocation.

**stderr vs stdout matters now.** spdlog writes the log to **stdout**; the
summary line and `main`'s fatal message go to **stderr**. Capture both when
scripting a run — redirecting only one of them loses either the diagnosis or the
verdict.

### `build` subcommand — regenerating scene config

`build` is the most useful target for non-capture work: it runs the
`tool/builder/*` C++ builders to emit
`assets/config/chara_detail/{scene_context,scene_scraper,scene_stitcher,recognizer}.json`,
then parses each back and asserts the round-trip is identical (data-loss guard).
Use it after editing any `tool/builder/*_builder.h`, pointing `--assets_dir` at
`C:\Projects\umacapture\assets\config` to overwrite the tracked JSONs, then
commit them as the build artifact. (The round-trip `assert_` is only active in a
Debug build — see Debugging.) With an absolute `--assets_dir`, `build` does not
depend on the working directory, unlike the event-loop subcommands.

### Runtime DLLs are auto-copied (including the video/FFmpeg ones)

A `POST_BUILD` step copies everything the exe needs next to it: the matching
`opencv_world4130[d].dll`, `onnxruntime.dll`, OpenCV's video decoder plugin
`opencv_videoio_ffmpeg4130_64.dll` (used by the `video` subcommand), and the
libav runtime DLLs (`av*.dll` / `sw*.dll` from `windows/ffmpeg/bin`, used by
`capture --record` / `replay`). No manual DLL copying is needed. One caveat: the
copied videoio plugin is the release-named one; a **Debug** build's
`opencv_world4130d.dll` looks for the `d`-suffixed plugin name, so if a Debug
`video` run stops decoding early (progress stalls near 0), duplicate the DLL as
`opencv_videoio_ffmpeg4130_64d.dll` in the build dir.

### `video` subcommand: the producer shapes nothing

`captureFromVideo` (`src/core/cli.cpp`) hands over each clip's **full decoded
frame**, with the default anchor and **no pane snapshot**; `original_size` is
that same decoded size. `VideoLoader` resolves no pane decision at all — the
pane latch is applied on the consumer side by `DetailCropTracker::beginFrame`,
which re-anchors any frame that carries no snapshot (see the class comment in
`src/cv/video_loader.h` and `.claude/rules/platform-parity.md`). That is
deliberate and shared by all three *offline* producers: an offline producer runs
concurrently with the thread that owns the latch, so a producer-side crop would
make the result depend on thread scheduling instead of on the clip. The two
*live* producers (Windows, web worker) do crop, which saves them the copy
bandwidth.

Shared pane detection/calibration still decides whether the content is a
one-pane frame or the left pane of a wider game surface — it just does so
downstream. There is no aspect-ratio `crop_profiles` config and no manual
orientation switch: the same shared detector used by live capture owns the
decision. A successful run
logs `{"type":"onCharaDetailFinished",...,"success":true}` and writes
`record.json` + `prediction.json` + `skill/factor/campaign.png` + `trainee.jpg`
under `<build-dir>/storage/chara_detail/active/<uuid>/`. The `onCharaDetailFinished`
log line (or that artifact) marks a completed record. The `video` run then
self-terminates once the pipeline drains (see the self-termination note above),
whether or not the clip ends with the detail screen closing — no manual kill needed.

A clip that **ends while a detail screen is still being captured** no longer ends
silently: `captureFromVideo` / `replayFromRecording` send `NativeApi::endOfInput()`
on the recorder runner once the producer has returned, which closes the open scene
and reports `closed_before_completed` (exit 2, and the tag in the summary line's
`errors`). That is the **same** tag a clip gets when the detail screen closes
on-screen — the core does not distinguish the two endings, deliberately, so do not
expect to tell them apart from the tag or from the summary line. Either way it is
an ordinary outcome of a truncated clip: read it as "this clip does not contain a
whole character", not as a build problem.

**What that costs a diagnosis.** Because the tag is shared, a broken
`NativeApi::endOfInput()` does *not* show up as a different tag; it shows up as
the tag going **missing** on a clip that ends mid-capture, i.e. as exit 0 and an
empty `errors` where exit 2 was expected. `player_standard_factor_only_1` is the
one case in `native/test/integration/cases.json` whose tag can only come from the
end-of-input path, so it is the only automated thing that catches this — see
§4 of the `native-change-verification` skill.

### `capture --record` / `replay`: full-frame FFV1 input

New `capture --record` files contain the full, pre-shaping client pixels. `replay`
therefore enables pane detection/calibration by default, keeps the decoded pixels
full-size, and applies a latched pane as `Frame` anchor metadata only. This makes
the capture-to-replay round trip exercise the same detector as live capture.

FFV1 stores neither the `Frame` anchor nor a recording-format marker. Clips made
before full-frame recording was introduced may already contain shaped pixels and
are indistinguishable from new recordings at decode time. If recalibrating such a
legacy clip is harmful, replay it with `--no-calibrate`; new `capture --record`
files should normally use the default calibration-on behavior.

### Test inputs (from the old CLion run configurations)

The CLion run configs in `native/.idea/workspace.xml` recorded working inputs
that still exist in the repo:

- **`video`** — `sandbox/inheritance_only_1.mp4` (and many other `sandbox/*.mp4`
  clips). Verified: it decodes the clip and writes scraped scene dirs under
  `<build-dir>/temp/chara_detail/<uuid>/`.
- **`recognize`** / **`stitch`** — operate on record ids under
  `<build-dir>/storage/chara_detail/active/<uuid>/`. The committed CLion **debug**
  build dir (`cmake-build-debug-visual-studio`) already contains stitched data
  for these ids: `4bbc9295-567b-4068-8850-d3e963e638af`,
  `84050aec-0088-4f27-900d-814716ac3ebe`,
  `4404be29-3fc0-4ff3-9565-f7884f623399`,
  `9fc47f24-16f7-479d-bece-05cce428549f`. So the simplest way to exercise
  `recognize` is to run from that debug dir (it also already has the exe + all
  runtime DLLs including FFmpeg). Verified: `recognize --id <one of those>`
  rewrites `prediction.json` / `prediction_*.png` in the id's dir.

The data lives only in those gitignored build dirs — there is no fresh-checkout
fixture. To test `recognize` from a clean build dir, first produce stitched data
with `video` → `stitch`, or copy a `storage/chara_detail/active/<uuid>/` folder
from the debug build dir.

## Logs

Logging is spdlog, configured in `src/util/logger_util.cpp` /
`logger_util.h::init()`. This applies to every run; the buffering note below is
what bites when you kill an event-loop subcommand. On Windows:

- **Logs go to stdout**, colored, with pattern `%^%L%$ %T.%f [%t] [%!:%#] %v` —
  i.e. `<level-char> HH:MM:SS.microseconds [thread-id] [function:line] message`.
  There is **no file sink** by default (the `basic_file_sink` line is commented
  out). To capture a run, redirect stdout: `umacapture_cli.exe recognize --id
  <uuid> > run.log 2>&1` (ANSI color codes land in the file too). Keep the
  `2>&1`: **stderr is not empty** — it carries the `UMACAPTURE_RUN_SUMMARY` line
  and `main`'s fatal message (see the exit-code section above). Redirect the two
  to separate files if you want to parse the summary without stripping log lines.
- **Log macros:** `log_debug/info/warning/error/fatal(...)` and the `vlog_*`
  variants, which auto-print each argument as `name=value` (used in `main()` as a
  smoke test of all six levels at startup).
- **Compile-time level floor:** `logger_util.h` line 4 sets
  `SPDLOG_ACTIVE_LEVEL = SPDLOG_LEVEL_DEBUG`, so `log_trace` / `vlog_trace` are
  **compiled out**. To see TRACE, change that line to `SPDLOG_LEVEL_TRACE` and
  rebuild — the comment on line 3 marks the intended toggle. The runtime level
  (`set_level(trace)`) is already permissive, so the macro is the only gate.
- **Buffering gotcha:** `flush_on(warn)` + `flush_every(5s)`. WARN and above
  flush immediately; DEBUG/INFO can sit in the buffer up to 5 seconds. This bites
  a hard-killed `capture`: **the last few seconds of buffered DEBUG/INFO can be
  lost** when you `Stop-Process` it. Every graceful exit (`stitch` / `recognize` /
  `video` / `replay`, and `capture` via Ctrl-C / `--stop-file` / `--duration`)
  runs the final `spdlog::drop_all()`, which flushes the tail. If you must
  hard-kill and need the tail, log at WARN or wait for a flush first.

## Debugging

### Build a Debug configuration first

For any real debugging, configure a separate Debug build dir — inside the same
vcvars `.cmd` wrapper as the release build above (the `call vcvars64.bat` + `cd`
lines are still required; only the cmake flags change):

```bat
cmake -G Ninja -S . -B cmake-build-debug -DCMAKE_BUILD_TYPE=Debug
cmake --build cmake-build-debug
```

A Debug build differs from Release in three ways that matter:

- **PDBs are generated**, so debuggers can map to source and show locals.
- **`assert_` becomes live.** `assert_` (`src/util/misc.h`) is compiled to
  `((void)0)` whenever `NDEBUG` is defined — i.e. in Release. So the `build`
  subcommand's round-trip assertion, and every internal `assert_` in the
  pipeline, **only fire in a Debug build**. A failed `assert_` calls `_wassert`,
  which pops the abort/retry/ignore dialog and breaks into an attached debugger.
- POST_BUILD copies the debug OpenCV DLL (`opencv_world4130d.dll`) instead of the
  release one. (The videoio FFmpeg plugin and libav DLLs are copied too — see the
  runtime-DLL note above for the Debug `d`-suffix caveat on the videoio plugin.)

(The compile-time log level floor is independent of build type — see **Logs**.)

### Debugging with cdb (command-line debugger)

Use **`cdb`** from the Windows SDK Debugging Tools:
`C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe`. It is fully
scriptable (`-c "commands"`), so it works from a non-interactive shell — no GUI
IDE needed. The Debug build's PDB sits next to the exe, so symbols auto-load.

Two things to get right:

- **Working directory must be the build dir.** cdb launches the child with cdb's
  own cwd, and the CLI resolves `../../assets/config`, `./storage`, etc. relative
  to it. `cd` into the build dir before launching.
- **Pass the exe by absolute path.** A bare relative `umacapture_cli.exe` fails
  with `Win32 error 0n2` (file not found); give cdb the full path. Subcommand args
  follow the exe path normally.

Scripted example — set a breakpoint, run to it, dump a source-line stack, then
quit. Targets the self-terminating `build` subcommand (`capture` never exits, so
under cdb you just break, inspect, and `q` to stop; `stitch` / `recognize` /
`video` now drain and exit on their own at the drain barrier):

```bat
cd /d C:\Projects\umacapture\native\cmake-build-debug
"C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe" -lines ^
  -c "bm umacapture_cli!uma::cli::buildJson*; g; kn; x umacapture_cli!uma::cli::createConfig*; q" ^
  "C:\Projects\umacapture\native\cmake-build-debug\umacapture_cli.exe" build --assets_dir cdb_out
```

- `-lines` enables source line info in stacks.
- `bm <pattern>` sets breakpoints by mangled-name pattern (one per template
  instantiation, e.g. each `buildJson<...Builder, lambda, lambda>`); the fact that
  it resolves confirms the PDB loaded.
- `g` runs to the breakpoint; `kn` prints the call stack with `file @ line`
  (e.g. `cli.cpp @ 24` ← `main ... cli.cpp @ 187`).
- `x <pattern>` lists matching symbols with signatures.

Common interactive commands once stopped: `g` (go), `p`/`t` (step over/into),
`bp <func>` (breakpoint), `dv` (locals), `?? <expr>` (evaluate C++ expression),
`q` (quit and kill the child). A failed `assert_` (Debug only) calls `_wassert`,
which breaks straight into cdb.

## Source layout (for reference)

- `src/core/cli.cpp` — `main()` + CLI11 subcommand wiring (CLI entry point).
- `src/core/native_api.{h,cpp}` — `NativeApi` event loop shared with the Flutter app.
- `src/chara_detail/`, `src/condition/`, `src/cv/` — recognition pipeline.
- `tool/builder/*_builder.h` — programmatic builders for the scene JSONs.
- `vendor/` — header-only deps (CLI11, spdlog, nlohmann/json, eventpp, nameof,
  minimal_uuid4). Also includes `../windows` (for `runner/window_recorder.h`,
  `runner/windows_config.h`) and `tool/` on the include path.
