# Wasm recognition-core build

This directory holds the C++ sources and the build script that compile the
umacapture recognition core (scene context -> scraper -> stitcher -> recognizer)
to a WebAssembly module for Flutter Web. The build outputs are **not committed**;
each developer builds them locally, exactly like the Windows native
dependencies. See the Stage-6 design at
`.notes/analysis/wasm_poc6/design.md` (sections 3 and 6) for the rationale.

## What lives here

- `build.sh` — drives `em++` directly (the source list is small and fixed, so
  this does not use CMake). Compiles each translation unit individually, then
  links against a Wasm-target OpenCV static build.
- `wasm_api.cpp` — the embind surface (`init`, `pushFrameRgba`, `drainMessages`,
  `stop`, the shared-memory counters, `setupInferenceBridge`, ...).
- `wasm_recognizer_models.cpp` — two things: the shared-memory inference channel
  that hands recognizer inference off to the JS-side onnxruntime-web pump, and
  the Wasm replacement for **every production recognizer constructor**. It stands
  in for `native/src/chara_detail/chara_detail_recognizer_models.cpp` (which is
  excluded from this build because it links onnxruntime) and must define the same
  constructors with the same signatures.
- `wasm_inference_bridge.h` — the abort protocol `stop()` uses to cancel an
  in-flight bridged inference. Required, not optional: `stop()` runs on the JS
  thread and joins the recognizer pthread, but that pthread's inference is served
  by a pump on the very thread `stop()` is blocking, so without the abort a stop
  during recognition hangs the worker permanently.
- `check_sources.py` — the mechanical drift check for the two hand-maintained
  copies below. `build.sh` runs it before compiling; see "Drift checks".

The rest of the compiled sources come from `native/src/**` (the same C++ the
Windows desktop app uses), guarded for Emscripten where needed.

## Prerequisites (repo-external toolchains)

Both live outside the repository and are **not** provisioned by `fetch_deps`;
install them once on the build machine.

1. **emsdk** (Emscripten SDK) — default location
   `C:/Projects/umacapture-wasm-toolchain/emsdk`.
   `build.sh` sources `${EMSDK_DIR}/emsdk_env.sh`, so an activated emsdk under
   that path is all that is required.

2. **A Wasm-target OpenCV static build** — default location
   `C:/Projects/umacapture-wasm-toolchain/opencv-install`. This must be OpenCV compiled *for the
   Emscripten target* with matching flags (SIMD + pthreads), producing the
   static archives `build.sh` links: `libopencv_imgcodecs.a`,
   `libopencv_imgproc.a`, `libopencv_core.a`, and the bundled 3rd-party
   `liblibpng.a`, `liblibjpeg-turbo.a`, `libzlib.a` under
   `lib/opencv4/3rdparty/`. A desktop OpenCV install will **not** work; it must
   be the Wasm build.

## Build

From the repository root, in Git Bash:

```bash
bash native/wasm/build.sh
```

Overridable environment variables (defaults shown):

| Variable     | Default                                                | Meaning                            |
|--------------|--------------------------------------------------------|------------------------------------|
| `EMSDK_DIR`  | `C:/Projects/umacapture-wasm-toolchain/emsdk`          | Activated emsdk root.              |
| `OPENCV_DIR` | `C:/Projects/umacapture-wasm-toolchain/opencv-install` | Wasm-target OpenCV install prefix. |
| `BUILD_DIR`  | `C:/Projects/umacapture-wasm-toolchain/app-build`      | Where the outputs are written.     |

### Drift checks

Two things in this build are hand-maintained copies that no compiler
cross-checks, so they are checked mechanically instead:

- **The source list.** `build.sh`'s `SOURCES` is a third copy of "what the
  pipeline is made of", after `native/CMakeLists.txt` and
  `windows/runner/CMakeLists.txt`. A new `native/src/**.cpp` that nobody adds
  here is simply absent from the module. `build.sh` therefore also lists the
  files it deliberately leaves out (`EXCLUDED_SOURCES`, each with its reason),
  and the check requires the two lists together to cover `native/src` exactly —
  a new source lands in neither and fails.
- **The recognizer twin.** `wasm_recognizer_models.cpp` must define the same
  constructors, with the same signatures, as
  `chara_detail_recognizer_models.cpp`. Adding or re-signing a recognizer on the
  desktop side otherwise compiles fine on Windows and breaks the Wasm build with
  no signal until someone runs `build.sh` by hand.

