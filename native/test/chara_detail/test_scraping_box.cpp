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
// fragmentCount() > 0 -- i.e. the probe is armed. Mutates the box in place (returning it by value would
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

    // current_scan is still at begin() and fragmentCount() == 0: a green bar must not complete the tab.
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

// --- trimScrollAreaToFactorEnd: the green terminator crops from the maintained frontier ----------------
//
// Both terminator paths crop the stack a fixed margin below frontier_stack_rows: the last observed
// non-background -> background transition of the terminating scan, recorded in stack coordinates at latch
// time. The green path validates that evidence against the live bar top (the last factor sits a fixed
// distance above the bar, bounded by kFactorEndGreenSearchSpan) and falls back to the previous transition
// (the bar rendered early and its trailing background stole the last one) or to a fail-safe bar-top crop /
// no-op when the evidence cannot be the last factor's gap.
//
// Fixture: kArmScan (consumed on arm) matches kArmGray; the back scan kGapScan matches the page background
// gap. structuredArmFrame latches real factor + gap structure so the frontier holds evidence that is
// scroll-consistent with the live probes. On a 100 px frame the margin (0.0217) is 2 px, the probe
// back-scan K (0.2) is 20 px, and the factor search span (0.08) is 8 px -- so the fixed factor-to-bar
// distance must stay under 8 px.
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

// Arms the box with solid arm-gray: kArmScan consumed, no factor/gap structure latched (frontier stays -1).
void armFactorBox(scraper_impl::PageScrapingBox &box) {
    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)));  // consume kArmScan; kGapScan stays parked
}

// Arms the box with scroll-consistent structure: 2 px of arm-gray consume kArmScan, factor fill down to
// factor_bottom, page-background gap below -- so the frontier records factor_bottom at latch time. The
// latched gap run (100 - factor_bottom) must stay under the 20 px terminating length or the gray sequence
// would complete during the arm latch: factor_bottom >= 81.
Frame structuredArmFrame(int factor_bottom) {
    cv::Mat mat = testutil::solid(100, Color(243, 243, 243));                  // page-background gap
    mat(cv::Rect(0, 0, 100, factor_bottom)).setTo(cv::Scalar(200, 200, 200));  // factor fill
    mat(cv::Rect(0, 0, 100, 2)).setTo(cv::Scalar(130, 130, 130));              // kArmGray consumes kArmScan
    return Frame::fixed(mat);
}

// A pure page-background strip: the trailing background revealed by end-of-list overscroll.
Frame gapFrame() {
    return Frame::fixed(testutil::solid(100, Color(243, 243, 243)));
}

TEST_CASE("trimScrollAreaToFactorEnd crops the green-terminated tab at the frontier plus the fixed margin") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_factor_end_crop");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    box.addScrollArea(structuredArmFrame(82));  // stack 100, frontier 82, latched gap 82..99 (18 px < 20)

    // Live probe, scrolled 10 px past the arm frame (content = frame + 10): factor bottom 72 (content 82,
    // matching the frontier), gap [72, 77), anti-alias [77, 79), bar [79, 84). The bar's content rows were
    // latched as background before it lazily popped in, so it exists only in the live frame.
    const Frame probe = factorEndFrame(72, 5);
    REQUIRE(box.detectGreenTerminator(probe, 10));
    box.trimScrollAreaToFactorEnd(probe, 10);

    // Bar top in stack coordinates = 100 - (90 - 79) = 89; frontier 82 is within the 8 px span above it and
    // 82 + margin (2) = 84 <= 89, so the frontier is trusted: trim = 100 - 84 = 16 rows.
    const cv::Mat cropped = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(cropped.rows == 84);
}

TEST_CASE("trimScrollAreaToFactorEnd is a no-op on a green early fire without frontier evidence") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_factor_end_noop");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);  // no factor/gap structure latched: frontier stays -1

    // The bar fires before the last factor's gap was ever latched. With no latch evidence the trim must
    // fail safe; the bar (75) sits below the stack bottom (70), so the bar-top fallback is a no-op.
    const Frame probe = factorEndFrame(69, 4);  // gap [69, 73), anti-alias [73, 75), green [75, 80)
    REQUIRE(box.detectGreenTerminator(probe, 30));
    box.trimScrollAreaToFactorEnd(probe, 30);

    const cv::Mat kept = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(kept.rows == 100);
}

