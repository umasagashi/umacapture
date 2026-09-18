#pragma once

// How the recognizers obtain their predictors, and how a prediction's scalar outputs are read.
//
// The decoders are platform-free: they read through recognizer::PredictionOutputs and are defined once, in
// chara_detail_recognizer.cpp. makePredictor is the one thing each platform supplies, because running a model
// is the one thing the platforms cannot share (see the definitions for the constraint on each side). The
// production constructors in chara_detail_recognizer.cpp call it; each build links exactly one definition:
//   - desktop (CLI and Windows runner): chara_detail_recognizer_models.cpp, in-process onnxruntime;
//   - Wasm: native/wasm/wasm_recognizer_models.cpp, onnxruntime-web behind a JS bridge;
//   - umacapture_tests: native/test/chara_detail/fake_predictor_factory.cpp, which loads nothing.
// This header stays ONNX-free, so every one of those translation units may include it.

#include <cstddef>
#include <filesystem>
#include <memory>
#include <string>

#include "chara_detail/chara_detail_recognizer.h"
#include "cv/predictor.h"

namespace uma::chara_detail::recognizer_impl {

// Each decoder names its Result, the number of outputs it reads (its highest output index plus one), and how
// those outputs become a Predicted<Result>. Even output indices are int64 labels, odd ones float confidences.
struct IndexDecoder {
    using Result = int;
    static constexpr std::size_t kOutputCount = 2;

    [[nodiscard]] static recognizer::Predicted<Result> decode(const recognizer::PredictionOutputs &out);
};

struct CharaDecoder {
    using Result = Chara;
    // Reads outputs 0..9 (record-type head at 8, its confidence at 9).
    static constexpr std::size_t kOutputCount = 10;

    [[nodiscard]] static recognizer::Predicted<Result> decode(const recognizer::PredictionOutputs &out);
};

struct RacePlaceDecoder {
    using Result = RacePlace;
    static constexpr std::size_t kOutputCount = 8;

    [[nodiscard]] static recognizer::Predicted<Result> decode(const recognizer::PredictionOutputs &out);
};

struct DateTimeDecoder {
    using Result = std::string;
    static constexpr std::size_t kOutputCount = 2;

    [[nodiscard]] static recognizer::Predicted<Result> decode(const recognizer::PredictionOutputs &out);
};

template<typename Decoder>
using PredictorFor = std::unique_ptr<const recognizer::Predictor<typename Decoder::Result>>;

// Builds the predictor for one model. `module_root_dir` is the directory the module set was installed into and
// `module_path` the model's path inside it, as recognizer.json names it; a platform uses whichever of the two
// identifies a model there. `name` is the model name recorded with every prediction.
template<typename Decoder>
[[nodiscard]] PredictorFor<Decoder> makePredictor(
    const std::filesystem::path &module_root_dir, const std::string &module_path, const std::string &name);

// The decoders makePredictor is defined for. Every platform definition explicitly instantiates exactly these
// (native/wasm/check_sources.py compares the lists), so a decoder missing on one platform fails that link.
extern template PredictorFor<IndexDecoder> makePredictor<IndexDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
extern template PredictorFor<CharaDecoder> makePredictor<CharaDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
extern template PredictorFor<RacePlaceDecoder> makePredictor<RacePlaceDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
extern template PredictorFor<DateTimeDecoder> makePredictor<DateTimeDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);

}  // namespace uma::chara_detail::recognizer_impl
