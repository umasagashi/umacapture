#!/usr/bin/env bash
export PATH="/c/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja:$PATH"
source /c/Projects/umacapture-wasm-toolchain/emsdk/emsdk_env.sh >/dev/null 2>&1
cd /c/Projects/umacapture-wasm-toolchain/opencv-build
ninja > /c/Projects/umacapture-wasm-toolchain/finish.log 2>&1
echo "ninja rc=$?" >> /c/Projects/umacapture-wasm-toolchain/finish.log
