# Vendored: spdlog

Snapshot of **spdlog**, a fast C++ logging library (bundles {fmt}).

- Upstream: <https://github.com/gabime/spdlog>
- Version: **v1.17.0** (2025-01-04), bundles **{fmt} 12.1.0**
- License: MIT (see [`LICENSE`](LICENSE))

Vendored as the header subtree `include/spdlog` (built header-only).

## Local patches

None. A previous snapshot (v1.10.0) carried a local patch in
`fmt/bundled/format.h` that dropped the `_SECURE_SCL` /
`stdext::checked_array_iterator` block removed from the MSVC STL at toolset
>= 14.51. Upstream {fmt} 12.x removed that workaround itself, so the patch became
unnecessary and is gone with this update — the tree is now pristine again.

## Updating

Replace the whole `include/spdlog` tree and `LICENSE` from the new tag. Verify a
native build (the bundled {fmt} version can change formatting/ABI).
