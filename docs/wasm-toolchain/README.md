# umacapture — out-of-repo Wasm toolchain and build root

> **Read "this directory" as `C:\Projects\umacapture-wasm-toolchain`, not as the
> folder you are reading this in.** This is a copy, kept in the repository so that
> losing the toolchain directory does not also lose the record of how to rebuild
> it; the original and the build itself stay out of the repository for the reason
> given under "Why it lives outside the repository" below. The build is still
> managed there — the repository only consumes the result.
>
> The scripts beside this file are copies of the toolchain root's scripts, with
> one rename: its `build.sh` is `opencv_build.sh` here, so that it is not mistaken
> for the repository's own `native/wasm/build.sh`. Every `build.sh` mentioned
> *below* is the repository's, which is a different script with a different job.

**This directory is not scratch. Deleting it breaks the web build of
[umacapture](https://github.com/umasagashi/umacapture).**

`native/wasm/build.sh` in the umacapture repository resolves three paths, and all
three default to a subdirectory of *this* directory:

```bash
EMSDK_DIR="${EMSDK_DIR:-C:/Projects/umacapture-wasm-toolchain/emsdk}"
OPENCV_DIR="${OPENCV_DIR:-C:/Projects/umacapture-wasm-toolchain/opencv-install}"
BUILD_DIR="${BUILD_DIR:-C:/Projects/umacapture-wasm-toolchain/app-build}"
```

Each is overridable through the environment, but the defaults are what an
unqualified `bash native/wasm/build.sh` uses.

## Why it lives outside the repository

`native/wasm/README.md` states the reason: the two toolchains below are multi-GB
and are **not** provisioned by `tool/fetch_deps.py`. They are installed once per
build machine and shared across checkouts, so they cannot live under a
repository that gets cloned, branched and cleaned.

## What is in here

| Path | What it is | Disposable? |
|---|---|---|
| `emsdk/` | Emscripten SDK 6.0.3 — the C/C++ → WebAssembly toolchain (`emcc` / `em++`, wasm-targeting LLVM, Node). Verified working from this path on 2026-08-26. | **No.** Required by `build.sh`. |
| `opencv-install/` | OpenCV built **for the Emscripten target** with SIMD + pthreads. Supplies `libopencv_{core,imgproc,imgcodecs}.a` and the bundled `liblibpng.a` / `liblibjpeg-turbo.a` / `libzlib.a` that `build.sh` links. A desktop OpenCV will **not** work here. | **No.** Required by `build.sh`. |
| `opencv-src/`, `opencv-build/` | Sources and intermediate build tree that produced `opencv-install/`. | No — deleting them means rebuilding OpenCV from scratch to change anything. |
| `NOTES-opencv-build.md` | The record of how `opencv-install/` was produced. | **No.** It is the only reproduction record. |
| `video/`, `frames/`, `harness/` | Capture recordings, extracted frames and a browser harness used for web-import and recognition measurements. | **No.** Recordings of live game sessions; most cannot be produced again. |
| `*-cfg-out/`, `r5-*`, `y5-*` | Small inputs and outputs of past measurement runs. | Probably, but they are tiny — left in place. |
| `*.log`, `*.sh`, `*.cmd`, `*.txt`, `*.wat` (small) | Logs and driver scripts from past sessions. | Probably, but tiny — left in place. |
| `app-build*/` and other `*-build*/` | Output of `build.sh` runs. Recreated on every build. | **Yes.** Safe to delete at any time. |

On 2026-08-26 the disposable build outputs and the large `.wat` disassembly
dumps were removed (4,434 MB → 3,206 MB) and this directory was renamed from
`wasm-poc`, whose name said nothing about what it holds.

## Building

From the umacapture repository root, in Git Bash:

```bash
bash native/wasm/build.sh
```

`build.sh` sources `${EMSDK_DIR}/emsdk_env.sh` itself, so no prior activation is
needed. It runs `native/wasm/check_sources.py` (via `uv`) before compiling.

**Rebuilding is only half of it.** The emitted `umacapture_core.js` /
`umacapture_core.wasm` must be copied into the repository's `web/wasm/` and the
entry in `tool/web_deps.json` re-pinned (`sha256`, `bytes`, `build.git_commit`,
`build.sources.digest`), or `tool/check_web_pins.dart` — which the pre-commit
hook and CI both run — will reject the tree. The canonical procedure is in
`native/wasm/README.md` under "Repin the result".

## If you move or rename this directory

Update the three defaults in `native/wasm/build.sh` and the paths quoted in
`native/wasm/README.md`. Note that `native/wasm/*.sh` is inside the pin digest
(`tool/web_deps.json` → `roots: [native/src, native/vendor, native/wasm]`,
`extensions: [..., ".sh"]`), so editing `build.sh` invalidates
`build.sources.digest` and requires a rebuild and re-pin.

**The rebuilt module will not be byte-identical, and that is expected.** This is
the part that surprises people, so it is written down here rather than
rediscovered: `build.sh` passes `-I"${OPENCV_DIR}/include/opencv4"`, and
OpenCV's inline headers bake their own `__FILE__` into the module as string
literals (`CV_Assert` in `opencv2/core/mat.inl.hpp`). Renaming this directory
therefore changes the spelling of a string that is *inside* the `.wasm`. Measured
on 2026-08-26 for `wasm-poc` → `umacapture-wasm-toolchain`: the literal grew by
17 bytes, data-segment alignment absorbed part of it, and the module grew by a
net **16 bytes** (3,622,906 → 3,622,922), with the `i32.const` operands that
address the shifted segment changing along with it. `umacapture_core.js` was
byte-identical. Two consecutive builds reproduced the new `.wasm` exactly, so
this is a path effect and **not** build non-determinism.

So a move means: rebuild, copy, and update `sha256` and `bytes` as well as
`build.sources.digest` — not the digest alone.

The `C:/Projects/.../opencv-src/...` strings also present in the module come from
the **prebuilt** OpenCV static archives and do not move with this directory;
only a rebuild of `opencv-install/` would change those.

`emsdk/` stores its own absolute paths in a sanity cache
(`emsdk/upstream/emscripten/cache/sanity.txt`); it detects the move and
re-validates itself on the next `emcc` invocation, so no manual step is needed
there.
