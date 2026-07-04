#pragma once

#include <string>

#include "cv/frame.h"
#include "util/json_util.h"

namespace uma::recognizer {

// The decoded outcome of a single model inference: the recognized value, its confidence, and the JSON
// blob the recognizer appends to its PredictionHistory. Splitting this out of the ONNX-backed Prediction
// types lets the recognizer consume inference results without naming Ort::Value, so the scan-orchestration
// logic can be compiled (and unit-tested) without the ONNX runtime.
template<typename Result>
struct Predicted {
    Result result;
    float confidence;
    json_util::Json json;
};

// The inference seam the recognizers depend on. Model<PredictionType> implements it for production (running
// ONNX and decoding the tensors); tests supply a fake that returns scripted Predicted values against
// hand-built frames. Keeping this interface ONNX-free is what lets chara_detail_recognizer.h drop its
// cv/model.h include, so the recognize()/scan sources link into the test target without onnxruntime.
template<typename Result>
class Predictor {
public:
    virtual ~Predictor() = default;

    [[nodiscard]] virtual Predicted<Result> predict(const Frame &frame) const = 0;

    [[nodiscard]] virtual const std::string &name() const = 0;
};

}  // namespace uma::recognizer
