// ONNX-linked half of the recognizer TU split. This translation unit is the ONLY place that names
// recognizer::Model (and therefore includes cv/model.h -> onnxruntime), via chara_detail/recognizer_prediction.h.
// It contains nothing but the production constructors that load ONNX models from disk; every recognize()/scan
// method and the test-only injection ctors live in chara_detail_recognizer.cpp, which stays ONNX-free so it can
// link into the onnxruntime-less umacapture_tests target. Keep this split intact: do NOT move recognize()
// logic here, and do NOT name recognizer::Model in chara_detail_recognizer.cpp.

#include <memory>

#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/recognizer_prediction.h"

namespace uma::chara_detail {

namespace recognizer_impl {

StatusHeaderRecognizer::StatusHeaderRecognizer(
    const std::filesystem::path &module_root_dir, const recognizer_config::StatusHeaderConfig &config)
    : config(config)
    , evaluation_value_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.evaluation.module_path, "evaluation_value"))
    , status_value_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.status.module_path, "status_value"))
    , aptitude_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.aptitude.module_path, "aptitude")) {
}

SkillTabRecognizer::SkillTabRecognizer(
    const std::filesystem::path &module_root_dir, const recognizer_config::SkillTabConfig &config)
    : config(config)
    , skill_model(std::make_unique<recognizer::Model<IndexPrediction>>(module_root_dir / config.module_path, "skill"))
    , skill_level_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.skill_level.module_path, "skill_level")) {
}

FactorTabRecognizer::FactorTabRecognizer(
    const std::filesystem::path &module_root_dir, const recognizer_config::FactorTabConfig &config)
    : config(config)
    , factor_model(std::make_unique<recognizer::Model<IndexPrediction>>(module_root_dir / config.module_path, "factor"))
    , factor_rank_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.factor_rank.module_path, "factor_rank"))
    , character_model(
          std::make_unique<recognizer::Model<CharaPrediction>>(
              module_root_dir / config.trainee_icon.icon.module_path, "character"))
    , character_rank_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.trainee_icon.rank.module_path, "character_rank")) {
}

SupportCardRecognizer::SupportCardRecognizer(
    const std::filesystem::path &module_root_dir,
    const recognizer_config::SupportCardConfig &config,
    const recognizer_config::CampaignTabCommonConfig &common_config)
    : config(config)
    , common_config(common_config)
    , support_card_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(module_root_dir / config.module_path, "support_card"))
    , support_card_rank_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.rank.module_path, "support_card_rank")) {
}

FamilyTreeRecognizer::FamilyTreeRecognizer(
    const std::filesystem::path &module_root_dir,
    const recognizer_config::FamilyTreeConfig &config,
    const recognizer_config::CampaignTabCommonConfig &common_config)
    : config(config)
    , common_config(common_config)
    , character_model(
          std::make_unique<recognizer::Model<CharaPrediction>>(module_root_dir / config.module.chara, "character"))
    , character_rank_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.module.rank, "character_rank")) {
}

CampaignRecordRecognizer::CampaignRecordRecognizer(
    const std::filesystem::path &module_root_dir,
    const recognizer_config::CampaignRecordConfig &config,
    const recognizer_config::CampaignTabCommonConfig &common_config)
    : config(config)
    , common_config(common_config)
    , campaign_field_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.campaign_field.module_path, "campaign_field"))
    , fans_value_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.fans_value.module_path, "fans_value"))
    , scenario_model(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / config.scenario.module_path, "scenario"))
    , trained_date_model(
          std::make_unique<recognizer::Model<DateTimePrediction>>(
              module_root_dir / config.trained_date.module_path, "trained_date")) {
}

RaceRecordRecognizer::RaceBlockModelSet::RaceBlockModelSet(
    const std::filesystem::path &module_root_dir, const recognizer_config::RaceBlockConfig &block_config)
    : title(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / block_config.title.module_path, "race_title"))
    // race_place has 1line and 2line variations, but since there's no need to distinguish the output, name can be the same.
    , place(
          std::make_unique<recognizer::Model<RacePlacePrediction>>(
              module_root_dir / block_config.place.module_path, "race_place"))
    , weather(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / block_config.weather.module_path, "race_weather"))
    , strategy(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / block_config.strategy.module_path, "race_strategy"))
    , turn(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / block_config.turn.module_path, "race_turn"))
    , position(
          std::make_unique<recognizer::Model<IndexPrediction>>(
              module_root_dir / block_config.position.module_path, "race_position")) {
}

RaceRecordRecognizer::RaceRecordRecognizer(
    const std::filesystem::path &module_root_dir,
    const recognizer_config::RaceConfig &config,
    const recognizer_config::CampaignTabCommonConfig &common_config)
    : config(config)
    , common_config(common_config)
    , models_1line(module_root_dir, config.block_1line_config)
    , models_2line(module_root_dir, config.block_2line_config) {
}

CampaignTabRecognizer::CampaignTabRecognizer(
    const std::filesystem::path &module_root_dir, const recognizer_config::CampaignTabConfig &config)
    : config(config)
    , support_card_recognizer(module_root_dir, config.support_card, config.common)
    , family_tree_recognizer(module_root_dir, config.family_tree, config.common)
    , campaign_record_recognizer(module_root_dir, config.campaign_record, config.common)
    , race_record_recognizer(module_root_dir, config.race, config.common) {
}

}  // namespace recognizer_impl

CharaDetailRecognizer::CharaDetailRecognizer(
    const std::string &trainer_id,
    const std::filesystem::path &record_root_dir,
    const std::filesystem::path &module_root_dir,
    const event_util::Listener<RecordInfo> &on_recognize_ready,
    const event_util::Sender<RecordInfo> &on_recognize_completed,
    const event_util::Listener<RecordInfo> &on_update_requested,
    const event_util::Sender<RecordInfo> &on_update_completed,
    const event_util::Listener<Frame, RecordInfo> &on_factor_probe_ready,
    const event_util::Sender<std::vector<record::Factor>, int> &on_factor_probe_completed,
    const event_util::Sender<std::string> &on_error,
    const recognizer_config::CharaDetailRecognizerConfig &config)
    : trainer_id(trainer_id)
    , record_root_dir(record_root_dir)
    , module_root_dir(module_root_dir)
    , config(config)
    , status_header_recognizer(module_root_dir, config.status_header)
    , skill_tab_recognizer(module_root_dir, config.skill_tab)
    , factor_tab_recognizer(module_root_dir, config.factor_tab)
    , campaign_tab_recognizer(module_root_dir, config.campaign_tab)
    , on_recognize_ready(on_recognize_ready)
    , on_recognize_completed(on_recognize_completed)
    , on_update_requested(on_update_requested)
    , on_update_completed(on_update_completed)
    , on_factor_probe_ready(on_factor_probe_ready)
    , on_factor_probe_completed(on_factor_probe_completed)
    , on_error(on_error) {
    this->on_recognize_ready->listen([this](const auto &info) { this->recognize(info, false); });
    this->on_update_requested->listen([this](const auto &info) { this->recognize(info, true); });
    this->on_factor_probe_ready->listen([this](const auto &frame, const auto &info) { this->probe(frame, info); });
}

}  // namespace uma::chara_detail
