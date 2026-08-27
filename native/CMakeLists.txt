cmake_minimum_required(VERSION 3.21)
project(umacapture_cli)

set(CMAKE_CXX_STANDARD 17)

# spdlog's bundled {fmt} 12.x hard-requires /utf-8 on MSVC (a static_assert in fmt/base.h:
# "Unicode support requires compiling with /utf-8"). The native sources are ASCII-only, so
# this is safe, and it also makes narrow string literals genuine UTF-8. Applied globally so
# it reaches every target that pulls in spdlog.
add_compile_options(/utf-8)

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

# FFmpeg (BtbN LGPL shared, provisioned by tool/fetch_deps.py into windows/ffmpeg). Only the CLI target
# links it, for the lossless FFV1 capture recorder / replay reader (src/cv/ffv1_*). Its versioned runtime
# DLLs are copied next to the exe by the POST_BUILD step below. The Flutter Windows app target
# (windows/runner/CMakeLists.txt) deliberately does NOT link ffmpeg, since it never compiles cli.cpp; wiring
# recording into the app (via native_api.cpp) would require adding this include/lib/DLL there too.
set(FFMPEG_DIR "${CMAKE_CURRENT_LIST_DIR}/../windows/ffmpeg")

set(
        SOURCE_FILES
        src/core/cli.cpp
        src/core/native_api.cpp
        src/core/native_api_frame_shaping.cpp
        src/chara_detail/chara_detail_recognizer.cpp
        src/chara_detail/chara_detail_recognizer_models.cpp
        src/chara_detail/chara_detail_search_helpers.cpp
        src/chara_detail/chara_detail_scene_context.cpp
        src/chara_detail/chara_detail_scene_scraper.cpp
        src/chara_detail/chara_detail_scene_stitcher.cpp
        src/condition/serializer.cpp
        src/cv/ffv1_recorder.cpp
        src/cv/ffv1_reader.cpp
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
        # Compiles the diagnostic planar decode backend (cv/planar_video_decoder.h, libav) into
        # cv/video_loader.h. Deliberately on THIS TARGET ONLY: it is the only one that links libav, and the
        # only one that runs `video --color_matrix` / test/integration/run_dual_decode.py. The Flutter
        # Windows app target and the wasm build compile video_loader.h without it and get the cv::VideoCapture
        # backend alone, which is what they would use anyway.
        UMACAPTURE_WITH_PLANAR_DECODER
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
        "${FFMPEG_DIR}/include"
)

