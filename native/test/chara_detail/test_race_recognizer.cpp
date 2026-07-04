// Behavioral tests for RaceRecordRecognizer's block-scan orchestration.
//
// Exercised through the injection ctor with fake Predictors (see test/util/fake_predictor.h); this TU links
// into the onnxruntime-less umacapture_tests target. RaceRecordRecognizer owns two RaceBlockModelSets (the
// 1-line and 2-line variants), supplied here as RaceBlockPredictors holders.
//
// A block is located by a three-scan choreography on a hand-built 200x200 frame (unit_size == width == 200,
// so 1px == 0.005 normalized):
//   - findNextBlock: strict_bg (white) at the exact column x=0.5, scanning down for the block's top edge;
//   - findNextGap:   block_bg (gray) at the approx column x=0.4, scanning down past the block to its bottom;
//   - findLast:      strict_bg (white) at x=0.5, scanning UP from there for the exact bottom edge.
// A single gray rectangle spanning both columns synthesizes one block whose height picks the 1-/2-line set.

#include <doctest/doctest.h>

#include <string>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_recognizer.h"
#include "cv/frame.h"
#include "util/cv_test_helpers.h"
#include "util/fake_predictor.h"

namespace uma::chara_detail::recognizer_impl {
namespace {

using testutil::constantPredictor;
using testutil::solid;

const Color kWhite{240, 240, 240};  // strict/loose background
const Color kGray{128, 128, 128};  // block background
const Range<Color> kBgRange{Color(200, 200, 200), Color(255, 255, 255)};
const Range<Color> kBlockRange{Color(100, 100, 100), Color(160, 160, 160)};

Rect<double> rect(double left, double top, double right, double bottom) {
    return {Point<double>{left, top}, Point<double>{right, bottom}};
}

recognizer_config::BasicModuleConfig basicModule(const std::string &name) {
    return {name, rect(0.0, 0.0, 0.1, 0.1)};
}

recognizer_config::RaceBlockConfig blockConfig() {
    return {
        basicModule("race_title"),
        basicModule("race_place"),
        basicModule("race_turn"),
        basicModule("race_position"),
        basicModule("race_strategy"),
        basicModule("race_weather"),
    };
}

recognizer_config::CampaignTabCommonConfig commonConfig() {
    return {rect(0.0, 0.0, 1.0, 1.0), kBgRange, kBgRange, kBlockRange};
}

recognizer_config::RaceConfig raceConfig() {
    return {
        Point<double>{0.4, 0.0},  // approx_scan_point
        Point<double>{0.5, 0.0},  // exact_scan_point
        0.02,  // vertical_delta
        0.10,  // block_height_threshold
        blockConfig(),  // block_1line_config
        blockConfig(),  // block_2line_config
    };
}

// Six fake predictors for one block variant, in the struct's field order (title, place, weather, strategy,
// turn, position). `title` and `position` are parameterized so a test can tell which variant was chosen.
RaceBlockPredictors makeBlockPredictors(int title_id, int position_zero_based) {
    return {
        constantPredictor<int>("race_title", title_id),
        constantPredictor<RacePlace>("race_place", RacePlace{0, 0, 0, 0}),
        constantPredictor<int>("race_weather", 0),
        constantPredictor<int>("race_strategy", 0),
        constantPredictor<int>("race_turn", 0),
        constantPredictor<int>("race_position", position_zero_based),
    };
}

// A 200x200 white frame with one gray block rectangle spanning both scan columns (x in [70,110)).
Frame frameWithBlock(int block_top_px, int block_height_px) {
    cv::Mat mat = solid(200, kWhite);
    mat(cv::Rect(70, block_top_px, 40, block_height_px)).setTo(cv::Scalar(kGray.b(), kGray.g(), kGray.r()));
    return Frame::fixed(mat);
}

TEST_CASE("RaceRecordRecognizer records no races on an all-background frame") {
    // With the whole frame in strict_bg_color, findNextBlock finds no content and the scan loop breaks on the
    // first iteration, leaving record.races empty.
    const auto config = raceConfig();
    const auto common = commonConfig();
    RaceRecordRecognizer recognizer{config, common, makeBlockPredictors(11, 0), makeBlockPredictors(22, 4)};

    const Frame frame = Frame::fixed(solid(200, kWhite));
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    CHECK(record.races.empty());
}

TEST_CASE("RaceRecordRecognizer picks the 2-line model set for a tall block and makes position 1-based") {
    // Block spans pixels [40, 80): height ~0.195 > threshold 0.10, so the 2-line set (title 22) is used and
    // its position (4) is reported 1-based as 5.
    const auto config = raceConfig();
    const auto common = commonConfig();
    RaceRecordRecognizer recognizer{config, common, makeBlockPredictors(11, 0), makeBlockPredictors(22, 4)};

    const Frame frame = frameWithBlock(/*block_top_px=*/40, /*block_height_px=*/40);
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    REQUIRE(record.races.size() == 1);
    CHECK(record.races[0].title == 22);
    CHECK(record.races[0].position == 5);
}

TEST_CASE("RaceRecordRecognizer picks the 1-line model set for a short block") {
    // Block spans pixels [40, 55): height ~0.07 < threshold 0.10, so the 1-line set (title 11) is used.
    const auto config = raceConfig();
    const auto common = commonConfig();
    RaceRecordRecognizer recognizer{config, common, makeBlockPredictors(11, 0), makeBlockPredictors(22, 4)};

    const Frame frame = frameWithBlock(/*block_top_px=*/40, /*block_height_px=*/15);
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    REQUIRE(record.races.size() == 1);
    CHECK(record.races[0].title == 11);
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
