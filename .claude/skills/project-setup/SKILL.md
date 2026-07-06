---
name: project-setup
description: >-
  Bring a fresh umacapture clone to a buildable state end to end: install the
  external toolchain (FVM-pinned Flutter 3.44.4, uv, Visual Studio 2022 C++,
  optional 7-Zip), provision the gitignored Windows native dependencies via
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

Install these once on the machine; they are not vendored in the repo:

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
| OpenCV | 4.5.5 (vc14/vc15) | `windows/opencv/build` |
| ONNX Runtime | 1.11.1 | `windows/onnxruntime/{include,lib}` |

The third native dependency, `windows/clip`, is **committed** to the repo (pure MIT
source, no binaries — see [`windows/clip/VENDORED.md`](../../../windows/clip/VENDORED.md)),
so it needs no fetch. To bump an OpenCV/ONNX version, edit the pinned `*_URL` /
`*_SHA256` constants in [`tool/fetch_deps.py`](../../../tool/fetch_deps.py) and
re-run with `--force`. CI provisions OpenCV with the same script.

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
