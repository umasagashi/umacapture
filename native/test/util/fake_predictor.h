#pragma once

// Test double for recognizer::Predictor<Result>. The recognizers take their model inference through this
// interface (see cv/predictor.h), so a FakePredictor lets the scan-orchestration logic run against
// hand-built frames without the ONNX runtime. The predict() body is supplied as a std::function, so a test
// can return a constant, inspect the cropped view, or pop scripted results from a captured counter.

#include <functional>
#include <memory>
#include <string>
#include <utility>

#include "cv/frame.h"
#include "cv/predictor.h"

namespace uma::testutil {

template<typename Result>
class FakePredictor : public recognizer::Predictor<Result> {
public:
    using Fn = std::function<recognizer::Predicted<Result>(const Frame &)>;

    FakePredictor(std::string name, Fn fn)
        : model_name(std::move(name))
        , fn(std::move(fn)) {}

    [[nodiscard]] recognizer::Predicted<Result> predict(const Frame &frame) const override { return fn(frame); }

    [[nodiscard]] const std::string &name() const override { return model_name; }

private:
    std::string model_name;
    Fn fn;
};

// A predictor that ignores the frame and always returns the same value with the given confidence.
template<typename Result>
std::unique_ptr<const recognizer::Predictor<Result>>
constantPredictor(std::string name, Result value, float confidence = 1.0f) {
    return std::make_unique<FakePredictor<Result>>(
        std::move(name), [value = std::move(value), confidence](const Frame &) {
            return recognizer::Predicted<Result>{value, confidence, {}};
        });
}

// A predictor driven by a caller-supplied function (for scripted / view-inspecting fakes).
template<typename Result>
std::unique_ptr<const recognizer::Predictor<Result>>
functionPredictor(std::string name, typename FakePredictor<Result>::Fn fn) {
    return std::make_unique<FakePredictor<Result>>(std::move(name), std::move(fn));
}

}  // namespace uma::testutil
