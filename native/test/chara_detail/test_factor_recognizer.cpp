// Behavioral tests for FactorTabRecognizer's scan orchestration.
//
// Exercised through the injection ctor with fake Predictors (see test/util/fake_predictor.h); this TU links
// into the onnxruntime-less umacapture_tests target.

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

const Color kWhite{240, 240, 240};
const Color kBlack{0, 0, 0};
const Range<Color> kBgRange{Color(200, 200, 200), Color(255, 255, 255)};

Rect<double> rect(double left, double top, double right, double bottom) {
    return {Point<double>{left, top}, Point<double>{right, bottom}};
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

FactorTabRecognizer
makeRecognizer(const recognizer_config::FactorTabConfig &config, int factor_id, int rank_zero_based) {
    return FactorTabRecognizer{
        config,
        constantPredictor<int>("factor", factor_id),
        constantPredictor<int>("factor_rank", rank_zero_based),
        constantPredictor<Chara>("character", Chara{0, 0, 0, false, 0}),
        constantPredictor<int>("character_rank", 0),
    };
}

// Paints a thin horizontal content band spanning x=[start_x, start_x+w) at pixel row y.
void band(cv::Mat &mat, int start_x, int width, int y) {
    mat(cv::Rect(start_x, y, width, 2)).setTo(cv::Scalar(kBlack.b(), kBlack.g(), kBlack.r()));
}

TEST_CASE("recognizeVisibleSelf returns no factors when the top banner is not found") {
    // On an all-background frame the banner search (searchVertical over bg_color) never leaves the
    // background, so recognizeVisibleSelf bails and returns an empty list.
    const auto config = factorConfig();
    const auto recognizer = makeRecognizer(config, 0, 0);

    const Frame frame = Frame::fixed(solid(200, kWhite));
    PredictionHistory history;

    const auto factors = recognizer.recognizeVisibleSelf(frame, history);

    CHECK(factors.empty());
}

TEST_CASE("recognizeVisibleSelf reads a fully visible left+right row and makes the star 1-based") {
    // Banner at pixel 10 (x=0.10 column); one factor row at pixel 20 in both the left (x=0.10) and right
    // (x=0.50) columns. Both cells fit the frame, so two factors are read with star = rank + 1.
    const auto config = factorConfig();
    const auto recognizer = makeRecognizer(config, /*factor_id=*/7, /*rank_zero_based=*/2);

    cv::Mat mat = solid(200, kWhite);
    band(mat, 15, 20, 10);  // banner, left column (x=0.10 -> pixel 20)
    band(mat, 15, 20, 20);  // factor row, left column
    band(mat, 95, 20, 20);  // factor row, right column (x=0.50 -> pixel 100)
    const Frame frame = Frame::fixed(mat);
    PredictionHistory history;

    const auto factors = recognizer.recognizeVisibleSelf(frame, history);

    REQUIRE(factors.size() == 2);
    CHECK(factors[0].id == 7);
    CHECK(factors[0].star == 3);  // rank 2, 1-based
}

TEST_CASE("recognizeVisibleSelf stops before a row whose cell would fall off the frame") {
    // The banner sits near the bottom (pixel 180), and the only factor row (pixel 186) is found within the
    // scan gap but its 0.08-tall cell would extend past the frame's bottom edge. The bounded scan's
    // fits_frame guard drops it (preventing an out-of-bounds view()), so no factors are read.
    const auto config = factorConfig(/*banner_upper_gap=*/0.95);
    const auto recognizer = makeRecognizer(config, 7, 2);

    cv::Mat mat = solid(200, kWhite);
    band(mat, 15, 20, 180);  // banner near the bottom, left column
    band(mat, 15, 20, 186);  // factor row that would clip past the frame bottom
    const Frame frame = Frame::fixed(mat);
    PredictionHistory history;

    const auto factors = recognizer.recognizeVisibleSelf(frame, history);

    CHECK(factors.empty());
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
