---
name: native-deps-setup
description: >-
  Provision the Windows native build dependencies (OpenCV 4.5.5 and ONNX Runtime
  1.11.1) into windows/ on a fresh clone by running tool/fetch_deps.py, which
  downloads the official prebuilts, verifies them against pinned SHA-256 hashes,
  and extracts them into the exact layout native/CMakeLists.txt and windows/runner
  expect. Use when the user is setting up the project for the first time, hits a
  missing-OpenCV / missing-onnxruntime CMake error, needs to re-fetch or bump a
  native dependency, or asks how opencv/onnxruntime get into windows/. Covers what
  each dependency is, where it lands, why clip is committed instead of fetched, and
  how CI uses the same script.
---

# Provisioning the Windows native dependencies

The C++ backend links two large prebuilt third-party packages that are **not**
committed (they are big binaries) and were historically copied in by hand:

- **OpenCV 4.5.5** → `windows/opencv/build` (referenced by `native/CMakeLists.txt`
  and `windows/runner/CMakeLists.txt` via `OpenCV_DIR`).
- **ONNX Runtime 1.11.1** → `windows/onnxruntime` (`include/` + `lib/`).

[`tool/fetch_deps.py`](../../../tool/fetch_deps.py) replaces the manual copy: it
downloads each artifact from its official URL, hash-verifies it, and extracts it
into the layout CMake expects. Nothing is pruned, so the result is byte-identical
to a plain official extraction, and the pinned hashes in the script are the
authoritative record of which build is vendored.

## Quick start

Run from the repo root (this repo invokes Python through `uv`, never bare
`python`; the script is stdlib-only):

```bash
uv run tool/fetch_deps.py                 # both deps (skips ones already present)
uv run tool/fetch_deps.py --only opencv   # just OpenCV (what CI provisions)
uv run tool/fetch_deps.py --force         # re-fetch even if already present
```

By default an already-provisioned dependency is left untouched; use `--force` to
delete and re-download it.

## What it provisions

| Dependency | Version | Official source | Lands at |
|---|---|---|---|
| OpenCV | 4.5.5 (vc14/vc15) | `opencv-4.5.5-vc14_vc15.exe` (7-Zip SFX) | `windows/opencv/build` (+ `sources/`) |
| ONNX Runtime | 1.11.1 | `onnxruntime-win-x64-1.11.1.zip` | `windows/onnxruntime/{include,lib}` |
| ONNX experimental C++ headers | v1.11.1 tag | two `experimental_onnxruntime_cxx_*.h` raw blobs | `windows/onnxruntime/include/` |

The two experimental headers ship only in ONNX Runtime's source tree, not in the
release zip, so the script fetches them separately from the tagged raw blobs — the
one manual step the old procedure required, now automated.

After a successful run you should see `windows/opencv/build/OpenCVConfig.cmake`,
`windows/opencv/build/x64/vc15/bin/opencv_world455.dll`,
`windows/onnxruntime/lib/onnxruntime.lib`, and
`windows/onnxruntime/include/experimental_onnxruntime_cxx_api.h`.

## clip is committed, not fetched

The third native dependency, `windows/clip` (a small MIT C++ clipboard library
built from source via `add_subdirectory(clip)`), **is** in the repo — see
[`windows/clip/VENDORED.md`](../../../windows/clip/VENDORED.md). It is pure source
with no binaries, so committing it is simpler than fetching, and it keeps
`DistributionInfoBuilder` (which scans `windows/clip` for a `LICENSE`) working on a
plain checkout. Don't add it back to `windows/.gitignore`.

## Prerequisites

- **`uv`** on PATH (the only requirement to run the script).
- **Windows** — OpenCV is a Windows self-extracting `.exe`; the script errors out
  early if OpenCV is requested on a non-Windows host. On Windows it prefers a
  `7z`/`7za` on PATH and otherwise falls back to the `.exe`'s own 7-Zip extractor
  (no external tool needed).
- Building the native code additionally needs the MSVC toolchain — see the
  **native-cli-dev** skill. Fetching the deps does not.

## Provenance / upgrading

Every artifact is pinned by URL **and** SHA-256 in `tool/fetch_deps.py`; a
tampered or truncated download fails loudly instead of producing a subtly broken
tree. To bump a version, edit that dependency's `*_URL` / `*_SHA256` constants
(and the `ONNX_HEADERS` entries) in the script, then download a copy once and
`sha256sum` it to get the new pin. Re-run with `--force` and rebuild.

## Notes / gotchas

- `windows/opencv` and `windows/onnxruntime` stay **gitignored** — the script
  populates them; they are never committed.
- **No pruning.** OpenCV's bulk is under `build/`, so dropping `sources/` saves
  little; the tree is left exactly as the official archive extracts (the ONNX
  `onnxruntime.pdb` is likewise kept, matching the official zip).
- **CI uses the same script.** `.github/workflows/ci.yml` caches `windows/opencv`
  and, on a cache miss, runs `uv run tool/fetch_deps.py --only opencv` — one source
  of truth for the fetch logic. CI does not provision onnxruntime/clip: the
  `umacapture_tests` target links only OpenCV.
