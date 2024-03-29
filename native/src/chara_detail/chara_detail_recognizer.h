#pragma once

#include <opencv2/highgui.hpp>
#include <opencv2/imgproc.hpp>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_record.h"
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

    EXTENDED_JSON_TYPE_NDC(Chara, icon, chara, card, rental);
};

struct CharaPrediction : public recognizer::Prediction {
    [[nodiscard]] int icon() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] int chara() const { return static_cast<int>(at<int64_t>(2)); }

    [[nodiscard]] int card() const { return static_cast<int>(at<int64_t>(4)); }

    [[nodiscard]] bool rental() const { return at<int64_t>(6); }

    [[nodiscard]] Chara result() const {
        return {
            icon(),
            chara(),
            card(),
            rental(),
        };
    }

    [[nodiscard]] auto confidence() const { return std::min({at<float>(1), at<float>(3), at<float>(5), at<float>(7)}); }

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

    [[nodiscard]] json_util::Json toJson() const {
        vlog_debug(records.size());
        return records;
    }

private:
    std::vector<PredictionRecord> records;
};

template<typename PredictionType>
inline auto predict(
    const recognizer::Model<PredictionType> &model,
    const Frame &frame,
    const Rect<double> &position,
    PredictionHistory &history) {
    const auto &predicted = model.predict(frame.view(position));
    history.add(model.name(), frame.anchor().mapToFrame(position), predicted.toJson());
    return predicted.result();
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

[[nodiscard]] std::optional<double> inline searchVertical(
    const Frame &frame, const Range<Color> &bg_color, const Point<double> &scan_top_left, double max_length) {
    const auto &frame_anchor = frame.anchor();

    const auto scan_top_pixels = frame_anchor.mapToFrame(scan_top_left).y();
    const auto scan_length_pixels = frame_anchor.scaleToPixels(max_length);
    const auto scan_bottom_pixels = std::min(frame.height(), scan_top_pixels + scan_length_pixels);

    for (int y = scan_top_pixels; y < scan_bottom_pixels; y++) {
        const auto scaled_y = frame_anchor.scaleFromPixels(y);
        const auto scan_point = Point<double>{
            scan_top_left.x(),
            scaled_y,
            {scan_top_left.anchor().h(), ScreenStart},
        };
        if (!frame.isIn(bg_color, scan_point)) {
            return scaled_y;
        }
    }
    return std::nullopt;
}

class StatusHeaderRecognizer {
public:
    [[maybe_unused]] StatusHeaderRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::StatusHeaderConfig &config)
        : config(config)
        , evaluation_value_model(module_root_dir / config.evaluation.module_path, "evaluation_value")
        , status_value_model(module_root_dir / config.status.module_path, "status_value")
        , aptitude_model(module_root_dir / config.aptitude.module_path, "aptitude") {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record, PredictionHistory &history) const {
        record.evaluation_value = predict(evaluation_value_model, frame, config.evaluation.rect, history);
        record.status = predict(status_value_model, frame, config.status.rects, history);
        record.aptitudes = predict(aptitude_model, frame, config.aptitude.rects, history);
    }

private:
    const recognizer_config::StatusHeaderConfig config;

    recognizer::Model<IndexPrediction> evaluation_value_model;
    recognizer::Model<IndexPrediction> status_value_model;
    recognizer::Model<IndexPrediction> aptitude_model;
};