`build.sh` runs the check before compiling anything (`SKIP_SOURCE_CHECK=1`
bypasses it). It needs no Emscripten toolchain and no OpenCV, so it also stands
alone — this is the cheap gate to run anywhere, including CI:

```bash
uv run native/wasm/check_sources.py
```

Key compile/link flags (see `build.sh` for the full set): `-std=c++17 -O2
-msimd128 -pthread -DNDEBUG -fexceptions`, linked with `MODULARIZE`,
`EXPORT_ES6`, `EXPORT_NAME=UmacaptureCore`, `PTHREAD_POOL_SIZE=16`,
`ALLOW_MEMORY_GROWTH`, `INITIAL_MEMORY=256MB`, `FORCE_FILESYSTEM`.

### Outputs

`build.sh` emits into `${BUILD_DIR}`:

- `umacapture_core.js` — the ES6 `MODULARIZE` factory (`UmacaptureCore`).
- `umacapture_core.wasm` — the compiled module (~3.6 MB).
- `umacapture_core.worker.js` / `.ww.js` — pthread worker glue **if** the
  toolchain emits a separate file. With `EXPORT_ES6=1` + `MODULARIZE=1` the
  current toolchain inlines the pthread worker into `umacapture_core.js` (the
  module doubles as its own pthread worker via `import.meta.url`), so no
  separate file is produced.

## Placement for Flutter Web

Because the module is built `-pthread`, it needs `SharedArrayBuffer`, which the
browser gates behind cross-origin isolation (`crossOriginIsolated === true`, via
`Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy:
require-corp`). Isolation is delivered by the `coi-serviceworker` shim wired
into `web/index.html`; see that file's comment.

The build outputs, plus the vendored onnxruntime-web runtime, are served
same-origin from `web/wasm/` so they sit next to `main.dart.js` and satisfy
`require-corp` without cross-origin resource-policy juggling.

`web/wasm/` is **git-ignored** (see the repository `.gitignore`). Flutter picks
these files up automatically: `flutter build web` copies everything under `web/`
into `build/web/`, and `flutter run -d chrome` serves them. So a web build
requires provisioning that tree first, analogous to the Windows native deps
being provisioned before `flutter build windows`.

## Provisioning `web/`

Every file this repository places under `web/` is pinned by SHA-256 in
`tool/web_deps.json` — the web-side counterpart of the `*_URL` / `*_SHA256`
constants in `tool/fetch_deps.py`. It records, per file, the upstream artifact
it came from, the license text that covers it, and how to obtain the
corresponding sources; for `umacapture_core.wasm` it also lists the third-party
components statically linked into it. Run it via `uv run` (this repo invokes
Python through `uv`, never bare `python`):

```
uv run tool/fetch_web_deps.py                     # everything missing or drifted
uv run tool/fetch_web_deps.py --only onnxruntime-web   # a single package
uv run tool/fetch_web_deps.py --only mediabunny   # a single package
uv run tool/fetch_web_deps.py --force             # re-download even if present and valid
```

The fetcher restores the `origin: upstream` entries (onnxruntime-web 1.27.0 —
only the three files the `ort.wasm.bundle.min.mjs` distribution actually
references for the CPU-wasm SIMD-threaded execution provider, not the full
multi-backend tree — plus the Mediabunny 1.52.3 bundle, its shipped `LICENSE`
file so the MPL-2.0 notice travels with the code it covers, and the
`coi-serviceworker` shim). The `origin: in-tree` entries cannot be downloaded:
`umacapture_core.js` / `umacapture_core.wasm` come from `build.sh` (copy them
into `web/wasm/` after building). Those are verified when present and reported
when missing.

`DistributionInfoBuilder` re-checks the same pins during codegen and writes
`assets/web_license_info.json`, the license disclosure the in-app license page
reads. It treats `web/` as a closed world: a file whose bytes drifted from its
pin, a file that is neither pinned nor listed in the manifest's `first_party`
allowlist (matched exactly, file by file — symbolic links are always a
violation), or a referenced license text that is not committed all fail the
build, and the artifact is deleted rather than written. That is what makes the
"unmodified upstream" claim mechanical: it cannot be produced from a tree whose
bytes contradict it.

A checkout that never provisioned `web/wasm/` is not an error — the artifact
then says `not_provisioned`, so Windows-only development and CI keep working.
That only changes the *status*: the pins and the closed-world scan still run
over whatever is on disk, so the committed part of `web/`
(`coi-serviceworker.js`, the first-party files) is verified in every checkout.

