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

// --- detectGreenTerminator: presence detection of the green "継承履歴" end-bar ---------------------
//
// The green terminator lazily renders in-place (24 px at once) within already-scanned empty space, so
// the strip scanner in addScrollArea only ever catches a fraction of it and short-history factor lists
// never complete (closed_before_completed). detectGreenTerminator detects it by PRESENCE over a region
// anchored to the scroll frontier -- [height - offset - K, height], K = the gray-tail scan's length --
// independent of scroll strips. These tests use a 100 px frame where the terminator length (0.05)
// resolves to a 5 px required run and K (the absent scan's length, 0.2) resolves to 20 px.

// A fresh, empty temp directory for boxes whose addScrollArea writes real fragment files. Reused, cleared.
std::filesystem::path freshTempDir(const std::string &name) {
    const auto dir = std::filesystem::temp_directory_path() / name;
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    return dir;
}

const Color kGray{130, 130, 130};
const scraper_config::ScanParameter kGrayScan0{0.5, 0.02, {Color(120, 120, 120), Color(140, 140, 140)}};
// The terminating (last) scan. Its color is never matched, so it keeps current_scan parked past begin()
// (armed) but short of end() -- scrollAreaReady() can only become true via the green terminator, not the
// gray sequence. Its length (0.2 -> 20 px) is also the probe's back-scan distance K.
const scraper_config::ScanParameter kAbsentScan1{0.5, 0.2, {Color(0, 0, 200), Color(0, 0, 255)}};
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

// With offset = 10 and K = 20, the anchored scan region is [100 - 10 - 20, 100] = [70, 100].
constexpr int kOffset = 10;

TEST_CASE("detectGreenTerminator does not fire before scan0 is consumed (not armed)") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_unarmed"), recorder.hooks(), kGreenTerminator);

    // current_scan is still at begin() and image_count == 0: a green bar must not complete the tab.
    CHECK_FALSE(box.detectGreenTerminator(greenBarFrame(72, 10), kOffset));
    CHECK_FALSE(box.scrollAreaReady());
}

TEST_CASE("detectGreenTerminator fires on a green run above the new strip but within the back-scan") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_backscan"), recorder.hooks(), kGreenTerminator);
    armBox(box);

    // Green at rows [72, 82): above the new strip [height - offset, height] = [90, 100] (so the strip
    // scanner would miss it), yet within the frontier back-scan [70, 100]. This is the fix's core case.
    CHECK(box.detectGreenTerminator(greenBarFrame(72, 10), kOffset));
    CHECK(box.scrollAreaReady());
}

TEST_CASE("detectGreenTerminator ignores a green run above the back-scan region (top 因子 header guard)") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_above"), recorder.hooks(), kGreenTerminator);
    armBox(box);

    // A green bar above the region [70, 100] (like the top-of-list "因子" header, far from the frontier)
    // must not fire.
    CHECK_FALSE(box.detectGreenTerminator(greenBarFrame(30, 20), kOffset));
    CHECK_FALSE(box.scrollAreaReady());
}

TEST_CASE("detectGreenTerminator ignores a green run shorter than the required length") {
    HookRecorder recorder;
    scraper_impl::PageScrapingBox box(
        {kGrayScan0, kAbsentScan1}, freshTempDir("uma_probe_short"), recorder.hooks(), kGreenTerminator);
    armBox(box);

    // 3 px < the 5 px required run.
    CHECK_FALSE(box.detectGreenTerminator(greenBarFrame(72, 3), kOffset));
    CHECK_FALSE(box.scrollAreaReady());
}

