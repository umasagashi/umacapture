#pragma once

#include <algorithm>
#include <array>
#include <cctype>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_record.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/record_info.h"
#include "cv/frame.h"
#include "cv/predictor.h"
#include "util/event_util.h"
#include "util/logger_util.h"
#include "util/misc.h"

namespace uma::chara_detail {

namespace recognizer_impl {

struct VersionInfo {
    std::string format_version;
    std::string region;
    std::string recognizer_version;

    EXTENDED_JSON_TYPE_NDC(VersionInfo, format_version, region, recognizer_version);
};

// The recognized value of a Chara/CharaRank prediction. Kept here (ONNX-free) because it is the Result type
// of Predictor<Chara>; the ONNX-backed CharaPrediction that produces it lives in recognizer_prediction.h.
struct Chara {
    int icon;
    int chara;
    int card;
    bool rental;
    int record_type;

    EXTENDED_JSON_TYPE_NDC(Chara, icon, chara, card, rental, record_type);
};

// The recognized value of a RacePlace prediction. Kept here (ONNX-free) as the Result type of
// Predictor<RacePlace>; the ONNX-backed RacePlacePrediction lives in recognizer_prediction.h.
struct RacePlace {
    int place;
    int ground;
    int distance;
    int variation;

    EXTENDED_JSON_TYPE_NDC(RacePlace, place, ground, distance, variation);
};

// Formats a raw YYYYMMDD integer as "YYYY/MM/DD", degrading to the raw stringified value on any malformed
// input. Extracted from DateTimePrediction::result() (recognizer_prediction.h) so this pure string logic
// (which carries the edge-case fixes below) can be unit-tested without the ONNX-backed Prediction that
// supplies the integer.
//
// Expect exactly YYYYMMDD (8 digits). A misrecognition that stringifies to fewer digits would make substr(6)
// throw std::out_of_range, which the recognizer's per-record try/catch turns into a dropped record. A
// negative value stringifies to a leading '-' (e.g. "-1234567" is 8 chars), which would pass a bare length
// check and slice the sign into the year. Require exactly 8 digits; degrade only the date field otherwise:
// return the raw value so the record survives.
[[nodiscard]] inline std::string formatTrainedDate(int64_t value) {
    const auto short_str = std::to_string(value);
    const bool all_digits =
        std::all_of(short_str.begin(), short_str.end(), [](unsigned char c) { return std::isdigit(c) != 0; });
    if (short_str.size() != 8 || !all_digits) {
        log_warning("DateTimePrediction: unexpected date value '{}'", short_str);
        return short_str;
    }
    return short_str.substr(0, 4) + "/" + short_str.substr(4, 2) + "/" + short_str.substr(6);
}

struct PredictionRecord {
    std::string model;
    Rect<int> rect;
    json_util::Json prediction;

    EXTENDED_JSON_TYPE_NDC(PredictionRecord, model, rect, prediction);
};

class PredictionHistory {
public:
    void add(const std::string &model, const Rect<int> &rect, const json_util::Json &prediction) {
        records.push_back({model, rect, prediction});
    }

    [[nodiscard]] json_util::Json toJson() const;

private:
    std::vector<PredictionRecord> records;
};

template<typename Result>
inline auto predictWithConfidence(
    const recognizer::Predictor<Result> &model,
    const Frame &frame,
    const Rect<double> &position,
    PredictionHistory &history) {
    const auto predicted = model.predict(frame.view(position));
    history.add(model.name(), frame.anchor().mapToFrame(position), predicted.json);
    return std::make_pair(predicted.result, predicted.confidence);
}

template<typename Result>
inline auto predict(
    const recognizer::Predictor<Result> &model,
    const Frame &frame,
    const Rect<double> &position,
    PredictionHistory &history) {
    return predictWithConfidence(model, frame, position, history).first;
}

template<typename Result, size_t n>
inline auto predict(
    const recognizer::Predictor<Result> &model,
    const Frame &frame,
    const std::array<Rect<double>, n> &positions,
    PredictionHistory &history) {
    std::array<Result, n> values = {};
    for (size_t i = 0; i < n; i++) {
        values[i] = predict(model, frame, positions[i], history);
    }
    return values;
}

class StatusHeaderRecognizer {
public:
    [[maybe_unused]] StatusHeaderRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::StatusHeaderConfig &config);