class SkillTabRecognizer {
public:
    [[maybe_unused]] SkillTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::SkillTabConfig &config)
        : config(config)
        , skill_model(module_root_dir / config.module_path, "skill")
        , skill_level_model(module_root_dir / config.skill_level.module_path, "skill_level") {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record, PredictionHistory &history) const {
        const auto anchor = frame.anchor();
        const auto left_rect = anchor.absolute(config.left_rect);
        const auto right_rect = anchor.absolute(config.right_rect);

        double current_y = anchor.absolute(config.area).top() + config.vertical_margin;
        std::vector<record::Skill> skills;
        for (;;) {
            // Find next row of LEFT column.
            const auto left_column_y = findNext(frame, left_rect.topLeft().withY(current_y));
            if (!left_column_y) {
                break;
            }
            skills.push_back(predictSkill(frame, left_rect, left_column_y.value(), skills.empty(), history));

            // Find next row of RIGHT column.
            const auto right_column_y = findNext(frame, right_rect.topLeft().withY(current_y));
            if (!right_column_y) {
                break;
            }
            skills.push_back(predictSkill(frame, right_rect, right_column_y.value(), false, history));

            current_y = left_column_y.value() + config.vertical_delta;
        }
        record.skills = skills;
    }

private:
    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const {
        return searchVertical(frame, config.bg_color, scan_top_left, config.vertical_gap);
    }

    [[nodiscard]] record::Skill predictSkill(
        const Frame &frame,
        const Rect<double> &rect,
        double top,
        bool predict_level,
        PredictionHistory &history) const {
        assert_(config.skill_level.rect.topLeft().anchor() == ScreenStart);
        assert_(config.skill_level.rect.bottomRight().anchor() == ScreenStart);
        assert_(rect.topLeft().anchor() == ScreenStart);
        assert_(rect.bottomRight().anchor() == ScreenStart);

        const auto skill_id = predict(skill_model, frame, rect + Point<double>{0, top}, history);
        if (!predict_level) {
            return {skill_id};
        }

        const auto skill_level =
            predict(skill_level_model, frame, config.skill_level.rect + Point<double>{rect.left(), top}, history);

        return {
            skill_id,
            skill_level + 1,  // 1-based
        };
    }

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
        const std::filesystem::path &module_root_dir, const recognizer_config::FactorTabConfig &config)
        : config(config)
        , factor_model(module_root_dir / config.module_path, "factor")
        , factor_rank_model(module_root_dir / config.factor_rank.module_path, "factor_rank")
        , character_model(module_root_dir / config.trainee_icon.icon.module_path, "character")
        , character_rank_model(module_root_dir / config.trainee_icon.rank.module_path, "character_rank") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, CropInfo &crop_info, PredictionHistory &history) const {
        double current_y = frame.anchor().absolute(config.area).top() + config.vertical_margin;

        const auto self = recognizeOne(frame, current_y, history);
        const auto parent1 = recognizeOne(frame, current_y, history);
        const auto parent2 = recognizeOne(frame, current_y, history);

        record.factors = {self, parent1, parent2};

        record.trainee = recognizeTrainee(frame, crop_info, history);
    }

