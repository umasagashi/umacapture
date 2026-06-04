#pragma once

#include <chrono>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

namespace uma::chrono_util {

using time_unit = std::chrono::milliseconds;

inline std::chrono::system_clock::time_point local_now() {
    return std::chrono::system_clock::now();
}

inline uint64_t to_timestamp(std::chrono::system_clock::time_point tp) {
    return std::chrono::duration_cast<time_unit>(tp.time_since_epoch()).count();
}

template<typename T, typename S>
auto ms(std::chrono::duration<T, S> duration) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(duration).count();
}

// Elapsed time between two frame timestamps, safe against a non-monotonic clock. Live-capture frame
// timestamps come from system_clock (see local_now), which can step backward (NTP correction, manual
// change). A plain `now - since` is an unsigned subtraction that would wrap to a huge value on a backward
// step and instantly trip any timeout. When `since` is ahead of `now`, restart the window at `now` (by
// reference) and report zero elapsed, so the debounce simply starts over instead of firing prematurely.
inline uint64_t monotonicElapsed(uint64_t now, uint64_t &since) {
    if (now < since) {
        since = now;
    }
    return now - since;
}

inline std::string to_datetime_string(std::chrono::system_clock::time_point tp) {
    const time_t unix_ts = std::chrono::system_clock::to_time_t(tp);
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
