#pragma once

#include <experimental_onnxruntime_cxx_api.h>
#include <filesystem>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <opencv2/opencv.hpp>

#include "cv/frame.h"
#include "cv/prediction_check.h"
#include "cv/predictor.h"
#include "types/shape.h"
#include "util/logger_util.h"

namespace uma::recognizer {

namespace recognizer_impl {

// A single ONNX Runtime environment shared across every Model. Ort::Env is intended to be a per-process
// singleton (it owns the shared logging/threading state); one env per model wastes those resources. The
// function-local static is destroyed at process exit, after every Model's Session, so it outlives them.
inline Ort::Env &shared_env() {
    static Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "umacapture"};
    return env;
}

}  // namespace recognizer_impl

// The onnxruntime outputs of one inference, read through PredictionOutputs by the shared decoders. Every read
// passes through requireScalarOutput (cv/prediction_check.h), the check the Wasm build runs on its bridged
// outputs too; this class only describes each Ort::Value to it.
class Prediction final : public PredictionOutputs {
public:
    explicit Prediction(std::vector<Ort::Value> data)
        : data(std::move(data)) {}

    [[nodiscard]] std::int64_t int64At(int index) const override {
        return *checked(index, ScalarKind::kInt64).GetTensorData<std::int64_t>();
    }

    [[nodiscard]] float floatAt(int index) const override {
        return *checked(index, ScalarKind::kFloat).GetTensorData<float>();
    }

private:
    [[nodiscard]] static ScalarKind kindOf(ONNXTensorElementDataType type) {
        switch (type) {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return ScalarKind::kInt64;
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: return ScalarKind::kFloat;
            default: return ScalarKind::kOther;
        }
    }

    // A real check in release, not a Debug-only assert: the caller dereferences element 0 of the returned value, so
    // an index outside the outputs or an empty tensor would otherwise be undefined behaviour.
    [[nodiscard]] const Ort::Value &checked(int index, ScalarKind expected) const {
        requireScalarOutput(index, data.size(), expected, [this](std::size_t i) {
            const auto info = data[i].GetTensorTypeAndShapeInfo();
            return OutputDescription{kindOf(info.GetElementType()), info.GetElementCount()};
        });
        return data[static_cast<std::size_t>(index)];
    }

    std::vector<Ort::Value> data;
};

// Decoder supplies the head layout: `Result`, `kOutputCount` (the highest output index it reads, plus one) and
// `static Predicted<Result> decode(const PredictionOutputs &)`.
template<typename Decoder>
class Model : public Predictor<typename Decoder::Result> {
public:
    using Result = typename Decoder::Result;

    [[maybe_unused]] Model(const std::filesystem::path &path, const std::string &name)
        : model_name(name)
        , input_size(-1, -1) {
        log_debug("Load model from {}", std::filesystem::absolute(path).string());
        std::filesystem::path::string_type path_str = path;
        prediction =
            std::make_unique<Ort::Experimental::Session>(recognizer_impl::shared_env(), path_str, session_options);
        const auto input_shapes = prediction->GetInputShapes();
        if (input_shapes.empty() || input_shapes[0].size() < 3) {
            throw std::runtime_error("Model " + name + ": unexpected input shape rank");
        }
        const auto &input_shape = input_shapes[0];
        // A model exported with dynamic H/W axes reports -1 here; that would make input_size negative and
        // surface only later as an opaque cv::resize assertion in predict(). Reject it at load time.
        if (input_shape[1] <= 0 || input_shape[2] <= 0) {
            throw std::runtime_error("Model " + name + ": dynamic or invalid input H/W");
        }
        input_size = {static_cast<int>(input_shape[2]), static_cast<int>(input_shape[1])};

        requireOutputCount(name, prediction->GetOutputNames().size(), Decoder::kOutputCount);
    }

    // `const` reflects logical constness (the model configuration is unchanged), but this runs ONNX
    // inference which mutates hidden session state and is NOT thread-safe: calls on ONE instance must never
    // overlap. An instance used by a single stage is called from that stage's runner thread only. An instance
    // two stages share -- the factor tab's two row models, used by the recognizer and the scene scraper -- is
    // wrapped in chara_detail::recognizer_impl::AdmittedPredictor, which admits one call at a time in arrival
    // order. Decodes the raw Prediction into a Predicted<Result> here so callers never touch Ort::Value.
    [[nodiscard]] Predicted<Result> predict(const Frame &frame) const override {
        return Decoder::decode(runInference(frame));
    }

    [[nodiscard]] const std::string &name() const override { return model_name; }

private:
    [[nodiscard]] Prediction runInference(const Frame &frame) const {
        cv::Mat image;
        cv::resize(frame.data(), image, input_size.toCVSize(), 0, 0, cv::INTER_LINEAR);

        // CreateTensor below wraps image.data without copying and reads image.total()*channels contiguous
        // bytes, which assumes a continuous buffer. resize into a fresh Mat always yields one; assert the
        // invariant so a future change that feeds a non-continuous buffer here is caught in debug.
        assert_(image.isContinuous());

        const std::vector<int64_t> input_shape = {1, image.rows, image.cols, image.channels()};
        std::vector<Ort::Value> input_tensors;
        input_tensors.emplace_back(
            Ort::Experimental::Value::CreateTensor<uint8_t>(image.data, image.total() * image.channels(), input_shape));

        return Prediction{prediction->Run(prediction->GetInputNames(), input_tensors, prediction->GetOutputNames())};
    }

    const std::string model_name;
    Ort::SessionOptions session_options;
    std::unique_ptr<Ort::Experimental::Session> prediction;
    Size<int> input_size;
};

}  // namespace uma::recognizer