// --- trimScrollAreaToFactorEnd: unify the factor-end crop across both terminator paths -----------------
//
// The gray-completion path crops the terminating fragment a fixed margin below the last factor
// (factorEndCropY). The green terminator path used to leave the last fragment running to the frame bottom,
// so the trailing background below the last factor was variable. trimScrollAreaToFactorEnd scans up from the
// recorded green-bar top to the last factor and trims the fragment stack to the same crop line, so the
// bottom margin matches regardless of which terminator ended the tab.
//
// Fixture: kArmScan (consumed on arm) matches solid kArmGray; the back scan kGapScan matches the page
// background gap. Because kArmGray is not in the gap range, arm frames keep the box armed while a probe
// frame's gap region is recognized as the space below the last factor. On a 100 px frame the margin (0.0217)
// is 2 px, the probe back-scan K (0.2) is 20 px, and the factor search span (0.08) is 8 px -- so the fixed
// factor-to-bar distance below must stay under 8 px.
const Color kArmGray{130, 130, 130};
const scraper_config::ScanParameter kArmScan{0.5, 0.02, {Color(120, 120, 120), Color(140, 140, 140)}};
const scraper_config::ScanParameter kGapScan{0.5, 0.2, {Color(233, 233, 233), Color(253, 253, 253)}};
const scraper_config::ScanParameter kGreenEnd{0.6017, 0.05, {Color(83, 177, 0), Color(173, 255, 65)}};

// A 100 px frame reproducing the real column structure above the green bar (top -> bottom): factor fill,
// the fixed background gap, a 2 px anti-aliased bar edge (neither background nor cleanly green, so the scan
// must skip it), then the 5 px green bar. Returns the frame; the bar top is factor_bottom + gap_height + 2.
Frame factorEndFrame(int factor_bottom, int gap_height) {
    const int green_top = factor_bottom + gap_height + 2;
    cv::Mat mat = testutil::solid(100, Color(255, 255, 255));
    mat(cv::Rect(0, 0, 100, factor_bottom)).setTo(cv::Scalar(200, 200, 200));                       // factor
    mat(cv::Rect(0, factor_bottom, 100, gap_height)).setTo(cv::Scalar(243, 243, 243));              // gap bg
    mat(cv::Rect(0, factor_bottom + gap_height, 100, 2)).setTo(cv::Scalar(180, 240, 220));          // anti-alias
    mat(cv::Rect(0, green_top, 100, 5)).setTo(cv::Scalar(20, 222, 128));                            // green bar
    return Frame::fixed(mat);
}

void armFactorBox(scraper_impl::PageScrapingBox &box) {
    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)));  // consume kArmScan; kGapScan stays parked
}

TEST_CASE("trimScrollAreaToFactorEnd crops the green-terminated tab to the last factor plus the fixed margin") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_factor_end_crop");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);  // fragment 00000 = 100 px

    // Last factor bottom 70, gap [70, 74), anti-alias [74, 76), green bar [76, 81). offset 10 -> frontier 90.
    const Frame probe = factorEndFrame(70, 4);
    REQUIRE(box.detectGreenTerminator(probe, 10));
    box.trimScrollAreaToFactorEnd(probe, 10);

    // The scan skips the bar edge and walks the gap to the last factor (70); crop = 70 + margin (2 px) = 72.
    // The fragment bottom sat at the frontier (90), so 90 - 72 = 18 rows are trimmed: 100 -> 82.
    const cv::Mat cropped = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(cropped.rows == 82);
}

TEST_CASE("trimScrollAreaToFactorEnd leaves fragments untouched when nothing overshoots the crop line") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_factor_end_noop");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);

    // Crop line at/above the frontier: last factor 69 + margin 2 = 71 >= frontier 70 (offset 30) -> trim <= 0.
    const Frame probe = factorEndFrame(69, 4);  // gap [69, 73), anti-alias [73, 75), green [75, 80)
    REQUIRE(box.detectGreenTerminator(probe, 30));
    box.trimScrollAreaToFactorEnd(probe, 30);

    const cv::Mat kept = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(kept.rows == 100);
}

TEST_CASE("trimScrollAreaToFactorEnd peels whole fragments when the trim exceeds the last one") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_factor_end_spill");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);  // fragment 00000 = 100 px
    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)), 20);  // fragment 00001 = 20 px strip

    // Last factor 64, gap [64, 68), anti-alias [68, 70), green [70, 75); offset 10 -> frontier 90 -> crop 66
    // -> trim 24.
    const Frame probe = factorEndFrame(64, 4);
    REQUIRE(box.detectGreenTerminator(probe, 10));
    box.trimScrollAreaToFactorEnd(probe, 10);

    // trim 24 > fragment1 (20 px): fragment1 removed, remaining 4 px trimmed off fragment0 (100 -> 96).
    CHECK_FALSE(std::filesystem::exists(dir / path_config.scroll_area.withNumber(1, 5).filename()));
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 96);
}

