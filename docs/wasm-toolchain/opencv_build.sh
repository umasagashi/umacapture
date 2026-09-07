#!/usr/bin/env bash
set -e
export PATH="/c/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja:$PATH"
source /c/Projects/umacapture-wasm-toolchain/emsdk/emsdk_env.sh >/dev/null 2>&1
cd /c/Projects/umacapture-wasm-toolchain/opencv-build
cmake --build . -j
