// Desktop definition of recognizer_impl::makePredictor (declared in chara_detail/recognizer_prediction.h).
//
// Why this is per platform: on desktop a model runs in process through onnxruntime (recognizer::Model, which
// includes cv/model.h), and it is found as a file under the installed module directory. The Wasm build links no
// onnxruntime and defines the same function in native/wasm/wasm_recognizer_models.cpp; the onnxruntime-less
// umacapture_tests target links a fake. So this is the only translation unit that names recognizer::Model, and
// it holds nothing else: the constructors that call makePredictor and the decoders live, once for every
// platform, in chara_detail_recognizer.cpp.

#include <memory>

#include "chara_detail/recognizer_prediction.h"
#include "cv/model.h"

namespace uma::chara_detail::recognizer_impl {

template<typename Decoder>
PredictorFor<Decoder> makePredictor(
    const std::filesystem::path &module_root_dir, const std::string &module_path, const std::string &name) {
    return std::make_unique<recognizer::Model<Decoder>>(module_root_dir / module_path, name);
}

template PredictorFor<IndexDecoder> makePredictor<IndexDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
template PredictorFor<CharaDecoder> makePredictor<CharaDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
template PredictorFor<RacePlaceDecoder> makePredictor<RacePlaceDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
template PredictorFor<DateTimeDecoder> makePredictor<DateTimeDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);

}  // namespace uma::chara_detail::recognizer_impl
