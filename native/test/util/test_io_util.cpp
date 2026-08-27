// Byte-level tests for uma::io_util::read / uma::io_util::write.
//
// WHAT THESE GUARD. Both helpers open their stream with std::ios::binary. On Windows the CRT
// otherwise translates newlines in *both* directions: a text-mode write expands every "\n" to
// "\r\n", and a text-mode read collapses "\r\n" back to "\n". io_util::write emits the scene
// definitions that `umacapture_cli build` checks in, plus record.json at runtime, so a text-mode
// write puts CR into files the repo diffs (and the Dart side writes) as LF.
//
// WHY NO ROUND TRIP. A test that writes through io_util::write and reads back through
// io_util::read cannot see this: the two translations are exact inverses, so the round trip
// returns the input unchanged in either mode and stays green. That is not hypothetical -- the
// CLI's own build round-trip check went through this pair and masked the defect for years.
// Every case below therefore keeps io_util on exactly one side of the comparison and a raw
// binary std::fstream on the other, so the assertion is against the bytes on disk.
//
// PLATFORM NOTE. The CRT newline translation exists only on Windows; on POSIX targets (Android,
// emscripten) text mode and binary mode are the same thing and these cases are tautologically
// green -- they assert a real invariant there, but cannot fail. That costs no coverage today
// because umacapture_tests is a Windows/MSVC-only target (native/CMakeLists.txt links OpenCV's
// Windows prebuilt, and the suite is run on windows-latest in CI), so Windows is the only
// platform that ever compiles this file. If the suite is ever ported, this file is one of the
// ones whose signal does not come along.

#include <doctest/doctest.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <system_error>

#include "util/misc.h"

namespace uma::io_util {
namespace {

// Removes its file on destruction, so the temp file is cleaned up on every exit path -- including a
// failed REQUIRE (doctest throws) and a throw out of io_util itself. The noexcept error_code
// overload is required: this destructor can run during stack unwinding.
class ScopedTempFile {
public:
    explicit ScopedTempFile(const char *name)
        : path_(std::filesystem::temp_directory_path() / name) {
        remove();  // A leftover from a previously crashed run must not be mistaken for our output.
    }

    ~ScopedTempFile() { remove(); }

    ScopedTempFile(const ScopedTempFile &) = delete;
    ScopedTempFile &operator=(const ScopedTempFile &) = delete;

    [[nodiscard]] const std::filesystem::path &path() const { return path_; }

private:
    void remove() const {
        std::error_code ignored;
        std::filesystem::remove(path_, ignored);
    }

    std::filesystem::path path_;
};

// Reads the file as raw bytes, bypassing io_util::read entirely.
std::string readRawBytes(const std::filesystem::path &path) {
    std::ifstream file(path, std::ios::in | std::ios::binary);
    REQUIRE_MESSAGE(file.is_open(), "failed to open for raw read: ", path.string());
    return std::string(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}

// Writes raw bytes, bypassing io_util::write entirely.
void writeRawBytes(const std::filesystem::path &path, const std::string &bytes) {
    std::ofstream file(path, std::ios::out | std::ios::binary | std::ios::trunc);
    REQUIRE_MESSAGE(file.is_open(), "failed to open for raw write: ", path.string());
    file.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    file.flush();
    REQUIRE(static_cast<bool>(file));
}

// CR and LF are invisible in a doctest failure message, and a CR alone rewinds the terminal
// cursor, so a mismatch would print as garbage. Compare the escaped forms instead.
std::string escaped(const std::string &bytes) {
    std::string out;
    for (const char c : bytes) {
        switch (c) {
            case '\r': out += "\\r"; break;
            case '\n': out += "\\n"; break;
            default: out += c; break;
        }
    }
    return out;
}

TEST_CASE("io_util::write puts the exact bytes it was given on disk") {
    const ScopedTempFile temp("umacapture_io_util_write_lf.tmp");
    const std::string text = "{\n  \"a\": 1\n}\n";

    write(temp.path(), text);

    // Read back with a raw binary stream, NOT io_util::read: a text-mode read would undo a
    // text-mode write and this case would pass while the file on disk was CRLF.
    const std::string on_disk = readRawBytes(temp.path());
    CHECK(escaped(on_disk) == escaped(text));
    CHECK(on_disk.find('\r') == std::string::npos);
    CHECK(std::filesystem::file_size(temp.path()) == text.size());
}

TEST_CASE("io_util::write does not double the CR of text that already holds CRLF") {
    const ScopedTempFile temp("umacapture_io_util_write_crlf.tmp");
    // Second discriminator, independent of the LF case: a text-mode write expands the "\n" of an
    // existing "\r\n" too, so this lands as "\r\r\n" rather than being left alone.
    const std::string text = "first\r\nsecond\r\n";

    write(temp.path(), text);

    const std::string on_disk = readRawBytes(temp.path());
    CHECK(escaped(on_disk) == escaped(text));
    CHECK(on_disk.find("\r\r") == std::string::npos);
}

TEST_CASE("io_util::read hands back the bytes that are on disk, CR included") {
    const ScopedTempFile temp("umacapture_io_util_read_crlf.tmp");
    // Written with a raw binary stream, NOT io_util::write, so what is on disk is a fact of this
    // test rather than a product of the function under test.
    const std::string on_disk = "first\r\nsecond\r\n";
    writeRawBytes(temp.path(), on_disk);

    const std::string result = read(temp.path());

    // A text-mode read collapses each "\r\n" to "\n" on Windows, i.e. hands back 13 bytes for the
    // 15 that exist. Callers (json_util, the CLI's build round trip) would then never learn that
    // the file they just parsed carried CR.
    CHECK(escaped(result) == escaped(on_disk));
    CHECK(result.size() == on_disk.size());
}

TEST_CASE("io_util::read preserves a lone CR and a trailing CR") {
    const ScopedTempFile temp("umacapture_io_util_read_lone_cr.tmp");
    // A bare CR is not part of any newline pair, so it survives text mode too; the trailing CR at
    // the very end of the file is the interesting one, since it sits where a "\r\n" would begin.
    const std::string on_disk = "a\rb\nc\r";
    writeRawBytes(temp.path(), on_disk);

    CHECK(escaped(read(temp.path())) == escaped(on_disk));
}

TEST_CASE("io_util::read reports a missing file instead of returning empty") {
    // Guards the failure path the binary-mode change touches the constructor of: the stream is
    // opened with two flags now, and a silent failure here would turn a missing config into an
    // empty string and a confusing parse error much further downstream.
    const ScopedTempFile temp("umacapture_io_util_absent.tmp");
    REQUIRE_FALSE(std::filesystem::exists(temp.path()));
    CHECK_THROWS_AS(read(temp.path()), std::runtime_error);
}

}  // namespace
}  // namespace uma::io_util
