// Characterization tests for the scraping-box directory lifecycle.
//
// These lock the behavior that was previously coupled to the app::NativeApi singleton: the scraping
// boxes create (and, on reset, remove-then-recreate) their per-tab image directories. Directory
// operations are now injected as io_util::DirectoryHooks, so these tests drive them with fakes that
// record the requested paths instead of touching the real filesystem. This exercises the pipeline
// units that link only OpenCV (no ONNX / WinRT / singleton), per the harness scope in test/README.md.

#include <doctest/doctest.h>

#include <filesystem>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"
#include "util/misc.h"

namespace uma::chara_detail {
namespace {

// A placeholder factor-end-green terminator. These directory-lifecycle tests never run the green
// scan, but SceneScrapingBox now takes a ScanParameter by value and Range<Color> has no default
// constructor, so it cannot be brace-value-initialized with {}.
const scraper_config::ScanParameter kNoFactorEndGreen{0.0, 0.0, {Color(0, 0, 0), Color(0, 0, 0)}};

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

TEST_CASE("PageScrapingBox creates its image directory via the injected hook") {
    HookRecorder recorder;
    const std::filesystem::path dir = "unit_test_page_box";

    scraper_impl::PageScrapingBox box({}, dir, recorder.hooks());

    CHECK(recorder.made.size() == 1);
    CHECK(recorder.made.front() == dir);
    CHECK(recorder.removed.empty());
}

TEST_CASE("SceneScrapingBox creates one directory per tab") {
    HookRecorder recorder;
    const std::filesystem::path root = "unit_test_scene_box";

    scraper_impl::SceneScrapingBox box(
        {}, {}, {}, kNoFactorEndGreen, record::RecordType::Standard, root, recorder.hooks());

    CHECK(recorder.made.size() == 3);
    CHECK(recorder.made[0] == root / path_config.skill.stem());
    CHECK(recorder.made[1] == root / path_config.factor.stem());
    CHECK(recorder.made[2] == root / path_config.campaign.stem());
    CHECK(recorder.removed.empty());
}

TEST_CASE("SceneScrapingBox::resetFactorBox removes then recreates only the factor tab dir") {
    HookRecorder recorder;
    const std::filesystem::path root = "unit_test_scene_box";
    const std::filesystem::path factor_dir = root / path_config.factor.stem();

    scraper_impl::SceneScrapingBox box(
        {}, {}, {}, kNoFactorEndGreen, record::RecordType::Standard, root, recorder.hooks());
    recorder.made.clear();

    box.resetFactorBox();

    // The stale directory is cleared (so the fresh box numbers its fragments from zero again) and then
    // recreated -- both through the injected hooks, targeting only the factor tab.
    CHECK(recorder.removed.size() == 1);
    CHECK(recorder.removed.front() == factor_dir);
    CHECK(recorder.made.size() == 1);
    CHECK(recorder.made.front() == factor_dir);
}

// --- probeGreenTerminator: presence detection of the green "継承履歴" end-bar ---------------------
//
// The green terminator lazily renders in-place (24 px at once) within already-scanned empty space, so
// the strip scanner in addScrollArea only ever catches a fraction of it and short-history factor lists
// never complete (closed_before_completed). probeGreenTerminator detects it by PRESENCE over the lower
// half of the current frame, independent of scroll strips. These tests use a 100 px frame where the
// terminator length (0.05) resolves to a 5 px required run.

// A fresh, empty temp directory for boxes whose addScrollArea writes real fragment files. Reused, cleared.
std::filesystem::path freshTempDir(const std::string &name) {
    const auto dir = std::filesystem::temp_directory_path() / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

const Color kGray{130, 130, 130};
const scraper_config::ScanParameter kGrayScan0{0.5, 0.02, {Color(120, 120, 120), Color(140, 140, 140)}};
// A never-matched second scan keeps current_scan parked past begin() (armed) but short of end(): so
// scrollAreaReady() can only become true via the green terminator, not via the gray sequence.
const scraper_config::ScanParameter kAbsentScan1{0.5, 0.02, {Color(0, 0, 200), Color(0, 0, 255)}};
// Same green range as the real factorEndGreen (colorRange({128,222,20}, 45)), length 0.05 -> 5 px on 100.
const scraper_config::ScanParameter kGreenTerminator{0.6017, 0.05, {Color(83, 177, 0), Color(173, 255, 65)}};

// A 100 px frame: white background with a full-width green bar spanning rows [y0, y0 + height).
Frame greenBarFrame(int y0, int bar_height) {
    cv::Mat mat = testutil::solid(100, Color(255, 255, 255));
    mat(cv::Rect(0, y0, 100, bar_height)).setTo(cv::Scalar(20, 222, 128));  // BGR of (128, 222, 20)
    return Frame::fixed(mat);
}

// Consumes scan0 with a full gray frame, so current_scan is parked at the (never matched) scan1 and
// image_count > 0 -- i.e. the probe is armed. Mutates the box in place (returning it by value would
// leave current_scan, an iterator into the box's own vector, dangling into the moved-from source).
void armBox(scraper_impl::PageScrapingBox &box) {
    box.addScrollArea(Frame::fixed(testutil::solid(100, kGray)));
}

TEST_CASE("probeGreenTerminator does not fire before scan0 is consumed (not armed)") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_unarmed"), recorder.hooks(), kGreenTerminator);

    // current_scan is still at begin() and image_count == 0: a green bar must not complete the tab.
    CHECK_FALSE(box.probeGreenTerminator(greenBarFrame(60, 10)));
    CHECK_FALSE(box.scrollAreaReady());
}

TEST_CASE("probeGreenTerminator fires on a green run in the lower half once armed") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_lower"), recorder.hooks(), kGreenTerminator);
    armBox(box);

    CHECK(box.probeGreenTerminator(greenBarFrame(60, 10)));
    CHECK(box.scrollAreaReady());
}

TEST_CASE("probeGreenTerminator ignores a green run in the upper half (top 因子 header guard)") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_upper"), recorder.hooks(), kGreenTerminator);
    armBox(box);

    // A green bar entirely above the mid-line (like the top-of-list "因子" header) must not fire.
    CHECK_FALSE(box.probeGreenTerminator(greenBarFrame(20, 20)));
    CHECK_FALSE(box.scrollAreaReady());
}

TEST_CASE("probeGreenTerminator ignores a green run shorter than the required length") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_short"), recorder.hooks(), kGreenTerminator);
    armBox(box);

    // 3 px < the 5 px required run.
    CHECK_FALSE(box.probeGreenTerminator(greenBarFrame(60, 3)));
    CHECK_FALSE(box.scrollAreaReady());
}

}  // namespace
}  // namespace uma::chara_detail
