// Behavioral tests for SupportCardRecognizer.
//
// The recognizer finds the card row top via searchVertical(loose_bg_color), then predicts six card ids and
// six ranks and writes them 1-based. Exercised through the injection ctor with fake Predictors on a
// hand-built 200x200 frame; this TU links into the onnxruntime-less test target.

#include <doctest/doctest.h>

#include <array>
#include <memory>
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

using testutil::functionPredictor;
using testutil::solid;

const Color kWhite{240, 240, 240};
const Color kBlack{0, 0, 0};
const Range<Color> kBgRange{Color(200, 200, 200), Color(255, 255, 255)};

Rect<double> rect(double left, double top, double right, double bottom) {
    return {Point<double>{left, top}, Point<double>{right, bottom}};
}

template<size_t n>
std::array<Rect<double>, n> sameRects() {
    std::array<Rect<double>, n> rects;
    rects.fill(rect(0.0, 0.0, 0.1, 0.1));
    return rects;
}

recognizer_config::CampaignTabCommonConfig commonConfig() {
    return {rect(0.0, 0.0, 1.0, 1.0), kBgRange, kBgRange, kBgRange};
}

recognizer_config::SupportCardConfig supportCardConfig() {
    return {
        "support_card",  // module_path
        Point<double>{0.5, 0.0},  // scan_point
        sameRects<6>(),  // rects
        {"support_card_rank", sameRects<6>()},  // rank
        0.02,  // vertical_delta
    };
}

// Returns first, first+step, ... in call order, so the array-index mapping can be verified.
std::unique_ptr<const recognizer::Predictor<int>> rampPredictor(std::string name, int first, int step) {
    auto calls = std::make_shared<int>(0);
    return functionPredictor<int>(std::move(name), [calls, first, step](const Frame &) {
        const int i = (*calls)++;
        return recognizer::Predicted<int>{first + i * step, 1.0f, {}};
    });
}

SupportCardRecognizer makeRecognizer(
    const recognizer_config::SupportCardConfig &config, const recognizer_config::CampaignTabCommonConfig &common) {
    return SupportCardRecognizer{
        config,
        common,
        rampPredictor("support_card", 10, 1),  // ids 10..15
        rampPredictor("support_card_rank", 0, 1),  // ranks 0..5 -> 1..6
    };
}

TEST_CASE("SupportCardRecognizer leaves cards default and scan_top unchanged when no card top is found") {
    const auto config = supportCardConfig();
    const auto common = commonConfig();
    const auto recognizer = makeRecognizer(config, common);

    const Frame frame = Frame::fixed(solid(200, kWhite));
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.33;

    recognizer.recognize(frame, record, scan_top, history);

    CHECK(record.support_cards[0].id == 0);
    CHECK(scan_top == doctest::Approx(0.33));  // untouched
}

TEST_CASE("SupportCardRecognizer reads six cards and makes ranks 1-based") {
    const auto config = supportCardConfig();
    const auto common = commonConfig();
    const auto recognizer = makeRecognizer(config, common);

    cv::Mat mat = solid(200, kWhite);
    mat(cv::Rect(95, 20, 10, 2)).setTo(cv::Scalar(kBlack.b(), kBlack.g(), kBlack.r()));  // card top at x=0.5
    const Frame frame = Frame::fixed(mat);
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    CHECK(record.support_cards[0].id == 10);
    CHECK(record.support_cards[0].rank == 1);  // rank 0, 1-based
    CHECK(record.support_cards[5].id == 15);
    CHECK(record.support_cards[5].rank == 6);
    CHECK(scan_top > 0.0);  // advanced past the card row
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
