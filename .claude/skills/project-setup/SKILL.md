---
name: project-setup
description: >-
  Bring a fresh umacapture clone to a buildable state end to end: check for the
  required external toolchain (FVM-pinned Flutter 3.44.4, uv, Visual Studio 2022
  C++, optional 7-Zip) -- never installing host-level tools unprompted, only with
  the user's approval -- provision the gitignored Windows native dependencies via
  tool/fetch_deps.py, enable the git hooks and blame-ignore config, resolve Dart
  packages, and run build_runner codegen. Use when someone is setting up the
  project for the first time, asks "how do I get this building", hits a
  missing-SDK / missing-OpenCV / unformatted-hook / codegen error on a new
  machine, or wants the canonical first-time setup sequence. Points at the
  native-cli-dev and release skills for the deeper native-build and publishing
  flows.
---

# First-time project setup

This skill is the single entry point for standing up a fresh clone of umacapture
(a Flutter + native C++ Windows app) on a new machine. It consolidates the setup
steps that otherwise live scattered across `.claude/CLAUDE.md`, the native-cli-dev
skill, and `native/test/README.md`.

The app is **Windows-only** (WinRT screen capture, MSVC-linked native backend), so
setup targets a Windows dev box.

> ## ⚠️ Never install host-level tools unprompted
>
> The [Prerequisites](#prerequisites-external-tools) below live **outside this
> project** — system-wide packages and global SDK caches on the user's machine.
> **Do not install, upgrade, or modify any of them on your own initiative**, and
> **never run a system package manager** (winget, choco, scoop, `npm -g`, `pip
> install`, `dart pub global activate`, an installer `.exe`, etc.) to satisfy them.
>
> Instead, for each prerequisite:
>
> 1. **Check whether it is already present** (e.g. `command -v fvm`, `command -v
>    uv`, `where cl` / `vswhere`).
> 2. If it is missing, **stop and either (a) explain to the user exactly what needs
>    installing and how, or (b) ask for explicit approval before running anything
>    that touches the host.** Prefer explaining; get approval before acting.
>
> Only the **project-scoped** steps are safe to run without asking: `git config`
> **on this repo**, `tool/fetch_deps.py` (writes only into `windows/`), `pub get`,
> and `build_runner`. Note that even `fvm install` (step 1) and `uv run` (step 4)
> download into **global caches outside the repo** (`~/fvm`, uv's toolchain cache);
> if the user is sensitive to that, surface it before running them too.

## Quick sequence

From the repo root, in order (details for each below):

```bash
fvm install                                      # 1. Flutter 3.44.4 -> .fvm/flutter_sdk
git config core.hooksPath tool/hooks             # 2. pre-commit format/color hook
git config blame.ignoreRevsFile .git-blame-ignore-revs   # 3. clean git blame
uv run tool/fetch_deps.py                         # 4. native deps (OpenCV + ONNX Runtime)
.fvm/flutter_sdk/bin/flutter pub get              # 5. Dart packages
.fvm/flutter_sdk/bin/dart run build_runner build --force-jit   # 6. codegen
```

Then verify with a build (see [Verify](#verify)).

## Prerequisites (external tools)

These are host-level tools, not vendored in the repo. **Per the warning above,
check whether each is already installed; if one is missing, explain it to the user
or get approval before installing anything — do not install them unprompted.**

| Tool | Why | Notes |
|---|---|---|
| **Git** | clone the repo | — |
| **FVM** | pins Flutter **3.44.4** (`.fvmrc`) | `.fvm/` is gitignored, so a clone has no SDK until FVM materializes it. See step 1. |
| **uv** | runs the repo's Python tooling | `tool/fetch_deps.py`, native integration tests; this repo invokes Python via `uv`, never bare `python`. |
| **Visual Studio 2022+** (Desktop C++ workload) | MSVC toolchain for the native/Windows build | Provides `cl.exe`; VS ships `cmake` + `ninja`. Required for `flutter build windows` and the native CLI/tests. |
| **7-Zip** (optional) | faster OpenCV extraction | `tool/fetch_deps.py` falls back to the OpenCV `.exe`'s own self-extractor if `7z` is absent. |

Releasing additionally needs **Inno Setup** + `flutter_distributor` + a
`GITHUB_TOKEN` — out of scope here; see the **release** skill.

## Setup steps

### 1. Flutter SDK via FVM

`.fvmrc` pins `3.44.4`. From the repo root:

```bash
fvm install        # reads .fvmrc, installs 3.44.4, creates the .fvm/flutter_sdk symlink
```

Afterwards call the SDK through the pinned path the whole repo uses:
`.fvm/flutter_sdk/bin/flutter` and `.fvm/flutter_sdk/bin/dart`. (CI can't use the
FVM path — `.fvm/` is gitignored — so it installs the same 3.44.4 directly; keep
that version in sync with `.fvmrc` if it ever changes.)

The Dart MCP server in `.mcp.json` points at `.fvm/flutter_sdk/bin/dart.bat`, so it
only works after this step.

### 2. Enable the pre-commit hook

```bash
git config core.hooksPath tool/hooks
```

`tool/hooks/pre-commit` rejects staged Dart files that aren't `dart format`-clean
(120-col page width) and blocks **newly added** raw color literals outside the
theme allowlist. Override the Dart binary with `DART=...` if FVM lives elsewhere.

### 3. Clean `git blame`

```bash
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

Skips the one mechanical 120-col reformat commit so `git blame` shows real authors.

### 4. Native dependencies (OpenCV / ONNX Runtime)

```bash
uv run tool/fetch_deps.py            # both; add --only opencv|onnxruntime, or --force
```

Downloads the official prebuilts, verifies them against pinned SHA-256 hashes, and
extracts them into `windows/{opencv,onnxruntime}` (the gitignored layout CMake
expects), including the two experimental ONNX C++ headers that ship only in the
source tree. Nothing is pruned, so the result is byte-identical to a manual
extraction. Provisioning OpenCV requires Windows (it's a self-extracting `.exe`).

| Dependency | Version | Lands at |
|---|---|---|
| OpenCV | 4.13.0 (vc16) | `windows/opencv/build` |
| ONNX Runtime | 1.27.0 | `windows/onnxruntime/{include,lib}` |

The third native dependency, `windows/clip`, is **committed** to the repo (pure MIT
source, no binaries — see [`windows/clip/VENDORED.md`](../../../windows/clip/VENDORED.md)),
so it needs no fetch. To bump an OpenCV/ONNX version, edit the pinned `*_URL` /
`*_SHA256` constants in [`tool/fetch_deps.py`](../../../tool/fetch_deps.py) (for
ONNX also re-pin the two `ONNX_HEADERS` hashes at the new tag) and re-run with
`--force`. An OpenCV bump has three coupled edits beyond the URL/hash, because the
prebuilt encodes the version and MSVC toolset in its layout (`build/x64/vc16/bin/opencv_world<ver>.dll`):

- `OpenCV_VERSION` / `OpenCV_RUNTIME` in **both** [`native/CMakeLists.txt`](../../../native/CMakeLists.txt)
  and [`windows/runner/CMakeLists.txt`](../../../windows/runner/CMakeLists.txt)
  (e.g. `455`/`vc15` → `4130`/`vc16` — the runtime folder changed from `vc15` to
  `vc16` after OpenCV 4.6, and the release asset was renamed from
  `opencv-<ver>-vc14_vc15.exe` to `opencv-<ver>-windows.exe` at 4.7.0);
- the `key:` of the **Cache OpenCV** step in [`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml)
  — it pins the version, so a stale key would restore the old tree and break the build.

CI provisions OpenCV with the same script.

### 5. Resolve Dart packages

```bash
.fvm/flutter_sdk/bin/flutter pub get
```

### 6. Code generation

```bash
.fvm/flutter_sdk/bin/dart run build_runner build --force-jit
```

`--force-jit` is **required** here: a transitive native build hook (`objective_c`,
via `package_info_plus`) is incompatible with build_runner's default AOT
compilation. This regenerates the `dart_mappable` mappers, `auto_route` routes, and
the distribution/license/version assets. Generated outputs are committed, so this
also catches a stale regeneration. Re-run it after editing any annotated source.

## Verify

Fastest signal that setup worked:

```bash
.fvm/flutter_sdk/bin/flutter test          # Dart unit/widget suite
.fvm/flutter_sdk/bin/flutter build windows # full app + native backend + clip + OpenCV/ONNX link
```

For the standalone native C++ CLI / doctest suite (a separate CMake project under
`native/`), see the **native-cli-dev** skill.

## Where to go next

- **native-cli-dev** — build/run/debug the native C++ backend (`umacapture_cli`) and
  its doctest suite from the command line.
- **release** — bump the version, regenerate assets, and publish a Windows build to
  GitHub releases.
- **sentry-issues** — triage production error reports.
- **theme-gallery-refresh** — keep the debug theme gallery in sync after UI changes.

## Notes / gotchas

- **Windows-only.** The native backend links `windowsapp.lib`/`dwmapi.lib` and uses
  WinRT capture; there is no macOS/Linux build path.
- **`.fvm/` and `windows/{opencv,onnxruntime}` are gitignored** — FVM and
  `fetch_deps.py` populate them; they are never committed. `windows/clip` is the
  exception (committed source).
- **Keep `.fvmrc` and the CI Flutter version in sync** — CI hardcodes 3.44.4 because
  it can't read the gitignored `.fvm/`.
- **Order matters** for step 6: `pub get` before `build_runner`, and the native deps
  (step 4) before any `flutter build windows` / native CMake configure.
- **`flutter build windows` fails at INSTALL with `file cannot create directory:
  C:/Program Files/umacapture. Maybe need administrative privileges` → stale
  CMakeCache, not a real permission problem.** The bundle install prefix is set
  *only* by the `if (CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)` block in
  `windows/CMakeLists.txt` (flutter_tools never passes `-DCMAKE_INSTALL_PREFIX`),
  and that flag is true *only on a build tree's first configure*. `sentry_flutter`
  runs `FetchContent_MakeAvailable(sentry-native)` at **configure** time (before that
  block), so if the first configure aborts there — commonly a GitHub timeout while
  cloning sentry-native's submodules, ending in `Unable to generate build files` —
  CMake has already cached the default prefix `C:/Program Files/umacapture`. Any
  later reconfigure then sees the prefix as already-set and skips the override,
  leaving it wrong; INSTALL then tries to write to `C:/Program Files`.
  **Fix:** don't retry over the poisoned cache — deleting only
  `build/windows/x64/_deps` is not enough. `rm -rf build/windows` and rebuild
  uninterrupted. A clean configure yields `CMAKE_INSTALL_PREFIX =
  $<TARGET_FILE_DIR:umacapture>` and INSTALL populates `runner/Release/data/`
  (`app.so`, `flutter_assets`, `icudtl.dat`). The app enforces a single instance via
  the named mutex `umacapture_mutex` (`windows/runner/main.cpp`), so a second launch
  while one is running exits immediately with `EXIT_FAILURE` and an empty log — not a
  crash.