TEST_CASE("trimScrollAreaToFactorEnd peels whole staged strips when the trim spans them") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_factor_end_spill");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    box.addScrollArea(structuredArmFrame(93));  // stack 100, frontier 93, latched gap 7 px
    box.addScrollArea(gapFrame(), 6);           // trailing background strip: stack 106, gap run 13 px < 20

    // Probe scrolled 16 px past the arm frame (content = frame + 16): factor bottom 77 (content 93), gap
    // [77, 82), anti-alias [82, 84), bar [84, 89) at content 100 -- latched as background by the 6 px strip
    // before the bar popped in.
    const Frame probe = factorEndFrame(77, 5);
    REQUIRE(box.detectGreenTerminator(probe, 10));
    box.trimScrollAreaToFactorEnd(probe, 10);

    // Bar top in stack coordinates = 106 - (90 - 84) = 100; frontier 93 valid (span 7 <= 8): crop 95,
    // trim 11 -> the 6 px strip is peeled entirely in RAM (never written), the arm strip crops 100 -> 95.
    CHECK_FALSE(std::filesystem::exists(dir / path_config.scroll_area.withNumber(1, 5).filename()));
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 95);
}

TEST_CASE("trimScrollAreaToFactorEnd falls back to the previous transition when the early bar was latched") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_factor_end_early_bar");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);

    // A short history whose bar rendered before the arm latch, so the bar itself was latched: the column
    // reads factor [2, 81), gap [81, 86), anti-alias [86, 88), bar [88, 93), background [93, 100). The
    // post-bar background steals the last transition (93); the factor's own gap start (81) survives as the
    // previous one.
    cv::Mat arm = testutil::solid(100, Color(243, 243, 243));
    arm(cv::Rect(0, 0, 100, 81)).setTo(cv::Scalar(200, 200, 200));
    arm(cv::Rect(0, 0, 100, 2)).setTo(cv::Scalar(130, 130, 130));
    arm(cv::Rect(0, 86, 100, 2)).setTo(cv::Scalar(180, 240, 220));
    arm(cv::Rect(0, 88, 100, 5)).setTo(cv::Scalar(20, 222, 128));
    box.addScrollArea(Frame::fixed(arm));

    // Probe scrolled 10 px (content = frame + 10): bar [78, 83) -> bar top in stack coordinates 88. The
    // last transition (93) lies below the bar and is rejected; the previous one (81) is within the span.
    const Frame probe = factorEndFrame(71, 5);
    REQUIRE(box.detectGreenTerminator(probe, 10));
    box.trimScrollAreaToFactorEnd(probe, 10);

    // crop = 81 + margin (2) = 83, trim = 100 - 83 = 17: the latched bar and its trailing rows are removed.
    const cv::Mat cropped = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(cropped.rows == 83);
}

// --- gray-completion trim: sequence completion crops at the frontier -----------------------------------
//
// The gray-completion path (addScrollArea, scan sequence consumed) terminates a LONG-inheritance factor tab
// whose green bar is not near the bottom. The terminating run's own start IS the frontier -- recorded when
// the run began, possibly strips earlier -- so on completion the box stages the strip down to the completion
// row and crops the whole stack at frontier + margin, one path regardless of where the last factor sits.
// The run accumulates across strips (current_length_pixels survives frames), so trailing background latched
// during the recognition lag counts toward the 20 px threshold and is peeled from the staged tail.
//
// Fixture: a clean factor-fill over a page-background gap, no anti-aliased edge or green bar, so kGapScan
// completes on a continuous run. On a 100 px frame the margin (0.0217) is 2 px.
Frame factorThenGapFrame(int factor_bottom) {
    cv::Mat mat = testutil::solid(100, Color(243, 243, 243));                  // page-background gap
    mat(cv::Rect(0, 0, 100, factor_bottom)).setTo(cv::Scalar(200, 200, 200));  // factor fill (out of gap range)
    return Frame::fixed(mat);
}

