// Behavioral tests for CampaignRecordRecognizer and the pure formatTrainedDate helper.
//
// The recognizer's scan logic is exercised through its injection ctor, which takes fake Predictors instead of
// ONNX models (see test/util/fake_predictor.h and the TU split in chara_detail_recognizer.cpp). This TU links
// into the onnxruntime-less umacapture_tests target, proving the scan orchestration is ONNX-decoupled.

#include <doctest/doctest.h>

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

using testutil::constantPredictor;
using testutil::functionPredictor;
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

recognizer_config::CampaignTabCommonConfig commonConfig() {
    return {rect(0.0, 0.0, 1.0, 1.0), kBgRange, kBgRange, kBgRange};
}

recognizer_config::CampaignRecordConfig campaignConfig() {
    return {
        Point<double>{0.5, 0.0},  // scan_point
        Point<double>{0.6, 0.0},  // bg_scan_point (a separate column from scan_point)
        0.02,  // vertical_gap
        basicModule("campaign_field"),
        basicModule("fans_value"),
        basicModule("scenario"),
        basicModule("trained_date"),
        0.02,  // vertical_delta
    };
}

// -- formatTrainedDate ------------------------------------------------------------------------------------

TEST_CASE("formatTrainedDate reformats a valid YYYYMMDD value") {
    CHECK(formatTrainedDate(20241231) == "2024/12/31");
    CHECK(formatTrainedDate(20000101) == "2000/01/01");
}

TEST_CASE("formatTrainedDate returns the raw value when it is not exactly 8 digits") {
    CHECK(formatTrainedDate(1234567) == "1234567");  // 7 digits
    CHECK(formatTrainedDate(123456789) == "123456789");  // 9 digits
    CHECK(formatTrainedDate(0) == "0");
}

TEST_CASE("formatTrainedDate does not slice the sign of a negative value into the year") {
    // "-1234567" is 8 chars but not all digits, so it must degrade to the raw string rather than being read
    // as year "-123". This is the regression the digit check guards.
    CHECK(formatTrainedDate(-1234567) == "-1234567");
}

// -- CampaignRecordRecognizer scan ------------------------------------------------------------------------

TEST_CASE("CampaignRecordRecognizer leaves the record untouched when no area bottom is found") {
    // A frame that is entirely background: the initial findNext for the area bottom returns nullopt, so
    // recognize() bails before predicting any field. The record keeps its default-constructed values.
    const auto config = campaignConfig();
    const auto common = commonConfig();
    CampaignRecordRecognizer recognizer{
        config,
        common,
        constantPredictor<int>("campaign_field", 3),
        constantPredictor<int>("fans_value", 12345),
        constantPredictor<int>("scenario", 7),
        constantPredictor<std::string>("trained_date", "2024/01/01"),
    };

    const Frame frame = Frame::fixed(solid(200, kWhite));
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    CHECK(record.fans == 0);
    CHECK(record.scenario.id == 0);
    CHECK(record.trained_date.empty());
}

// A 200x200 white frame with two thin content bands at the scan column x=0.5 (pixels 60 and 110) and an
// area-bottom marker at the bg-scan column x=0.6 (pixel 160). findAll then returns exactly two field tops.
Frame frameWithTwoFields() {
    cv::Mat mat = solid(200, kWhite);
    const cv::Scalar black(kBlack.b(), kBlack.g(), kBlack.r());
    mat(cv::Rect(90, 60, 20, 3)).setTo(black);  // field 0 at x=0.5
    mat(cv::Rect(90, 110, 20, 3)).setTo(black);  // field 1 at x=0.5
    mat(cv::Rect(115, 160, 20, 3)).setTo(black);  // area bottom at x=0.6
    return Frame::fixed(mat);
}

TEST_CASE("CampaignRecordRecognizer keeps the higher-confidence detection when a class is seen twice") {
    // Both field tops resolve to class 3 (fans). The first is predicted with confidence 0.5, the second with
    // 0.9, so the second overwrites the first and record.fans reflects the second predictFans call (200).
    const auto config = campaignConfig();
    const auto common = commonConfig();

    auto class_calls = std::make_shared<int>(0);
    auto fans_calls = std::make_shared<int>(0);

    CampaignRecordRecognizer recognizer{
        config,
        common,
        functionPredictor<int>(
            "campaign_field",
            [class_calls](const Frame &) {
                const int i = (*class_calls)++;
                return recognizer::Predicted<int>{3, i == 0 ? 0.5f : 0.9f, {}};
            }),
        functionPredictor<int>(
            "fans_value",
            [fans_calls](const Frame &) {
                const int i = (*fans_calls)++;
                return recognizer::Predicted<int>{i == 0 ? 100 : 200, 1.0f, {}};
            }),
        constantPredictor<int>("scenario", 0),
        constantPredictor<std::string>("trained_date", ""),
    };

    const Frame frame = frameWithTwoFields();
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    CHECK(*class_calls == 2);  // both field tops were classified
    CHECK(record.fans == 200);  // higher-confidence (second) detection won
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