private:
    [[nodiscard]] record::Character
    recognizeTrainee(const Frame &frame, CropInfo &crop_info, PredictionHistory &history) const {
        const auto &anchor = frame.anchor();
        const auto &scan_top = findNext(
            frame,
            {
                anchor.absolute(config.left_rect).left(),
                anchor.absolute(config.area).top() + config.vertical_margin,
            });

        const auto chara_rect = anchor.absolute(config.trainee_icon.icon.rect) + Point<double>{0, scan_top.value()};
        const auto rank_rect = anchor.absolute(config.trainee_icon.rank.rect) + Point<double>{0, scan_top.value()};
        crop_info.trainee_icon = chara_rect;

        const auto icon = predict(character_model, frame, chara_rect, history);
        const auto rank = predict(character_rank_model, frame, rank_rect, history);

        record::Character character{};
        character.icon = icon.icon;
        character.character = icon.chara;
        character.card = icon.card;
        character.rank = rank;
        return character;
    }

    [[nodiscard]] std::vector<record::Factor>
    recognizeOne(const Frame &frame, double &scan_top, PredictionHistory &history) const {
        const auto anchor = frame.anchor();
        const auto left_rect = anchor.absolute(config.left_rect);
        const auto right_rect = anchor.absolute(config.right_rect);

        std::vector<record::Factor> factors;
        for (;;) {
            const auto current_scan_top = scan_top;

            // Find next row of LEFT column.
            const auto left_column_y = findNext(frame, left_rect.topLeft().withY(current_scan_top));
            if (!left_column_y) {
                break;
            }
            factors.push_back(predictFactor(frame, left_rect, left_column_y.value(), history));
            scan_top = left_column_y.value() + config.vertical_delta;

            // Find next row of RIGHT column.
            const auto right_column_y = findNext(frame, right_rect.topLeft().withY(current_scan_top));
            if (!right_column_y) {
                break;
            }
            factors.push_back(predictFactor(frame, right_rect, right_column_y.value(), history));
        }

        scan_top += config.vertical_chara_gap;
        return factors;
    }

    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const {
        return searchVertical(frame, config.bg_color, scan_top_left, config.vertical_factor_gap);
    }

    [[nodiscard]] record::Factor
    predictFactor(const Frame &frame, const Rect<double> &rect, double top, PredictionHistory &history) const {
        assert_(config.factor_rank.rect.topLeft().anchor() == ScreenStart);
        assert_(config.factor_rank.rect.bottomRight().anchor() == ScreenStart);
        assert_(rect.topLeft().anchor() == ScreenStart);
        assert_(rect.bottomRight().anchor() == ScreenStart);

        const auto factor_id = predict(factor_model, frame, rect + Point<double>{0, top}, history);

        const auto factor_rank =
            predict(factor_rank_model, frame, config.factor_rank.rect + Point<double>{rect.left(), top}, history);

        return {
            factor_id,
            factor_rank + 1,  // 1-based
        };
    }

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
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , support_card_model(module_root_dir / config.module_path, "support_card")
        , support_card_rank_model(module_root_dir / config.rank.module_path, "support_card_rank")
        , support_card_level_model(module_root_dir / config.level.module_path, "support_card_level") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto card_top = searchVertical(
            frame,
            common_config.bg_color,
            {frame.anchor().absolute(config.scan_point).x(), scan_top, ScreenStart},
            1.0);

        const auto top_offset = Point<double>{0, card_top.value()};
        const auto &anchor = frame.anchor();

        const auto id_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto rank_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.rank.rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto level_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.level.rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto id = predict(support_card_model, frame, id_rects, history);
        const auto rank = predict(support_card_rank_model, frame, rank_rects, history);
        const auto level = predict(support_card_level_model, frame, level_rects, history);

        std::array<record::SupportCard, 6> support_cards{};
        for (int i = 0; i < support_cards.size(); i++) {
            support_cards[i] = {
                id[i],
                rank[i] + 1,  // 1-based
                level[i],
            };
        }

        record.support_cards = support_cards;

        scan_top = card_top.value() + config.vertical_delta;
    }

private:
    const recognizer_config::SupportCardConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    recognizer::Model<IndexPrediction> support_card_model;
    recognizer::Model<IndexPrediction> support_card_rank_model;
    recognizer::Model<IndexPrediction> support_card_level_model;
};

class FamilyTreeRecognizer {
public:
    [[maybe_unused]] FamilyTreeRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::FamilyTreeConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , character_model(module_root_dir / config.module_path, "character")
        , character_rank_model(module_root_dir / config.chara_rank.module_path, "character_rank") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto top = searchVertical(
            frame,
            common_config.bg_color,
            {frame.anchor().absolute(config.scan_point).x(), scan_top, ScreenStart},
            1.0);

        const auto top_offset = Point<double>{0, top.value()};

        record.family.parent1 = recognizeParent(frame, top_offset, config.parent1, config.chara_rank.parent1, history);
        record.family.parent2 = recognizeParent(frame, top_offset, config.parent2, config.chara_rank.parent2, history);

        scan_top = top.value() + config.vertical_delta;
    }

