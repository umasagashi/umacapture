#pragma once

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_record.h"
#include "cv/frame.h"
#include "cv/model.h"
#include "util/event_util.h"
#include "util/misc.h"

namespace uma::chara_detail {

namespace recognizer_impl {

struct IndexPrediction : public recognizer::Prediction {
    [[nodiscard]] int result() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] auto confidence() const { return at<float>(1); }
};

struct CharaPrediction : public recognizer::Prediction {
    [[nodiscard]] int icon() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] int chara() const { return static_cast<int>(at<int64_t>(2)); }

    [[nodiscard]] int card() const { return static_cast<int>(at<int64_t>(4)); }

    [[nodiscard]] bool rental() const { return at<int64_t>(6); }

    [[nodiscard]] std::pair<record::Character, bool> result() const {
        return {
            {
                icon(),
                chara(),
                card(),
            },
            rental(),
        };
    }

    [[nodiscard]] auto confidence() const { return std::min({at<float>(1), at<float>(3), at<float>(5), at<float>(7)}); }
};

struct RacePlace {
    int place;
    int ground;
    int distance;
    int variation;
};

struct RacePlacePrediction : public recognizer::Prediction {
    [[nodiscard]] int place() const { return static_cast<int>(at<int64_t>(0)); }

    [[nodiscard]] int ground() const { return static_cast<int>(at<int64_t>(2)); }

    [[nodiscard]] int distance() const { return static_cast<int>(at<int64_t>(4)); }

    [[nodiscard]] int variation() const { return static_cast<int>(at<int64_t>(6)); }

    [[nodiscard]] RacePlace result() const {
        return {
            place(),
            ground(),
            distance(),
            variation(),
        };
    }

    [[nodiscard]] auto confidence() const { return std::min({at<float>(1), at<float>(3), at<float>(5), at<float>(7)}); }
};

struct DateTimePrediction : public recognizer::Prediction {
    [[nodiscard]] std::string result() const {
        const auto short_str = std::to_string(at<int64_t>(0));
        return short_str.substr(0, 4) + "/" + short_str.substr(4, 2) + "/" + short_str.substr(6);
    }

    [[nodiscard]] auto confidence() const { return at<float>(1); }
};

inline int count = 0;

template<typename PredictionType>
inline auto predict(const recognizer::Model<PredictionType> &model, const Frame &frame, const Rect<double> &position) {
    const auto path = std::string("./sandbox/") + std::to_string(10000 + count++).substr(1) + ".png";
    frame.view(position).save(path);
    const auto predicted = model.predict(frame.view(position));
    vlog_debug(predicted.confidence(), path);
    return predicted.result();
}

template<typename PredictionType, size_t n>
inline auto predict(
    const recognizer::Model<PredictionType> &model, const Frame &frame, const std::array<Rect<double>, n> &positions) {
    std::array<decltype(PredictionType().result()), n> values = {};
    for (int i = 0; i < n; i++) {
        values[i] = predict(model, frame, positions[i]);
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
    StatusHeaderRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::StatusHeaderConfig &config)
        : config(config)
        , evaluation_value_model(module_root_dir / config.evaluation.module_path)
        , status_value_model(module_root_dir / config.status.module_path)
        , aptitude_model(module_root_dir / config.aptitude.module_path) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record) const {
        record.evaluation_value = predict(evaluation_value_model, frame, config.evaluation.position);
        record.status = predict(status_value_model, frame, config.status.positions);
        record.aptitudes = predict(aptitude_model, frame, config.aptitude.positions);
    }

private:
    const recognizer_config::StatusHeaderConfig config;

    recognizer::Model<IndexPrediction> evaluation_value_model;
    recognizer::Model<IndexPrediction> status_value_model;
    recognizer::Model<IndexPrediction> aptitude_model;
};

class SkillTabRecognizer {
public:
    SkillTabRecognizer(const std::filesystem::path &module_root_dir, const recognizer_config::SkillTabConfig &config)
        : config(config)
        , skill_model(module_root_dir / config.module_path)
        , skill_level_model(module_root_dir / config.skill_level.module_path) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record) const {
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
            skills.push_back(predictSkill(frame, left_rect, left_column_y.value(), skills.empty()));

            // Find next row of RIGHT column.
            const auto right_column_y = findNext(frame, right_rect.topLeft().withY(current_y));
            if (!right_column_y) {
                break;
            }
            skills.push_back(predictSkill(frame, right_rect, right_column_y.value()));

            current_y = left_column_y.value() + config.vertical_delta;
        }
        record.skills = skills;
    }

