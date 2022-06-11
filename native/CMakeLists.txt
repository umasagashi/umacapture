cmake_minimum_required(VERSION 3.21)
project(umasagashi_cli)

set(CMAKE_CXX_STANDARD 17)

set(OpenCV_DIR "${CMAKE_CURRENT_LIST_DIR}/../windows/opencv/build")
set(OpenCV_VERSION "455")
set(OpenCV_ARCH "x64")
set(OpenCV_RUNTIME "vc15")
set(OpenCV_DLL_NAME "opencv_world")
set(OpenCV_DLL_PREFIX "${OpenCV_DIR}/${OpenCV_ARCH}/${OpenCV_RUNTIME}/bin/${OpenCV_DLL_NAME}${OpenCV_VERSION}")
set(OpenCV_DEBUG_DLL "${OpenCV_DLL_PREFIX}d.dll")
set(OpenCV_RELEASE_DLL "${OpenCV_DLL_PREFIX}.dll")

set(SOURCE_FILES
        src/cli.cpp
        src/native_api.cpp
        src/condition/serializer.cpp
        src/util/logger_util.cpp
        )

add_executable(${PROJECT_NAME}
        ${SOURCE_FILES})

target_compile_options(${PROJECT_NAME} PRIVATE /wd4068)

target_include_directories(${PROJECT_NAME} PRIVATE
        "${CMAKE_CURRENT_LIST_DIR}/src"
        "${CMAKE_CURRENT_LIST_DIR}/vendor"
        "${CMAKE_CURRENT_LIST_DIR}/../windows"
        "${CMAKE_CURRENT_LIST_DIR}/tool"
        )

target_compile_definitions(${PROJECT_NAME} PRIVATE
        USE_CUSTOM_ASSERT
        )

find_package(OpenCV REQUIRED)
message(STATUS "You don't need to add OpenCV to your PATH, but you need to copy dll files into build directory.")

target_include_directories(${PROJECT_NAME} PRIVATE "${OpenCV_INCLUDE_DIRS}")
target_link_libraries(${PROJECT_NAME} PRIVATE "${OpenCV_LIBS}")

add_custom_command(
        TARGET ${PROJECT_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E
        copy
        $<$<CONFIG:Debug>:${OpenCV_DEBUG_DLL}>
        $<$<CONFIG:Release>:${OpenCV_RELEASE_DLL}>
        $<TARGET_FILE_DIR:${PROJECT_NAME}>
)