// --- gray-completion trim: the factor gray-sequence path shares the same tail-trim ---------------------
//
// The gray-completion path (addScrollArea, scan sequence consumed) terminates a LONG-inheritance factor tab
// whose green bar is not near the bottom. End-of-list overscroll used to leave phantom trailing-background (and
// occasionally a duplicate "ghost" row) strips below the last factor. The path now routes through the same
// trimStackToLastFactor core as the green terminator: when the terminating frame's gray run began at the strip
// top (the whole new strip is trailing background, the real last factor already saved above the frontier), it
// does NOT save the phantom but scans the frame up from the frontier and trims the fragment stack to the last
// factor + fixed margin. When the run began below the strip top (the last factor is in this frame), it saves
// the cropped strip exactly as before (no phantom can precede the first reveal of the last factor).
//
// Fixture: a clean factor-fill over a page-background gap, no anti-aliased edge or green bar, so kGapScan
// completes on a continuous run. On a 100 px frame the margin (0.0217) is 2 px and the gray search span
// (0.16) is 16 px. Phantom fragments are built with an arm-gray strip (out of the gap range) so
// current_length_pixels stays 0 and the terminating frame completes the 20 px gray run on its own -> Case A.
Frame factorThenGapFrame(int factor_bottom) {
    cv::Mat mat = testutil::solid(100, Color(243, 243, 243));                  // page-background gap
    mat(cv::Rect(0, 0, 100, factor_bottom)).setTo(cv::Scalar(200, 200, 200));  // factor fill (out of gap range)
    return Frame::fixed(mat);
}

TEST_CASE("gray-completion trims a phantom fragment latched below the last factor (Case A)") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_peel");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);                                                    // fragment 00000 = 100 px
    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)), 6);   // fragment 00001 = 6 px phantom

    // Terminating frame: factor [0, 68), gap [68, 100). offset 20 -> frontier 80; the strip [80, 100] is all
    // gap, so the gray run begins at the strip top -> Case A. The gap frontier(80)->factor(68) is 12 px, within
    // the 16 px (0.16 w) search span. Scan up 79..68 (gap), factor at 67 -> last factor bottom 68 -> crop 70.
    // trim = 80 - 70 = 10: phantom (6) removed, 4 more off fragment0 (100 -> 96).
    box.addScrollArea(factorThenGapFrame(68), 20);

    CHECK(box.scrollAreaReady());
    CHECK_FALSE(std::filesystem::exists(dir / path_config.scroll_area.withNumber(1, 5).filename()));
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 96);
}

TEST_CASE("gray-completion saves the cropped strip and does not trim when the last factor is in-frame (Case B)") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_caseb");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);  // fragment 00000 = 100 px

    // Terminating frame: factor [0, 75), gap [75, 100). offset 30 -> frontier 70; the gray run begins at 75
    // (below the strip top 70) -> Case B. Save strip [70, 75 + margin(2)] = [70, 77] = 7 px; fragment0 stays.
    box.addScrollArea(factorThenGapFrame(75), 30);

    CHECK(box.scrollAreaReady());
    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 7);
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
}

TEST_CASE("gray-completion crops within the phantom fragment, preserving earlier ones (Case A)") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_partial");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);                                                     // fragment 00000 = 100 px
    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)), 30);   // fragment 00001 = 30 px phantom

    // factor [0, 65), gap [65, 100). offset 20 -> frontier 80; Case A. last factor 65 -> crop 67 ->
    // trim = 80 - 67 = 13 (< phantom's 30): phantom cropped to 30 - 13 = 17, fragment0 untouched.
    box.addScrollArea(factorThenGapFrame(65), 20);

    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 17);
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
}

TEST_CASE("gray-completion is a no-op when the last factor sits at the frontier (Case A)") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_noop");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);                                                     // fragment 00000 = 100 px
    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)), 10);   // fragment 00001 = 10 px

    // factor [0, 78), gap [78, 100). offset 20 -> frontier 80; Case A. last factor 78 -> crop 78 + 2 = 80 ==
    // frontier -> trim 0: nothing peeled.
    box.addScrollArea(factorThenGapFrame(78), 20);

    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 10);
}

}  // namespace
}  // namespace uma::chara_detail
