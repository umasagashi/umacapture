// Behavioral tests for StatusHeaderRecognizer.
//
// StatusHeaderRecognizer has no vertical scan: it just predicts fixed rects and maps the results into the
// record. The tests pin the inheritance-only gate (evaluation/status are skipped for inheritance-only records
// while aptitudes are always read) and the array-to-struct field mapping. Exercised through the injection
// ctor with fake Predictors; this TU links into the onnxruntime-less umacapture_tests target.

#include <doctest/doctest.h>

#include <array>
#include <memory>
#include <string>

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

Rect<double> rect(double left, double top, double right, double bottom) {
    return {Point<double>{left, top}, Point<double>{right, bottom}};
}

template<size_t n>
std::array<Rect<double>, n> sameRects() {
    std::array<Rect<double>, n> rects;
    rects.fill(rect(0.0, 0.0, 0.1, 0.1));
    return rects;
}

recognizer_config::StatusHeaderConfig statusHeaderConfig() {
    return {
        {"evaluation", rect(0.0, 0.0, 0.1, 0.1)},  // evaluation
        {"status", sameRects<5>()},  // status
        {"aptitude", sameRects<10>()},  // aptitude
    };
}

// A predictor that returns increasing values (first * step, ...) in call order, so a test can verify which
// rect a result was mapped to.
std::unique_ptr<const recognizer::Predictor<int>> rampPredictor(std::string name, int first, int step) {
    auto calls = std::make_shared<int>(0);
    return functionPredictor<int>(std::move(name), [calls, first, step](const Frame &) {
        const int i = (*calls)++;
        return recognizer::Predicted<int>{first + i * step, 1.0f, {}};
    });
}

StatusHeaderRecognizer makeRecognizer(const recognizer_config::StatusHeaderConfig &config) {
    return StatusHeaderRecognizer{
        config,
        constantPredictor<int>("evaluation_value", 42),
        rampPredictor("status_value", 10, 10),  // 10, 20, 30, 40, 50
        rampPredictor("aptitude", 1, 1),  // 1..10
    };
}

TEST_CASE("StatusHeaderRecognizer reads evaluation, status and aptitudes for a standard record") {
    const auto config = statusHeaderConfig();
    const auto recognizer = makeRecognizer(config);

    const Frame frame = Frame::fixed(solid(200, kWhite));
    record::CharaDetailRecord record{};
    PredictionHistory history;
    const RecordInfo info{"rec", record::Standard};

    recognizer.recognize(frame, info, record, history);

    CHECK(record.evaluation_value == 42);
    // status array maps in order: speed, stamina, power, guts, intelligence.
    CHECK(record.status.speed == 10);
    CHECK(record.status.stamina == 20);
    CHECK(record.status.intelligence == 50);
    // aptitude array slices into ground / distance / style.
    CHECK(record.aptitudes.ground.turf == 1);
    CHECK(record.aptitudes.distance.short_range == 3);
    CHECK(record.aptitudes.style.late_charge == 10);
}

TEST_CASE("StatusHeaderRecognizer skips evaluation and status for an inheritance-only record") {
    // Inheritance-only records show no evaluation value or base stats, so those predictions are skipped and
    // the fields keep their defaults. Aptitudes are still read.
    const auto config = statusHeaderConfig();
    const auto recognizer = makeRecognizer(config);

    const Frame frame = Frame::fixed(solid(200, kWhite));
    record::CharaDetailRecord record{};
    PredictionHistory history;
    const RecordInfo info{"rec", record::InheritanceOnly};

    recognizer.recognize(frame, info, record, history);

    CHECK(record.evaluation_value == 0);
    CHECK(record.status.speed == 0);
    CHECK(record.aptitudes.ground.turf == 1);  // aptitudes still read
}

}  // namespace
}  // namespace uma::chara_detail::recognizer_impl
