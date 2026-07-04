// Behavioral tests for the character-detail scene stitcher.
//
// Two behaviors are pinned here: ScrollAreaStitcher::stitch, which filters a directory to the scroll-area
// fragments and vconcats them (validating up front rather than throwing deep inside OpenCV), and the
// failure-cleanup path of CharaDetailSceneStitcher::stitch. The latter is the safety-critical one: when a
// tab throws partway, a half-written output must be removed and a terminal failure surfaced, or the
// recognizer never runs and the UI waits forever. Directory operations are injected as DirectoryHooks
// fakes; only the scroll-area fragment reads need real files (imagePaths/vconcat walk the real filesystem).
//
// The full success path is not exercised here: it needs a complete, calibrated stitcher config plus a
// valid base/tab image set, which belongs to the CLI/integration harness rather than a unit test.

#include <doctest/doctest.h>

#include <filesystem>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_stitcher.h"
#include "chara_detail/record_info.h"
#include "util/event_util.h"
#include "util/misc.h"

namespace uma::chara_detail {
namespace {

// Records the paths passed to the injected directory hooks, without touching the filesystem.
struct HookRecorder {
    std::vector<std::filesystem::path> made;
    std::vector<std::filesystem::path> removed;

    [[nodiscard]] io_util::DirectoryHooks hooks() {
        io_util::DirectoryHooks h;
        h.mkdir = [this](const std::filesystem::path &path) { made.push_back(path); };
        h.rmdir = [this](const std::filesystem::path &path) { removed.push_back(path); };
        return h;
    }
};

bool contains(const std::vector<std::filesystem::path> &paths, const std::filesystem::path &target) {
    return std::find(paths.begin(), paths.end(), target) != paths.end();
}

// A fresh, empty temp directory for the tests that need real fragment files. Reused name, cleared first.
std::filesystem::path freshTempDir(const std::string &name) {
    const auto dir = std::filesystem::temp_directory_path() / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

TEST_CASE("ScrollAreaStitcher stitches only the scroll-area fragments, in order") {
    const auto dir = freshTempDir("uma_stitcher_scroll_area");

    // Two scroll-area fragments (same width, so vconcat is valid) plus a decoy of a different width that
    // must be excluded -- if it were picked up, vconcat would throw on the column mismatch.
    cv::imwrite((dir / path_config.scroll_area.withNumber(0, 2).filename()).string(),
        cv::Mat(4, 10, CV_8UC3, cv::Scalar(10, 20, 30)));
    cv::imwrite((dir / path_config.scroll_area.withNumber(1, 2).filename()).string(),
        cv::Mat(6, 10, CV_8UC3, cv::Scalar(40, 50, 60)));
    cv::imwrite((dir / path_config.base.filename()).string(), cv::Mat(3, 5, CV_8UC3, cv::Scalar(0, 0, 0)));

    const stitcher_impl::ScrollAreaStitcher stitcher;
    const cv::Mat stitched = stitcher.stitch(dir);

    CHECK(stitched.cols == 10);
    CHECK(stitched.rows == 10);  // 4 + 6, the decoy excluded

    std::filesystem::remove_all(dir);
}

TEST_CASE("ScrollAreaStitcher throws when the directory has no scroll-area fragments") {
    const auto dir = freshTempDir("uma_stitcher_empty");
    const stitcher_impl::ScrollAreaStitcher stitcher;

    CHECK_THROWS_AS((void) stitcher.stitch(dir), std::runtime_error);

    std::filesystem::remove_all(dir);
}

TEST_CASE("CharaDetailSceneStitcher cleans up and reports failure when the base image is missing") {
    const auto scraping_dir = std::filesystem::temp_directory_path() / "uma_stitcher_scrape";
    const auto stitching_dir = std::filesystem::temp_directory_path() / "uma_stitcher_stitch";
    const std::string record_id = "rec1";

    const auto ready = event_util::makeDirectConnection<RecordInfo>();
    const auto completed = event_util::makeDirectConnection<RecordInfo>();
    const auto failed = event_util::makeDirectConnection<RecordInfo>();

    std::vector<std::string> completed_ids;
    std::vector<std::string> failed_ids;
    completed->listen([&](const RecordInfo &info) { completed_ids.push_back(info.record_id); });
    failed->listen([&](const RecordInfo &info) { failed_ids.push_back(info.record_id); });

    HookRecorder recorder;
    // stretch_range (a Line, which has no default constructor) must be supplied; the remaining rects
    // default-construct. None of them are consulted before the missing base.png aborts the stitch.
    const stitcher_config::CharaDetailSceneStitcherConfig config{
        Line<double>{Point<double>(0.0, 0.0), Point<double>(0.0, 0.0)},
    };

    const CharaDetailSceneStitcher stitcher(
        scraping_dir, stitching_dir, ready, completed, failed, config, recorder.hooks());

    RecordInfo info;
    info.record_id = record_id;
    ready->send(info);  // no base.png under scraping_dir/rec1 -> the stitch fails and cleans up

    CHECK(completed_ids.empty());
    CHECK(failed_ids == std::vector<std::string>{record_id});
    // The partial output is removed; the input is kept for diagnosis.
    CHECK(contains(recorder.removed, stitching_dir / record_id));
    CHECK_FALSE(contains(recorder.removed, scraping_dir / record_id));
}

}  // namespace
}  // namespace uma::chara_detail
