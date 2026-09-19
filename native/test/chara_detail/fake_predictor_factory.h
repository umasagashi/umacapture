#pragma once

// The names the test target's makePredictor (fake_predictor_factory.cpp) has been asked to build.
//
// Every recognizer stage builds its predictors by name in its constructor, so this list is a record of what a
// pipeline's construction asked for. A name appearing twice means two objects were built for one model, which is
// what makes "one factor-row reader per pipeline" (native_api.cpp's factor_rows, handed to both the scraper and
// the recognizer) assertable without reaching inside either stage.

#include <string>
#include <vector>

namespace uma::chara_detail::recognizer_impl {

// Forgets every name recorded so far. Call it before the construction a case measures.
void resetBuiltPredictorNames();

// The names built since the last reset, in construction order.
[[nodiscard]] std::vector<std::string> builtPredictorNames();

}  // namespace uma::chara_detail::recognizer_impl
