#pragma once

// The check every platform runs on the outputs of a model before a decoder reads them.
//
// A decoder (chara_detail/recognizer_prediction.h) reads a fixed head layout: at least Decoder::kOutputCount
// outputs, each a single element, int64 labels through PredictionOutputs::int64At and float confidences through
// floatAt. Whether a loaded model actually has that layout is a fact of the model, not of the platform running
// it, so it is decided here, once, and each platform only reports what it can observe of its own outputs:
//   - desktop: cv/model.h, from the onnxruntime session (output count) and each Ort::Value (type, element count);
//   - web: native/wasm/wasm_recognizer_models.cpp, from what web/worker.js reports of the onnxruntime-web
//     session at load and of each output tensor it writes back.
// Both call the two functions below at the same points: requireOutputCount while the predictor is constructed,
// requireScalarOutput on every read. This header names neither onnxruntime nor Emscripten, so it is unit-tested
// directly (native/test/cv/test_prediction_check.cpp).

#include <cstddef>
#include <stdexcept>
#include <string>

namespace uma::recognizer {

// The element type of one output, in the terms a decoder reads it: int64At reads a kInt64 output, floatAt a
// kFloat one. A platform maps its runtime's own type tag onto this, and anything a decoder cannot read is kOther.
// The values are what the web bridge carries across the JS boundary (setupInferenceBridge hands them to JS).
enum class ScalarKind : int {
    kOther = 0,
    kInt64 = 1,
    kFloat = 2,
};

// What a platform observes of one output of a finished inference.
struct OutputDescription {
    ScalarKind kind;
    std::size_t element_count;
};

namespace prediction_check_impl {

inline const char *kindName(ScalarKind kind) {
    switch (kind) {
        case ScalarKind::kInt64: return "int64";
        case ScalarKind::kFloat: return "float";
        case ScalarKind::kOther: break;
    }
    return "other";
}

}  // namespace prediction_check_impl

// Load time. Throws std::runtime_error naming the model when its session has fewer outputs than the decoder reads.
// Both platforms call it while constructing the predictor, i.e. inside NativeApi::startPipeline, so the error
// reaches onError as a configuration error instead of surfacing later as every record being dropped.
inline void requireOutputCount(const std::string &model_name, std::size_t output_count, std::size_t required) {
    if (output_count < required) {
        throw std::runtime_error(
            "Model " + model_name + ": expected at least " + std::to_string(required) + " outputs, got "
            + std::to_string(output_count));
    }
}

// Per read. Throws unless output `index`, of an inference that produced `output_count` outputs, is a single
// element of the `expected` kind: std::out_of_range for an index outside the outputs or an empty output,
// std::invalid_argument for a wrong kind or more than one element. The recognizer's try/catch turns the throw
// into a dropped record.
//
// `describe(index)` returns the OutputDescription of that output. It is called only after `index` is known to be
// in range, so a platform may index its own storage with it unchecked: the range check comes first here rather
// than being left to each caller to remember.
template<typename Describe>
void requireScalarOutput(int index, std::size_t output_count, ScalarKind expected, const Describe &describe) {
    if (index < 0 || static_cast<std::size_t>(index) >= output_count) {
        throw std::out_of_range(
            "prediction output index " + std::to_string(index) + " is out of range (" + std::to_string(output_count)
            + " outputs)");
    }
    const OutputDescription output = describe(static_cast<std::size_t>(index));
    if (output.element_count < 1) {
        throw std::out_of_range("prediction output " + std::to_string(index) + " is empty");
    }
    if (output.kind != expected) {
        throw std::invalid_argument(
            "prediction output " + std::to_string(index) + " is " + prediction_check_impl::kindName(output.kind)
            + ", the decoder reads it as " + prediction_check_impl::kindName(expected));
    }
    if (output.element_count != 1) {
        throw std::invalid_argument(
            "prediction output " + std::to_string(index) + " has " + std::to_string(output.element_count)
            + " elements, the decoder reads a scalar");
    }
}

}  // namespace uma::recognizer
