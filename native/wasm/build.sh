#!/usr/bin/env bash
# Build the ONNX-free recognition core (scene_context -> scraper -> stitcher) as a Wasm/embind module.
#
# Usage (Git Bash):
#   bash native/wasm/build.sh
#
# Emits, into $BUILD_DIR (default C:/Projects/umacapture-wasm-toolchain/app-build):
#   umacapture_core.js    (ES6 module, MODULARIZE factory)
#   umacapture_core.wasm
#   umacapture_core.worker.js / .ww.js  (pthread worker glue, if the toolchain emits it)
#
# The source list is fixed and small, so this drives em++ directly instead of CMake. Objects are compiled
# individually (clearer errors) and then linked.
set -euo pipefail

# --- Locations ---------------------------------------------------------------
EMSDK_DIR="${EMSDK_DIR:-C:/Projects/umacapture-wasm-toolchain/emsdk}"
OPENCV_DIR="${OPENCV_DIR:-C:/Projects/umacapture-wasm-toolchain/opencv-install}"
BUILD_DIR="${BUILD_DIR:-C:/Projects/umacapture-wasm-toolchain/app-build}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
source "${EMSDK_DIR}/emsdk_env.sh" >/dev/null 2>&1

mkdir -p "${BUILD_DIR}"
OBJ_DIR="${BUILD_DIR}/obj"
mkdir -p "${OBJ_DIR}"

# --- Drift checks ------------------------------------------------------------
# Two things here are hand-maintained copies that no compiler cross-checks: the SOURCES/EXCLUDED_SOURCES lists
# below (a third copy after native/CMakeLists.txt and windows/runner/CMakeLists.txt), and
# wasm_recognizer_models.cpp, which must define the same constructors as its desktop twin. Both are checked
# before anything is compiled, so drift fails loudly here instead of producing a module that is quietly missing
# a stage. The check needs no toolchain, so CI can run it on its own (see check_sources.py).
if [[ "${SKIP_SOURCE_CHECK:-0}" != "1" ]]; then
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found; it runs the source-drift check (see native/wasm/check_sources.py)." >&2
    echo "Install uv, or set SKIP_SOURCE_CHECK=1 to build without the check." >&2
    exit 1
  fi
  uv run "${SCRIPT_DIR}/check_sources.py"
fi

# --- Flags -------------------------------------------------------------------
INCLUDES=(
  -I"${NATIVE_DIR}/src"
  -I"${NATIVE_DIR}/vendor"
  -I"${OPENCV_DIR}/include/opencv4"
)

# NDEBUG compiles out the custom assert_ macro (which uses the Windows CRT _wassert), and the SIMD/pthread
# flags match the OpenCV Wasm build. USE_CUSTOM_ASSERT is intentionally NOT defined here.
CXXFLAGS=(
  -std=c++17
  -O2
  -msimd128
  -pthread
  -DNDEBUG
  -fexceptions
  -Wno-deprecated-declarations
  # NOT OPTIONAL, and it looks like noise, which is why it is commented here. OpenCV 4.13 sets CV_WASM_SIMD
  # only inside its own `#if defined __OPENCV_BUILD` branch; the "Compatibility code" block a downstream
  # consumer reaches covers SSE2/NEON/SVE/VSX and has NO wasm case, so without this the Universal Intrinsics in
  # cv/decoded_frame_to_bgr.h silently become intrin_cpp.hpp's element-wise reference implementation -- same
  # bytes, no warning, on the web only. -DCV_ENABLE_INTRINSICS does not help: the branch it
  # guards is nested inside the __OPENCV_BUILD one. The header answers with a static_assert(CV_SIMD128), so
  # deleting this line stops the build instead of quietly slowing the import.
  -DCV_WASM_SIMD=1
  # ... and intrin_wasm.hpp, which the line above selects, reads the deprecated __EMSCRIPTEN_major__ macro.
  -Wno-deprecated-pragma
  "${INCLUDES[@]}"
)

SOURCES=(
  "${NATIVE_DIR}/src/core/native_api.cpp"
  "${NATIVE_DIR}/src/core/native_api_frame_shaping.cpp"
  "${NATIVE_DIR}/src/chara_detail/chara_detail_scene_context.cpp"
  "${NATIVE_DIR}/src/chara_detail/chara_detail_scene_scraper.cpp"
  "${NATIVE_DIR}/src/chara_detail/chara_detail_scene_stitcher.cpp"
  "${NATIVE_DIR}/src/chara_detail/chara_detail_search_helpers.cpp"
  "${NATIVE_DIR}/src/chara_detail/chara_detail_recognizer.cpp"
  "${NATIVE_DIR}/src/condition/serializer.cpp"
  "${NATIVE_DIR}/src/util/logger_util.cpp"
  "${SCRIPT_DIR}/wasm_api.cpp"
  "${SCRIPT_DIR}/wasm_recognizer_models.cpp"
)

