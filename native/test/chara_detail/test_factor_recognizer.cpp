// Behavioral tests for the factor tab's row scan (FactorRowReader, which FactorTabRecognizer, the early duplicate
// probe and the scene scraper's character-switch rule all read through), and for how the single-frame read's
// limit reaches the probe message's below_threshold.
//
// Exercised through the injection ctor with fake Predictors (see test/util/fake_predictor.h); this TU links
// into the onnxruntime-less umacapture_tests target.

#include <doctest/doctest.h>

#include <atomic>
#include <cmath>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_recognizer.h"
#include "core/native_api_messages.h"
#include "cv/frame.h"
#include "util/json_util.h"
#include "util/cv_test_helpers.h"
#include "util/fake_predictor.h"

namespace uma::chara_detail::recognizer_impl {
namespace {

using testutil::constantPredictor;
using testutil::solid;

const Color kWhite{240, 240, 240};
const Color kBlack{0, 0, 0};
const Range<Color> kBgRange{Color(200, 200, 200), Color(255, 255, 255)};

Rect<double> rect(double left, double top, double right, double bottom) {
    return {Point<double>{left, top}, Point<double>{right, bottom}};
}

// A limit no fixture in this file reaches, so the cases whose subject is the scroll-area bound are decided by the
// bound alone. The limit's own cases below name their limits explicitly.
constexpr std::size_t kNoFixtureReaches = 100;

SelfFactorWindow boundOnly(const Rect<double> &scroll_area) {
    return {scroll_area, kNoFixtureReaches};
}

recognizer_config::BasicModuleConfig basicModule(const std::string &name) {
    return {name, rect(0.0, 0.0, 0.1, 0.1)};
}

recognizer_config::FactorTabConfig factorConfig(double banner_upper_gap = 0.30) {
    return {
        "factor",  // module_path
        kBgRange,  // bg_color
        rect(0.0, 0.0, 1.0, 1.0),  // area
        rect(0.10, 0.0, 0.40, 0.08),  // left_rect
        rect(0.50, 0.0, 0.80, 0.08),  // right_rect
        0.06,  // vertical_delta
        banner_upper_gap,  // vertical_banner_upper_gap
        0.02,  // vertical_banner_bottom_delta
        0.10,  // vertical_factor_gap
        0.03,  // vertical_chara_gap
        basicModule("factor_rank"),  // factor_rank
        {basicModule("character"), basicModule("character_rank")},  // trainee_icon
    };
}

FactorRowReader makeRecognizer(const recognizer_config::FactorTabConfig &config, int factor_id, int rank_zero_based) {
    return FactorRowReader{
        config,
        constantPredictor<int>("factor", factor_id),
        constantPredictor<int>("factor_rank", rank_zero_based),
    };
}

// Paints a thin horizontal content band spanning x=[start_x, start_x+w) at pixel row y.
void band(cv::Mat &mat, int start_x, int width, int y) {
    mat(cv::Rect(start_x, y, width, 2)).setTo(cv::Scalar(kBlack.b(), kBlack.g(), kBlack.r()));
}

TEST_CASE("visibleSelfPrefix returns no factors when the top banner is not found") {
    // On an all-background frame the banner search (findBanner, a vertical scan over bg_color) never leaves the
    // background, so visibleSelfPrefix bails and returns an empty list.
    const auto config = factorConfig();
    const auto recognizer = makeRecognizer(config, 0, 0);

    const Frame frame = Frame::fixed(solid(200, kWhite));

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(config.area));

