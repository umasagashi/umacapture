# Vendored: clip

This directory is a vendored snapshot of **clip**, a cross-platform C++ clipboard
library by David Capello.

- Upstream: <https://github.com/dacap/clip>
- Version: **v1.15** (upstream tag, released 2026-03-04)
- License: MIT (see [`LICENSE.txt`](LICENSE.txt))

The C++ backend builds it from source via `add_subdirectory(clip)` in
[`../CMakeLists.txt`](../CMakeLists.txt), so it is pure source (no binaries) and
small enough to commit directly — unlike the OpenCV / ONNX Runtime prebuilts,
which are gitignored and provisioned by `tool/fetch_deps.py` (see the
`project-setup` skill).

## Provenance

Vendored from the upstream `v1.15` tag. clip now publishes semantic version tags
(it was commit-only when first vendored in April 2025), so the pinned version is
the tag above rather than the committed tree itself. To update, download the tag
tarball (`.../archive/refs/tags/<tag>.tar.gz`), copy it over this directory
excluding `.github/` (preserving this file), bump the version note above, and
review the diff.