# Every native/src/**/*.cpp that is deliberately NOT in the module, with the reason. check_sources.py requires
# SOURCES and this list together to cover native/src exactly, so a newly added pipeline source cannot silently
# go missing from the Wasm build by being forgotten in SOURCES -- it lands in neither list and the check fails.
EXCLUDED_SOURCES=(
  # CLI entry point (main()); the module is a library and the CLI subcommands have no web counterpart.
  "${NATIVE_DIR}/src/core/cli.cpp"
  # FFV1 record/replay, CLI-only: both are built on FFmpeg, which is not part of the Wasm dependency set.
  "${NATIVE_DIR}/src/cv/ffv1_reader.cpp"
  "${NATIVE_DIR}/src/cv/ffv1_recorder.cpp"
  # Replaced, not dropped: wasm_recognizer_models.cpp defines the same constructors against the JS bridge
  # instead of an in-process onnxruntime. check_sources.py compares the two files' signatures.
  "${NATIVE_DIR}/src/chara_detail/chara_detail_recognizer_models.cpp"
)

# --- Compile -----------------------------------------------------------------
OBJECTS=()
for src in "${SOURCES[@]}"; do
  obj="${OBJ_DIR}/$(basename "${src}" .cpp).o"
  echo "[cc] $(basename "${src}")"
  em++ "${CXXFLAGS[@]}" -c "${src}" -o "${obj}"
  OBJECTS+=("${obj}")
done

# --- Link --------------------------------------------------------------------
# Order matters for static archives (dependents before dependencies): imgcodecs depends on imgproc/core.
# features2d/flann (AKAZE) are no longer linked -- the scraper's ImageOffsetEstimator now uses a
# vertical-shift proposer instead of AKAZE+LSH, and neither module is referenced anywhere under
# native/src or native/wasm (verified: no AKAZE/Feature2D/KeyPoint/flann/LshIndex symbol remains).
OPENCV_LIBS=(
  "${OPENCV_DIR}/lib/libopencv_imgcodecs.a"
  "${OPENCV_DIR}/lib/libopencv_imgproc.a"
  "${OPENCV_DIR}/lib/libopencv_core.a"
  "${OPENCV_DIR}/lib/opencv4/3rdparty/liblibpng.a"
  "${OPENCV_DIR}/lib/opencv4/3rdparty/liblibjpeg-turbo.a"
  "${OPENCV_DIR}/lib/opencv4/3rdparty/libzlib.a"
)

# Pipeline runners: distributor + scraper + stitcher + recognizer(empty) + scene-context debounce Timers.
# A generous pool with non-strict sizing lets the scraper's transient Timer threads spin up on demand.
LINKFLAGS=(
  -O2
  -pthread
  -fexceptions
  -sPTHREAD_POOL_SIZE=16
  -sPTHREAD_POOL_SIZE_STRICT=0
  -sALLOW_MEMORY_GROWTH=1
  -sINITIAL_MEMORY=268435456
  -sMODULARIZE=1
  -sEXPORT_ES6=1
  -sEXPORT_NAME=UmacaptureCore
  -sEXPORTED_RUNTIME_METHODS=['FS','HEAPU8','HEAP32','HEAPF64']
  -sFORCE_FILESYSTEM=1
  # OFF in the shipped build. Measured 2026-08-14 (testdata/evidence/android-web-import/handover/
  # Z2-wasm-build-flags.md), this was the one flag in this file with no reason comment, carried
  # over from development. ASSERTIONS also selects emscripten's debug vs. release system-library
  # variant (libc++, the allocator -- tools/system_libs.py's get_default_variation(is_debug=
  # settings.ASSERTIONS)), not just the JS asserts, so turning it off is a real, stage-level win:
  # the matcher's LSH build/knnSearch -8.0%, the scraper stage total -1.9%; the whole-window effect
  # is too small to resolve against this machine's run-to-run noise. Recognition output
  # (record.json / prediction.json) measured identical on/off across 93 leaf-by-leaf comparisons,
  # including a -fsanitize=undefined build. The trade is diagnosability: this also drops
  # env.__assert_fail and the stack-cookie/exception-message exports from the shipped module, so a
  # field failure loses the runtime's own guard messages and exception stack traces. Deleting the
  # line is exactly -sASSERTIONS=0 (emscripten defaults it to 0 at -O1+); kept explicit so the next
  # reader does not have to rediscover why.
  -sASSERTIONS=0
  -lembind
)

echo "[link] umacapture_core.js"
em++ "${LINKFLAGS[@]}" "${OBJECTS[@]}" "${OPENCV_LIBS[@]}" -o "${BUILD_DIR}/umacapture_core.js"

echo "Done. Artifacts in ${BUILD_DIR}:"
ls -la "${BUILD_DIR}"/umacapture_core.* 2>/dev/null || true
