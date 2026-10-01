#pragma once

#include <cassert>  // _wassert, used by the assert_ macro below
#include <chrono>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <system_error>

#if defined(_WIN32)
#include <io.h>  // _commit
#elif !defined(__EMSCRIPTEN__)
#include <unistd.h>  // fsync
#endif

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

#if defined(__ANDROID__) || defined(__EMSCRIPTEN__)
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

// Both helpers open in binary mode on purpose. Text mode is a no-op on POSIX (Android, emscripten) but on
// Windows the CRT translates between "\n" and "\r\n", so the same call would return different bytes per
// platform: a write would emit CRLF into files that are checked in and diffed as LF, and a read would strip
// the CR back out, hiding the fact from any round-trip check that goes through these two functions.
inline std::string read(const std::filesystem::path &path) {
    std::ifstream file(path, std::ios::in | std::ios::binary);
    if (!file) {
        throw std::runtime_error("io_util::read: failed to open: " + path.string());
    }
    std::ostringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

inline void write(const std::filesystem::path &path, const std::string &text) {
    std::ofstream file(path, std::ios::out | std::ios::binary);
    if (!file) {
        throw std::runtime_error("io_util::write: failed to open: " + path.string());
    }
    file << text;
    file.flush();
    if (!file) {
        throw std::runtime_error("io_util::write: failed to write: " + path.string());
    }
}

namespace detail {

// Writes `text` to `path` in binary mode and has the operating system put it on the disk before returning.
// std::ofstream::flush only hands the bytes to the OS, which can still lose them to a power cut; the file
// descriptor that _commit (Windows: FlushFileBuffers) and fsync need is reachable only through a FILE*.
inline void writeAndSync(const std::filesystem::path &path, const std::string &text) {
#ifdef _WIN32
    std::FILE *file = nullptr;
    if (_wfopen_s(&file, path.c_str(), L"wb") != 0) {
        file = nullptr;
    }
#else
    std::FILE *file = std::fopen(path.c_str(), "wb");
#endif
    if (file == nullptr) {
        throw std::runtime_error("io_util::replace: failed to open: " + path.string());
    }
    bool ok = std::fwrite(text.data(), 1, text.size(), file) == text.size() && std::fflush(file) == 0;
#if defined(_WIN32)
    ok = ok && _commit(_fileno(file)) == 0;
#elif !defined(__EMSCRIPTEN__)
    ok = ok && fsync(fileno(file)) == 0;
#endif
    // No sync under Emscripten. Its fsync is the one file call proxied to the main runtime thread
    // asynchronously: the calling pthread waits until that thread returns to its event loop, so a
    // recognizer writing here while the worker's main thread is blocked joining it (stop) would never
    // return. The file is in MEMFS, which has nothing to sync and does not outlive the page.
    ok = std::fclose(file) == 0 && ok;
    if (!ok) {
        throw std::runtime_error("io_util::replace: failed to write: " + path.string());
    }
}

}  // namespace detail

// Replaces the file at `path` with `text` so that a crash at any point leaves the old file or the new one whole,
// never a torn one: the bytes go to `<path>.part` beside it, reach the disk, and that file is then renamed over
// `path`. std::filesystem::rename replaces an existing target: POSIX rename does, and MSVC's implements it as
// MoveFileExW with MOVEFILE_REPLACE_EXISTING; the staging file sits in the same directory, so the move is a
// rename on one volume and never a copy. On failure the staging file is removed and `path` is left as it was.
//
// For record.json, which the app moves to quarantine when it cannot decode it, so a write torn by a crash would
// take a listed record off the list. The wasm build writes into MEMFS, where nothing outlives the page and the
// web app makes the result durable itself (it publishes the record directory it reads back); the staging and
// the rename hold there too, and only the sync is skipped (see writeAndSync).
inline void replace(const std::filesystem::path &path, const std::string &text) {
    auto staging = path;
    staging += ".part";
    try {
        detail::writeAndSync(staging, text);
        std::filesystem::rename(staging, path);
    } catch (...) {
        std::error_code ignored;
        std::filesystem::remove(staging, ignored);
        throw;
    }
}

// Injectable directory-creation / removal operations. The Dart side overrides these so directory
// operations can be routed through platform-specific storage (e.g. Android scoped storage) instead of
// touching std::filesystem directly. Defaults perform the real filesystem operations, so the CLI, unit
// tests, and builders can construct pipeline components without wiring anything up. Both members must
// stay callable (never empty) -- the defaults guarantee that unless a caller overwrites one with an
// empty std::function.
struct DirectoryHooks {
    std::function<void(const std::filesystem::path &)> mkdir =
        [](const std::filesystem::path &path) { std::filesystem::create_directories(path); };
    std::function<void(const std::filesystem::path &)> rmdir =
        [](const std::filesystem::path &path) { std::filesystem::remove_all(path); };
};

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