Two cheaper checks back the codegen gate up, both running the same verification
code (`lib/web_deps_verify.dart`):

```
dart run tool/check_web_pins.dart      # pins + closed-world scan, no codegen
```

`tool/hooks/pre-commit` runs it on every commit, so a commit that changed a
pinned file without re-running codegen is rejected instead of shipping the old
claim over new bytes; CI runs it with `--ci-artifact` after regenerating the
artifact, which additionally pins down the shape a CI run must produce (CI can
restore only the `origin: upstream` entries, so its artifact is legitimately
smaller than the committed one and cannot be compared with `git diff`).

The hook adds one flag the other consumers do not: `--warn-stale-source-digest`
(see "Repin the result" below), which downgrades exactly one of the checks — the
`build.sources` staleness check — to a printed notice, leaving every other check
fatal.

### Bumping a pin

1. Pick the new version and download its artifact once (npm tarball or raw
   release file); `sha256sum` the artifact and each shipped member, and note
   the byte sizes.
2. Update that entry's `sha256` / `bytes` / `upstream.version` / `upstream.url`
   and the matching `source_form.url` + `source_form.sha256` +
   `source_form.git_url` in `tool/web_deps.json`.
3. Refresh `license.asset` under `assets/license/` if the upstream license text
   changed. A text under a license that needs its sources disclosed (MPL-2.0)
   is only accepted with a complete `source_form` block.
4. `uv run tool/fetch_web_deps.py --force --only <package>`, then
   `dart run build_runner build --force-jit` to regenerate
   `assets/web_license_info.json`. Both fail loudly on a mismatch.

To re-pin an in-tree entry, rebuild it, copy the artifacts into `web/wasm/`,
and update its `sha256` / `bytes` / `build.*` fields the same way.

## When to rebuild

Rebuild (`bash native/wasm/build.sh`) and re-copy into `web/wasm/` whenever any
of the following change:

- `wasm_api.cpp`, `wasm_recognizer_models.cpp` or `wasm_inference_bridge.h`.
- Any compiled `native/src/**` source in the recognition pipeline (scene
  context / scraper / stitcher / recognizer, the condition serializer, or the
  logger util) or a header they include.
- A **new** `native/src/**` pipeline source: it must be added to `build.sh`'s
  `SOURCES` (or to `EXCLUDED_SOURCES` with a reason) or it is not in the module
  at all. This is the step most easily forgotten, which is why the drift check
  above exists.
- A recognizer constructor in `chara_detail_recognizer_models.cpp`: its twin in
  `wasm_recognizer_models.cpp` must be updated to match.
- The Wasm-target OpenCV build (version or flags) or the emsdk version.
- The build flags in `build.sh`.

Do not reuse a previously built module when the sources have changed — always
rebuild from the current working tree (project rule: never run a build artifact
you did not build this session).

### Repin the result

Rebuilding is only half of it: **repin the result**. Copy `umacapture_core.js`
and `umacapture_core.wasm` into `web/wasm/`, then update that entry's `sha256`,
`bytes`, `build.git_commit` and `build.sources.digest` in `tool/web_deps.json`.
The digest is what makes the previous section mechanical rather than a promise:
it records the source tree the pinned bytes came from, so a pin left behind by a
`native/` change is visible to `tool/check_web_pins.dart` without an emsdk and
without the artifact on disk. Print the value to paste with:

```bash
.fvm/flutter_sdk/bin/dart run tool/check_web_pins.dart --source-digest
```

**Who fails on a stale digest, and who does not.** `tool/build_web.sh` and CI
fail — they decide what ships, so a module older than the `native/` sources in
the tree must not get into a bundle. `tool/hooks/pre-commit` does not: it passes
`--warn-stale-source-digest`, prints what drifted and lets the commit through,
because rebuilding needs an emsdk toolchain and a fatal check would make every
`native/` change uncommittable from a machine without one. So committing a
`native/` change before the rebuild is fine and expected — the branch just
cannot go green until the module is rebuilt and repinned.

**What the digest does not prove.** It compares the *recorded* digest with the
current tree. Nothing reads the binary back, so editing the digest by hand, or
repinning after a `native/` change without actually rebuilding, passes every
check. What it removes is the silent case, where nobody touches the manifest at
all and the stale artifact keeps verifying against its own byte pin.