TEST_CASE("gray-completion trims the trailing background latched during the recognition lag") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_peel");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    box.addScrollArea(structuredArmFrame(91));  // stack 100, frontier 91, gap run 9 px
    box.addScrollArea(gapFrame(), 6);           // lag strip: all background, run 15 px, stack 106

    // The 20 px gray run completes 5 rows into this strip (15 + 5): rows [80, 85) are staged, stack 111.
    // crop = frontier (91) + margin (2) = 93 -> trim 18: the 5 staged rows and the 6 px lag strip are
    // peeled entirely in RAM (never written), and the arm strip crops 100 -> 93.
    box.addScrollArea(gapFrame(), 20);

    CHECK(box.scrollAreaReady());
    CHECK_FALSE(std::filesystem::exists(dir / path_config.scroll_area.withNumber(1, 5).filename()));
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 93);
}

TEST_CASE("gray-completion crops the terminating strip when the last factor is in-frame") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_caseb");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    armFactorBox(box);  // fragment 00000 = 100 px

    // Terminating frame: factor [0, 75), gap [75, 100). offset 30 -> the transition at 75 sets the frontier
    // to stack row 105; the 20 px run completes at row 94, staging [70, 95) = 25 rows. crop = 105 + 2 = 107
    // -> trim 18: the staged strip crops to 7 rows; fragment0 stays.
    box.addScrollArea(factorThenGapFrame(75), 30);

    CHECK(box.scrollAreaReady());
    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 7);
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
}

TEST_CASE("gray-completion crops within a middle strip, preserving earlier fragments") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_partial");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    box.addScrollArea(structuredArmFrame(100));   // all factor: stack 100, no transition yet
    box.addScrollArea(factorThenGapFrame(82), 25);  // strip [75, 100): factor to 81, transition at 82

    // The transition at frame row 82 puts the frontier at stack row 107; the gap run is 18 px so the box
    // stays armed (stack 125). The next background strip completes the run 2 rows in (staging 2, stack 127).
    // crop = 107 + 2 = 109 -> trim 18: the 2 staged rows peel, the 25 px strip crops to 9, the arm strip
    // (pure factor) is untouched.
    box.addScrollArea(gapFrame(), 6);

    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 9);
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
    CHECK_FALSE(std::filesystem::exists(dir / path_config.scroll_area.withNumber(2, 5).filename()));
}

TEST_CASE("gray-completion never over-trims a factor ending exactly at a strip boundary") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_boundary");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    box.addScrollArea(structuredArmFrame(100));  // all factor: the last factor row is the strip's bottom row

    // The background run starts exactly at the next strip's top. current_length_pixels survives across
    // frames and is zero here (the previous strip ended non-background), so the transition is recorded at
    // the boundary: frontier = stack row 100.
    box.addScrollArea(gapFrame(), 18);  // gap run 18 px < 20, stack 118

    // The run completes 2 rows into the next strip (staging 2, stack 120). crop = 100 + 2 = 102 -> trim 18:
    // the staged rows peel, the 18 px strip crops to 2 margin rows, and the factor strip is fully kept.
    box.addScrollArea(gapFrame(), 6);

    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 2);
}

TEST_CASE("gray-completion keeps a stray non-background strip below the factor (ghost repair out of scope)") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_gray_trim_stray");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    box.addScrollArea(structuredArmFrame(91));                            // stack 100, frontier 91
    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)), 6);  // stray non-background strip

    // The stray strip resets the run, so the terminating strip's top row is a boundary transition: the
    // frontier moves to stack row 106, below the stray. Latch evidence alone cannot tell a stray from a
    // factor ending at the boundary (see the boundary test above), so the crop refuses to reach past the
    // transition: the stray survives and factor rows are never cut. Repairing mis-latched (ghost) strips is
    // an alignment concern, out of scope here. The full 20 px run stages [80, 100), stack 126; crop = 108
    // -> trim 18 crops the staged rows to 2.
    box.addScrollArea(gapFrame(), 20);

    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 6);
    const cv::Mat frag2 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(2, 5).filename());
    CHECK(frag2.rows == 2);
}

// --- delayed commit: the factor box stages its tail in RAM and flushes on terminal exits ----------------
//
// The factor box no longer writes each strip to disk as it is latched: strips are staged in a RAM tail so
// the terminator-time trim never has to decode/re-save committed PNGs and phantom overscroll strips never
// reach disk at all. The tail holdback is the worst-case trim depth: on a 100 px frame,
// back().length (0.2) + the gray search span (0.16) -> 36 px. Strips older than that are flushed as they
// can never be trimmed; every terminal exit (gray completion, green trim, setScrollArea) drains the tail.

