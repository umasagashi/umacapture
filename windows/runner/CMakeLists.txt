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

find_package(OpenCV REQUIRED)
message(STATUS "You don't need to add OpenCV to your PATH, but you need to copy dll files into build directory.")

apply_standard_settings(${BINARY_NAME})

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

target_compile_definitions(
        ${BINARY_NAME} PRIVATE
        NOMINMAX
        USE_CUSTOM_ASSERT
)

target_link_libraries(
        ${BINARY_NAME} PRIVATE
        flutter
        flutter_wrapper_app
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

        # OpenCV
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>

        # VC++ Redistributable
        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/vcruntime140d.dll>
        $<$<CONFIG:Release>:${SYSTEM_DLL_DIR}/vcruntime140.dll>

        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/vcruntime140_1d.dll>
        $<$<CONFIG:Release>:${SYSTEM_DLL_DIR}/vcruntime140_1.dll>

        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/msvcp140d.dll>
        $<$<CONFIG:Release>:${SYSTEM_DLL_DIR}/msvcp140.dll>

        $<$<CONFIG:Debug>:${SYSTEM_DLL_DIR}/concrt140d.dll>
        $<$<CONFIG:Release>:${SYSTEM_DLL_DIR}/concrt140.dll>

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