private:
    [[nodiscard]] record::Parent recognizeParent(
        const Frame &frame,
        const Point<double> &top_offset,
        const std::array<Rect<double>, 3> &icon_rects,
        const std::array<Rect<double>, 3> &rank_rects,
        PredictionHistory &history) const {
        const auto &anchor = frame.anchor();

        const auto &mapped_icon_rects = stds::transformed_inplace<std::array<Rect<double>, 3>>(
            icon_rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });
        const auto &mapped_rank_rects = stds::transformed_inplace<std::array<Rect<double>, 3>>(
            rank_rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto &icon = predict(character_model, frame, mapped_icon_rects, history);
        const auto &rank = predict(character_rank_model, frame, mapped_rank_rects, history);

        record::Parent parent;
        parent.self = makeCharacter(icon[0], rank[0]);
        parent.parent1 = makeCharacter(icon[1], rank[1]);
        parent.parent2 = makeCharacter(icon[2], rank[2]);

        parent.rental = icon[0].rental ? std::optional<bool>(true) : std::nullopt;

        return parent;
    }

    [[nodiscard]] record::Character makeCharacter(const Chara &chara, int rank) const {
        record::Character character{};
        character.icon = chara.icon;
        character.character = chara.chara;
        character.card = chara.card;
        character.rank = rank;
        return character;
    }

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
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , fans_value_model(module_root_dir / config.fans_value.module_path, "fans_value")
        , scenario_model(module_root_dir / config.scenario.module_path, "scenario")
        , foreign_aptitude_model(module_root_dir / config.foreign_aptitude.module_path, "foreign_aptitude")
        , uaf_wins_model(module_root_dir / config.uaf_wins.module_path, "uaf_wins")
        , trained_date_model(module_root_dir / config.trained_date.module_path, "trained_date") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto &anchor = frame.anchor();
        const double scan_left = anchor.absolute(config.scan_point).x();

        // winning
        scan_top = findNext(frame, {scan_left, scan_top}).value();

        // fans
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();
        record.fans = predict(
            fans_value_model, frame, anchor.absolute(config.fans_value.rect) + Point<double>{0, scan_top}, history);

        // winning record
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();

        // scenario
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();
        record.scenario = {
            predict(scenario_model, frame, anchor.absolute(config.scenario.rect) + Point<double>{0, scan_top}, history),
        };

        // There might be two lines of space below the scenario,
        // so first get the position below the scenario and then get the rest.
        const auto below_scenario_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();
        const auto &rest =
            findAll(frame, {scan_left, below_scenario_top}, config.vertical_gap, config.vertical_gap_limit);

        log_debug("rest: {}, scenario: {}", rest.size(), record.scenario.id);
        if (rest.size() >= 2) {
            // TODO: Do not want to hardcode the ID, but it is on hold because it is not possible to decide what kind of generalization is needed at this point.
            if (record.scenario.id == 5) {
                record.foreign_aptitude = predict(
                    foreign_aptitude_model,
                    frame,
                    anchor.absolute(config.foreign_aptitude.rect) + Point<double>{0, below_scenario_top},
                    history);
            } else {
                record.uaf_wins = predict(
                    uaf_wins_model,
                    frame,
                    anchor.absolute(config.uaf_wins.rect) + Point<double>{0, below_scenario_top},
                    history);
            }
        }

        record.trained_date = predict(
            trained_date_model,
            frame,
            anchor.absolute(config.trained_date.rect) + Point<double>{0, rest.back()},
            history);

        scan_top = rest.back() + config.vertical_delta;
    }