    CHECK(factors.empty());
}

TEST_CASE("visibleSelfPrefix reads a fully visible left+right row and makes the star 1-based") {
    // Banner at pixel 10 (x=0.10 column); one factor row at pixel 20 in both the left (x=0.10) and right
    // (x=0.50) columns. Both rows' cells lie inside the scroll area, so two factors are read with
    // star = rank + 1 -- both of them, with nothing dropped from the end.
    const auto config = factorConfig();
    const auto recognizer = makeRecognizer(config, /*factor_id=*/7, /*rank_zero_based=*/2);

    cv::Mat mat = solid(200, kWhite);
    band(mat, 15, 20, 10);  // banner, left column (x=0.10 -> pixel 20)
    band(mat, 15, 20, 20);  // factor row, left column
    band(mat, 95, 20, 20);  // factor row, right column (x=0.50 -> pixel 100)
    const Frame frame = Frame::fixed(mat);

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(config.area));

    REQUIRE(factors.size() == 2);
    CHECK(factors[0].id == 7);
    CHECK(factors[0].star == 3);  // rank 2, 1-based
}

TEST_CASE("visibleSelfPrefix stops before a row whose cell would fall off the frame, even inside the scroll area") {
    // The banner sits near the bottom (pixel 180), and the only factor row (pixel 186) is found within the
    // scan gap but its 0.08-tall cell would extend past the frame's bottom edge. The scroll area handed in
    // runs past the frame, so what refuses the row is the FRAME half of "the scroll area intersected with
    // the frame" -- the half that keeps a crop inside the image, where view() would otherwise throw.
    const auto config = factorConfig(/*banner_upper_gap=*/0.95);
    const auto recognizer = makeRecognizer(config, 7, 2);

    cv::Mat mat = solid(200, kWhite);
    band(mat, 15, 20, 180);  // banner near the bottom, left column
    band(mat, 15, 20, 186);  // factor row that would clip past the frame bottom
    const Frame frame = Frame::fixed(mat);

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(rect(0.0, 0.0, 1.0, 1.2)));

    CHECK(factors.empty());
}

// ---------------------------------------------------------------------------------------------------
// Live-frame layout cases.
//
// visibleSelfPrefix runs on a LIVE frame (the scraper's fragment #0), not on the stitched image the
// rest of the recognizer sees. On a live frame the scroll area sits where the record's layout puts it,
// and the Friend full-record layout drops it by the height of the "register practice partner" button.
// The cases below paint that geometry at the pixel rows measured off a real clip, so a scan that starts
// from the wrong place is visible as wrong factors rather than as no factors.
//
// Measured from testdata/clips/golden/friend_standard.mp4 frame 165 (736x1308, anchor unit 735), at the
// scan column x = left_rect.left(): the tab-bar pill's top edge at row 676, the pill body at 706-719, the
// scroll area top at 727, the green factor header at 742-769, and the first two factor rows at 788 and
// 848. The offsets below are those rows expressed relative to the scroll area top, so the fixture stays
// internally consistent if the configured rects move.
// ---------------------------------------------------------------------------------------------------

constexpr int kFrameWidth = 736;
constexpr int kFrameHeight = 1308;

// Values pinned from native/tool/builder/chara_detail_recognizer_builder.h (factorTab),
// chara_detail_scene_scraper_builder.h (common / friendCommon) and chara_detail_geometry.h (the Standard scroll
// area's top). They are copies, not the source of truth:
// what these cases assert is the RELATIONSHIP between the supplied content area and the scan, so the exact
// numbers only have to be plausible production geometry. The golden suite covers the real values.
constexpr double kScanTop = 0.9111;
constexpr double kCommonScrollAreaTop = 0.8093;
// How far the friend scroll area sits below the Standard one. It keeps common's bottom edge and loses the
// difference of the two visible content heights, so its top drops by that difference -- see friendCommon in
// chara_detail_scene_scraper_builder.h. NOT the tab bar's drop, which is a few pixels smaller.
constexpr double kFriendScrollAreaDrop = 0.738 - 0.553;
// How far above the bottom of the frame the scroll area ends: common's bottom_right, which friend_common keeps.
constexpr double kScrollAreaBottomInset = 0.2426;

