#pragma once

#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

namespace uma::chrono_util {

using time_unit = std::chrono::milliseconds;

inline uint64_t timestamp() {
    return std::chrono::duration_cast<time_unit>(std::chrono::system_clock::now().time_since_epoch()).count();
}

inline std::string utc() {
    const time_t unix_ts = std::time(nullptr);
    std::tm datetime{};

#if defined(__ANDROID__)
    localtime_r(&unix_ts, &datetime);
#else
    localtime_s(&datetime, &unix_ts);
#endif

    std::ostringstream stream;
    stream << std::put_time(&datetime, "%FT%T%z");
    return stream.str();
}

}  // namespace uma::chrono_util

namespace uma::io_util {

inline std::string read(const std::filesystem::path &path) {
    std::ifstream file(path);
    std::ostringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

inline void write(const std::filesystem::path &path, const std::string &text) {
    std::ofstream file;
    file.open(path, std::ios::out);
    file << text;
    file.close();
}

}  // namespace uma::io_util

#ifdef NDEBUG
#define assert_(expression) ((void) 0)
#else
#ifdef USE_CUSTOM_ASSERT
inline void assert_impl(wchar_t const *message, wchar_t const *file, unsigned line) {
    _wassert(message, file, line);
}
#define assert_(expression) \
    (void) ((!!(expression)) || (assert_impl(_CRT_WIDE(#expression), _CRT_WIDE(__FILE__), (unsigned) (__LINE__)), 0))
#else
#define assert_(expression) assert(expression)
#endif
#endif