private:
    [[nodiscard]] std::vector<double>
    findAll(const Frame &frame, const Point<double> &scan_top_left, double gap, double gap_limit) const {
        std::vector<double> found_tops;
        double current_top = scan_top_left.y();
        for (;;) {
            const auto &found = findNext(frame, {scan_top_left.x(), current_top + gap}, gap_limit);
            if (!found.has_value()) {
                break;
            }
            current_top = found.value();
            found_tops.push_back(current_top);
        }
        return found_tops;
    }

    [[nodiscard]] std::optional<double>
    findNext(const Frame &frame, const Point<double> &scan_top_left, double max_length = 1.0) const {
        return searchVertical(frame, common_config.bg_color, scan_top_left, max_length);
    }

    const recognizer_config::CampaignRecordConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

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
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , title_model(module_root_dir / config.title.module_path, "race_title")
        , place_model(module_root_dir / config.place.module_path, "race_place")
        , weather_model(module_root_dir / config.weather.module_path, "race_weather")
        , strategy_model(module_root_dir / config.strategy.module_path, "race_strategy")
        , turn_model(module_root_dir / config.turn.module_path, "race_turn")
        , position_model(module_root_dir / config.position.module_path, "race_position") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto &anchor = frame.anchor();
        const double scan_left = anchor.absolute(config.scan_point).x();
        const double area_bottom = anchor.absolute(common_config.area).bottom();

        std::vector<record::Race> races;
        for (;;) {
            const auto scan_result = findNext(frame, {scan_left, scan_top}, area_bottom - scan_top);
            if (!scan_result) {
                break;
            }
            races.push_back(recognizeRace(frame, {0.0, scan_result.value()}, history));
            scan_top = scan_result.value() + config.vertical_delta;
        }

        record.races = races;
    }

private:
    [[nodiscard]] std::optional<double>
    findNext(const Frame &frame, const Point<double> &scan_top_left, double max_length) const {
        return searchVertical(frame, common_config.bg_color, scan_top_left, max_length);
    }

    [[nodiscard]] record::Race
    recognizeRace(const Frame &frame, const Point<double> &scan_offset, PredictionHistory &history) const {
        assert_(scan_offset.anchor() == ScreenStart);
        const auto &anchor = frame.anchor();

        record::Race race{};

        race.title = predict(title_model, frame, anchor.absolute(config.title.rect) + scan_offset, history);

        race.weather = predict(weather_model, frame, anchor.absolute(config.weather.rect) + scan_offset, history);

        race.strategy = predict(strategy_model, frame, anchor.absolute(config.strategy.rect) + scan_offset, history);

        race.turn = predict(turn_model, frame, anchor.absolute(config.turn.rect) + scan_offset, history);

        race.position = predict(position_model, frame, anchor.absolute(config.position.rect) + scan_offset, history)
                      + 1;  // 1-based

        const auto &place = predict(place_model, frame, anchor.absolute(config.place.rect) + scan_offset, history);
        race.place = place.place;
        race.ground = place.ground;
        race.distance = place.distance;
        race.variation = place.variation;

        return race;
    }

    const recognizer_config::RaceConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    recognizer::Model<IndexPrediction> title_model;
    recognizer::Model<RacePlacePrediction> place_model;
    recognizer::Model<IndexPrediction> weather_model;
    recognizer::Model<IndexPrediction> strategy_model;
    recognizer::Model<IndexPrediction> turn_model;
    recognizer::Model<IndexPrediction> position_model;
};