// The scroll area of a live frame whose scroll area starts at pixel row `content_top`, ending where production's
// does. Its bottom edge is part of what the reader is handed, so it is production geometry rather than a stand-in.
Rect<double> liveScrollArea(const Frame &frame, int content_top) {
    const auto anchor = frame.anchor();
    return rect(
        0.0,
        anchor.mapFromFrame(Point<int>{0, content_top}).y(),
        1.0,
        anchor.mapFromFrame(Point<int>{0, kFrameHeight}).y() - kScrollAreaBottomInset);
}

recognizer_config::FactorTabConfig productionFactorConfig() {
    const double top_offset = 0.9259 - kScanTop;
    const double bottom_offset = 0.9537 - kScanTop;
    const auto left_rect = rect(0.2426, top_offset, 0.5519, bottom_offset);
    const auto right_rect = rect(0.6259, top_offset, 0.9352, bottom_offset);
    return {
        "factor",  // module_path
        Range<Color>{Color(235, 235, 235), Color(255, 255, 255)},  // bg_color
        rect(0.0, kCommonScrollAreaTop, 1.0, 1.2),  // area (stitched-image rect; these cases never read with it)
        left_rect,
        right_rect,
        0.9852 - 0.9111,  // vertical_delta
        0.0555,  // vertical_banner_upper_gap
        0.0481 + 0.0056,  // vertical_banner_bottom_delta
        0.0129,  // vertical_factor_gap
        1.3704 - 1.3111,  // vertical_chara_gap
        {"factor_rank",
         rect(0.3315 - left_rect.left(), 0.9556 - kScanTop, 0.4259 - left_rect.left(), 0.9833 - kScanTop)},
        {basicModule("character"), basicModule("character_rank")},
    };
}

// A factor predictor that reports the marker byte painted into the cell it was handed, so a case can state
// WHICH row the scan read rather than only how many rows it read.
std::unique_ptr<const recognizer::Predictor<int>> markerFactorPredictor() {
    return testutil::functionPredictor<int>("factor", [](const Frame &view) {
        return recognizer::Predicted<int>{view.colorAt(Point<double>{0.02, 0.02}).b(), 1.0f, {}};
    });
}

FactorRowReader makeMarkerRecognizer(const recognizer_config::FactorTabConfig &config) {
    return FactorRowReader{
        config,
        markerFactorPredictor(),
        constantPredictor<int>("factor_rank", 0),
    };
}

// Paints a horizontal band over [start_x, end_x) x [top_y, bottom_y) carrying `marker` in the blue channel.
void slab(cv::Mat &mat, int start_x, int end_x, int top_y, int bottom_y, int marker) {
    mat(cv::Rect(start_x, top_y, end_x - start_x, bottom_y - top_y)).setTo(cv::Scalar(marker, 0, 0));
}

// Builds a live factor-tab frame whose scroll area starts at `content_top_px`, with the tab bar above it
// and two factor rows below the green header.
cv::Mat liveFactorTabFrame(int content_top_px) {
    cv::Mat mat(kFrameHeight, kFrameWidth, CV_8UC3, cv::Scalar(240, 240, 240));
    const int left_x0 = 175, left_x1 = 410, right_x0 = 455, right_x1 = 695;
    // Tab bar: the pill's top edge, then its body. Both sit ABOVE the scroll area, and both are inside the
    // stretch a scan that started at the common scroll-area top would have to cross.
    slab(mat, left_x0, right_x1, content_top_px - 52, content_top_px - 50, 90);
    slab(mat, left_x0, right_x1, content_top_px - 22, content_top_px - 9, 99);
    // Green "factor" header at the top of the scroll area.
    slab(mat, left_x0, right_x1, content_top_px + 15, content_top_px + 43, 70);
    // Two factor rows, left and right column, each carrying its own marker.
    slab(mat, left_x0, left_x1, content_top_px + 61, content_top_px + 109, 11);
    slab(mat, right_x0, right_x1, content_top_px + 61, content_top_px + 109, 12);
    slab(mat, left_x0, left_x1, content_top_px + 121, content_top_px + 169, 21);
    slab(mat, right_x0, right_x1, content_top_px + 121, content_top_px + 169, 22);
    return mat;
}