private:
    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const {
        return searchVertical(frame, config.bg_color, scan_top_left, config.vertical_gap);
    }

    [[nodiscard]] record::Skill
    predictSkill(const Frame &frame, const Rect<double> &rect, double top, bool predict_level = false) const {
        assert_(config.skill_level.position.topLeft().anchor() == ScreenStart);
        assert_(config.skill_level.position.bottomRight().anchor() == ScreenStart);
        assert_(rect.topLeft().anchor() == ScreenStart);
        assert_(rect.bottomRight().anchor() == ScreenStart);

        const auto skill_id = predict(skill_model, frame, rect + Point<double>{0.0, top});
        if (!predict_level) {
            return {skill_id};
        }
        const auto skill_level =
            predict(skill_level_model, frame, config.skill_level.position + Point<double>{rect.left(), top});
        return {
            skill_id,
            skill_level + 1,  // 1-based
        };
    }

    const recognizer_config::SkillTabConfig config;

    recognizer::Model<IndexPrediction> skill_model;
    recognizer::Model<IndexPrediction> skill_level_model;
};

class FactorTabRecognizer {
public:
    FactorTabRecognizer(const std::filesystem::path &module_root_dir, const recognizer_config::FactorTabConfig &config)
        : config(config)
        , factor_model(module_root_dir / config.module_path)
        , factor_rank_model(module_root_dir / config.factor_rank.module_path) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record) const {
        double current_y = frame.anchor().absolute(config.area).top() + config.vertical_margin;

        const auto self = recognizeOne(frame, current_y);
        const auto parent1 = recognizeOne(frame, current_y);
        const auto parent2 = recognizeOne(frame, current_y);

        record.factors = {self, parent1, parent2};
    }

private:
    [[nodiscard]] std::vector<record::Factor> recognizeOne(const Frame &frame, double &scan_top) const {
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
            factors.push_back(predictFactor(frame, left_rect, left_column_y.value()));
            scan_top = left_column_y.value() + config.vertical_delta;

            // Find next row of RIGHT column.
            const auto right_column_y = findNext(frame, right_rect.topLeft().withY(current_scan_top));
            if (!right_column_y) {
                break;
            }
            factors.push_back(predictFactor(frame, right_rect, right_column_y.value()));
        }

        scan_top += config.vertical_chara_gap;
        return factors;
    }

    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const {
        return searchVertical(frame, config.bg_color, scan_top_left, config.vertical_factor_gap);
    }

    [[nodiscard]] record::Factor predictFactor(const Frame &frame, const Rect<double> &rect, double top) const {
        assert_(config.factor_rank.position.topLeft().anchor() == ScreenStart);
        assert_(config.factor_rank.position.bottomRight().anchor() == ScreenStart);
        assert_(rect.topLeft().anchor() == ScreenStart);
        assert_(rect.bottomRight().anchor() == ScreenStart);

        const auto factor_id = predict(factor_model, frame, rect + Point<double>{0.0, top});
        const auto factor_rank =
            predict(factor_rank_model, frame, config.factor_rank.position + Point<double>{rect.left(), top});
        return {
            factor_id,
            factor_rank + 1,  // 1-based
        };
    }

    const recognizer_config::FactorTabConfig config;

    recognizer::Model<IndexPrediction> factor_model;
    recognizer::Model<IndexPrediction> factor_rank_model;
};

class SupportCardRecognizer {
public:
    SupportCardRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::SupportCardConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , support_card_model(module_root_dir / config.module_path)
        , support_card_rank_model(module_root_dir / config.rank.module_path)
        , support_card_level_model(module_root_dir / config.level.module_path) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record, double &scan_top) const {
        const auto card_top = searchVertical(
            frame,
            common_config.bg_color,
            {frame.anchor().absolute(config.scan_point).x(), scan_top, ScreenStart},
            1.0);

        const auto top_offset = Point<double>{0.0, card_top.value()};
        const auto &anchor = frame.anchor();

        const auto id_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.positions, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto rank_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.rank.positions, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto level_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.level.positions, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto id = predict(support_card_model, frame, id_rects);
        const auto rank = predict(support_card_rank_model, frame, rank_rects);
        const auto level = predict(support_card_level_model, frame, level_rects);

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
    FamilyTreeRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::FamilyTreeConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , character_model(module_root_dir / config.module_path)
        , character_rank_model(module_root_dir / config.chara_rank.module_path) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record, double &scan_top) const {
        const auto top = searchVertical(
            frame,
            common_config.bg_color,
            {frame.anchor().absolute(config.scan_point).x(), scan_top, ScreenStart},
            1.0);

        const auto top_offset = Point<double>{0.0, top.value()};
        const auto &anchor = frame.anchor();

        record.family.parent1 = recognizeParent(frame, top_offset, config.parent1, config.chara_rank.parent1);
        record.family.parent2 = recognizeParent(frame, top_offset, config.parent2, config.chara_rank.parent2);

        scan_top = top.value() + config.vertical_delta;
    }