class CampaignTabRecognizer {
public:
    [[maybe_unused]] CampaignTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::CampaignTabConfig &config)
        : config(config)
        , support_card_recognizer(module_root_dir, config.support_card, config.common)
        , family_tree_recognizer(module_root_dir, config.family_tree, config.common)
        , campaign_record_recognizer(module_root_dir, config.campaign_record, config.common)
        , race_record_recognizer(module_root_dir, config.race, config.common) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record, PredictionHistory &history) const {
        double scan_top = frame.anchor().absolute(config.common.area).top();
        support_card_recognizer.recognize(frame, record, scan_top, history);
        family_tree_recognizer.recognize(frame, record, scan_top, history);
        campaign_record_recognizer.recognize(frame, record, scan_top, history);
        race_record_recognizer.recognize(frame, record, scan_top, history);
    }

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
        const event_util::Listener<std::string> &on_recognize_ready,
        const event_util::Sender<std::string> &on_recognize_completed,
        const event_util::Listener<std::string> &on_update_requested,
        const event_util::Sender<std::string> &on_update_completed,
        const recognizer_config::CharaDetailRecognizerConfig &config)
        : trainer_id(trainer_id)
        , record_root_dir(record_root_dir)
        , module_root_dir(module_root_dir)
        , on_recognize_ready(on_recognize_ready)
        , on_recognize_completed(on_recognize_completed)
        , on_update_requested(on_update_requested)
        , on_update_completed(on_update_completed)
        , config(config)
        , status_header_recognizer(module_root_dir, config.status_header)
        , skill_tab_recognizer(module_root_dir, config.skill_tab)
        , factor_tab_recognizer(module_root_dir, config.factor_tab)
        , campaign_tab_recognizer(module_root_dir, config.campaign_tab) {
        this->on_recognize_ready->listen([this](const auto &id) { this->recognize(id, false); });
        this->on_update_requested->listen([this](const auto &id) { this->recognize(id, true); });
    }

    void recognize(const std::string &id, bool isUpdateMode) {
        vlog_debug(id, isUpdateMode);

        const auto &record_dir = record_root_dir / id;

        const auto &skill_frame = Frame::open(record_dir / "skill.png");
        const auto &factor_frame = Frame::open(record_dir / "factor.png");
        const auto &campaign_frame = Frame::open(record_dir / "campaign.png");

        recognizer_impl::PredictionHistory status_header_history;
        recognizer_impl::PredictionHistory skill_tab_history;
        recognizer_impl::PredictionHistory factor_tab_history;
        recognizer_impl::PredictionHistory campaign_tab_history;

        recognizer_impl::CropInfo crop_info;

        auto started = std::chrono::steady_clock::now();

        const auto timestamp = chrono_util::utc();
        record::CharaDetailRecord record;

        status_header_recognizer.recognize(skill_frame, record, status_header_history);
        skill_tab_recognizer.recognize(skill_frame, record, skill_tab_history);
        factor_tab_recognizer.recognize(factor_frame, record, crop_info, factor_tab_history);
        campaign_tab_recognizer.recognize(campaign_frame, record, campaign_tab_history);

        const auto version_info =
            json_util::read(module_root_dir / "version_info.json").get<recognizer_impl::VersionInfo>();

        if (isUpdateMode) {
            const auto old_record = json_util::read(record_dir / "record.json").get<record::CharaDetailRecord>();
            record.metadata = old_record.metadata;
            record.metadata.recognizer_version = version_info.recognizer_version;
        } else {
            record.metadata = {
                version_info.format_version,
                version_info.region,
                {id},
                trainer_id,
                timestamp,
                version_info.recognizer_version,
                "active",
                (!record.races.empty() ? record.races.front().strategy : 0),
            };
        }

        auto elapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        vlog_debug(elapsed);

        json_util::write(record_dir / "record.json", record, 4);

        json_util::write(
            record_dir / "prediction.json",
            {
                {"status_header", status_header_history.toJson()},
                {"skill_tab", skill_tab_history.toJson()},
                {"factor_tab", factor_tab_history.toJson()},
                {"campaign_tab", campaign_tab_history.toJson()},
            },
            4);

        factor_frame.view(crop_info.trainee_icon.margined(0.0037, 0.0120, 0.0037, 0.0018))
            .save(record_dir / "trainee.jpg");

        if (isUpdateMode) {
            on_update_completed->send(id);
        } else {
            on_recognize_completed->send(id);
        }
    }

private:
    const std::string trainer_id;
    const std::filesystem::path record_root_dir;
    const std::filesystem::path module_root_dir;
    const recognizer_config::CharaDetailRecognizerConfig config;

    const recognizer_impl::StatusHeaderRecognizer status_header_recognizer;
    const recognizer_impl::SkillTabRecognizer skill_tab_recognizer;
    const recognizer_impl::FactorTabRecognizer factor_tab_recognizer;
    const recognizer_impl::CampaignTabRecognizer campaign_tab_recognizer;

    const event_util::Listener<std::string> on_recognize_ready;
    const event_util::Sender<std::string> on_recognize_completed;

    const event_util::Listener<std::string> on_update_requested;
    const event_util::Sender<std::string> on_update_completed;
};

}  // namespace uma::chara_detail