TEST_CASE("visibleSelfPrefix reads the Standard layout's own scroll area") {
    // Positive control for the Friend case below: on the Standard layout the live scroll area happens to
    // coincide with the stitched-image rect in config.area, so this case passes either way. It is here so a
    // Friend failure can be read as "the layout was not carried", not as "the fixture is wrong".
    const auto config = productionFactorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const int content_top = static_cast<int>(std::lround(kCommonScrollAreaTop * kFrameWidth));

    const Frame frame = Frame::fixed(liveFactorTabFrame(content_top));
    const auto content_area = liveScrollArea(frame, content_top);

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(content_area));

    REQUIRE(factors.size() == 4);
    CHECK(factors[0].id == 11);
    CHECK(factors[1].id == 12);
    CHECK(factors[2].id == 21);
    CHECK(factors[3].id == 22);
}

TEST_CASE("visibleSelfPrefix reads the Friend layout's scroll area, not the configured one") {
    // The Friend full-record layout drops the scroll area by kFriendScrollAreaDrop. config.area still names
    // the Standard position, so a scan anchored to it starts 136 px too high: the 41 px banner gap lands in
    // empty space above the tab bar and finds nothing at all, and merely lengthening the gap would latch
    // onto the tab bar instead (markers 90 / 99) and read the pill body as a factor row. Only the caller's
    // content area puts the scan on the green header.
    const auto config = productionFactorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const int content_top =
        static_cast<int>(std::lround((kCommonScrollAreaTop + kFriendScrollAreaDrop) * kFrameWidth));

    const Frame frame = Frame::fixed(liveFactorTabFrame(content_top));
    const auto content_area = liveScrollArea(frame, content_top);

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(content_area));

    REQUIRE(factors.size() == 4);
    CHECK(factors[0].id == 11);
    CHECK(factors[1].id == 12);
    CHECK(factors[2].id == 21);
    CHECK(factors[3].id == 22);
}

// ---------------------------------------------------------------------------------------------------
// The scroll-area bound.
//
// A read must not reach below the scroll area. On a live frame that is the bottom UI: its edge shadow can
// pass for a row top, and a row whose star cell crosses the edge shows the models pixels the stitched record
// is never given. Every case below uses factorConfig() on a 200 px frame (anchor unit 200): the banner at
// y 10, so row 1's search starts at y 14; a row's name cell (left_rect) is 16 px tall and its star cell
// (basicModule's 0.1 square) 20 px, both from the row top, so the STAR cell is the one that crosses an edge
// first. Row 1 at y 20 puts row 2's search window at [32, 52) and row 3's at [52, 72).
//
// Each cell carries a marker (10 * row + 1 on the left, + 2 on the right) that markerFactorPredictor reports,
// so a case states WHICH cells were read, not just how many.
// ---------------------------------------------------------------------------------------------------

constexpr int kBoundFrameSize = 200;

// A scroll area from the frame's top to pixel row `bottom_px` (exclusive), full width.
Rect<double> scrollAreaTo(int bottom_px) {
    return rect(0.0, 0.0, 1.0, static_cast<double>(bottom_px) / kBoundFrameSize);
}

// The banner, then one row per {left top, right top} pair, each cell a 2 px marker slab at its top.
cv::Mat boundTestFrame(const std::vector<std::pair<int, int>> &row_tops) {
    cv::Mat mat = solid(kBoundFrameSize, kWhite);
    band(mat, 15, 20, 10);  // banner, left column
    for (std::size_t row = 0; row < row_tops.size(); row++) {
        const int marker = 10 * static_cast<int>(row + 1);
        slab(mat, 20, 80, row_tops[row].first, row_tops[row].first + 2, marker + 1);
        slab(mat, 100, 160, row_tops[row].second, row_tops[row].second + 2, marker + 2);
    }
    return mat;
}

