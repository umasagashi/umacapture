#pragma once

#include <cstdint>
#include <string>

#include "cv/frame.h"
#include "util/json_util.h"

namespace uma::recognizer {

// The decoded outcome of a single model inference: the recognized value, its confidence, and the JSON
// blob the recognizer appends to its PredictionHistory. This header names no onnxruntime type, so the
// recognizer consumes inference results without naming Ort::Value, and the scan-orchestration logic can be
// compiled (and unit-tested) without the ONNX runtime.
template<typename Result>
struct Predicted {
    Result result;
    float confidence;
    json_util::Json json;
};

// The scalar heads of one inference, read by position. A decoder turns these into a Predicted<Result> without
// knowing how the platform ran the model: desktop reads them off onnxruntime tensors (cv/model.h), the Wasm
// build off the doubles its JS bridge writes back (native/wasm/wasm_recognizer_models.cpp).
class PredictionOutputs {
public:
    [[nodiscard]] virtual std::int64_t int64At(int index) const = 0;

    [[nodiscard]] virtual float floatAt(int index) const = 0;

protected:
    ~PredictionOutputs() = default;
};

// The inference seam the recognizers depend on. Model<Decoder> implements it for production (running ONNX and
// decoding the tensors); tests supply a fake that returns scripted Predicted values against
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
