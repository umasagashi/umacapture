// Behavioral tests for the character-detail scene stitcher.
//
// Two behaviors are pinned here: ScrollAreaStitcher::stitch, which filters a directory to the scroll-area
// fragments and vconcats them (validating up front rather than throwing deep inside OpenCV), and the
// failure-cleanup path of CharaDetailSceneStitcher::stitch. The latter is the safety-critical one: when a
// tab throws partway, a half-written output must be removed and a terminal failure surfaced, or the
// recognizer never runs and the UI waits forever. Directory operations are injected as DirectoryHooks
// fakes; only the scroll-area fragment reads need real files (imagePaths/vconcat walk the real filesystem).
//
// The success path is exercised for one property only, at the end of this file: that the factor tab's banner,
// found on the stitched image the way the recognizer finds it, sits at the row, column and search length it had
// on the live frame. That case stitches synthetic frames with the SHIPPED configs; what the stitched records
// read as is the golden suite's business, not this file's.

#include <doctest/doctest.h>

#include <cmath>
#include <filesystem>
#include <random>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "chara_detail/chara_detail_scene_stitcher.h"
#include "chara_detail/record_info.h"
#include "util/event_util.h"
#include "util/fake_predictor.h"
#include "util/json_util.h"
#include "util/misc.h"