    // Injection ctor for unit tests; see FactorTabRecognizer's for the rationale.
    StatusHeaderRecognizer(
        const recognizer_config::StatusHeaderConfig &config,
        std::unique_ptr<const recognizer::Predictor<int>> evaluation_value_model,
        std::unique_ptr<const recognizer::Predictor<int>> status_value_model,
        std::unique_ptr<const recognizer::Predictor<int>> aptitude_model);

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        PredictionHistory &history) const;

private:
    const recognizer_config::StatusHeaderConfig config;

    std::unique_ptr<const recognizer::Predictor<int>> evaluation_value_model;
    std::unique_ptr<const recognizer::Predictor<int>> status_value_model;
    std::unique_ptr<const recognizer::Predictor<int>> aptitude_model;
};

class SkillTabRecognizer {
public:
    [[maybe_unused]] SkillTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::SkillTabConfig &config);

    // Injection ctor for unit tests; see FactorTabRecognizer's for the rationale.
    SkillTabRecognizer(
        const recognizer_config::SkillTabConfig &config,
        std::unique_ptr<const recognizer::Predictor<int>> skill_model,
        std::unique_ptr<const recognizer::Predictor<int>> skill_level_model);

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        PredictionHistory &history) const;

private:
    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const;

    const recognizer_config::SkillTabConfig config;

    std::unique_ptr<const recognizer::Predictor<int>> skill_model;
    std::unique_ptr<const recognizer::Predictor<int>> skill_level_model;
};

struct CropInfo {
    Rect<double> trainee_icon;
};

class FactorTabRecognizer {
public:
    [[maybe_unused]] FactorTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::FactorTabConfig &config);

    // Injection ctor: takes pre-built predictors instead of loading ONNX models from disk, so the scan
    // logic can be unit-tested against fakes. The production ctor above lives in the ONNX-linked
    // recognizer_models.cpp; this one and all recognize()/scan methods live in the ONNX-free recognizer.cpp.
    FactorTabRecognizer(
        const recognizer_config::FactorTabConfig &config,
        std::unique_ptr<const recognizer::Predictor<int>> factor_model,
        std::unique_ptr<const recognizer::Predictor<int>> factor_rank_model,
        std::unique_ptr<const recognizer::Predictor<Chara>> character_model,
        std::unique_ptr<const recognizer::Predictor<int>> character_rank_model);

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        CropInfo &crop_info,
        PredictionHistory &history) const;

    // Recognizes only the trainee's own factors that are fully visible on a single, non-stitched
    // factor-tab frame (no scrolling). Used by the early duplicate probe: the returned list is a
    // prefix of the self-factors the full pipeline would read, which is enough to match a recapture.
    [[nodiscard]] std::vector<record::Factor>
    recognizeVisibleSelf(const Frame &frame, PredictionHistory &history) const;

private:
    [[nodiscard]] record::Character recognizeTrainee(
        const Frame &frame,
        const RecordInfo &record_info,
        const double scan_top,
        CropInfo &crop_info,
        PredictionHistory &history) const;

    // When [bounded] is set the scan stops before any row whose cell rect would fall outside the
    // frame. The full pipeline runs on a stitched image tall enough to hold every row, so it leaves
    // [bounded] false and the guard never fires. The early probe runs on a single, non-stitched
    // frame where the bottom-most visible row is clipped; predicting it would crop past the image
    // and abort OpenCV, so the probe sets [bounded] to stop at the last fully-visible row.
    [[nodiscard]] std::vector<record::Factor>
    recognizeOne(const Frame &frame, double &scan_top, PredictionHistory &history, bool bounded = false) const;

    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const;

    [[nodiscard]] record::Factor
    predictFactor(const Frame &frame, const Rect<double> &rect, double top, PredictionHistory &history) const;

    const recognizer_config::FactorTabConfig config;

    std::unique_ptr<const recognizer::Predictor<int>> factor_model;
    std::unique_ptr<const recognizer::Predictor<int>> factor_rank_model;
    std::unique_ptr<const recognizer::Predictor<Chara>> character_model;
    std::unique_ptr<const recognizer::Predictor<int>> character_rank_model;
};

class SupportCardRecognizer {
public:
    [[maybe_unused]] SupportCardRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::SupportCardConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