int scrollAreaFileCount(const std::filesystem::path &dir) {
    int count = 0;
    for (const auto &entry : std::filesystem::directory_iterator(dir)) {
        if (entry.is_regular_file()
            && stds::starts_with(entry.path().filename().string(), path_config.scroll_area.stem())) {
            count++;
        }
    }
    return count;
}

TEST_CASE("delayed commit stages the factor tail and flushes strips past the holdback") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_delayed_stage");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);

    // The arm strip (100 px, pure factor) is the whole tail: nothing on disk yet.
    box.addScrollArea(structuredArmFrame(100));
    CHECK(scrollAreaFileCount(dir) == 0);

    // A second 50 px strip pushes the arm strip past the 36 px holdback: it flushes as 00000, while the
    // 50 px strip itself stays staged. Factor to frame row 90, transition at 91 -> frontier stack row 141,
    // gap run 9 px (< 20, still armed).
    box.addScrollArea(factorThenGapFrame(91), 50);
    CHECK(std::filesystem::exists(dir / path_config.scroll_area.withNumber(0, 5).filename()));
    CHECK(scrollAreaFileCount(dir) == 1);

    // Gray termination: the run completes 11 rows into this background strip (staging 11, stack 161).
    // crop = 141 + 2 = 143 -> trim 18: the staged rows peel and the 50 px strip crops in RAM to 43. The
    // final set is contiguous and complete.
    box.addScrollArea(gapFrame(), 20);
    CHECK(box.scrollAreaReady());
    CHECK(scrollAreaFileCount(dir) == 2);
    const cv::Mat frag0 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(0, 5).filename());
    CHECK(frag0.rows == 100);
    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 43);
}

TEST_CASE("delayed commit keeps committed indices contiguous when a staged strip is peeled") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_delayed_peel_contiguous");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
    box.addScrollArea(structuredArmFrame(100));      // staged: 100 px, pure factor
    box.addScrollArea(factorThenGapFrame(91), 50);   // flushes 00000; staged: 50 px, frontier 141, run 9 px
    box.addScrollArea(gapFrame(), 6);                // lag strip: staged 50 + 6 px, run 15 px

    // The run completes 5 rows into this strip (staging 5, stack 161). crop = 143 -> trim 18: the staged
    // rows and the 6 px lag strip peel entirely in RAM (never written), the 50 px strip crops to 43, and
    // the flushed names have no gap for the stitcher's lexical enumeration.
    box.addScrollArea(gapFrame(), 20);
    CHECK(scrollAreaFileCount(dir) == 2);
    CHECK_FALSE(std::filesystem::exists(dir / path_config.scroll_area.withNumber(2, 5).filename()));
    const cv::Mat frag1 = Frame::decodeBgr(dir / path_config.scroll_area.withNumber(1, 5).filename());
    CHECK(frag1.rows == 43);
}

TEST_CASE("non-factor boxes write through immediately") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_writethrough");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks());  // no end_green

    box.addScrollArea(Frame::fixed(testutil::solid(100, kArmGray)));

    CHECK(std::filesystem::exists(dir / path_config.scroll_area.withNumber(0, 5).filename()));
}

TEST_CASE("discarding the box abandons the staged tail without flushing") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_delayed_abandon");
    {
        scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);
        armFactorBox(box);  // staged, not on disk
        CHECK(scrollAreaFileCount(dir) == 0);
    }
    // Reset paths drop the box (recreate()/release() replace the shared_ptr) and rmdir the directory; a
    // destructor flush would resurrect strips the reset meant to discard.
    CHECK(scrollAreaFileCount(dir) == 0);
}

TEST_CASE("setScrollArea on a factor box commits its sole strip immediately") {
    HookRecorder recorder;
    const auto dir = freshTempDir("uma_delayed_set_scroll_area");
    scraper_impl::PageScrapingBox box({kArmScan, kGapScan}, dir, recorder.hooks(), kGreenEnd);

    box.setScrollArea(Frame::fixed(testutil::solid(100, kArmGray)));

    CHECK(std::filesystem::exists(dir / path_config.scroll_area.withNumber(0, 5).filename()));
    CHECK(box.scrollAreaReady());
}

}  // namespace
}  // namespace uma::chara_detail