#ifndef TEST_ASSET_CONFIG_DIR
#error "TEST_ASSET_CONFIG_DIR must be defined by the build (see native/CMakeLists.txt)."
#endif

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
//
// The directory name carries a per-PROCESS random token: more than one umacapture_tests process can run
// at a time in the same working directory (Debug and Release side by side, an independent verification
// run alongside a regression run), and a fixed name under the shared system temp directory would let one
// process's remove_all/create_directories race another's still-open files. There is no pid helper in this
// tree, so a random token stands in (test_scraper_estimators.cpp's uniqueHarnessDir() uses the same
// device for the same reason). One token per process is enough here -- unlike uniqueHarnessDir(), this
// function already takes a distinguishing `name` per call, so no additional counter is needed.
std::filesystem::path freshTempDir(const std::string &name) {
    static const std::string token = std::to_string(std::random_device{}());
    const auto dir = std::filesystem::temp_directory_path() / (name + "_" + token);
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

// ---------------------------------------------------------------------------------------------------------------
// THE BANNER'S ROW SURVIVES STITCHING.
//
// The scraper judges a live frame by where the factor tab's green banner sits below the layout's scroll area,
// and the recognizer reads the stitched image from where it finds that banner below config.area. Both searches
// are FactorRowReader::findBanner; what makes them agree is not the function but the stitch: the stitched image
// must carry the live crop's pixels unscaled, starting exactly on config.area's top row, on a canvas whose anchor
// unit is the live frame's (the stitcher's stretch compensates when base.png's own unit comes out short).
// Nothing but this case states that. It stitches a synthetic record with the shipped configs and asserts
// that the banner is found at the same row, column, search length and run end on both sides.
//
// The banner's top row alternates with the column's parity, so a search that lands one column off also lands on
// a different row. That is the failure a search on a CROP of the scroll area (one pixel narrower than the
// intersection) produces at some units, 720 and 736 among them.
// ---------------------------------------------------------------------------------------------------------------

template<typename Config>
Config shippedConfig(const std::string &file) {
    return json_util::read(std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / file).get<Config>();
}

const Color kScrollBg{242, 243, 242};
const Color kOutside{90, 90, 110};
const Color kBanner{127, 199, 58};

// The banner's top row below the scroll area's top edge, at a column `column_from_left` pixels right of its left edge.
constexpr int kBannerRow = 5;
constexpr int kBannerHeight = 12;

int bannerRowAt(int column_from_left) {
    return kBannerRow + column_from_left % 2;
}

cv::Scalar bgrOf(const Color &color) {
    return {static_cast<double>(color.b()), static_cast<double>(color.g()), static_cast<double>(color.r())};
}

// A live frame of `frame_size` whose game surface is `intersection`, with the layout's scroll area painted as
// background and the banner drawn below its top edge. Everything else is a colour no background range accepts.
Frame liveFrame(const Size<int> &frame_size, const Rect<int> &intersection, const Rect<double> &scroll_area) {
    cv::Mat image(frame_size.toCVSize(), CV_8UC3, bgrOf(kOutside));
    const auto frame = Frame(image).reanchored(intersection);
    const auto area = frame.anchor().mapToFrame(scroll_area);
    cv::rectangle(image, area.toCVRect(), bgrOf(kScrollBg), cv::FILLED);
    for (int x = area.left(); x < area.right(); x++) {
        const int top = area.top() + bannerRowAt(x - area.left());
        cv::rectangle(image, cv::Rect(x, top, 1, kBannerHeight), bgrOf(kBanner), cv::FILLED);
    }
    return frame;
}

// The three shapes a live frame's anchor takes in production.
enum class LiveShape {
    // The whole frame is the 9:16 surface.
    Exact,
    // A frame one row taller at each end than the surface, so the intersection starts at row 1.
    VerticalMargin,
    // A wider two-pane frame re-anchored onto a surface two rows' worth shorter than 9:16. base.png, a crop of that
    // surface, reads back through FrameAnchor::intersect with a one-column margin on each side, i.e. with unit U-2,
    // which the stitch's stretch compensates. (A surface only one column's worth short reads back with unit U: the
    // margin is the shortfall halved in integers, so a 1 px shortfall leaves no margin at all.)
    ReanchoredPane,
    // A frame re-anchored onto a surface two rows taller than 9:16: base.png reads back with a one-row vertical
    // margin, so the stitched canvas's intersection starts at row 1 and config.area's top row moves with it.
    ReanchoredTall,
};

const char *nameOf(const LiveShape shape) {
    switch (shape) {
        case LiveShape::Exact:
            return "exact";
        case LiveShape::VerticalMargin:
            return "vertical_margin";
        case LiveShape::ReanchoredPane:
            return "reanchored_pane";
        case LiveShape::ReanchoredTall:
            return "reanchored_tall";
    }
    return "?";
}

struct LiveGeometry {
    Size<int> frame_size;
    Rect<int> intersection;
};

LiveGeometry geometryOf(const LiveShape shape, const int unit) {
    const int surface_height = static_cast<int>(std::lround(unit * 960.0 / 540.0));
    switch (shape) {
        case LiveShape::Exact:
            return {{unit, surface_height}, {{0, 0}, Point<int>{unit, surface_height}}};
        case LiveShape::VerticalMargin:
            return {{unit, surface_height + 2}, {{0, 1}, Point<int>{unit, surface_height + 1}}};
        case LiveShape::ReanchoredPane: {
            const int pane_height = static_cast<int>(std::lround((unit - 2) * 960.0 / 540.0));
            const Point<int> origin{7, 5};
            return {
                {2 * unit + 37, pane_height + 11},
                {origin, Point<int>{origin.x() + unit, origin.y() + pane_height}},
            };
        }
        case LiveShape::ReanchoredTall: {
            const Point<int> origin{3, 4};
            return {
                {unit + 9, surface_height + 13},
                {origin, Point<int>{origin.x() + unit, origin.y() + surface_height + 2}},
            };
        }
    }
    throw std::logic_error("unknown shape");
}

// Stitches one record whose base image and factor fragment #0 are cut from `live` the way the scraper cuts them,
// and returns the stitched factor image as the recognizer opens it.
Frame stitchFactorTab(
    const Frame &live,
    const scraper_config::SceneScraperConfig &layout,
    const stitcher_config::CharaDetailSceneStitcherConfig &stitcher_config,
    const std::string &name) {
    const auto root = freshTempDir("uma_stitch_identity_" + name);
    const auto scraping_dir = root / "scrape";
    const auto stitching_dir = root / "stitch";
    const std::string record_id = "rec";
    std::filesystem::create_directories(scraping_dir / record_id);

    // SceneScrapingBox::addBase saves BaseFrameCatcher::frame(), the base rect's view of the live frame.
    live.view(layout.base_image_rect).save(scraping_dir / record_id / path_config.base.filename());

    // Fragment #0 is the scraper's own crop (FrameDescriptor::frame is frame.copy(scroll_area_rect)), written by
    // a PageScrapingBox. The scan never completes, so every strip is written whole. Two background strips follow,
    // so the stitched strip is taller than the Standard window even when the crop is Friend's shorter one.
    const std::vector<scraper_config::ScanParameter> never_completes{
        {0.5, 100.0, Range<Color>{Color(0, 0, 0), Color(255, 255, 255)}},
    };
    scraper_impl::PageScrapingBox box(
        never_completes, scraping_dir / record_id / path_config.factor.stem(), io_util::DirectoryHooks{});
    const auto head = live.copy(layout.scroll_area_rect);
    box.addScrollArea(head);
    const auto blank = Frame::fixed(cv::Mat(head.size().toCVSize(), CV_8UC3, bgrOf(kScrollBg)));
    box.addScrollArea(blank, blank.height());
    box.addScrollArea(blank, blank.height());

    const auto ready = event_util::makeDirectConnection<RecordInfo>();
    const auto completed = event_util::makeDirectConnection<RecordInfo>();
    const auto failed = event_util::makeDirectConnection<RecordInfo>();
    int completed_count = 0;
    completed->listen([&](const RecordInfo &) { completed_count++; });
    const CharaDetailSceneStitcher stitcher(
        scraping_dir, stitching_dir, ready, completed, failed, stitcher_config, io_util::DirectoryHooks{});
    RecordInfo info;
    info.record_id = record_id;
    ready->send(info);
    REQUIRE(completed_count == 1);

    // Frame::open decodes into memory, so the directory can go before the frame is used.
    auto stitched = Frame::open(stitching_dir / record_id / path_config.factor.filename());
    std::filesystem::remove_all(root);
    return stitched;
}

TEST_CASE("the stitched factor image finds the banner at the live frame's row, column, length and run end") {
    const auto scraper = shippedConfig<scraper_config::CharaDetailSceneScraperConfig>("scene_scraper.json");
    const auto stitcher = shippedConfig<stitcher_config::CharaDetailSceneStitcherConfig>("scene_stitcher.json");
    const auto recognizer = shippedConfig<recognizer_config::CharaDetailRecognizerConfig>("recognizer.json");
    const recognizer_impl::FactorRowReader reader(
        recognizer.factor_tab,
        testutil::constantPredictor<int>("factor", 0),
        testutil::constantPredictor<int>("factor_rank", 0));

    const std::vector<std::pair<const char *, const scraper_config::SceneScraperConfig *>> layouts{
        {"common", &scraper.common},
        {"friend_common", &scraper.friend_common},
    };
    const auto shapes = {
        LiveShape::Exact, LiveShape::VerticalMargin, LiveShape::ReanchoredPane, LiveShape::ReanchoredTall};
    for (const auto &entry : layouts) {
        const std::string layout_name = entry.first;
        const auto *const layout = entry.second;
        for (const int unit : {540, 720, 736, 1079}) {
            for (const auto shape : shapes) {
                CAPTURE(layout_name);
                CAPTURE(unit);
                const std::string shape_name = nameOf(shape);
                CAPTURE(shape_name);

                const auto geometry = geometryOf(shape, unit);
                const auto live = liveFrame(geometry.frame_size, geometry.intersection, layout->scroll_area_rect);
                REQUIRE(live.anchor().intersection().width() == unit);
                // The premise of each re-anchored shape: base.png's own anchor differs from the live one.
                const auto base_anchor = FrameAnchor::intersect(live.view(layout->base_image_rect).size());
                if (shape == LiveShape::ReanchoredPane) {
                    REQUIRE(base_anchor.intersection().width() == unit - 2);
                }
                if (shape == LiveShape::ReanchoredTall) {
                    REQUIRE(base_anchor.intersection().top() == 1);
                }

                const auto stitched = stitchFactorTab(
                    live, *layout, stitcher, layout_name + "_" + std::to_string(unit) + "_" + shape_name);
                REQUIRE(stitched.anchor().intersection().width() == unit);

                const auto on_live = reader.findBanner(live, layout->scroll_area_rect);
                const auto on_stitched = reader.findBanner(stitched, recognizer.factor_tab.area);
                REQUIRE(on_live.has_value());
                REQUIRE(on_stitched.has_value());

                // The live search found the banner where it was drawn, so the comparison below is about a real row.
                CHECK(on_live->row == bannerRowAt(on_live->column));
                CHECK(on_live->run_end_row == on_live->row + kBannerHeight);

                CHECK(on_stitched->row == on_live->row);
                CHECK(on_stitched->column == on_live->column);
                CHECK(on_stitched->search_rows == on_live->search_rows);
                CHECK(on_stitched->run_end_row == on_live->run_end_row);
            }
        }
    }
}

}  // namespace
}  // namespace uma::chara_detail
