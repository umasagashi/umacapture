#!/usr/bin/env bash
set -e
export PATH="/c/Program Files/Microsoft Visual Studio/2022/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja:$PATH"
source /c/Projects/umacapture-wasm-toolchain/emsdk/emsdk_env.sh >/dev/null 2>&1
cd /c/Projects/umacapture-wasm-toolchain
rm -rf opencv-build && mkdir -p opencv-build && cd opencv-build

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
  -DWITH_TBB=OFF \
  -DWITH_IPP=OFF \
  -DWITH_OPENCL=OFF \
  -DWITH_ITT=OFF \
  -DWITH_PROTOBUF=OFF \
  -DWITH_QUIRC=OFF \
  -DWITH_ADE=OFF \
  -DWITH_EIGEN=OFF \
  -DWITH_1394=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_GSTREAMER=OFF \
  -DWITH_TIFF=OFF \
  -DWITH_WEBP=OFF \
  -DWITH_OPENJPEG=OFF \
  -DWITH_JASPER=OFF \
  -DWITH_OPENEXR=OFF \
  -DWITH_IMGCODEC_HDR=OFF \
  -DWITH_IMGCODEC_SUNRASTER=OFF \
  -DWITH_IMGCODEC_PXM=OFF \
  -DWITH_IMGCODEC_PFM=OFF \
  -DWITH_PNG=ON \
  -DBUILD_PNG=ON \
  -DWITH_JPEG=ON \
  -DBUILD_JPEG=ON \
  -DBUILD_ZLIB=ON \
  -DBUILD_TESTS=OFF \
  -DBUILD_PERF_TESTS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_opencv_apps=OFF \
  -DBUILD_DOCS=OFF \
  -DBUILD_PACKAGE=OFF \
  -DBUILD_JAVA=OFF \
  -DBUILD_opencv_python2=OFF \
  -DBUILD_opencv_python3=OFF \
  -DBUILD_opencv_js=OFF \
  -DBUILD_opencv_world=OFF
