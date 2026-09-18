// Test-target definition of recognizer_impl::makePredictor (declared in chara_detail/recognizer_prediction.h).
//
// umacapture_tests links chara_detail_recognizer.cpp, whose production constructors call makePredictor, but
// links no onnxruntime and ships no model files, so neither platform definition can be used here. This one loads
// nothing: every predictor it builds ignores the frame and returns the value-initialized Result (0, an all-zero
// Chara / RacePlace, an empty string) with confidence 1, under the name it was given. That is enough to
// construct the production recognizers in a test and drive what they do around their predictions.
//
// It also RECORDS the name of every predictor it is asked for (fake_predictor_factory.h), so a case can state how
// many times a pipeline's construction asked for a given model.

#include <filesystem>
#include <mutex>
#include <string>
#include <vector>

#include "chara_detail/fake_predictor_factory.h"
#include "chara_detail/recognizer_prediction.h"
#include "util/fake_predictor.h"

namespace uma::chara_detail::recognizer_impl {

namespace {

// Guarded because a pipeline builds its stages on the calling thread but nothing promises that stays true, and a
// torn vector would fail a case for the wrong reason.
std::mutex &builtNamesMutex() {
    static std::mutex mutex;
    return mutex;
}

std::vector<std::string> &builtNames() {
    static std::vector<std::string> names;
    return names;
}

}  // namespace

void resetBuiltPredictorNames() {
    const std::lock_guard<std::mutex> lock(builtNamesMutex());
    builtNames().clear();
}

std::vector<std::string> builtPredictorNames() {
    const std::lock_guard<std::mutex> lock(builtNamesMutex());
    return builtNames();
}

template<typename Decoder>
PredictorFor<Decoder> makePredictor(
    const std::filesystem::path &module_root_dir, const std::string &module_path, const std::string &name) {
    (void) module_root_dir;
    (void) module_path;
    {
        const std::lock_guard<std::mutex> lock(builtNamesMutex());
        builtNames().push_back(name);
    }
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
