cmake_minimum_required(VERSION 3.21)
project(umacapture_cli)

set(CMAKE_CXX_STANDARD 17)

set(OpenCV_DIR "${CMAKE_CURRENT_LIST_DIR}/../windows/opencv/build")
set(OpenCV_VERSION "4130")
set(OpenCV_ARCH "x64")
set(OpenCV_RUNTIME "vc16")
set(OpenCV_DLL_NAME "opencv_world")
set(OpenCV_DLL_PREFIX "${OpenCV_DIR}/${OpenCV_ARCH}/${OpenCV_RUNTIME}/bin/${OpenCV_DLL_NAME}${OpenCV_VERSION}")
set(OpenCV_DEBUG_DLL "${OpenCV_DLL_PREFIX}d.dll")
set(OpenCV_RELEASE_DLL "${OpenCV_DLL_PREFIX}.dll")
# OpenCV decodes video through this FFmpeg plugin DLL; the `video` subcommand fails to open a clip
# without it next to the exe. Copied by the POST_BUILD step below so `video` works from the build dir.
set(OpenCV_FFMPEG_DLL "${OpenCV_DIR}/${OpenCV_ARCH}/${OpenCV_RUNTIME}/bin/opencv_videoio_ffmpeg${OpenCV_VERSION}_64.dll")

set(ONNX_DIR "${CMAKE_CURRENT_LIST_DIR}/../windows/onnxruntime")

set(
        SOURCE_FILES
        src/core/cli.cpp
        src/core/native_api.cpp
        src/chara_detail/chara_detail_recognizer.cpp
        src/chara_detail/chara_detail_recognizer_models.cpp
        src/chara_detail/chara_detail_search_helpers.cpp
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
)

# cli.cpp is the only TU that still needs /bigobj: it includes the tool/builder/* headers, which
# instantiate the full condition/builder template set in a single translation unit and overflow the
# COFF section limit. The recognition-pipeline sources no longer need it now that their
# implementations live in their own .cpp files (previously they were compiled inline into
# native_api.cpp's TU), so scope the flag to this one file instead of the whole target.
set_source_files_properties(src/core/cli.cpp PROPERTIES COMPILE_OPTIONS "/bigobj")

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

