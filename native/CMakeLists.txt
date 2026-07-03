cmake_minimum_required(VERSION 3.21)
project(umacapture_cli)

set(CMAKE_CXX_STANDARD 17)

set(OpenCV_DIR "${CMAKE_CURRENT_LIST_DIR}/../windows/opencv/build")
set(OpenCV_VERSION "455")
set(OpenCV_ARCH "x64")
set(OpenCV_RUNTIME "vc15")
set(OpenCV_DLL_NAME "opencv_world")
set(OpenCV_DLL_PREFIX "${OpenCV_DIR}/${OpenCV_ARCH}/${OpenCV_RUNTIME}/bin/${OpenCV_DLL_NAME}${OpenCV_VERSION}")
set(OpenCV_DEBUG_DLL "${OpenCV_DLL_PREFIX}d.dll")
set(OpenCV_RELEASE_DLL "${OpenCV_DLL_PREFIX}.dll")

set(ONNX_DIR "${CMAKE_CURRENT_LIST_DIR}/../windows/onnxruntime")

set(
        SOURCE_FILES
        src/core/cli.cpp
        src/core/native_api.cpp
        src/chara_detail/chara_detail_recognizer.cpp
        src/chara_detail/chara_detail_scene_context.cpp
        src/chara_detail/chara_detail_scene_scraper.cpp
        src/chara_detail/chara_detail_scene_stitcher.cpp
        src/condition/serializer.cpp
        src/util/logger_util.cpp
)

add_executable(
        ${PROJECT_NAME}
        ${SOURCE_FILES}
)

target_compile_options(
        ${PROJECT_NAME} PRIVATE
        /wd4068
        /wd4819
        /wd4996
        /we4062    # Treat "enumerator not handled in switch (no default)" as an error, so a
                   # default-less switch over an enum must stay exhaustive (e.g. recordTypeTag,
                   # tabPageTag). Not /we4061, which also fires when a default IS present.
        /bigobj
)

target_compile_definitions(
        ${PROJECT_NAME} PRIVATE
        USE_CUSTOM_ASSERT
        WINVER=0x0A00
        _WIN32_WINNT=0x0A00
        # Silence the STL1011 hard error that newer MSVC toolsets (>= 14.51) raise when the
        # C++/WinRT capture headers (runner/window_capturer.h) still include the deprecated
        # <experimental/coroutine> under /std:c++17. Mirrors the same define in windows/CMakeLists.txt.
        _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
)

find_package(OpenCV REQUIRED)
message(STATUS "You don't need to add OpenCV to your PATH, but you need to copy dll files into build directory.")

target_include_directories(
        ${PROJECT_NAME} PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${CMAKE_CURRENT_LIST_DIR}/vendor"
        "${CMAKE_CURRENT_LIST_DIR}/../windows"
        "${CMAKE_CURRENT_LIST_DIR}/tool"
        "${OpenCV_INCLUDE_DIRS}"
        "${ONNX_DIR}/include"
)

target_link_libraries(
        ${PROJECT_NAME} PRIVATE
        "${OpenCV_LIBS}"
        "${ONNX_DIR}/lib/onnxruntime.lib"
        windowsapp.lib
        dwmapi.lib
)

add_custom_command(
        TARGET ${PROJECT_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>
        $<TARGET_FILE_DIR:${PROJECT_NAME}>
)

add_custom_command(
        TARGET ${PROJECT_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        ${ONNX_DIR}/lib/onnxruntime.dll
        $<TARGET_FILE_DIR:${PROJECT_NAME}>
)

# ---------------------------------------------------------------------------
# Unit tests (doctest, vendored header-only under vendor/doctest).
#
# Configure/build:  cmake --build <build-dir> --target umacapture_tests
# Run:              ctest --test-dir <build-dir> --output-on-failure
#                   (or run the umacapture_tests executable directly)
#
# The test target deliberately links only the pure-logic sources it needs
# (currently the condition serializer, which pulls in OpenCV via cv/frame.h but
# not ONNX/WinRT). Add new pure-logic .cpp files and their tests here as the
# header/.cpp split progresses.
# ---------------------------------------------------------------------------
enable_testing()

set(
        TEST_SOURCE_FILES
        test/test_main.cpp
        test/condition/test_serializer.cpp
        test/condition/test_condition.cpp
        src/condition/serializer.cpp
)

add_executable(umacapture_tests ${TEST_SOURCE_FILES})

target_compile_options(
        umacapture_tests PRIVATE
        /wd4068
        /wd4819
        /wd4996
        /wd5285    # doctest specializes std::tuple, which MSVC flags under N5014; harmless here.
        /bigobj
)

target_compile_definitions(
        umacapture_tests PRIVATE
        USE_CUSTOM_ASSERT
        WINVER=0x0A00
        _WIN32_WINNT=0x0A00
        _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
)

target_include_directories(
        umacapture_tests PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${CMAKE_CURRENT_LIST_DIR}/vendor"
        "${CMAKE_CURRENT_LIST_DIR}/../windows"
        "${OpenCV_INCLUDE_DIRS}"
)

target_link_libraries(
        umacapture_tests PRIVATE
        "${OpenCV_LIBS}"
)

add_test(NAME umacapture_tests COMMAND umacapture_tests)

add_custom_command(
        TARGET umacapture_tests POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>
        $<TARGET_FILE_DIR:umacapture_tests>
)