private:
    [[nodiscard]] record::Parent recognizeParent(
        const Frame &frame,
        const Point<double> &top_offset,
        const std::array<Rect<double>, 3> &icon_rects,
        const std::array<Rect<double>, 3> &rank_rects) const {
        const auto &anchor = frame.anchor();

        const auto &mapped_icon_rects = stds::transformed_inplace<std::array<Rect<double>, 3>>(
            icon_rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });
        const auto &mapped_rank_rects = stds::transformed_inplace<std::array<Rect<double>, 3>>(
            rank_rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto &icon = predict(character_model, frame, mapped_icon_rects);
        const auto &rank = predict(character_rank_model, frame, mapped_rank_rects);

        record::Parent parent;

        parent.self = icon[0].first;
        parent.parent1 = icon[1].first;
        parent.parent2 = icon[2].first;

        parent.self.rank = rank[0];
        parent.parent1.rank = rank[1];
        parent.parent2.rank = rank[2];

        parent.rental = icon[0].second ? std::optional<bool>(true) : std::nullopt;

        return parent;
    }

    const recognizer_config::FamilyTreeConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    recognizer::Model<CharaPrediction> character_model;
    recognizer::Model<IndexPrediction> character_rank_model;
};

class CampaignRecordRecognizer {
public:
    CampaignRecordRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::CampaignRecordConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , fans_value_model(module_root_dir / config.fans_value.module_path)
        , scenario_model(module_root_dir / config.scenario.module_path)
        , trained_date_model(module_root_dir / config.trained_date.module_path) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record, double &scan_top) const {
        const auto &anchor = frame.anchor();
        const double scan_left = anchor.absolute(config.scan_point).x();

        // winning
        scan_top = findNext(frame, {scan_left, scan_top}).value();

        // fans
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();
        record.fans = predict(
            fans_value_model, frame, anchor.absolute(config.fans_value.position) + Point<double>{0.0, scan_top});

        // winning record
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();

        // scenario
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();
        record.scenario = {
            predict(scenario_model, frame, anchor.absolute(config.scenario.position) + Point<double>{0.0, scan_top}),
        };

        // evaluation value
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();

        // trained date
        scan_top = findNext(frame, {scan_left, scan_top + config.vertical_gap}).value();
        record.trained_date = predict(
            trained_date_model, frame, anchor.absolute(config.trained_date.position) + Point<double>{0.0, scan_top});

        scan_top += config.vertical_delta;
    }

private:
    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const {
        return searchVertical(frame, common_config.bg_color, scan_top_left, 1.0);
    }

    const recognizer_config::CampaignRecordConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    recognizer::Model<IndexPrediction> fans_value_model;
    recognizer::Model<IndexPrediction> scenario_model;
    recognizer::Model<DateTimePrediction> trained_date_model;
};

class RaceRecordRecognizer {
public:
    RaceRecordRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::RaceConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , race_title_model(module_root_dir / config.title.module_path)
        , race_place_model(module_root_dir / config.place.module_path)
        , race_weather_model(module_root_dir / config.weather.module_path)
        , race_strategy_model(module_root_dir / config.strategy.module_path)
        , race_turn_model(module_root_dir / config.turn.module_path)
        , race_position_model(module_root_dir / config.position.module_path) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record, double &scan_top) const {
        const auto &anchor = frame.anchor();
        const double scan_left = anchor.absolute(config.scan_point).x();
        const double area_bottom = anchor.absolute(common_config.area).bottom();

        std::vector<record::Race> races;
        for (;;) {
            const auto scan_result = findNext(frame, {scan_left, scan_top}, area_bottom - scan_top);
            if (!scan_result) {
                break;
            }
            races.push_back(recognizeRace(frame, {0.0, scan_result.value()}));
            scan_top = scan_result.value() + config.vertical_delta;
        }

        record.races = races;
    }