std::vector<int> idsOf(const std::vector<record::Factor> &factors) {
    std::vector<int> ids;
    for (const auto &factor : factors) {
        ids.push_back(factor.id);
    }
    return ids;
}

TEST_CASE("a stain directly below the scroll area is not read as a row") {
    // The player_standard shape: the scroll area's edge shadow is one level out of the background range, inside
    // the next row's search window, so the search finds a "row" there whose cells are the bottom UI. A reader
    // bounded by the frame reads that phantom row (marker 240, the background under it).
    const auto config = factorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    cv::Mat mat = boundTestFrame({{20, 20}, {40, 40}});
    mat.row(64).setTo(cv::Scalar(190, 190, 190));  // one non-background row, the first row below the area
    const Frame frame = Frame::fixed(mat);

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(scrollAreaTo(64)));

    CHECK(idsOf(factors) == std::vector<int>{11, 12, 21, 22});
}

TEST_CASE("a row whose name cell fits the scroll area but whose star cell crosses it is not read") {
    // The friend_standard shape: row 2's name cell ends at y 56, inside an area ending at 58, while its star
    // cell ends at 60. Testing the name cell alone would hand the star model two pixel rows outside the area.
    const auto config = factorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const Frame frame = Frame::fixed(boundTestFrame({{20, 20}, {40, 40}}));

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(scrollAreaTo(58)));

    CHECK(idsOf(factors) == std::vector<int>{11, 12});
}

TEST_CASE("a row whose star cell ends exactly on the scroll area's bottom edge is read") {
    // The boundary itself, and the positive control for the case above: row 2's star cell is [40, 60) and the
    // area is [0, 60), so both of its cells are inside and the row is read in full.
    const auto config = factorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const Frame frame = Frame::fixed(boundTestFrame({{20, 20}, {40, 40}}));

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(scrollAreaTo(60)));

    CHECK(idsOf(factors) == std::vector<int>{11, 12, 21, 22});
}

// ---------------------------------------------------------------------------------------------------
// The factor limit.
//
// A single-frame read never holds more than its window's factor_limit (the layout's
// self_factor_prefix_length): the rows past it are not promised to be readable, so they are not read. The
// probe and the character-switch rule both take this read, so the limit applies to both of them; the stitched
// record's read takes no window and reads everything (recognizeOne with no limit, in
// FactorTabRecognizer::recognize).
// ---------------------------------------------------------------------------------------------------

TEST_CASE("a read stops at the window's limit even when more rows lie inside the scroll area") {
    // Four cells inside config.area, a limit of three: the read ends after row 2's left cell, which is also what a
    // limit that falls between a row's two cells looks like. A limit of two ends on a row boundary.
    const auto config = factorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const Frame frame = Frame::fixed(boundTestFrame({{20, 20}, {40, 40}}));
    // The control: the bound alone lets all four through, so a shorter list below is the limit's doing.
    REQUIRE(idsOf(recognizer.visibleSelfPrefix(frame, boundOnly(config.area))) == std::vector<int>{11, 12, 21, 22});

    CHECK(idsOf(recognizer.visibleSelfPrefix(frame, SelfFactorWindow{config.area, 3})) == std::vector<int>{11, 12, 21});
    CHECK(idsOf(recognizer.visibleSelfPrefix(frame, SelfFactorWindow{config.area, 2})) == std::vector<int>{11, 12});
}

