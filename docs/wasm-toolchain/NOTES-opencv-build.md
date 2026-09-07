# OpenCV Wasm build — PoC toolchain notes

Toolchain root: `C:\Projects\umacapture-wasm-toolchain\` (outside the umacapture repo; the repo tree
was not modified — read-only).

> **This file is a copy.** The original lives at the toolchain root above, which
> is where the OpenCV build is still managed from; the repository only *uses* the
> result. The copy exists so that losing that directory does not also lose the
> instructions for rebuilding it. The scripts next to this file are copies of the
> same scripts at the toolchain root, with one rename: the toolchain root's
> `build.sh` is `opencv_build.sh` here, so it cannot be confused with the
> repository's own `native/wasm/build.sh`, which builds the recognition core and
> is a different script with a different job.

## Versions

| Component            | Version |
|----------------------|---------|
| emsdk / Emscripten   | **6.0.3** (`latest`), clang/LLVM **23.0.0git** (commit `592953b`), target `wasm32-unknown-emscripten` |
| bundled node         | 22.16.0 |
| bundled python       | 3.13.3 (emsdk); host python 3.14 used to drive `emsdk.py` |
| OpenCV               | **4.13.0** (tag `4.13.0`, shallow clone) — matches the repo's prebuilt `windows/opencv` (CV_VERSION 4.13.0) |
| CMake                | 4.x (`C:\Program Files\CMake`) |
| Ninja                | bundled with Visual Studio 2022 (`.../CommonExtensions/Microsoft/CMake/Ninja/ninja.exe`) — no install performed |

Bundled codec 3rdparty (built from OpenCV source, all Wasm):
- zlib **1.3.1**, libjpeg-turbo **3.1.2**, libpng **1.6.53**.

## Directory layout

```
C:\Projects\umacapture-wasm-toolchain\
  emsdk\                 emsdk clone (Emscripten 6.0.3 installed+activated, session-only env)
  opencv-src\            OpenCV 4.13.0 source (shallow)
  opencv-build\          emcmake/Ninja build tree
  opencv-install\        `ninja install` output (include/ + lib/*.a + lib/opencv4/3rdparty/*.a)
  configure.sh           reconfigure script (see caveat below)
  build.sh / finish.sh   build drivers (`build.sh` is `opencv_build.sh` in the repository copy)
  NOTES-opencv-build.md  this file
```

## Toolchain setup (session-only; no permanent host changes)

```bash
cd /c/Projects/umacapture-wasm-toolchain/emsdk
/c/Python314/python emsdk.py install latest
/c/Python314/python emsdk.py activate latest      # NOT --permanent / --system
# per shell:
export PATH="/c/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja:$PATH"
source /c/Projects/umacapture-wasm-toolchain/emsdk/emsdk_env.sh
```

## OpenCV source

```bash
git clone --depth 1 --branch 4.13.0 https://github.com/opencv/opencv.git opencv-src
```

## Configure (emcmake + Ninja)

Full command (`configure.sh`):

```bash
emcmake cmake -G Ninja /c/Projects/umacapture-wasm-toolchain/opencv-src \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/c/Projects/umacapture-wasm-toolchain/opencv-install \
  -DBUILD_LIST="core,imgproc,imgcodecs" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_C_FLAGS="-msimd128 -pthread" \
  -DCMAKE_CXX_FLAGS="-msimd128 -pthread" \
  -DCPU_BASELINE="" \
  -DCPU_DISPATCH="" \
  -DOPENCV_PYTHON3_VERSION= \
  -DOPENCV_PYTHON2_VERSION= \
  -DWITH_PTHREADS_PF=ON \
  -DWITH_TBB=OFF -DWITH_IPP=OFF -DWITH_OPENCL=OFF -DWITH_ITT=OFF \
  -DWITH_PROTOBUF=OFF -DWITH_QUIRC=OFF -DWITH_ADE=OFF -DWITH_EIGEN=OFF \
  -DWITH_1394=OFF -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF \
  -DWITH_TIFF=OFF -DWITH_WEBP=OFF -DWITH_OPENJPEG=OFF -DWITH_JASPER=OFF -DWITH_OPENEXR=OFF \
  -DWITH_IMGCODEC_HDR=OFF -DWITH_IMGCODEC_SUNRASTER=OFF -DWITH_IMGCODEC_PXM=OFF -DWITH_IMGCODEC_PFM=OFF \
  -DWITH_PNG=ON -DBUILD_PNG=ON \
  -DWITH_JPEG=ON -DBUILD_JPEG=ON \
  -DBUILD_ZLIB=ON \
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF -DBUILD_DOCS=OFF -DBUILD_PACKAGE=OFF -DBUILD_JAVA=OFF \
  -DBUILD_opencv_python2=OFF -DBUILD_opencv_python3=OFF \
  -DBUILD_opencv_js=OFF -DBUILD_opencv_world=OFF
```

**`BUILD_LIST` above is not what the surviving `opencv-install/` was built with.**
`opencv-build/CMakeCache.txt` records
`BUILD_LIST:STRING=core,imgproc,imgcodecs,features2d,flann`, and both the build
tree and the install tree carry `libopencv_features2d.a` and
`libopencv_flann.a` accordingly (the artifact lists below name only the three the
repository links) — the archived
`configure.sh` was reduced to three modules afterwards and never re-run. The two
extra modules were needed by the scraper's former AKAZE + LSH offset estimator;
`native/wasm/build.sh` no longer links either one (it says so at its `OPENCV_LIBS`
list), so a fresh build from the three-module line above is sufficient for the
repository as it stands today. Reproducing the *archived* install byte-for-byte
would need the five-module line.

Resulting config summary (verified): modules built = `core imgcodecs imgproc`
from the three-module line above — the archived install additionally has
`features2d` and `flann`, per the caveat immediately above;
Parallel framework = **pthreads**; codecs = PNG(build 1.6.53) + JPEG(libjpeg-turbo 3.1.2) +
ZLib(build 1.3.1); GIF also on (built-in). `C++ flags (Release)` include
`-msimd128 -pthread ... -O3 -DNDEBUG`.

## Build

```bash
cmake --build . -j     # i.e. ninja
ninja install
```

## Artifacts (verified present, confirmed `file format wasm`)

Build tree (`opencv-build`):
- `lib/libopencv_core.a`
- `lib/libopencv_imgproc.a`
- `lib/libopencv_imgcodecs.a`
- `3rdparty/lib/liblibpng.a`
- `3rdparty/lib/liblibjpeg-turbo.a`
- `3rdparty/lib/libzlib.a`

Install tree (`opencv-install`) — use this for downstream `emcmake` link:
- headers: `opencv-install/include/opencv4/opencv2/...`
- module libs: `opencv-install/lib/libopencv_{core,imgproc,imgcodecs}.a` — plus
  `libopencv_features2d.a` and `libopencv_flann.a`, which the archived tree also
  has and nothing links any more (see the `BUILD_LIST` caveat above)
- 3rdparty codec libs: `opencv-install/lib/opencv4/3rdparty/lib{libpng,libjpeg-turbo,zlib}.a`

Downstream link order (dependencies last): `-lopencv_imgcodecs -lopencv_imgproc
-lopencv_core -llibpng -llibjpeg-turbo -lzlib`, and compile/link the app with
`-msimd128 -pthread` to match (SIMD is mandatory — see below).

## Gotchas hit and how they were resolved

1. **No system Ninja.** Used the Ninja bundled with Visual Studio 2022 (no
   winget/pip install, per task constraint). MSVC `vcvars` is NOT needed — the
   compiler is Emscripten's clang.

2. **CMake error: `find_package called with invalid argument "OFF"`** in
   `OpenCVDetectPython.cmake` under the Emscripten cross toolchain. Root cause:
   `option(OPENCV_PYTHON3_VERSION "..." "")` normalizes the empty default to
   `OFF`, which is then passed as a *version* argument to `find_package(Python3
   ...)` when host-python detection mismatches under cross-compile.
   **Fix:** pre-seed the cache with empty strings on the command line
   (`-DOPENCV_PYTHON3_VERSION= -DOPENCV_PYTHON2_VERSION=`) so `option()` keeps
   the empty value and the version arg is empty (valid). No Python module is
   built anyway.

3. **LLVM 23 WebAssembly ISel crash at `-O2`/`-O3`.** `modules/imgproc/src/imgwarp.cpp`
   crashes the clang frontend during *"WebAssembly Instruction Selection"* on
   `cv::hal::warpPerspectiveBlocklineNNE` when compiled at `-O2` or `-O3` with
   `-msimd128`. It is the **only** file in the whole build that crashes
   (verified with `ninja -k 0`: 1/326 objects).
   - `-O1` with SIMD compiles it fine.
   - Dropping `-msimd128` is NOT an option: OpenCV 4.13's `intrin_wasm.hpp`
     unconditionally emits `always_inline` wasm-SIMD intrinsics on the Wasm
     target, so building without `simd128` fails to compile. **SIMD is mandatory
     for OpenCV-on-Wasm here.**
   - **Fix applied:** keep `-O3 -msimd128 -pthread` globally; pin only
     `imgwarp.cpp` to `-O1` by appending `-O1` (last `-O` wins) to that single
     edge's `FLAGS` line in `opencv-build/build.ninja`. Everything else stays
     `-O3`.
   - **CAVEAT:** this pin lives in the generated `build.ninja`. Re-running
     `configure.sh` (a fresh `emcmake`) regenerates `build.ninja` and drops the
     pin — you must re-apply it (re-append `-O1` to the `imgwarp.cpp.o` FLAGS
     line) or add a `set_source_files_properties(imgwarp.cpp PROPERTIES
     COMPILE_OPTIONS -O1)` override in `opencv-src` before rebuilding.
     A follow-up could try a newer/older Emscripten to see if the ISel bug is
     fixed and the pin can be dropped.

4. **PNG "SIMD Support: YES (Intel SSE)"** and *"SIMD extensions disabled: could
   not find NASM"* in the config summary are x86-oriented and harmless on Wasm —
   the SSE/NASM paths are gated out by the target macros and did not affect the
   build.

## Reproduce a clean rebuild

```bash
bash /c/Projects/umacapture-wasm-toolchain/configure.sh          # emcmake configure
# re-apply the imgwarp -O1 pin (gotcha #3) to opencv-build/build.ninja
cd /c/Projects/umacapture-wasm-toolchain/opencv-build && ninja && ninja install
```