private:
    [[nodiscard]] std::optional<double>
    findNext(const Frame &frame, const Point<double> &scan_top_left, double max_length) const {
        return searchVertical(frame, common_config.bg_color, scan_top_left, max_length);
    }

    [[nodiscard]] record::Race recognizeRace(const Frame &frame, const Point<double> &scan_offset) const {
        assert_(scan_offset.anchor() == ScreenStart);
        const auto &anchor = frame.anchor();

        record::Race race{};

        race.title = predict(race_title_model, frame, anchor.absolute(config.title.position) + scan_offset);
        race.weather = predict(race_weather_model, frame, anchor.absolute(config.weather.position) + scan_offset);
        race.strategy = predict(race_strategy_model, frame, anchor.absolute(config.strategy.position) + scan_offset);
        race.turn = predict(race_turn_model, frame, anchor.absolute(config.turn.position) + scan_offset);
        race.position = predict(race_position_model, frame, anchor.absolute(config.position.position) + scan_offset)
                      + 1;  // 1-based

        const auto &place = predict(race_place_model, frame, anchor.absolute(config.place.position) + scan_offset);
        race.place = place.place;
        race.ground = place.ground;
        race.distance = place.distance;
        race.variation = place.variation;

        return race;
    }

    const recognizer_config::RaceConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    recognizer::Model<IndexPrediction> race_title_model;
    recognizer::Model<RacePlacePrediction> race_place_model;
    recognizer::Model<IndexPrediction> race_weather_model;
    recognizer::Model<IndexPrediction> race_strategy_model;
    recognizer::Model<IndexPrediction> race_turn_model;
    recognizer::Model<IndexPrediction> race_position_model;
};

class CampaignTabRecognizer {
public:
    CampaignTabRecognizer(
        const std::filesystem::path &module_root_dir, const recognizer_config::CampaignTabConfig &config)
        : config(config)
        , support_card_recognizer(module_root_dir, config.support_card, config.common)
        , family_tree_recognizer(module_root_dir, config.family_tree, config.common)
        , campaign_record_recognizer(module_root_dir, config.campaign_record, config.common)
        , race_record_recognizer(module_root_dir, config.race, config.common) {}

    void recognize(const Frame &frame, record::CharaDetailRecord &record) const {
        double scan_top = frame.anchor().absolute(config.common.area).top();
        support_card_recognizer.recognize(frame, record, scan_top);
        family_tree_recognizer.recognize(frame, record, scan_top);
        campaign_record_recognizer.recognize(frame, record, scan_top);
        race_record_recognizer.recognize(frame, record, scan_top);
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
        const recognizer_config::CharaDetailRecognizerConfig &config)
        : trainer_id(trainer_id)
        , record_root_dir(record_root_dir)
        , on_recognize_ready(on_recognize_ready)
        , on_recognize_completed(on_recognize_completed)
        , config(config)
        , status_header_recognizer(module_root_dir, config.status_header)
        , skill_tab_recognizer(module_root_dir, config.skill_tab)
        , factor_tab_recognizer(module_root_dir, config.factor_tab)
        , campaign_tab_recognizer(module_root_dir, config.campaign_tab) {
        this->on_recognize_ready->listen([this](const auto &id) { this->recognize(id); });
    }

    void recognize(const std::string &id) {
        vlog_debug(id, record_root_dir.string());

        const auto &record_dir = record_root_dir / id;

        const auto &skill_frame = Frame::open(record_dir / "skill.png");
        const auto &factor_frame = Frame::open(record_dir / "factor.png");
        const auto &campaign_frame = Frame::open(record_dir / "campaign.png");

        auto started = std::chrono::steady_clock::now();

        record::CharaDetailRecord record;
        record.metadata = {
            "1.0.0",
            "JPN",
            {id},
            trainer_id,
            chrono_util::utc(),
        };

        status_header_recognizer.recognize(skill_frame, record);
        skill_tab_recognizer.recognize(skill_frame, record);
        factor_tab_recognizer.recognize(factor_frame, record);
        campaign_tab_recognizer.recognize(campaign_frame, record);

        auto elapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        vlog_debug(elapsed);

        json_util::write(record_dir / "record.json", record, 2);

        on_recognize_completed->send(id);
    }

private:
    const std::string trainer_id;
    const std::filesystem::path record_root_dir;
    const recognizer_config::CharaDetailRecognizerConfig config;

    const recognizer_impl::StatusHeaderRecognizer status_header_recognizer;
    const recognizer_impl::SkillTabRecognizer skill_tab_recognizer;
    const recognizer_impl::FactorTabRecognizer factor_tab_recognizer;
    const recognizer_impl::CampaignTabRecognizer campaign_tab_recognizer;

    const event_util::Listener<std::string> on_recognize_ready;
    const event_util::Sender<std::string> on_recognize_completed;
};

}  // namespace uma::chara_detail