TEST_CASE("a read shorter than the window's limit returns every row inside the scroll area, the last one included") {
    // Nothing is dropped from the end of a list the limit did not stop: the bound already keeps out every cell that
    // is cut off, so the last factor read is as fully visible as the first. A limit equal to the factor count is
    // the boundary: all four are read, and the list is not below the limit.
    const auto config = factorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const Frame frame = Frame::fixed(boundTestFrame({{20, 20}, {40, 40}}));

    CHECK(idsOf(recognizer.visibleSelfPrefix(frame, SelfFactorWindow{config.area, 5})) == std::vector<int>{11, 12, 21, 22});
    CHECK(idsOf(recognizer.visibleSelfPrefix(frame, SelfFactorWindow{config.area, 4})) == std::vector<int>{11, 12, 21, 22});
}

TEST_CASE("a limited read hands the models no cell past the limit") {
    // "Not read" and not "read, then dropped": both models are asked exactly `limit` times. A reader that read the
    // whole area and truncated afterwards would ask four times and return the same list, so the list alone could
    // not tell the two apart.
    const auto config = factorConfig();
    std::atomic<int> factor_calls{0};
    std::atomic<int> rank_calls{0};
    const FactorRowReader reader{
        config,
        testutil::functionPredictor<int>(
            "factor",
            [&factor_calls](const Frame &) {
                ++factor_calls;
                return recognizer::Predicted<int>{7, 1.0f, {}};
            }),
        testutil::functionPredictor<int>(
            "factor_rank",
            [&rank_calls](const Frame &) {
                ++rank_calls;
                return recognizer::Predicted<int>{0, 1.0f, {}};
            }),
    };
    const Frame frame = Frame::fixed(boundTestFrame({{20, 20}, {40, 40}}));

    const auto factors = reader.visibleSelfPrefix(frame, SelfFactorWindow{config.area, 3});

    CHECK(factors.size() == 3);
    CHECK(factor_calls.load() == 3);
    CHECK(rank_calls.load() == 3);
}

// THE FLAG THE FRONT END RECEIVES IS THE READ'S, END TO END. The reader's list goes into messages::factorProbe with
// the limit it was read under, which is what CharaDetailRecognizer::probe does (that class has no injection ctor,
// so this composes the two halves it joins). below_threshold is asserted in the message text, on both sides of the
// boundary.
TEST_CASE("the probe message states below_threshold for exactly the reads that are shorter than their limit") {
    const auto config = factorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const Frame frame = Frame::fixed(boundTestFrame({{20, 20}, {40, 40}}));
    const auto message = [&](std::size_t limit) {
        const auto factors = recognizer.visibleSelfPrefix(frame, SelfFactorWindow{config.area, limit});
        return json_util::Json::parse(app::messages::factorProbe(factors, limit, false, "probe_record"));
    };

    // Stopped by the limit: as many factors as the limit, not below it.
    const auto stopped = message(3);
    CHECK(stopped.at("factors").size() == 3);
    CHECK(stopped.at("below_threshold") == false);
    // The list ends exactly at the limit: still not below it.
    const auto exact = message(4);
    CHECK(exact.at("factors").size() == 4);
    CHECK(exact.at("below_threshold") == false);
    // The list ended first: below.
    const auto ended = message(5);
    CHECK(ended.at("factors").size() == 4);
    CHECK(ended.at("below_threshold") == true);
}

TEST_CASE("a row whose left cell fits and whose right cell does not keeps the left factor and ends the list") {
    // The two columns find their row tops independently (measured on friend_standard_many_rental frames that
    // were still settling: left 782, right 786). Row 2's left star cell ends at 60, its right one at 64, and the
    // area ends at 60: the left factor is read and the scan stops there, reading neither the right one nor
    // anything below.
    const auto config = factorConfig();
    const auto recognizer = makeMarkerRecognizer(config);
    const Frame frame = Frame::fixed(boundTestFrame({{20, 20}, {40, 44}}));

    const auto factors = recognizer.visibleSelfPrefix(frame, boundOnly(scrollAreaTo(60)));

    CHECK(idsOf(factors) == std::vector<int>{11, 12, 21});
}

