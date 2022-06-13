#pragma once

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

namespace uma {

namespace chrono {

inline uint64_t timestamp() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}

}  // namespace chrono

namespace io {

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

}  // namespace io

}

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
