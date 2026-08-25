cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

set(OpenCV_DIR "${CMAKE_CURRENT_LIST_DIR}/../opencv/build")
set(OpenCV_VERSION "4130")
set(OpenCV_ARCH "x64")
set(OpenCV_RUNTIME "vc16")
set(OpenCV_DLL_NAME "opencv_world")
set(OpenCV_DLL_PREFIX "${OpenCV_DIR}/${OpenCV_ARCH}/${OpenCV_RUNTIME}/bin/${OpenCV_DLL_NAME}${OpenCV_VERSION}")
set(OpenCV_DEBUG_DLL "${OpenCV_DLL_PREFIX}d.dll")
set(OpenCV_RELEASE_DLL "${OpenCV_DLL_PREFIX}.dll")
# OpenCV decodes video through this FFmpeg plugin DLL, loaded at run time from next to the exe. The app needs
# it for video import (windows/runner/video_import_session.h -> cv/video_loader.h -> cv::VideoCapture); without
# it every clip fails to open. Same DLL and same reason as native/CMakeLists.txt copies for the CLI's `video`
# subcommand -- tool/fetch_deps.py already put it in the OpenCV bin dir, so nothing new is provisioned.
#
# The base name is captured into a variable of its own because it is needed again far below, AFTER
# find_package(OpenCV) -- which overwrites OpenCV_VERSION with the dotted "4.13.0". Spelling the name out down
# there produced `opencv_videoio_ffmpeg4.13.0_64.dll`, which OpenCV's loader never looks for.
set(OpenCV_FFMPEG_DLL_NAME "opencv_videoio_ffmpeg${OpenCV_VERSION}_64")
set(OpenCV_FFMPEG_DLL "${OpenCV_DIR}/${OpenCV_ARCH}/${OpenCV_RUNTIME}/bin/${OpenCV_FFMPEG_DLL_NAME}.dll")

set(ONNX_DIR "${CMAKE_CURRENT_LIST_DIR}/../onnxruntime")

set(NATIVE_EXTENSION_DIR "${CMAKE_CURRENT_LIST_DIR}/../../native")

set(
        SOURCE_FILES
        "flutter_window.cpp"
        "main.cpp"
        "utils.cpp"
        "win32_window.cpp"
        "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
        "Runner.rc"
        "runner.exe.manifest"
        "${NATIVE_EXTENSION_DIR}/src/core/native_api.cpp"
        "${NATIVE_EXTENSION_DIR}/src/core/native_api_frame_shaping.cpp"
        "${NATIVE_EXTENSION_DIR}/src/chara_detail/chara_detail_recognizer.cpp"
        "${NATIVE_EXTENSION_DIR}/src/chara_detail/chara_detail_recognizer_models.cpp"
        "${NATIVE_EXTENSION_DIR}/src/chara_detail/chara_detail_search_helpers.cpp"
        "${NATIVE_EXTENSION_DIR}/src/chara_detail/chara_detail_scene_context.cpp"
        "${NATIVE_EXTENSION_DIR}/src/chara_detail/chara_detail_scene_scraper.cpp"
        "${NATIVE_EXTENSION_DIR}/src/chara_detail/chara_detail_scene_stitcher.cpp"
        "${NATIVE_EXTENSION_DIR}/src/condition/serializer.cpp"
        "${NATIVE_EXTENSION_DIR}/src/util/logger_util.cpp"
)

add_executable(${BINARY_NAME} WIN32 ${SOURCE_FILES})

# Flutter adds a Profile configuration that third-party packages know nothing about. The OpenCV
# imported targets only carry DEBUG and RELEASE, and CMake's fallback picks the first one (DEBUG),
# so Profile would link opencv_world*d.lib while compiling without _DEBUG. OpenCV wraps the array
# types in an inline `debug_build_guard` namespace under _DEBUG (see core/cvdef.h), so the two sides
# mangle differently and the link fails with LNK2019 on every _InputArray/_OutputArray overload.
# Profile is a release build with symbols, so map it to Release. Must precede find_package, which is
# where the imported targets pick the mapping up.
set(CMAKE_MAP_IMPORTED_CONFIG_PROFILE Release)

find_package(OpenCV REQUIRED)
message(STATUS "You don't need to add OpenCV to your PATH, but you need to copy dll files into build directory.")

apply_standard_settings(${BINARY_NAME})