    // Injection ctor for unit tests; see FactorTabRecognizer's for the rationale.
    SupportCardRecognizer(
        const recognizer_config::SupportCardConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config,
        std::unique_ptr<const recognizer::Predictor<int>> support_card_model,
        std::unique_ptr<const recognizer::Predictor<int>> support_card_rank_model);

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const;

private:
    const recognizer_config::SupportCardConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    std::unique_ptr<const recognizer::Predictor<int>> support_card_model;
    std::unique_ptr<const recognizer::Predictor<int>> support_card_rank_model;
};

class FamilyTreeRecognizer {
public:
    [[maybe_unused]] FamilyTreeRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::FamilyTreeConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

    // Injection ctor for unit tests; see FactorTabRecognizer's for the rationale.
    FamilyTreeRecognizer(
        const recognizer_config::FamilyTreeConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config,
        std::unique_ptr<const recognizer::Predictor<Chara>> character_model,
        std::unique_ptr<const recognizer::Predictor<int>> character_rank_model);

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const;

private:
    [[nodiscard]] record::Family recognizeTree(
        const Frame &frame,
        const Point<double> &top_offset,
        const recognizer_config::FamilyTreeIconConfig &icon_config,
        PredictionHistory &history) const;

    [[nodiscard]] record::Parent recognizeParent(
        const Frame &frame,
        const Point<double> &top_offset,
        const std::array<recognizer_config::IconSetConfig, 3> &icon_config,
        PredictionHistory &history) const;

    [[nodiscard]] record::Character makeCharacter(const Chara &chara, int rank) const;

    const recognizer_config::FamilyTreeConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    std::unique_ptr<const recognizer::Predictor<Chara>> character_model;
    std::unique_ptr<const recognizer::Predictor<int>> character_rank_model;
};

class CampaignRecordRecognizer {
public:
    [[maybe_unused]] CampaignRecordRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::CampaignRecordConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

