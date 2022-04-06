cmake_minimum_required(VERSION 3.21)
project(native_cli)

set(CMAKE_CXX_STANDARD 11)

set(OpenCV_DIR "${CMAKE_CURRENT_LIST_DIR}/../windows/opencv/build")
message(STATUS ${OpenCV_DIR})
find_package(OpenCV REQUIRED)
message(STATUS "You don't need to add OpenCV to your PATH, but you need to copy dll files into build directory.")
include_directories(${OpenCV_INCLUDE_DIRS})

set(SOURCE_FILES
        src/cli.cpp
        src/App.h
        src/App.cpp
        )

add_executable(native_cli
        ${SOURCE_FILES})