add_custom_command(
        TARGET ${PROJECT_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        ${OpenCV_FFMPEG_DLL}
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
        test/condition/test_cv_rule.cpp
        test/chara_detail/test_scraping_box.cpp
        test/chara_detail/test_scene_context.cpp
        test/chara_detail/test_scene_stitcher.cpp
        test/chara_detail/test_scene_scraper.cpp
        test/chara_detail/test_scraper_estimators.cpp
        test/chara_detail/test_search_helpers.cpp
        test/chara_detail/test_record.cpp
        test/chara_detail/test_race_recognizer.cpp
        test/chara_detail/test_campaign_recognizer.cpp
        test/chara_detail/test_factor_recognizer.cpp
        test/chara_detail/test_status_header_recognizer.cpp
        test/chara_detail/test_skill_tab_recognizer.cpp
        test/chara_detail/test_support_card_recognizer.cpp
        test/chara_detail/test_family_tree_recognizer.cpp
        test/chara_detail/test_config.cpp
        test/core/test_native_api_messages.cpp
        test/core/test_frame_rate.cpp
        test/util/test_thread_util.cpp
        test/types/test_range.cpp
        test/types/test_color.cpp
        test/types/test_shape.cpp
        test/util/test_misc.cpp
        test/util/test_stds.cpp
        test/util/test_json_util.cpp
        test/util/test_event_util.cpp
        test/cv/test_frame.cpp
        test/cv/test_frame_distributor.cpp
        test/cv/test_frame_stall_watchdog.cpp
        src/condition/serializer.cpp
        src/chara_detail/chara_detail_scene_scraper.cpp
        src/chara_detail/chara_detail_scene_context.cpp
        src/chara_detail/chara_detail_scene_stitcher.cpp
        src/chara_detail/chara_detail_search_helpers.cpp
        # ONNX-free half of the recognizer TU split (its production ctors, which name recognizer::Model, live
        # in chara_detail_recognizer_models.cpp and are deliberately NOT linked here). This lets the scan logic
        # be tested against fake predictors without onnxruntime; the ONNX include dir/lib below are omitted.
        src/chara_detail/chara_detail_recognizer.cpp
)

add_executable(umacapture_tests ${TEST_SOURCE_FILES})

target_compile_options(
        umacapture_tests PRIVATE
        /wd4068
        /wd4819
        /wd4996
        /wd5285    # doctest specializes std::tuple, which MSVC flags under N5014; harmless here.
)

target_compile_definitions(
        umacapture_tests PRIVATE
        USE_CUSTOM_ASSERT
        WINVER=0x0A00
        _WIN32_WINNT=0x0A00
        _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
        # The <algorithm>/<string> vectorized search helpers (__std_find_end_1,
        # __std_find_not_ch_1, __std_find_last_not_ch_pos_1) live in the separately-compiled STL and are
        # only pulled in from the C++ runtime import lib. This minimal test target links just OpenCV's
        # opencv_world (built with an older toolset), so those symbols go unresolved at link time
        # (LNK2019). The cli/app targets avoid it by also linking onnxruntime/windowsapp. Disabling the
        # vectorized codepaths makes the test TUs use the header-inline scalar fallback instead, which is
        # behaviourally identical and needs no runtime symbol. Scoped to the test binary only.
        _USE_STD_VECTOR_ALGORITHMS=0
        # Absolute path to the repo-committed config assets, so test/chara_detail/test_config.cpp can
        # characterization-test the real shipped config without depending on the working directory.
        TEST_ASSET_CONFIG_DIR="${CMAKE_CURRENT_LIST_DIR}/../assets/config"
)

target_include_directories(
        umacapture_tests PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${CMAKE_CURRENT_LIST_DIR}/test"
        "${CMAKE_CURRENT_LIST_DIR}/vendor"
        "${CMAKE_CURRENT_LIST_DIR}/../windows"
        "${OpenCV_INCLUDE_DIRS}"
)

target_link_libraries(
        umacapture_tests PRIVATE
        "${OpenCV_LIBS}"
)

add_test(NAME umacapture_tests COMMAND umacapture_tests)

# ---------------------------------------------------------------------------
# Integration (golden) test -- drives the real umacapture_cli over recorded clips
# and diffs the recognized record.json against committed goldens. Unlike the unit
# tests above, this exercises the full ONNX/WinRT/FFmpeg pipeline, so it depends on
# local-only assets (the .notes clips and sandbox/modules ONNX models, neither of
# which is committed). The harness self-skips (exit 77) when those inputs are
# absent, so a fresh checkout / CI reports it Skipped rather than Failed.
#
# Prefer running this against a RELEASE cli: in a Debug build the pipeline's
# assert_ is live and a violated invariant pops an abort/retry/ignore dialog that
# blocks an unattended run. See test/README.md.
# ---------------------------------------------------------------------------
find_program(UV_EXECUTABLE uv)
if(UV_EXECUTABLE)
    add_test(
            NAME integration_golden
            COMMAND ${UV_EXECUTABLE} run "${CMAKE_CURRENT_LIST_DIR}/test/integration/run.py"
            --cli $<TARGET_FILE:${PROJECT_NAME}>
            --data-dir "${CMAKE_CURRENT_LIST_DIR}/../.notes"
            --assets-dir "${CMAKE_CURRENT_LIST_DIR}/../assets/config"
            --modules-dir "${CMAKE_CURRENT_LIST_DIR}/../sandbox/modules"
    )
    set_tests_properties(integration_golden PROPERTIES SKIP_RETURN_CODE 77)
else()
    message(STATUS "uv not found on PATH; the integration_golden ctest is not registered.")
endif()

add_custom_command(
        TARGET umacapture_tests POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>
        $<TARGET_FILE_DIR:umacapture_tests>
)