    // Injection ctor for unit tests; see FactorTabRecognizer's for the rationale.
    CampaignRecordRecognizer(
        const recognizer_config::CampaignRecordConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config,
        std::unique_ptr<const recognizer::Predictor<int>> campaign_field_model,
        std::unique_ptr<const recognizer::Predictor<int>> fans_value_model,
        std::unique_ptr<const recognizer::Predictor<int>> scenario_model,
        std::unique_ptr<const recognizer::Predictor<std::string>> trained_date_model);

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const;

private:
    [[nodiscard]] std::pair<int, float> predictFieldClass(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const;

    [[nodiscard]] int predictFans(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const;

    [[nodiscard]] record::Scenario predictScenario(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const;

    [[nodiscard]] std::string predictTrainedDate(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const;

    [[nodiscard]] std::vector<double>
    findAll(const Frame &frame, const Point<double> &scan_top_left, double initial_gap, double bottom_limit) const;

    [[nodiscard]] std::optional<double>
    findNext(const Frame &frame, const Point<double> &scan_top_left, const double max_length = 1.0) const;

    const recognizer_config::CampaignRecordConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    std::unique_ptr<const recognizer::Predictor<int>> campaign_field_model;
    std::unique_ptr<const recognizer::Predictor<int>> fans_value_model;
    std::unique_ptr<const recognizer::Predictor<int>> scenario_model;
    std::unique_ptr<const recognizer::Predictor<std::string>> trained_date_model;
};

// Named holder for the six predictors of one race-block variant, passed to RaceRecordRecognizer's injection
// ctor. Named fields (not a positional ctor) are deliberate: `place` is a Predictor<RacePlace> while the
// other five are Predictor<int>, so a positional list would let two int-typed slots be transposed silently.
// It is a plain aggregate so tests can populate its named fields directly.
struct RaceBlockPredictors {
    std::unique_ptr<const recognizer::Predictor<int>> title;
    std::unique_ptr<const recognizer::Predictor<RacePlace>> place;
    std::unique_ptr<const recognizer::Predictor<int>> weather;
    std::unique_ptr<const recognizer::Predictor<int>> strategy;
    std::unique_ptr<const recognizer::Predictor<int>> turn;
    std::unique_ptr<const recognizer::Predictor<int>> position;
};

class RaceRecordRecognizer {
public:
    [[maybe_unused]] RaceRecordRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::RaceConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

    // Injection ctor for unit tests; see FactorTabRecognizer's for the rationale. The two block variants are
    // supplied as named holders rather than 12 positional predictors (see RaceBlockPredictors).
    RaceRecordRecognizer(
        const recognizer_config::RaceConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config,
        RaceBlockPredictors models_1line,
        RaceBlockPredictors models_2line);

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const;

private:
    struct RaceBlockModelSet {
        RaceBlockModelSet(
            const std::filesystem::path &module_root_dir, const recognizer_config::RaceBlockConfig &block_config);

        explicit RaceBlockModelSet(RaceBlockPredictors predictors);

        std::unique_ptr<const recognizer::Predictor<int>> title;
        std::unique_ptr<const recognizer::Predictor<RacePlace>> place;
        std::unique_ptr<const recognizer::Predictor<int>> weather;
        std::unique_ptr<const recognizer::Predictor<int>> strategy;
        std::unique_ptr<const recognizer::Predictor<int>> turn;
        std::unique_ptr<const recognizer::Predictor<int>> position;
    };

    [[nodiscard]] std::optional<double>
    findNextBlock(const Frame &frame, const Point<double> &scan_top_left, const double bottom) const;

    [[nodiscard]] std::optional<double>
    findNextGap(const Frame &frame, const Point<double> &scan_top_left, const double bottom) const;

    [[nodiscard]] std::optional<double> findLast(const Frame &frame, const Point<double> &scan_bottom_left) const;

    [[nodiscard]] record::Race recognizeRace(
        const Frame &frame,
        const Rect<double> &block_rect,
        const RaceBlockModelSet &block_models,
        const recognizer_config::RaceBlockConfig &block_config,
        PredictionHistory &history) const;

    const recognizer_config::RaceConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    RaceBlockModelSet models_1line;
    RaceBlockModelSet models_2line;
};

class CampaignTabRecognizer {
public:
    [[maybe_unused]] CampaignTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::CampaignTabConfig &config);

    void recognize(const Frame &frame, record::CharaDetailRecord &record, PredictionHistory &history) const;

private:
    const recognizer_config::CampaignTabConfig config;

    const SupportCardRecognizer support_card_recognizer;
    const FamilyTreeRecognizer family_tree_recognizer;
    const CampaignRecordRecognizer campaign_record_recognizer;
    const RaceRecordRecognizer race_record_recognizer;
};

}  // namespace recognizer_impl

class CharaDetailRecognizer {
public:
    CharaDetailRecognizer(
        const std::string &trainer_id,
        const std::filesystem::path &record_root_dir,
        const std::filesystem::path &module_root_dir,
        const event_util::Listener<RecordInfo> &on_recognize_ready,
        const event_util::Sender<RecordInfo> &on_recognize_completed,
        const event_util::Listener<RecordInfo> &on_update_requested,
        const event_util::Sender<RecordInfo> &on_update_completed,
        const event_util::Listener<Frame, RecordInfo> &on_factor_probe_ready,
        const event_util::Sender<std::vector<record::Factor>, int> &on_factor_probe_completed,
        const recognizer_config::CharaDetailRecognizerConfig &config);

    // Recognizes only the trainee's own factors visible on a single, non-stitched factor-tab frame
    // (the stable frame captured at scroll-ready) so the duplicate check can run before scrolling.
    // Reuses the same FactorTabRecognizer as the full pipeline, bounded to the visible rows; the
    // result is a prefix of the self-factor list, matched against stored records on the Dart side.
    void probe(const Frame &frame, const RecordInfo &raw_info) const;

    void recognize(const RecordInfo &raw_info, bool isUpdateMode) const;

private:
    const std::string trainer_id;
    const std::filesystem::path record_root_dir;
    const std::filesystem::path module_root_dir;
    const recognizer_config::CharaDetailRecognizerConfig config;

    const recognizer_impl::StatusHeaderRecognizer status_header_recognizer;
    const recognizer_impl::SkillTabRecognizer skill_tab_recognizer;
    const recognizer_impl::FactorTabRecognizer factor_tab_recognizer;
    const recognizer_impl::CampaignTabRecognizer campaign_tab_recognizer;

    const event_util::Listener<RecordInfo> on_recognize_ready;
    const event_util::Sender<RecordInfo> on_recognize_completed;

    const event_util::Listener<RecordInfo> on_update_requested;
    const event_util::Sender<RecordInfo> on_update_completed;

    const event_util::Listener<Frame, RecordInfo> on_factor_probe_ready;
    const event_util::Sender<std::vector<record::Factor>, int> on_factor_probe_completed;
};

}  // namespace uma::chara_detail
