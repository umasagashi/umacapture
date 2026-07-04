// Behavioral tests for SkillTabRecognizer's row scan.
//
// The recognizer walks skill rows down the left and right columns via searchVertical, reading a level only
// for the very first (top-left) skill. Exercised through the injection ctor with fake Predictors on a
// hand-built 200x200 frame (1px == 0.005 normalized); this TU links into the onnxruntime-less test target.

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

recognizer_config::SkillTabConfig skillConfig() {
    return {
        "skill",  // module_path
        kBgRange,  // bg_color
        rect(0.0, 0.0, 1.0, 1.0),  // area
        rect(0.10, 0.0, 0.40, 0.05),  // left_rect
        rect(0.50, 0.0, 0.80, 0.05),  // right_rect
        0.06,  // vertical_delta
        0.03,  // vertical_margin
        0.30,  // vertical_gap
        {"skill_level", rect(0.0, 0.0, 0.1, 0.1)},  // skill_level
    };
}

SkillTabRecognizer makeRecognizer(const recognizer_config::SkillTabConfig &config, int skill_id, int level_zero_based) {
    return SkillTabRecognizer{
        config,
        constantPredictor<int>("skill", skill_id),
        constantPredictor<int>("skill_level", level_zero_based),
    };
}

void band(cv::Mat &mat, int start_x, int width, int y) {
    mat(cv::Rect(start_x, y, width, 2)).setTo(cv::Scalar(kBlack.b(), kBlack.g(), kBlack.r()));
}

TEST_CASE("SkillTabRecognizer returns no skills for an inheritance-only record") {
    const auto config = skillConfig();
    const auto recognizer = makeRecognizer(config, 5, 2);

    const Frame frame = Frame::fixed(solid(200, kWhite));
    record::CharaDetailRecord record{};
    PredictionHistory history;
    const RecordInfo info{"rec", record::InheritanceOnly};

    recognizer.recognize(frame, info, record, history);

    CHECK(record.skills.empty());
}

TEST_CASE("SkillTabRecognizer reads a level only for the first skill in a left+right row") {
    // One row at pixel 30 in both columns. The top-left skill carries a level (2 + 1 = 3); the right-column
    // skill in the same row does not.
    const auto config = skillConfig();
    const auto recognizer = makeRecognizer(config, /*skill_id=*/5, /*level_zero_based=*/2);

    cv::Mat mat = solid(200, kWhite);
    band(mat, 15, 20, 30);  // left column (x=0.10 -> pixel 20)
    band(mat, 95, 20, 30);  // right column (x=0.50 -> pixel 100)
    const Frame frame = Frame::fixed(mat);
    record::CharaDetailRecord record{};
    PredictionHistory history;
    const RecordInfo info{"rec", record::Standard};

    recognizer.recognize(frame, info, record, history);

    REQUIRE(record.skills.size() == 2);
    CHECK(record.skills[0].id == 5);
    REQUIRE(record.skills[0].level.has_value());
    CHECK(record.skills[0].level.value() == 3);  // 1-based
    CHECK_FALSE(record.skills[1].level.has_value());
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
