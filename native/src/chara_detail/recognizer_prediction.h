#pragma once

// ONNX-backed Prediction decoders. These derive from recognizer::Prediction (cv/model.h) and read Ort tensor
// outputs, so they are kept OUT of chara_detail_recognizer.h to keep that header (and the scan logic in
// chara_detail_recognizer.cpp) free of the onnxruntime include. Only recognizer_models.cpp, which
// instantiates Model<PredictionType>, includes this header.
//
// Each type's result()/confidence()/toJson() is what Model<PredictionType>::predict() calls to produce a
// Predicted<Result>; the Result structs (Chara, RacePlace) and the pure formatTrainedDate() helper live in
// chara_detail_recognizer.h so they stay testable without ONNX.

#include <algorithm>
#include <string>

#include "chara_detail/chara_detail_recognizer.h"
#include "cv/model.h"
#include "util/json_util.h"

namespace uma::chara_detail::recognizer_impl {

struct IndexPrediction : public recognizer::Prediction {
    // Highest output index this type reads, plus one; validated against the loaded model in Model's ctor.
    static constexpr size_t kOutputCount = 2;

    [[nodiscard]] int result() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] auto confidence() const { return at<float>(1); }

    [[nodiscard]] json_util::Json toJson() const { return {{"confidence", confidence()}, {"label", result()}}; }
};

struct CharaPrediction : public recognizer::Prediction {
    // Reads outputs 0..9 (record-type head at 8, its confidence at 9); validated in Model's ctor so a model
    // with fewer heads fails loudly at load instead of dropping every record via a per-call out_of_range.
    static constexpr size_t kOutputCount = 10;

    [[nodiscard]] int icon() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] int chara() const { return static_cast<int>(at<int64_t>(2)); }

    [[nodiscard]] int card() const { return static_cast<int>(at<int64_t>(4)); }

    [[nodiscard]] bool rental() const { return at<int64_t>(6); }

    // record_type_index (output 8), not rental_index (output 6): the model has a dedicated record-type
    // head with values 0-3 (see record::RecordType). Read it as int, not bool, so a FriendStandard/
    // FriendInheritance value (>= 2) is not truncated to 1.
    [[nodiscard]] int recordType() const { return static_cast<int>(at<int64_t>(8)); }

    [[nodiscard]] Chara result() const {
        return {
            icon(),
            chara(),
            card(),
            rental(),
            recordType(),
        };
    }

    [[nodiscard]] auto confidence() const {
        return std::min({at<float>(1), at<float>(3), at<float>(5), at<float>(7), at<float>(9)});
    }

    [[nodiscard]] json_util::Json toJson() const { return {{"confidence", confidence()}, {"label", result()}}; }
};

struct RacePlacePrediction : public recognizer::Prediction {
    // Reads outputs 0..7; validated against the loaded model in Model's ctor.
    static constexpr size_t kOutputCount = 8;

    [[nodiscard]] int place() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] int ground() const { return static_cast<int>(at<int64_t>(2)); }

    [[nodiscard]] int distance() const { return static_cast<int>(at<int64_t>(4)); }

    [[nodiscard]] int variation() const { return static_cast<int>(at<int64_t>(6)); }

    [[nodiscard]] RacePlace result() const { return {place(), ground(), distance(), variation()}; }

    [[nodiscard]] auto confidence() const { return std::min({at<float>(1), at<float>(3), at<float>(5), at<float>(7)}); }

    [[nodiscard]] json_util::Json toJson() const { return {{"confidence", confidence()}, {"label", result()}}; }
};

struct DateTimePrediction : public recognizer::Prediction {
    // Reads outputs 0 and 1; validated against the loaded model in Model's ctor.
    static constexpr size_t kOutputCount = 2;

    [[nodiscard]] std::string result() const { return formatTrainedDate(at<int64_t>(0)); }

    [[nodiscard]] auto confidence() const { return at<float>(1); }

    [[nodiscard]] json_util::Json toJson() const { return {{"confidence", confidence()}, {"label", result()}}; }
};

}  // namespace uma::chara_detail::recognizer_impl
