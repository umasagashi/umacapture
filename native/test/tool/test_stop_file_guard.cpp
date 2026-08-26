// Tests for the `--stop-file` startup clearing shared by `capture` (src/core/cli.cpp) and the mimic
// player (tool/mimic_player/mimic_player.cpp).
//
// WHY THIS IS WORTH A SUITE OF ITS OWN. Both callers used to clear the sentinel with an
// unconditional `std::filesystem::remove(path, ec)`: whatever the path named was deleted, without
// inspection and without a word either way, because `ec` was discarded. The paths those two options
// are handed every day live beside recordings of live game sessions, most of which cannot be
// produced again. So the property under test is not "the sentinel gets cleared" -- that was never in
// doubt -- it is "NOTHING ELSE IS EVER DELETED", and that is a property only a negative test can
// hold: the earlier code passed every test that only asked whether the sentinel went away.
//
// Everything here happens inside a freshly created directory under the OS temp directory, and the
// test refuses to run if it did not create that directory itself. No case names a path outside it.

#include <doctest/doctest.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

#include "tool/stop_file_guard.h"

namespace uma::tool {
namespace {

// A directory this test created and therefore owns. `create_directory` returning false means the
// name was already taken, which is the one case where cleaning up afterwards would not be ours to do.
class OwnedTempDir {
public:
    explicit OwnedTempDir(const std::string &name): path_(std::filesystem::temp_directory_path() / name) {
        std::error_code ec;
        std::filesystem::remove_all(path_, ec);  // a leftover from an aborted earlier run of this test
        REQUIRE(std::filesystem::create_directory(path_));
    }

    ~OwnedTempDir() {
        std::error_code ec;
        std::filesystem::remove_all(path_, ec);
    }

    OwnedTempDir(const OwnedTempDir &) = delete;
    OwnedTempDir &operator=(const OwnedTempDir &) = delete;

    [[nodiscard]] std::filesystem::path child(const std::string &name) const { return path_ / name; }

private:
    std::filesystem::path path_;
};

void write(const std::filesystem::path &path, const std::string &content) {
    std::ofstream out(path, std::ios::binary);
    out << content;
    out.close();
    REQUIRE(std::filesystem::exists(path));
}

[[nodiscard]] std::string read(const std::filesystem::path &path) {
    std::ifstream in(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

TEST_CASE("a path with nothing at it is the ordinary case and needs no report") {
    const OwnedTempDir dir("umacapture_stop_file_guard_absent");
    const auto path = dir.child("stop.flag");

    const auto result = clearStaleStopFile(path);

    CHECK(result.clearance == StopFileClearance::Absent);
    CHECK(result.reason.empty());
    CHECK_FALSE(std::filesystem::exists(path));
}

TEST_CASE("an empty regular file is a stale sentinel and is cleared") {
    const OwnedTempDir dir("umacapture_stop_file_guard_stale");
    const auto path = dir.child("stop.flag");
    write(path, "");
    REQUIRE(std::filesystem::file_size(path) == 0);

    const auto result = clearStaleStopFile(path);

    CHECK(result.clearance == StopFileClearance::Cleared);
    CHECK_FALSE(result.reason.empty());
    CHECK_FALSE(std::filesystem::exists(path));
}

// THE CASE THE OLD CODE FAILED. A mistyped --stop-file that lands on a recording must come back as a
// refusal with the bytes untouched, not as a deletion.
TEST_CASE("a file that holds bytes is refused and left byte-identical") {
    const OwnedTempDir dir("umacapture_stop_file_guard_recording");
    const auto path = dir.child("live_session.mkv");
    const std::string content = "not really matroska, but not empty either";
    write(path, content);

    const auto result = clearStaleStopFile(path);

    CHECK(result.clearance == StopFileClearance::Refused);
    CHECK_FALSE(result.reason.empty());
    REQUIRE(std::filesystem::exists(path));
    CHECK(read(path) == content);
}

// One byte is enough: the rule is "carries no content", not "is small".
TEST_CASE("a one-byte file is refused") {
    const OwnedTempDir dir("umacapture_stop_file_guard_one_byte");
    const auto path = dir.child("stop.flag");
    write(path, "x");

    const auto result = clearStaleStopFile(path);

    CHECK(result.clearance == StopFileClearance::Refused);
    CHECK(std::filesystem::exists(path));
    CHECK(read(path) == "x");
}

// An EMPTY directory is the dangerous one: std::filesystem::remove deletes it happily, so "empty"
// alone would have let this through. The guard asks for a regular file as well.
TEST_CASE("an empty directory is refused, not removed") {
    const OwnedTempDir dir("umacapture_stop_file_guard_empty_dir");
    const auto path = dir.child("captures");
    REQUIRE(std::filesystem::create_directory(path));

    const auto result = clearStaleStopFile(path);

    CHECK(result.clearance == StopFileClearance::Refused);
    CHECK(std::filesystem::is_directory(path));
}

TEST_CASE("a directory with contents is refused, and its contents survive") {
    const OwnedTempDir dir("umacapture_stop_file_guard_full_dir");
    const auto path = dir.child("captures");
    REQUIRE(std::filesystem::create_directory(path));
    write(path / "run.mkv", "pixels");

    const auto result = clearStaleStopFile(path);

    CHECK(result.clearance == StopFileClearance::Refused);
    CHECK(std::filesystem::is_directory(path));
    CHECK(read(path / "run.mkv") == "pixels");
}

// Every non-ordinary outcome has to be sayable, because the defect being fixed was as much about
// silence (`ec` discarded) as about deletion: a caller must be able to print a reason.
TEST_CASE("every refusal names the path it refused") {
    const OwnedTempDir dir("umacapture_stop_file_guard_reason");
    const auto path = dir.child("held.bin");
    write(path, "content");

    const auto result = clearStaleStopFile(path);

    REQUIRE(result.clearance == StopFileClearance::Refused);
    CHECK(result.reason.find(path.string()) != std::string::npos);
}

}  // namespace
}  // namespace uma::tool
