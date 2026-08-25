<div align="center"><img src="https://raw.githubusercontent.com/umasagashi/umacapture/develop/logo.png" width="400" alt="umacapture_logo"/></div>

# umacapture

<div align="center">

[![CI](https://github.com/umasagashi/umacapture/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/umasagashi/umacapture/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/umasagashi/umacapture)](https://github.com/umasagashi/umacapture/releases/latest)
[![License](https://img.shields.io/github/license/umasagashi/umacapture)](LICENSE)
![platform](https://img.shields.io/badge/platform-Windows-blue)

</div>

umacapture is a software that extracts in-game information from the game [ウマ娘](https://umamusume.jp/) using only image recognition.
This software is designed not to interfere with the game client or server and is not intended to violate the terms of use.

NOTE: Currently, only supports the game client for the Japanese market.


## System requirements

The Windows build imposes no CPU requirement beyond the x86-64 baseline. No `/arch:` switch appears anywhere in
this repository's build files, so every first-party translation unit is compiled for MSVC's default x64 baseline,
and the bundled native libraries select wider instruction sets at run time rather than requiring them: the shipped
`opencv_world4130.dll` records `Baseline: SSE SSE2 SSE3`, with SSE4.1 / SSE4.2 / AVX / AVX2 / AVX-512 built as
runtime-dispatched code paths, and ONNX Runtime likewise chooses its kernels from a CPU-feature probe.

The web build is the stricter of the two. The recognition core is compiled with WebAssembly SIMD (`-msimd128`) and
pthreads, and ONNX Runtime is loaded as its SIMD + threaded build, so the browser must support both WebAssembly
SIMD and `SharedArrayBuffer`. Browsers gate `SharedArrayBuffer` behind cross-origin isolation, so the page has to
be served with `COOP: same-origin` and `COEP: require-corp`; without it the worker refuses the session rather than
falling back to a slower path.


## Docs

under development


## Community

Discord: https://discord.gg/Ph9hEGHR4M [Japanese/日本語]

Twitter: https://twitter.com/umasagashi

## Licence

MIT License
