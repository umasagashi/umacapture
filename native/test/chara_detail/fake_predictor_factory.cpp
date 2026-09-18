// Test-target definition of recognizer_impl::makePredictor (declared in chara_detail/recognizer_prediction.h).
//
// umacapture_tests links chara_detail_recognizer.cpp, whose production constructors call makePredictor, but
// links no onnxruntime and ships no model files, so neither platform definition can be used here. This one loads
// nothing: every predictor it builds ignores the frame and returns the value-initialized Result (0, an all-zero
// Chara / RacePlace, an empty string) with confidence 1, under the name it was given. That is enough to
// construct the production recognizers in a test and drive what they do around their predictions.

#include <filesystem>
#include <string>

#include "chara_detail/recognizer_prediction.h"
#include "util/fake_predictor.h"

namespace uma::chara_detail::recognizer_impl {

template<typename Decoder>
PredictorFor<Decoder> makePredictor(
    const std::filesystem::path &module_root_dir, const std::string &module_path, const std::string &name) {
    (void) module_root_dir;
    (void) module_path;
    return testutil::constantPredictor<typename Decoder::Result>(name, typename Decoder::Result{});
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