target_link_libraries(
        ${PROJECT_NAME} PRIVATE
        "${OpenCV_LIBS}"
        "${ONNX_DIR}/lib/onnxruntime.lib"
        "${FFMPEG_DIR}/lib/avformat.lib"
        "${FFMPEG_DIR}/lib/avcodec.lib"
        "${FFMPEG_DIR}/lib/avutil.lib"
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

# The FFV1 recorder/reader link libav directly, so its versioned runtime DLLs (avutil/avcodec/avformat and
# their transitive swresample/swscale) must sit next to the exe. Globbed to stay version-agnostic across
# ffmpeg bumps; these names are distinct from OpenCV's opencv_videoio_ffmpeg plugin, so they coexist.
file(GLOB FFMPEG_DLLS "${FFMPEG_DIR}/bin/av*.dll" "${FFMPEG_DIR}/bin/sw*.dll")
add_custom_command(
        TARGET ${PROJECT_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy_if_different
        ${FFMPEG_DLLS}
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
        test/chara_detail/test_factor_change_discriminator.cpp
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
        test/core/test_cli_run_report.cpp
        test/core/test_native_api_capture_session.cpp
        test/core/test_native_api_frame_shaping.cpp
        test/core/test_native_api_messages.cpp
        test/core/test_record_production_counter.cpp
        test/core/test_forwarded_frame_geometry.cpp
        test/core/test_native_api_preview.cpp
        test/core/test_pipeline_config.cpp
        test/core/test_pipeline_drain.cpp
        test/core/test_detail_crop_report_throttle.cpp
        test/core/test_frame_flow_counters.cpp
        test/core/test_frame_rate.cpp
        test/runner/test_method_argument.cpp
        test/util/test_thread_util.cpp
        test/types/test_range.cpp
        test/types/test_color.cpp
        test/types/test_shape.cpp
        test/util/test_misc.cpp
        test/util/test_io_util.cpp
        test/util/test_error_util.cpp
        test/util/test_stds.cpp
        test/util/test_json_util.cpp
        test/util/test_event_util.cpp
        test/cv/test_frame.cpp
        test/cv/test_frame_shaper.cpp
        test/cv/test_decoded_frame_to_bgr.cpp
        test/cv/test_media_timestamp.cpp
        # Compiled WITHOUT UMACAPTURE_WITH_PLANAR_DECODER, on purpose: this target must not pull in libav, and
        # that is also the configuration the Flutter Windows app compiles video_loader.h in.
        test/cv/test_video_loader.cpp
        # cv/video_frame_grabber.h is header-only and Windows/CLI-only (the wasm build links no
        # opencv_videoio, so cv::VideoCapture does not exist there -- see the header). This is its only
        # compilation, which is also what keeps it compiling.
        test/cv/test_video_frame_grabber.cpp
        test/cv/test_pane_mode.cpp
        test/cv/test_pane_mode_latch.cpp
        test/cv/test_detail_crop_calibrator.cpp
        test/cv/test_detail_crop_tracker.cpp
        test/cv/test_frame_distributor.cpp
        test/cv/test_frame_stall_watchdog.cpp
        # The Wasm module itself needs Emscripten and is compiled by no suite; its Emscripten-free wire-contract
        # headers (native/wasm/*.h) are testable here, which is why they are kept free of emscripten includes.
        test/wasm/test_pane_snapshot_token.cpp
        # tool/ is outside the web-pin digest roots and outside src/, but its header-only pieces are
        # ordinary logic and are tested here. Included as "tool/..." through the native-root include dir
        # below, the same way the wasm wire-contract headers are.
        test/tool/test_stop_file_guard.cpp
        test/tool/test_mimic_spec_parse.cpp
        src/core/native_api_frame_shaping.cpp
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
        UMACAPTURE_TESTING
        # Absolute path to the repo-committed config assets, so test/chara_detail/test_config.cpp can
        # characterization-test the real shipped config without depending on the working directory.
        TEST_ASSET_CONFIG_DIR="${CMAKE_CURRENT_LIST_DIR}/../assets/config"
)

target_include_directories(
        umacapture_tests PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${CMAKE_CURRENT_LIST_DIR}/test"
        # For "wasm/*.h" -- the Emscripten-free halves of the Wasm module's wire contracts.
        "${CMAKE_CURRENT_LIST_DIR}"
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
# FFV1 recorder/reader round-trip test. Kept as a SEPARATE target from umacapture_tests because it links
# libav (ffmpeg), which the pristine opencv-only umacapture_tests must not pull in. It reuses the same
# opencv-old-toolset STL guard (_USE_STD_VECTOR_ALGORITHMS=0). CI provisions windows/ffmpeg for this.
# ---------------------------------------------------------------------------
add_executable(
        umacapture_ffv1_tests
        test/test_main.cpp
        test/cv/test_ffv1_roundtrip.cpp
        src/cv/ffv1_recorder.cpp
        src/cv/ffv1_reader.cpp
)

target_compile_options(
        umacapture_ffv1_tests PRIVATE
        /wd4068
        /wd4819
        /wd4996
        /wd5285
)

target_compile_definitions(
        umacapture_ffv1_tests PRIVATE
        USE_CUSTOM_ASSERT
        WINVER=0x0A00
        _WIN32_WINNT=0x0A00
        _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
        _USE_STD_VECTOR_ALGORITHMS=0
)

target_include_directories(
        umacapture_ffv1_tests PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${CMAKE_CURRENT_LIST_DIR}/test"
        "${CMAKE_CURRENT_LIST_DIR}/vendor"
        "${OpenCV_INCLUDE_DIRS}"
        "${FFMPEG_DIR}/include"
)

target_link_libraries(
        umacapture_ffv1_tests PRIVATE
        "${OpenCV_LIBS}"
        "${FFMPEG_DIR}/lib/avformat.lib"
        "${FFMPEG_DIR}/lib/avcodec.lib"
        "${FFMPEG_DIR}/lib/avutil.lib"
)

add_test(NAME umacapture_ffv1_tests COMMAND umacapture_ffv1_tests)

add_custom_command(
        TARGET umacapture_ffv1_tests POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>
        $<TARGET_FILE_DIR:umacapture_ffv1_tests>
)

file(GLOB FFMPEG_TEST_DLLS "${FFMPEG_DIR}/bin/av*.dll" "${FFMPEG_DIR}/bin/sw*.dll")
add_custom_command(
        TARGET umacapture_ffv1_tests POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy_if_different
        ${FFMPEG_TEST_DLLS}
        $<TARGET_FILE_DIR:umacapture_ffv1_tests>
)

# ---------------------------------------------------------------------------
# Mimic player (test harness) -- presents a recorded FFV1 clip inside a window that impersonates the
# game window (class "UnityWndClass", title "umamusume"), so the real Windows capture path can be
# driven from a recording instead of the game. See tool/mimic_player/mimic_player.cpp.
#
# Its source lives under tool/ rather than src/ ON PURPOSE. tool/web_deps.json pins the web
# recognition core with a source digest taken over native/src, native/vendor and native/wasm; a new
# .cpp under src/ would change that digest and force a re-pin (which needs an emsdk toolchain) even
# though nothing the wasm module compiles has changed. tool/ is outside those roots, so a
# Windows-only test fixture cannot invalidate the web pin. It also cannot reach the wasm build,
# which compiles src/ only.
#
# Decoding is its own pull-based, seekable reader (tool/mimic_player/clip_decoder.h) because the
# player has to pause, step and seek, which src/cv/ffv1_reader.h's single forward run() cannot do.
# It reuses the header-only src/cv/ffv1_avio.h and src/cv/ffv1_pixfmt.h, so the wide-path AVIO
# bridge and the BGR0 <-> BGR mapping stay shared with the recorder and with `replay`; nothing in
# src/ is compiled into this target and `replay` is unaffected.
# ---------------------------------------------------------------------------
add_executable(
        umacapture_mimic_player
        tool/mimic_player/mimic_player.cpp
        tool/mimic_player/clip_decoder.h
        tool/mimic_player/spec_parse.h
        tool/stop_file_guard.h
)

target_compile_options(
        umacapture_mimic_player PRIVATE
        /wd4068
        /wd4819
        /wd4996
)

target_compile_definitions(
        umacapture_mimic_player PRIVATE
        USE_CUSTOM_ASSERT
        WINVER=0x0A00
        _WIN32_WINNT=0x0A00
        _SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS
        # Same opencv-old-toolset STL guard the other opencv-only targets need (see umacapture_tests).
        _USE_STD_VECTOR_ALGORITHMS=0
)

target_include_directories(
        umacapture_mimic_player PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src"
        # For "stop_file_guard.h", the --stop-file clearing rule this shares with `capture` (which
        # reaches it through the same tool/ include dir on the CLI target).
        "${CMAKE_CURRENT_LIST_DIR}/tool"
        "${CMAKE_CURRENT_LIST_DIR}/vendor"
        "${OpenCV_INCLUDE_DIRS}"
        "${FFMPEG_DIR}/include"
)

target_link_libraries(
        umacapture_mimic_player PRIVATE
        "${OpenCV_LIBS}"
        "${FFMPEG_DIR}/lib/avformat.lib"
        "${FFMPEG_DIR}/lib/avcodec.lib"
        "${FFMPEG_DIR}/lib/avutil.lib"
        user32.lib
        gdi32.lib
        dwmapi.lib
        # Presentation is a DXGI flip-model swap chain, not GDI: only that is atomic enough for the
        # capture never to observe a half-updated frame. See present() in mimic_player.cpp.
        d3d11.lib
        dxgi.lib
)

add_custom_command(
        TARGET umacapture_mimic_player POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>
        $<TARGET_FILE_DIR:umacapture_mimic_player>
)

file(GLOB FFMPEG_MIMIC_DLLS "${FFMPEG_DIR}/bin/av*.dll" "${FFMPEG_DIR}/bin/sw*.dll")
add_custom_command(
        TARGET umacapture_mimic_player POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy_if_different
        ${FFMPEG_MIMIC_DLLS}
        $<TARGET_FILE_DIR:umacapture_mimic_player>
)

# ---------------------------------------------------------------------------
# Integration (golden) tests -- drive the real umacapture_cli over recorded clips
# and diff the recognized record.json against committed goldens. Unlike the unit
# tests above, this exercises the full ONNX/WinRT/FFmpeg pipeline, so it depends on
# local-only assets (the testdata/clips/golden clips and sandbox/modules ONNX models,
# neither of which is committed). Every case self-skips (exit 77) when its inputs are absent,
# so a fresh checkout / CI reports Skipped rather than Failed.
#
# ONE CTEST PER CASE, deliberately. ctest suppresses the stdout of a test that
# passes or skips (--output-on-failure only opens it up on failure), so a single
# aggregate test could not tell "11 of 11 goldens ran" apart from "3 ran, 8 were
# skipped" -- both printed one identical `Passed` line, and the difference was
# reachable only by knowing to pass -V. Splitting the manifest into one test per
# case moves that information into test *identity and status*, which ctest always
# prints: a case with no clip is its own `***Skipped` line and is named again in
# the "tests did not run" block. `ctest -N` then lists the full expected set, and
# `-R integration_golden` still selects all of them plus the coverage test.
#
# Prefer running these against a RELEASE cli: in a Debug build the pipeline's
# assert_ is live and a violated invariant pops an abort/retry/ignore dialog that
# blocks an unattended run. See test/README.md.
# ---------------------------------------------------------------------------
find_program(UV_EXECUTABLE uv)
if(UV_EXECUTABLE)
    set(INTEGRATION_DIR "${CMAKE_CURRENT_LIST_DIR}/test/integration")
    set(INTEGRATION_CASES "${INTEGRATION_DIR}/cases.json")

    # The case list is read at configure time, so a manifest edit must re-run configure --
    # otherwise a new case would sit unregistered in an already-configured tree and its
    # coverage would go missing exactly the way this split is meant to prevent.
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${INTEGRATION_CASES}")

    set(
            INTEGRATION_ARGS
            ${UV_EXECUTABLE} run "${INTEGRATION_DIR}/run.py"
            --cli $<TARGET_FILE:${PROJECT_NAME}>
            --cases "${INTEGRATION_CASES}"
            --data-dir "${CMAKE_CURRENT_LIST_DIR}/../testdata/clips/golden"
            --assets-dir "${CMAKE_CURRENT_LIST_DIR}/../assets/config"
            --modules-dir "${CMAKE_CURRENT_LIST_DIR}/../sandbox/modules"
    )

    file(READ "${INTEGRATION_CASES}" INTEGRATION_CASES_JSON)
    string(JSON INTEGRATION_CASE_COUNT LENGTH "${INTEGRATION_CASES_JSON}" cases)
    set(INTEGRATION_TESTS "")
    if(INTEGRATION_CASE_COUNT GREATER 0)
        math(EXPR INTEGRATION_LAST_CASE "${INTEGRATION_CASE_COUNT} - 1")
        foreach(case_index RANGE ${INTEGRATION_LAST_CASE})
            string(JSON case_name GET "${INTEGRATION_CASES_JSON}" cases ${case_index} name)
            # A case states what run.py must assert either as `golden` (a committed record baseline) or as
            # `expect_records` (the count and the announcement a zero-record clip owes -- such a clip carries
            # no baseline on purpose, see cases.json). A case with NEITHER has nothing for this suite:
            # registering it anyway would add a test that is Skipped forever, and ctest hides the stdout of a
            # skipped test -- so it would be indistinguishable from the missing-clip skip this per-case split
            # exists to make visible. Mirrors run.py's has_expectation(); the two must move together.
            string(JSON case_golden ERROR_VARIABLE case_golden_error
                   GET "${INTEGRATION_CASES_JSON}" cases ${case_index} golden)
            string(JSON case_expect_records ERROR_VARIABLE case_expect_records_error
                   GET "${INTEGRATION_CASES_JSON}" cases ${case_index} expect_records)
            if(case_golden_error STREQUAL "NOTFOUND" OR case_expect_records_error STREQUAL "NOTFOUND")
                add_test(NAME integration_golden.${case_name} COMMAND ${INTEGRATION_ARGS} --only ${case_name})
                list(APPEND INTEGRATION_TESTS integration_golden.${case_name})
            endif()
        endforeach()
    else()
        message(WARNING "${INTEGRATION_CASES} lists no cases; no golden ctest is registered.")
    endif()

    # Runs no pipeline: it resolves the inputs only, and turns "this machine can exercise
    # fewer goldens than it could last time" into a failing test instead of a quieter set of
    # Skipped lines. Harmless where the assets never existed (it skips with them), so CI is
    # unaffected. See run.py --coverage.
    add_test(NAME integration_golden_coverage COMMAND ${INTEGRATION_ARGS} --coverage)
    list(APPEND INTEGRATION_TESTS integration_golden_coverage)

    # The coverage alarm's own test, and the only integration test here that is NOT conditional on
    # local-only assets: --coverage decides everything from file existence, so its whole decision
    # table can be driven against a synthetic manifest inside a TemporaryDirectory. It therefore runs
    # in CI, where every other test in this block skips.
    #
    # It exists because integration_golden_coverage cannot check itself: it is registered against the
    # real clips and the real gitignored baseline, so exercising its failure paths there would mean
    # damaging the record it protects. Measured before the fix it covers: a baseline file truncated
    # mid-write was read as "no record", so the run rewrote it from the current set and exited 0 --
    # the same lost clip that exits 1 with an intact baseline, silently lowering the high-water mark.
    #
    # Deliberately NOT given SKIP_RETURN_CODE or the integration_cli RESOURCE_LOCK: it spawns no cli,
    # and there is no machine on which it is allowed to skip.
    add_test(NAME integration_coverage_selftest
             COMMAND ${UV_EXECUTABLE} run "${INTEGRATION_DIR}/test_run_coverage.py")
    set_tests_properties(integration_coverage_selftest PROPERTIES LABELS "integration;golden")

    # Dual-decode equivalence: the same clip run through `video --color_matrix bt601` and
    # `--color_matrix bt709`, requiring one identical record set. See test/integration/run_dual_decode.py
    # for what that measures and why the bt601 run is also diffed against the golden.
    #
    # It reads the SAME manifest and needs no coverage test of its own: integration_golden_coverage walks
    # every case in the manifest and only asks whether its clip is present, so it polices the clip set for
    # this suite too -- including the one case that has no golden and therefore no integration_golden test.
    # What the two suites do not share is eligibility, so this registration stays UNCONDITIONAL and the
    # runner decides: a `replay` case is FFV1, which stores BGR0 and applies no matrix, and a case whose
    # manifest entry says `expect_records: 0` would compare two empty sets. Both skip here with their reason
    # printed, rather than being deregistered -- ineligibility that the manifest can state is a property of
    # the case, and `ctest -N` listing one dual-decode test per case is how the suite's ceiling stays visible.
    # (The golden registration above is conditional for the opposite reason: a case with no expectation at
    # all has nothing that suite could ever assert, so its test would never be more than a Skipped line.)
    #
    # Registered per case for the same reason the goldens are, and it takes TWO full pipeline runs per case,
    # so it carries the same RESOURCE_LOCK.
    set(DUAL_DECODE_ARGS
            ${UV_EXECUTABLE} run "${INTEGRATION_DIR}/run_dual_decode.py"
            --cli $<TARGET_FILE:${PROJECT_NAME}>
            --cases "${INTEGRATION_CASES}"
            --data-dir "${CMAKE_CURRENT_LIST_DIR}/../testdata/clips/golden"
            --assets-dir "${CMAKE_CURRENT_LIST_DIR}/../assets/config"
            --modules-dir "${CMAKE_CURRENT_LIST_DIR}/../sandbox/modules"
    )
    set(DUAL_DECODE_TESTS "")
    if(INTEGRATION_CASE_COUNT GREATER 0)
        foreach(case_index RANGE ${INTEGRATION_LAST_CASE})
            string(JSON case_name GET "${INTEGRATION_CASES_JSON}" cases ${case_index} name)
            add_test(NAME integration_dual_decode.${case_name} COMMAND ${DUAL_DECODE_ARGS} --only ${case_name})
            list(APPEND DUAL_DECODE_TESTS integration_dual_decode.${case_name})
        endforeach()
        set_tests_properties(
                ${DUAL_DECODE_TESTS} PROPERTIES
                SKIP_RETURN_CODE 77
                LABELS "integration;dual_decode"
                RESOURCE_LOCK integration_cli
        )
    endif()

    set_tests_properties(
            ${INTEGRATION_TESTS} PROPERTIES
            SKIP_RETURN_CODE 77
            LABELS "integration;golden"
            # Each case spawns the full ONNX recognizer; `ctest -j` must not run several at once.
            RESOURCE_LOCK integration_cli
    )
else()
    message(STATUS "uv not found on PATH; the integration_golden ctests are not registered.")
endif()

add_custom_command(
        TARGET umacapture_tests POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>
        $<TARGET_FILE_DIR:umacapture_tests>
)
