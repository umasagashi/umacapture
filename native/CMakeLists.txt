cmake_minimum_required(VERSION 3.21)
project(native_cli)

set(CMAKE_CXX_STANDARD 11)

set(SOURCE_FILES
        src/cli.cpp
        src/App.h
        src/App.cpp
        )

add_executable(native_cli
        ${SOURCE_FILES})
