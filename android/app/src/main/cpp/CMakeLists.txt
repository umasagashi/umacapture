
# For more information about using CMake with Android Studio, read the
# documentation: https://d.android.com/studio/projects/add-native-code.html

# Sets the minimum version of CMake required to build the native library.

cmake_minimum_required(VERSION 3.18.1)

# Declares and names the project.
project(umasagashi_app)

set(CMAKE_CXX_STANDARD 17)

set(NATIVE_EXTENSION_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../../native")
set(ONNX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../onnxruntime")

set(SOURCE_FILES
        umasagashi_app.cpp
        "${NATIVE_EXTENSION_DIR}/src/core/native_api.cpp"
        "${NATIVE_EXTENSION_DIR}/src/condition/serializer.cpp"
        )

# Creates and names a library, sets it as either STATIC
# or SHARED, and provides the relative paths to its source code.
# You can define multiple libraries, and CMake builds them for you.
# Gradle automatically packages shared libraries with your APK.

add_library( # Sets the name of the library.
        ${PROJECT_NAME}

        # Sets the library as a shared library.
        SHARED

        # Provides a relative path to your source file(s).
        ${SOURCE_FILES})

target_include_directories(${PROJECT_NAME} PRIVATE
        "${NATIVE_EXTENSION_DIR}/src"
        "${NATIVE_EXTENSION_DIR}/vendor"
        "${ONNX_DIR}/headers"
        )

target_compile_definitions(${PROJECT_NAME} PRIVATE
        SPDLOG_ACTIVE_LEVEL=SPDLOG_LEVEL_TRACE
        )

set(OpenCV_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../../sdk/native/jni")

find_package(OpenCV REQUIRED)

if (OpenCV_FOUND)
    target_include_directories(${PROJECT_NAME} PUBLIC ${OpenCV_INCLUDE_DIRS})
    target_link_libraries(${PROJECT_NAME} ${OpenCV_LIBS})
endif ()


# Searches for a specified prebuilt library and stores the path as a
# variable. Because CMake includes system libraries in the search path by
# default, you only need to specify the name of the public NDK library
# you want to add. CMake verifies that the library exists before
# completing its build.

find_library( # Sets the name of the path variable.
        log-lib

        # Specifies the name of the NDK library that
        # you want CMake to locate.
        log)

# Specifies libraries CMake should link to your target library. You
# can link multiple libraries, such as libraries you define in this
# build script, prebuilt third-party libraries, or system libraries.

target_link_libraries( # Specifies the target library.
        ${PROJECT_NAME}

        # Links the target library to the log library
        # included in the NDK.
        ${log-lib}

        "${ONNX_DIR}/jni/${ANDROID_NDK_ABI_NAME}/libonnxruntime.so"
        )
