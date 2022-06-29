#pragma once

#include <experimental_onnxruntime_cxx_api.h>
#include <filesystem>
#include <iostream>

#include <opencv2/opencv.hpp>

namespace uma::recognizer {

namespace recognizer_impl {

template<typename T>
bool is_same(ONNXTensorElementDataType type) {
    switch (type) {
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8: return std::is_same<T, uint8_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT16: return std::is_same<T, uint16_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT32: return std::is_same<T, uint32_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT64: return std::is_same<T, uint64_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8: return std::is_same<T, int8_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT16: return std::is_same<T, int16_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: return std::is_same<T, int32_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return std::is_same<T, int64_t>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: return std::is_same<T, float>::value;
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_DOUBLE: return std::is_same<T, double>::value;
        default: throw std::invalid_argument("Unsupported type: " + std::to_string(type));
    }
}

}  // namespace recognizer_impl

struct Prediction {
    const std::vector<Ort::Value> data;

    template<typename T>
    [[nodiscard]] const T &at(int index, bool check = true) const {
        if (check) {
            auto type_info = data[index].GetTensorTypeAndShapeInfo();
            auto element_type = type_info.GetElementType();
            if (!recognizer_impl::is_same<T>(element_type)) {
                std::ostringstream stream;
                stream << "Incorrect template type specified. index=" << index
                       << ", type=" << std::to_string(element_type) << ", See ONNXTensorElementDataType.";
                throw std::invalid_argument(stream.str());
            }

            if (data[index].GetTensorTypeAndShapeInfo().GetElementCount() != 1) {
                throw std::invalid_argument("Vector output is not supported.");
            }
        }

        return *data[index].template GetTensorData<T>();
    }
};

template<typename PredictionType>
class Model {
public:
    explicit Model(const std::filesystem::path &path)
        : input_size(-1, -1) {
        std::filesystem::path::string_type path_str = path;
        prediction = std::make_unique<Ort::Experimental::Session>(env, path_str, session_options);
        const auto input_shape = prediction->GetInputShapes()[0];
        input_size = {static_cast<int>(input_shape[2]), static_cast<int>(input_shape[1])};
    }

    PredictionType predict(const Frame &frame) const {
        cv::Mat image;
        cv::resize(frame.data(), image, input_size.toCVSize(), 0, 0, cv::INTER_LINEAR);

        const std::vector<int64_t> input_shape = {1, image.rows, image.cols, image.channels()};
        std::vector<Ort::Value> input_tensors;
        input_tensors.emplace_back(
            Ort::Experimental::Value::CreateTensor<uint8_t>(image.data, image.total() * image.channels(), input_shape));

        return {prediction->Run(prediction->GetInputNames(), input_tensors, prediction->GetOutputNames())};
    }

private:
    Ort::Env env;
    Ort::SessionOptions session_options;
    std::unique_ptr<Ort::Experimental::Session> prediction;
    Size<int> input_size;
};

}  // namespace uma::recognizer
