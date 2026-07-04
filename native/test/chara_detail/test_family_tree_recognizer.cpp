// Behavioral tests for FamilyTreeRecognizer.
//
// The recognizer finds the tree's top (strict_bg_color) and bottom (frame_color) via two vertical scans, then
// picks the legacy or current icon layout by the tree's pixel height before predicting the parent icons.
// Exercised through the injection ctor with fake Predictors on a hand-built 200x200 frame; this TU links into
// the onnxruntime-less test target.
//
// The legacy/current branch only changes which icon rects are read, so it is observed with a
// content-inspecting Chara predictor: the legacy self-icon rect sits over a black marker and the current one
// over white background, so the reported icon (1 vs 0) reveals which layout was chosen.

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

using testutil::constantPredictor;
using testutil::functionPredictor;
using testutil::solid;

const Color kWhite{240, 240, 240};
const Color kBlack{0, 0, 0};
const Color kBlue{0, 0, 255};  // frame_color of the family tree border
const Range<Color> kBgRange{Color(200, 200, 200), Color(255, 255, 255)};
const Range<Color> kFrameRange{Color(0, 0, 200), Color(80, 80, 255)};

Rect<double> rect(double left, double top, double right, double bottom) {
    return {Point<double>{left, top}, Point<double>{right, bottom}};
}

recognizer_config::IconSetConfig iconSet(const Rect<double> &chara) {
    return {chara, rect(0.0, 0.0, 0.05, 0.05)};
}

recognizer_config::CampaignTabCommonConfig commonConfig() {
    return {rect(0.0, 0.0, 1.0, 1.0), kBgRange, kBgRange, kBgRange};
}

// The self-icon rect of parent1 differs between the two layouts; every other icon/rank rect is a safe
// in-bounds placeholder. legacy self sits at x=0.60, current self at x=0.80.
recognizer_config::FamilyTreeConfig familyConfig() {
    const auto placeholder = iconSet(rect(0.0, 0.0, 0.05, 0.05));
    const recognizer_config::FamilyTreeIconConfig legacy_icons{
        {iconSet(rect(0.60, 0.0, 0.70, 0.03)), placeholder, placeholder},
        {placeholder, placeholder, placeholder},
    };
    const recognizer_config::FamilyTreeIconConfig current_icons{
        {iconSet(rect(0.80, 0.0, 0.90, 0.03)), placeholder, placeholder},
        {placeholder, placeholder, placeholder},
    };
    return {
        {"chara", "rank"},  // module
        Point<double>{0.5, 0.0},  // scan_point
        0.02,  // vertical_gap
        kFrameRange,  // frame_color
        0.20,  // legacy_frame_height
        legacy_icons,  // legacy_icons
        current_icons,  // icons
        0.02,  // vertical_delta
    };
}

// A 200x200 white frame with a vertical blue tree-border strip at x=0.5 spanning [40, 40+height_px), plus a
// black marker over the legacy self-icon rect (x=[120,140), y=[40,46)). The blue strip height selects the
// legacy (tall) or current (short) layout.
Frame frameWithTree(int strip_height_px) {
    cv::Mat mat = solid(200, kWhite);
    mat(cv::Rect(95, 40, 10, strip_height_px)).setTo(cv::Scalar(kBlue.b(), kBlue.g(), kBlue.r()));
    mat(cv::Rect(120, 40, 20, 6)).setTo(cv::Scalar(kBlack.b(), kBlack.g(), kBlack.r()));
    return Frame::fixed(mat);
}

// A Chara predictor that reports icon=1 when its crop is mostly dark (the legacy marker) and icon=0 otherwise.
std::unique_ptr<const recognizer::Predictor<Chara>> markerSensingCharaPredictor() {
    return functionPredictor<Chara>("character", [](const Frame &view) {
        const cv::Scalar m = cv::mean(view.data());
        const int icon = m[0] < 128.0 ? 1 : 0;
        return recognizer::Predicted<Chara>{Chara{icon, 0, 0, false, 0}, 1.0f, {}};
    });
}

TEST_CASE("FamilyTreeRecognizer leaves the family default when the tree top is not found") {
    const auto config = familyConfig();
    const auto common = commonConfig();
    FamilyTreeRecognizer recognizer{
        config,
        common,
        constantPredictor<Chara>("character", Chara{9, 0, 0, false, 0}),
        constantPredictor<int>("character_rank", 0),
    };

    const Frame frame = Frame::fixed(solid(200, kWhite));
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    CHECK(record.family.parent1.self.icon == 0);  // untouched default
}

TEST_CASE("FamilyTreeRecognizer maps predicted icon/rank into the parent and sets rental") {
    // Short blue strip -> current layout. A constant Chara with rental=true and record_type FriendStandard is
    // mapped into parent1.self, and the parent's rental flag follows the self icon's rental bit.
    const auto config = familyConfig();
    const auto common = commonConfig();
    FamilyTreeRecognizer recognizer{
        config,
        common,
        constantPredictor<Chara>("character", Chara{1, 2, 3, true, static_cast<int>(record::FriendStandard)}),
        constantPredictor<int>("character_rank", 4),
    };

    const Frame frame = frameWithTree(/*strip_height_px=*/20);  // height ~0.10 < 0.20 -> current layout
    record::CharaDetailRecord record{};
    PredictionHistory history;
    double scan_top = 0.0;

    recognizer.recognize(frame, record, scan_top, history);

    const auto &self = record.family.parent1.self;
    CHECK(self.icon == 1);
    CHECK(self.character == 2);
    CHECK(self.card == 3);
    CHECK(self.rank == 4);
    REQUIRE(self.record_type.has_value());
    CHECK(self.record_type.value() == record::FriendStandard);
    REQUIRE(record.family.parent1.rental.has_value());
    CHECK(record.family.parent1.rental.value() == true);
}

TEST_CASE("FamilyTreeRecognizer selects the legacy icon layout for a tall tree") {
    // Tall blue strip -> frame_height > legacy_frame_height, so the legacy self-icon rect (over the black
    // marker) is read and the marker-sensing predictor reports icon=1. A short strip reads the current rect
    // (white) and reports icon=0.
    const auto config = familyConfig();
    const auto common = commonConfig();

    FamilyTreeRecognizer legacy_recognizer{
        config, common, markerSensingCharaPredictor(), constantPredictor<int>("character_rank", 0)};
    record::CharaDetailRecord legacy_record{};
    PredictionHistory legacy_history;
    double legacy_scan_top = 0.0;
    legacy_recognizer.recognize(frameWithTree(/*strip_height_px=*/80), legacy_record, legacy_scan_top, legacy_history);

    FamilyTreeRecognizer current_recognizer{
        config, common, markerSensingCharaPredictor(), constantPredictor<int>("character_rank", 0)};
    record::CharaDetailRecord current_record{};
    PredictionHistory current_history;
    double current_scan_top = 0.0;
    current_recognizer.recognize(
        frameWithTree(/*strip_height_px=*/20), current_record, current_scan_top, current_history);

    CHECK(legacy_record.family.parent1.self.icon == 1);  // legacy rect read (black marker)
    CHECK(current_record.family.parent1.self.icon == 0);  // current rect read (white)
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