# The native backend sources above pull in spdlog, whose bundled {fmt} 12.x hard-requires
# /utf-8 on MSVC (static_assert in fmt/base.h). Scoped to this target (not the plugins) so it
# only touches the ASCII-only runner + native code. See native/vendor/spdlog/VENDORED.md.
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# Emit debug symbols (a .pdb) for optimized builds so native crashes reported to
# Sentry can be symbolicated. The native C++ backend is compiled straight into
# this executable (see SOURCE_FILES above), so umacapture.pdb covers both the
# runner and the recognition code. Without /DEBUG the exe carries no CodeView
# debug-id, and Sentry has nothing to match an uploaded pdb against. /OPT:REF and
# /OPT:ICF restore the size optimizations that /DEBUG otherwise turns off.
set(RELEASE_OR_PROFILE "$<OR:$<CONFIG:Release>,$<CONFIG:Profile>>")
target_compile_options(${BINARY_NAME} PRIVATE "$<${RELEASE_OR_PROFILE}:/Zi>")
target_link_options(
        ${BINARY_NAME} PRIVATE
        "$<${RELEASE_OR_PROFILE}:/DEBUG>"
        "$<${RELEASE_OR_PROFILE}:/OPT:REF>"
        "$<${RELEASE_OR_PROFILE}:/OPT:ICF>"
)

# Version resource inputs for Runner.rc. Without these the #else branches in
# Runner.rc take over and the exe reports itself as 1.0.0 forever, no matter what
# pubspec.yaml says. FLUTTER_VERSION* come from the top-level CMakeLists.txt,
# which the Flutter tool populates from the pubspec version at configure time.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

target_compile_definitions(
        ${BINARY_NAME} PRIVATE
        NOMINMAX
        USE_CUSTOM_ASSERT
)

target_link_libraries(
        ${BINARY_NAME} PRIVATE
        flutter
        flutter_wrapper_app
        "dwmapi.lib"
        "${OpenCV_LIBS}"
        "${ONNX_DIR}/lib/onnxruntime.lib"
        clip
)

target_include_directories(
        ${BINARY_NAME} PRIVATE
        "${NATIVE_EXTENSION_DIR}/src"
        "${NATIVE_EXTENSION_DIR}/vendor"
        "${CMAKE_SOURCE_DIR}"
        "${OpenCV_INCLUDE_DIRS}"
        "${ONNX_DIR}/include"
)

add_dependencies(${BINARY_NAME} flutter_assemble)

# TODO: Should use TARGET_RUNTIME_DLLS. (cmake 3.21 or later)
set(SYSTEM_DLL_DIR "C:/Windows/System32")
set(
        DEPENDENT_DLLS

        # ONNX Runtime
        ${ONNX_DIR}/lib/onnxruntime.dll

        # OpenCV. Profile takes the release DLLs to match CMAKE_MAP_IMPORTED_CONFIG_PROFILE above.
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<${RELEASE_OR_PROFILE}:${OpenCV_RELEASE_DLL}>

        # VC++ Redistributable
        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/vcruntime140d.dll>
        $<${RELEASE_OR_PROFILE}:${SYSTEM_DLL_DIR}/vcruntime140.dll>

        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/vcruntime140_1d.dll>
        $<${RELEASE_OR_PROFILE}:${SYSTEM_DLL_DIR}/vcruntime140_1.dll>

        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/msvcp140d.dll>
        $<${RELEASE_OR_PROFILE}:${SYSTEM_DLL_DIR}/msvcp140.dll>

        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/concrt140d.dll>
        $<${RELEASE_OR_PROFILE}:${SYSTEM_DLL_DIR}/concrt140.dll>

        # For debug mode build for non-developer
        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/ucrtbased.dll>
)

add_custom_command(
        TARGET ${BINARY_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        ${DEPENDENT_DLLS}
        $<TARGET_FILE_DIR:${BINARY_NAME}>
        COMMAND_EXPAND_LISTS
)

# The videoio plugin is copied SEPARATELY from DEPENDENT_DLLS because it is the one DLL whose destination NAME
# depends on the configuration. OpenCV's plugin loader asks for a name derived from the opencv_world it is
# loaded by, so a Debug build's opencv_world4130d.dll looks for `..._64d.dll` while Release/Profile look for
# `..._64.dll` -- and the vendored package ships only the release-named file (see the OpenCV bin dir; there is
# no `..._64d.dll` to copy). The same asymmetry bites the CLI, where it is worked around by hand
# (.claude/skills/native-cli-dev/SKILL.md, "Runtime DLLs are auto-copied": a Debug `video` run stalls near 0
# until the DLL is duplicated under the d-suffixed name). Renaming on copy does that automatically, so every
# configuration of the app ships a plugin its opencv_world will actually find. DEPENDENT_DLLS cannot express
# this: it copies a list into a directory, preserving names.
#
# Only the Release/Profile branch has been exercised by a build (`flutter build windows` is Release); the Debug
# name is the skill's measured claim about the CLI applied here, not a verified app run.
add_custom_command(
        TARGET ${BINARY_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        ${OpenCV_FFMPEG_DLL}
        "$<TARGET_FILE_DIR:${BINARY_NAME}>/${OpenCV_FFMPEG_DLL_NAME}$<$<CONFIG:Debug>:d>.dll"
)
