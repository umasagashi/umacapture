#pragma once

#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_record.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/record_info.h"
#include "cv/frame.h"
#include "cv/model.h"
#include "util/event_util.h"
#include "util/misc.h"

namespace uma::chara_detail {

namespace recognizer_impl {

struct VersionInfo {
    std::string format_version;
    std::string region;
    std::string recognizer_version;

    EXTENDED_JSON_TYPE_NDC(VersionInfo, format_version, region, recognizer_version);
};

struct IndexPrediction : public recognizer::Prediction {
    [[nodiscard]] int result() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] auto confidence() const { return at<float>(1); }

    [[nodiscard]] json_util::Json toJson() const { return {{"confidence", confidence()}, {"label", result()}}; }
};

struct Chara {
    int icon;
    int chara;
    int card;
    bool rental;
    int record_type;

    EXTENDED_JSON_TYPE_NDC(Chara, icon, chara, card, rental, record_type);
};

struct CharaPrediction : public recognizer::Prediction {
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

struct RacePlace {
    int place;
    int ground;
    int distance;
    int variation;

    EXTENDED_JSON_TYPE_NDC(RacePlace, place, ground, distance, variation);
};

struct RacePlacePrediction : public recognizer::Prediction {
    [[nodiscard]] int place() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] int ground() const { return static_cast<int>(at<int64_t>(2)); }

    [[nodiscard]] int distance() const { return static_cast<int>(at<int64_t>(4)); }

    [[nodiscard]] int variation() const { return static_cast<int>(at<int64_t>(6)); }

    [[nodiscard]] RacePlace result() const { return {place(), ground(), distance(), variation()}; }

    [[nodiscard]] auto confidence() const { return std::min({at<float>(1), at<float>(3), at<float>(5), at<float>(7)}); }

    [[nodiscard]] json_util::Json toJson() const { return {{"confidence", confidence()}, {"label", result()}}; }
};

struct DateTimePrediction : public recognizer::Prediction {
    [[nodiscard]] std::string result() const {
        const auto short_str = std::to_string(at<int64_t>(0));
        return short_str.substr(0, 4) + "/" + short_str.substr(4, 2) + "/" + short_str.substr(6);
    }

    [[nodiscard]] auto confidence() const { return at<float>(1); }

    [[nodiscard]] json_util::Json toJson() const { return {{"confidence", confidence()}, {"label", result()}}; }
};

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

template<typename PredictionType>
inline auto predictWithConfidence(
    const recognizer::Model<PredictionType> &model,
    const Frame &frame,
    const Rect<double> &position,
    PredictionHistory &history) {
    const auto &predicted = model.predict(frame.view(position));
    history.add(model.name(), frame.anchor().mapToFrame(position), predicted.toJson());
    return std::make_pair(predicted.result(), predicted.confidence());
}

template<typename PredictionType>
inline auto predict(
    const recognizer::Model<PredictionType> &model,
    const Frame &frame,
    const Rect<double> &position,
    PredictionHistory &history) {
    return predictWithConfidence(model, frame, position, history).first;
}

template<typename PredictionType, size_t n>
inline auto predict(
    const recognizer::Model<PredictionType> &model,
    const Frame &frame,
    const std::array<Rect<double>, n> &positions,
    PredictionHistory &history) {
    std::array<decltype(PredictionType().result()), n> values = {};
    for (int i = 0; i < n; i++) {
        values[i] = predict(model, frame, positions[i], history);
    }
    return values;
}

class StatusHeaderRecognizer {
public:
    [[maybe_unused]] StatusHeaderRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::StatusHeaderConfig &config);

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        PredictionHistory &history) const;

private:
    const recognizer_config::StatusHeaderConfig config;

    recognizer::Model<IndexPrediction> evaluation_value_model;
    recognizer::Model<IndexPrediction> status_value_model;
    recognizer::Model<IndexPrediction> aptitude_model;
};

class SkillTabRecognizer {
public:
    [[maybe_unused]] SkillTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::SkillTabConfig &config);

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        PredictionHistory &history) const;

private:
    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const;

    const recognizer_config::SkillTabConfig config;

    recognizer::Model<IndexPrediction> skill_model;
    recognizer::Model<IndexPrediction> skill_level_model;
};

struct CropInfo {
    Rect<double> trainee_icon;
};

class FactorTabRecognizer {
public:
    [[maybe_unused]] FactorTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::FactorTabConfig &config);

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        CropInfo &crop_info,
        PredictionHistory &history) const;

    // Recognizes only the trainee's own factors that are fully visible on a single, non-stitched
    // factor-tab frame (no scrolling). Used by the early duplicate probe: the returned list is a
    // prefix of the self-factors the full pipeline would read, which is enough to match a recapture.
    [[nodiscard]] std::vector<record::Factor> recognizeVisibleSelf(const Frame &frame, PredictionHistory &history) const;

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

    recognizer::Model<IndexPrediction> factor_model;
    recognizer::Model<IndexPrediction> factor_rank_model;
    recognizer::Model<CharaPrediction> character_model;
    recognizer::Model<IndexPrediction> character_rank_model;
};

class SupportCardRecognizer {
public:
    [[maybe_unused]] SupportCardRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::SupportCardConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const;

private:
    const recognizer_config::SupportCardConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    recognizer::Model<IndexPrediction> support_card_model;
    recognizer::Model<IndexPrediction> support_card_rank_model;
};

class FamilyTreeRecognizer {
public:
    [[maybe_unused]] FamilyTreeRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::FamilyTreeConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

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

    recognizer::Model<CharaPrediction> character_model;
    recognizer::Model<IndexPrediction> character_rank_model;
};

class CampaignRecordRecognizer {
public:
    [[maybe_unused]] CampaignRecordRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::CampaignRecordConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

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

    recognizer::Model<IndexPrediction> campaign_field_model;
    recognizer::Model<IndexPrediction> fans_value_model;
    recognizer::Model<IndexPrediction> scenario_model;
    recognizer::Model<IndexPrediction> foreign_aptitude_model;
    recognizer::Model<IndexPrediction> uaf_wins_model;
    recognizer::Model<DateTimePrediction> trained_date_model;
};

class RaceRecordRecognizer {
public:
    [[maybe_unused]] RaceRecordRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::RaceConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config);

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const;

private:
    struct RaceBlockModelSet {
        RaceBlockModelSet(
            const std::filesystem::path &module_root_dir, const recognizer_config::RaceBlockConfig &block_config);

        recognizer::Model<IndexPrediction> title;
        recognizer::Model<RacePlacePrediction> place;
        recognizer::Model<IndexPrediction> weather;
        recognizer::Model<IndexPrediction> strategy;
        recognizer::Model<IndexPrediction> turn;
        recognizer::Model<IndexPrediction> position;
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
