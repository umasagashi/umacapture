# Vendored: clip

This directory is a vendored snapshot of **clip**, a cross-platform C++ clipboard
library by David Capello.

- Upstream: <https://github.com/dacap/clip>
- License: MIT (see [`LICENSE.txt`](LICENSE.txt))

The C++ backend builds it from source via `add_subdirectory(clip)` in
[`../CMakeLists.txt`](../CMakeLists.txt), so it is pure source (no binaries) and
small enough to commit directly — unlike the OpenCV / ONNX Runtime prebuilts,
which are gitignored and provisioned by `tool/fetch_deps.py` (see the
`project-setup` skill).

## Provenance

Vendored as a source snapshot in April 2025. clip publishes no version macro or
release tag, so the pinned "version" is this committed tree itself. To update,
copy a newer checkout of the upstream repository over this directory (preserving
`LICENSE.txt` and this file) and review the diff.