TEST_CASE("the stitched recognition stops at config.area as well") {
    // ONE RULE ON EVERY PATH. FactorTabRecognizer::recognize reads the stitched image with config.area as its
    // scroll area, so the same stain below it that the live read refuses is refused here too -- for self and for
    // both parents, whose searches start inside the stain's window.
    auto config = factorConfig();
    config.area = scrollAreaTo(64);
    auto rows = std::make_shared<const FactorRowReader>(
        config, markerFactorPredictor(), constantPredictor<int>("factor_rank", 0));
    const FactorTabRecognizer recognizer{
        config,
        rows,
        constantPredictor<Chara>("character", Chara{}),
        constantPredictor<int>("character_rank", 0),
    };
    cv::Mat mat = boundTestFrame({{20, 20}, {40, 40}});
    mat.row(64).setTo(cv::Scalar(190, 190, 190));
    const Frame frame = Frame::fixed(mat);
    record::CharaDetailRecord record{};
    CropInfo crop_info;
    PredictionHistory history;

    recognizer.recognize(frame, RecordInfo{"record", record::Standard}, record, crop_info, history);

    CHECK(idsOf(record.factors.self) == std::vector<int>{11, 12, 21, 22});
    CHECK(record.factors.parent1.empty());
    CHECK(record.factors.parent2.empty());
}

TEST_CASE("FactorRowReader never lets two callers into one of its models at once") {
    // THE PROPERTY THE SHARING RESTS ON. One reader serves two stages on two threads (the recognizer and the scene
    // scraper), and a model instance must never be entered twice at once (recognizer::Model::predict mutates
    // session state). Nothing in the type system says so; the admission in front of each model does, so this
    // asserts the property directly instead of hoping a data race shows up somewhere downstream.
    //
    // Each fake model counts the callers inside it and records the most it ever saw. The body yields while
    // inside, which widens any overlap an unserialized reader would allow; no case outcome depends on how long
    // anything sleeps.
    struct Occupancy {
        std::atomic<int> inside{0};
        std::atomic<int> most{0};
    };
    const auto occupied = [](Occupancy &o, int value) {
        return [&o, value](const Frame &) {
            const int now = ++o.inside;
            int seen = o.most.load();
            while (now > seen && !o.most.compare_exchange_weak(seen, now)) {
            }
            for (int i = 0; i < 50; i++) {
                std::this_thread::yield();
            }
            --o.inside;
            return recognizer::Predicted<int>{value, 1.0f, {}};
        };
    };
    Occupancy factor_occupancy;
    Occupancy rank_occupancy;
    const auto config = factorConfig();
    const FactorRowReader reader{
        config,
        testutil::functionPredictor<int>("factor", occupied(factor_occupancy, 7)),
        testutil::functionPredictor<int>("factor_rank", occupied(rank_occupancy, 2)),
    };

    cv::Mat mat = solid(200, kWhite);
    band(mat, 15, 20, 10);  // banner
    band(mat, 15, 20, 20);  // factor row, left column
    band(mat, 95, 20, 20);  // factor row, right column
    const Frame frame = Frame::fixed(mat);

    constexpr int kThreads = 4;
    constexpr int kReadsPerThread = 200;
    std::atomic<int> wrong_reads{0};
    std::vector<std::thread> threads;
    for (int t = 0; t < kThreads; t++) {
        threads.emplace_back([&]() {
            for (int i = 0; i < kReadsPerThread; i++) {
                const auto factors = reader.visibleSelfPrefix(frame, boundOnly(config.area));
                if (factors.size() != 2) {
                    ++wrong_reads;
                }
            }
        });
    }
    for (auto &thread : threads) {
        thread.join();
    }

    CHECK(wrong_reads.load() == 0);
    CHECK(factor_occupancy.most.load() == 1);
    CHECK(rank_occupancy.most.load() == 1);
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
