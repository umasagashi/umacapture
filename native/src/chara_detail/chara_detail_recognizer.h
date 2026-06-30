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

    [[nodiscard]] bool recordType() const { return at<int64_t>(6); }

    [[nodiscard]] Chara result() const {
        return {
            icon(),
            chara(),
            card(),
            rental(),
            recordType(),
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

[[nodiscard]] std::optional<double> inline searchVertical(
    const Frame &frame,
    const Range<Color> &bg_color,
    const Point<double> &scan_start_left,
    const double max_length,
    const bool reversed = false) {
    const auto &frame_anchor = frame.anchor();
    // The scan point can map at or past the frame edge (e.g. a scan_top near the bottom); clamp the start so the
    // first isIn() does not index out of bounds in release, where bgrAt only asserts.
    const auto scan_start_pixels = std::clamp(frame_anchor.mapToFrame(scan_start_left).y(), 0, frame.height() - 1);
    const auto scan_length_pixels = frame_anchor.scaleToPixels(max_length);

    const int direction = reversed ? -1 : 1;
    const auto scan_end_pixels = std::clamp(scan_start_pixels + direction * scan_length_pixels, 0, frame.height());

    for (int y = scan_start_pixels; reversed ? (y >= scan_end_pixels) : (y < scan_end_pixels); y += direction) {
        const auto scaled_y = frame_anchor.scaleFromPixels(y);
        const auto scan_point = Point<double>{
            scan_start_left.x(),
            scaled_y,
            {scan_start_left.anchor().h(), ScreenStart},
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

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        PredictionHistory &history) const {
        if (!record::isInheritanceOnly(record_info.record_type.value())) {
            record.evaluation_value = predict(evaluation_value_model, frame, config.evaluation.rect, history);
            record.status = predict(status_value_model, frame, config.status.rects, history);
        }
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

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        PredictionHistory &history) const {
        if (record::isInheritanceOnly(record_info.record_type.value())) {
            record.skills = {};
            return;
        }
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
            {
                const Point<double> current_column_offset = {0.0, left_column_y.value()};
                const int skill_id = predict(skill_model, frame, left_rect + current_column_offset, history);
                if (!skills.empty()) {
                    skills.push_back({skill_id});
                } else {
                    const int skill_level = predict(
                        skill_level_model,
                        frame,
                        anchor.absolute(config.skill_level.rect) + current_column_offset,
                        history);
                    skills.push_back({skill_id, skill_level + 1});  // 1-based.
                }
            }

            // Find next row of RIGHT column.
            const auto right_column_y = findNext(frame, right_rect.topLeft().withY(current_y));
            if (!right_column_y) {
                break;
            }
            {
                const Point<double> current_column_offset = {0.0, right_column_y.value()};
                const int skill_id = predict(skill_model, frame, right_rect + current_column_offset, history);
                skills.push_back({skill_id});
            }

            current_y = left_column_y.value() + config.vertical_delta;
        }
        record.skills = skills;
    }

private:
    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const {
        return searchVertical(frame, config.bg_color, scan_top_left, config.vertical_gap);
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
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        CropInfo &crop_info,
        PredictionHistory &history) const {
        const auto anchor = frame.anchor();

        // Find the green banner at the top of the Factors tab to calibrate the initial Y position,
        const auto top_banner_y = searchVertical(
            frame,
            config.bg_color,
            {
                anchor.absolute(config.left_rect).left(),
                anchor.absolute(config.area).top(),
            },
            config.vertical_banner_upper_gap);
        if (!top_banner_y) {
            log_warning("Failed to find top banner of factor tab.");
            return;
        }

        // Move to the space between the banner and the first factor.
        const double scan_top = top_banner_y.value() + config.vertical_banner_bottom_delta;

        double current_y = scan_top;
        const auto self = recognizeOne(frame, current_y, history);
        const auto parent1 = recognizeOne(frame, current_y, history);
        const auto parent2 = recognizeOne(frame, current_y, history);

        record.factors = {self, parent1, parent2};

        record.trainee = recognizeTrainee(frame, record_info, scan_top, crop_info, history);
    }

    // Recognizes only the trainee's own factors that are fully visible on a single, non-stitched
    // factor-tab frame (no scrolling). Used by the early duplicate probe: the returned list is a
    // prefix of the self-factors the full pipeline would read, which is enough to match a recapture.
    [[nodiscard]] std::vector<record::Factor>
    recognizeVisibleSelf(const Frame &frame, PredictionHistory &history) const {
        const auto anchor = frame.anchor();

        const auto top_banner_y = searchVertical(
            frame,
            config.bg_color,
            {
                anchor.absolute(config.left_rect).left(),
                anchor.absolute(config.area).top(),
            },
            config.vertical_banner_upper_gap);
        if (!top_banner_y) {
            log_warning("Failed to find top banner of factor tab.");
            return {};
        }

        double scan_top = top_banner_y.value() + config.vertical_banner_bottom_delta;
        return recognizeOne(frame, scan_top, history, /*bounded=*/true);
    }

private:
    [[nodiscard]] record::Character recognizeTrainee(
        const Frame &frame,
        const RecordInfo &record_info,
        const double scan_top,
        CropInfo &crop_info,
        PredictionHistory &history) const {
        const auto &anchor = frame.anchor();
        const auto reference_top = findNext(frame, anchor.absolute(config.left_rect).topLeft().withY(scan_top));
        if (!reference_top.has_value()) {
            log_warning("Failed to find reference point for trainee icon.");
            return {};
        }
        const auto reference_offset = Point<double>{0, reference_top.value()};
        const auto chara_rect = anchor.absolute(config.trainee_icon.icon.rect) + reference_offset;
        const auto rank_rect = anchor.absolute(config.trainee_icon.rank.rect) + reference_offset;
        const auto icon = predict(character_model, frame, chara_rect, history);

        const auto rank = !record::isInheritanceOnly(record_info.record_type.value())
                            ? predict(character_rank_model, frame, rank_rect, history)
                            : 0;

        crop_info.trainee_icon = chara_rect;

        record::Character character{};
        character.icon = icon.icon;
        character.character = icon.chara;
        character.card = icon.card;
        character.rank = rank;
        return character;
    }

    // When [bounded] is set the scan stops before any row whose cell rect would fall outside the
    // frame. The full pipeline runs on a stitched image tall enough to hold every row, so it leaves
    // [bounded] false and the guard never fires. The early probe runs on a single, non-stitched
    // frame where the bottom-most visible row is clipped; predicting it would crop past the image
    // and abort OpenCV, so the probe sets [bounded] to stop at the last fully-visible row.
    [[nodiscard]] std::vector<record::Factor>
    recognizeOne(const Frame &frame, double &scan_top, PredictionHistory &history, bool bounded = false) const {
        const auto anchor = frame.anchor();
        const auto left_rect = anchor.absolute(config.left_rect);
        const auto right_rect = anchor.absolute(config.right_rect);

        const auto fits_frame = [&](const Rect<double> &cell, double top) {
            const auto mapped = anchor.mapToFrame(cell + Point<double>{0, top});
            return mapped.top() >= 0 && mapped.left() >= 0  //
                && mapped.bottom() <= frame.height() && mapped.right() <= frame.width();
        };

        std::vector<record::Factor> factors;
        for (;;) {
            const auto current_scan_top = scan_top;

            // Find next row of LEFT column.
            const auto left_column_y = findNext(frame, left_rect.topLeft().withY(current_scan_top));
            if (!left_column_y) {
                break;
            }
            if (bounded && !fits_frame(left_rect, left_column_y.value())) {
                break;
            }
            factors.push_back(predictFactor(frame, left_rect, left_column_y.value(), history));
            scan_top = left_column_y.value() + config.vertical_delta;

            // Find next row of RIGHT column.
            const auto right_column_y = findNext(frame, right_rect.topLeft().withY(current_scan_top));
            if (!right_column_y) {
                break;
            }
            if (bounded && !fits_frame(right_rect, right_column_y.value())) {
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
        , support_card_rank_model(module_root_dir / config.rank.module_path, "support_card_rank") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto card_top = searchVertical(
            frame,
            common_config.loose_bg_color,  // May start from slightly above the scroll area.
            {frame.anchor().absolute(config.scan_point).x(), scan_top, ScreenStart},
            1.0);
        if (!card_top) {
            log_warning("Failed to find top of support card area.");
            return;
        }

        const auto top_offset = Point<double>{0, card_top.value()};
        const auto &anchor = frame.anchor();

        const auto id_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto rank_rects = stds::transformed_inplace<std::array<Rect<double>, 6>>(
            config.rank.rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto id = predict(support_card_model, frame, id_rects, history);
        const auto rank = predict(support_card_rank_model, frame, rank_rects, history);

        std::array<record::SupportCard, 6> support_cards{};
        for (int i = 0; i < support_cards.size(); i++) {
            // Card levels no longer exist in the game.
            // Until the record field is deleted, fill it with a dummy value.
            constexpr auto level = 0;

            support_cards[i] = {
                id[i],
                rank[i] + 1,  // 1-based
                level,
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
};

class FamilyTreeRecognizer {
public:
    [[maybe_unused]] FamilyTreeRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::FamilyTreeConfig &config,
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , character_model(module_root_dir / config.module.chara, "character")
        , character_rank_model(module_root_dir / config.module.rank, "character_rank") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto top = searchVertical(
            frame,
            common_config.strict_bg_color,
            {frame.anchor().absolute(config.scan_point).x(), scan_top, ScreenStart},
            1.0);
        if (!top) {
            log_warning("Failed to find top of family tree.");
            return;
        }
        const auto bottom = searchVertical(
            frame,
            config.frame_color,
            {frame.anchor().absolute(config.scan_point).x(), top.value() + config.vertical_gap, ScreenStart},
            1.0);
        if (!bottom) {
            log_warning("Failed to find bottom of family tree.");
            return;
        }
        const auto top_offset = Point<double>{0, top.value()};
        const auto frame_height = bottom.value() - top.value();
        if (frame_height > config.legacy_frame_height) {
            record.family = recognizeTree(frame, top_offset, config.legacy_icons, history);
        } else {
            record.family = recognizeTree(frame, top_offset, config.icons, history);
        }

        scan_top = bottom.value() + config.vertical_delta;
    }

private:
    [[nodiscard]] record::Family recognizeTree(
        const Frame &frame,
        const Point<double> &top_offset,
        const recognizer_config::FamilyTreeIconConfig &icon_config,
        PredictionHistory &history) const {
        return {
            recognizeParent(frame, top_offset, icon_config.parent1, history),
            recognizeParent(frame, top_offset, icon_config.parent2, history),
        };
    }

    [[nodiscard]] record::Parent recognizeParent(
        const Frame &frame,
        const Point<double> &top_offset,
        const std::array<recognizer_config::IconSetConfig, 3> &icon_config,
        PredictionHistory &history) const {
        const std::array<Rect<double>, 3> icon_rects = {
            icon_config[0].chara, icon_config[1].chara, icon_config[2].chara};
        const std::array<Rect<double>, 3> rank_rects = {icon_config[0].rank, icon_config[1].rank, icon_config[2].rank};
        const auto &anchor = frame.anchor();

        const auto &mapped_icon_rects = stds::transformed_inplace<std::array<Rect<double>, 3>>(
            icon_rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });
        const auto &mapped_rank_rects = stds::transformed_inplace<std::array<Rect<double>, 3>>(
            rank_rects, [&](const auto &r) { return anchor.absolute(r) + top_offset; });

        const auto &icon = predict(character_model, frame, mapped_icon_rects, history);
        const auto &rank = predict(character_rank_model, frame, mapped_rank_rects, history);

        record::Parent parent{};
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
        character.record_type = static_cast<record::RecordType>(chara.record_type);
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
        , campaign_field_model(module_root_dir / config.campaign_field.module_path, "campaign_field")
        , fans_value_model(module_root_dir / config.fans_value.module_path, "fans_value")
        , scenario_model(module_root_dir / config.scenario.module_path, "scenario")
        , foreign_aptitude_model(module_root_dir / config.foreign_aptitude.module_path, "foreign_aptitude")
        , uaf_wins_model(module_root_dir / config.uaf_wins.module_path, "uaf_wins")
        , trained_date_model(module_root_dir / config.trained_date.module_path, "trained_date") {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto &anchor = frame.anchor();
        const double scan_left = anchor.absolute(config.scan_point).x();
        const double bg_scan_left = anchor.absolute(config.bg_scan_point).x();

        // Find the bottom of the area to be scanned.
        const auto area_bottom_opt = findNext(frame, {bg_scan_left, scan_top});
        if (!area_bottom_opt) {
            log_warning("Failed to find bottom of campaign record area.");
            return;
        }
        const double area_bottom = area_bottom_opt.value();

        const auto &field_tops =
            findAll(frame, {scan_left, scan_top}, config.vertical_gap, area_bottom - config.vertical_gap);

        std::map<int, float> predicted_field_confidences;
        for (const auto &field_top : field_tops) {
            const auto [field_class, confidence] = predictFieldClass(frame, anchor, {0.0, field_top}, history);
            if (field_class == 0) {
                continue;  // Unknown (not yet supported) class.
            }
            float &best_confidence = predicted_field_confidences[field_class];
            if (best_confidence > 0) {
                // This should not happen, but fields added for the new scenario may be incorrectly recognized as existing ones.
                log_warning("Field {} found multiple times.", field_class);
            }
            if (best_confidence >= confidence) {
                // If the previous prediction has higher confidence, use that one.
                // If the new prediction has higher confidence, allow it to overwrite the previous one.
                // This does not guarantee that incorrect fields will always be overwritten.
                continue;
            }
            best_confidence = confidence;

            switch (field_class) {
                case 3: record.fans = predictFans(frame, anchor, {0.0, field_top}, history); break;
                case 5: record.scenario = predictScenario(frame, anchor, {0.0, field_top}, history); break;
                case 7: record.trained_date = predictTrainedDate(frame, anchor, {0.0, field_top}, history); break;
                default:  // Do nothing for the rest of the classes.
                    break;
            }
        }

        if (field_tops.empty()) {
            log_warning("No campaign record fields found.");
            return;
        }
        scan_top = field_tops.back() + config.vertical_delta;
    }

private:
    [[nodiscard]] std::pair<int, float> predictFieldClass(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const {
        return predictWithConfidence(
            campaign_field_model, frame, anchor.absolute(config.campaign_field.rect) + pos, history);
    }

    [[nodiscard]] int predictFans(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const {
        return predict(fans_value_model, frame, anchor.absolute(config.fans_value.rect) + pos, history);
    }

    [[nodiscard]] record::Scenario predictScenario(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const {
        return {predict(scenario_model, frame, anchor.absolute(config.scenario.rect) + pos, history)};
    }

    [[nodiscard]] std::string predictTrainedDate(
        const Frame &frame, const FrameAnchor &anchor, const Point<double> &pos, PredictionHistory &history) const {
        return predict(trained_date_model, frame, anchor.absolute(config.trained_date.rect) + pos, history);
    }

    [[nodiscard]] std::vector<double>
    findAll(const Frame &frame, const Point<double> &scan_top_left, double initial_gap, double bottom_limit) const {
        std::vector<double> found_tops;
        double current_top = scan_top_left.y();
        for (;;) {
            const auto &found = findNext(frame, {scan_top_left.x(), current_top + initial_gap});
            if (!found.has_value() || found.value() > bottom_limit) {
                break;
            }
            current_top = found.value();
            found_tops.push_back(current_top);
        }
        return found_tops;
    }

    [[nodiscard]] std::optional<double>
    findNext(const Frame &frame, const Point<double> &scan_top_left, const double max_length = 1.0) const {
        return searchVertical(frame, common_config.strict_bg_color, scan_top_left, max_length);
    }

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
        const recognizer_config::CampaignTabCommonConfig &common_config)
        : config(config)
        , common_config(common_config)
        , models_1line(module_root_dir, config.block_1line_config)
        , models_2line(module_root_dir, config.block_2line_config) {}

    void recognize(
        const Frame &frame, record::CharaDetailRecord &record, double &scan_top, PredictionHistory &history) const {
        const auto &anchor = frame.anchor();
        const auto approx_scan_offset = anchor.absolute(config.approx_scan_point);
        const auto exact_scan_offset = anchor.absolute(config.exact_scan_point);
        const double area_bottom = anchor.absolute(common_config.area).bottom();

        std::vector<record::Race> races;
        for (;;) {
            // First, determine the exact top coordinate of the block.
            const auto block_top = findNextBlock(frame, exact_scan_offset + Point<double>{0.0, scan_top}, area_bottom);
            if (!block_top) {
                break;
            }

            // Next, determine the approximate bottom coordinate of the block.
            // Search points that avoid interference from elements within the block are only available along the edges.
            // However, the edges are rounded, which can result in inaccurate results.
            const auto approx_bottom =
                findNextGap(frame, approx_scan_offset + Point<double>{0.0, block_top.value()}, area_bottom);
            assert_(approx_bottom.has_value());
            if (!approx_bottom) {
                log_warning("Failed to find approximate bottom of race block.");
                break;
            }

            // Then, determine the exact bottom coordinate of the block.
            // By starting the search from the approx bottom, elements within the block will no longer interfere.
            const auto block_bottom = findLast(frame, exact_scan_offset + Point<double>{0.0, approx_bottom.value()});
            if (!block_bottom) {
                log_warning("Failed to find bottom of race block.");
                break;
            }

            // Finally, we can recognize the block.
            const auto block_rect =
                Rect<double>{Point<double>{0.0, block_top.value()}, Point<double>{0.0, block_bottom.value()}};
            const bool is_2line = (block_bottom.value() - block_top.value()) > config.block_height_threshold;
            races.push_back(recognizeRace(
                frame,
                block_rect,
                is_2line ? models_2line : models_1line,
                is_2line ? config.block_2line_config : config.block_1line_config,
                history));

            // Proceed to the next block.
            scan_top = block_bottom.value() + config.vertical_delta;
        }

        record.races = races;
    }

private:
    struct RaceBlockModelSet {
        RaceBlockModelSet(
            const std::filesystem::path &module_root_dir, const recognizer_config::RaceBlockConfig &block_config)
            : title(module_root_dir / block_config.title.module_path, "race_title")
            // race_place has 1line and 2line variations, but since there's no need to distinguish the output, name can be the same.
            , place(module_root_dir / block_config.place.module_path, "race_place")
            , weather(module_root_dir / block_config.weather.module_path, "race_weather")
            , strategy(module_root_dir / block_config.strategy.module_path, "race_strategy")
            , turn(module_root_dir / block_config.turn.module_path, "race_turn")
            , position(module_root_dir / block_config.position.module_path, "race_position") {}

        recognizer::Model<IndexPrediction> title;
        recognizer::Model<RacePlacePrediction> place;
        recognizer::Model<IndexPrediction> weather;
        recognizer::Model<IndexPrediction> strategy;
        recognizer::Model<IndexPrediction> turn;
        recognizer::Model<IndexPrediction> position;
    };

    [[nodiscard]] std::optional<double>
    findNextBlock(const Frame &frame, const Point<double> &scan_top_left, const double bottom) const {
        return searchVertical(frame, common_config.strict_bg_color, scan_top_left, bottom - scan_top_left.y());
    }

    [[nodiscard]] std::optional<double>
    findNextGap(const Frame &frame, const Point<double> &scan_top_left, const double bottom) const {
        return searchVertical(frame, common_config.block_bg_color, scan_top_left, bottom - scan_top_left.y());
    }

    [[nodiscard]] std::optional<double> findLast(const Frame &frame, const Point<double> &scan_bottom_left) const {
        return searchVertical(frame, common_config.strict_bg_color, scan_bottom_left, scan_bottom_left.y(), true);
    }

    [[nodiscard]] record::Race recognizeRace(
        const Frame &frame,
        const Rect<double> &block_rect,
        const RaceBlockModelSet &block_models,
        const recognizer_config::RaceBlockConfig &block_config,
        PredictionHistory &history) const {
        const auto &anchor = frame.anchor();
        const auto block_top_offset = Point<double>{0, block_rect.top()};
        const auto block_bottom_offset = Point<double>{0, block_rect.bottom()};
        const auto block_center_offset = (block_top_offset + block_bottom_offset) / 2.0;

        record::Race race{};

        // Offset from the top of the block.
        race.title =
            predict(block_models.title, frame, anchor.absolute(block_config.title.rect) + block_top_offset, history);
        race.weather = predict(
            block_models.weather, frame, anchor.absolute(block_config.weather.rect) + block_top_offset, history);

        const auto &place =
            predict(block_models.place, frame, anchor.absolute(block_config.place.rect) + block_top_offset, history);
        race.place = place.place;
        race.ground = place.ground;
        race.distance = place.distance;
        race.variation = place.variation;

        // Offset from the bottom of the block.
        race.strategy = predict(
            block_models.strategy, frame, anchor.absolute(block_config.strategy.rect) + block_bottom_offset, history);
        race.turn =
            predict(block_models.turn, frame, anchor.absolute(block_config.turn.rect) + block_bottom_offset, history);

        // Offset from the vertical-center of the block.
        race.position = predict(
                            block_models.position,
                            frame,
                            anchor.absolute(block_config.position.rect) + block_center_offset,
                            history)
                      + 1;  // 1-based

        return race;
    }

    const recognizer_config::RaceConfig config;
    const recognizer_config::CampaignTabCommonConfig common_config;

    RaceBlockModelSet models_1line;
    RaceBlockModelSet models_2line;
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
        const event_util::Listener<RecordInfo> &on_recognize_ready,
        const event_util::Sender<RecordInfo> &on_recognize_completed,
        const event_util::Listener<RecordInfo> &on_update_requested,
        const event_util::Sender<RecordInfo> &on_update_completed,
        const event_util::Listener<Frame, RecordInfo> &on_factor_probe_ready,
        const event_util::Sender<std::vector<record::Factor>> &on_factor_probe_completed,
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
        , on_factor_probe_completed(on_factor_probe_completed) {
        this->on_recognize_ready->listen([this](const auto &info) { this->recognize(info, false); });
        this->on_update_requested->listen([this](const auto &info) { this->recognize(info, true); });
        this->on_factor_probe_ready->listen([this](const auto &frame, const auto &info) { this->probe(frame, info); });
    }

    // Recognizes only the trainee's own factors visible on a single, non-stitched factor-tab frame
    // (the stable frame captured at scroll-ready) so the duplicate check can run before scrolling.
    // Reuses the same FactorTabRecognizer as the full pipeline, bounded to the visible rows; the
    // result is a prefix of the self-factor list, matched against stored records on the Dart side.
    void probe(const Frame &frame, const RecordInfo &raw_info) const {
        vlog_debug(raw_info.record_id, raw_info.record_type.has_value());

        recognizer_impl::PredictionHistory factor_tab_history;
        auto self_factors = factor_tab_recognizer.recognizeVisibleSelf(frame, factor_tab_history);
        // Drop the last recognized row: on a non-stitched live frame the bottom-most visible row can
        // be clipped by the tab boundary, so its star rank is unreliable. The remaining prefix is still
        // a strong signature and is matched against the leading self-factors of stored records.
        if (!self_factors.empty()) {
            self_factors.pop_back();
        }

        on_factor_probe_completed->send(self_factors);
    }

    void recognize(const RecordInfo &raw_info, bool isUpdateMode) const {
        vlog_debug(raw_info.record_id, raw_info.record_type.has_value(), isUpdateMode);

        const auto record_dir = record_root_dir / raw_info.record_id;
        const auto record_path = record_dir / "record.json";
        auto record_info = raw_info;

        if (!record_info.record_type.has_value()) {
            assert_(std::filesystem::exists(record_path));
            const auto old_record = json_util::read(record_path).get<record::CharaDetailRecord>();
            record_info.record_type = old_record.metadata.record_type.value_or(record::RecordType::Standard);
        }

        const auto &skill_frame = Frame::open(record_dir / "skill.png");
        const auto &factor_frame = Frame::open(record_dir / "factor.png");
        const auto &campaign_frame = Frame::open(record_dir / "campaign.png");

        recognizer_impl::PredictionHistory status_header_history;
        recognizer_impl::PredictionHistory skill_tab_history;
        recognizer_impl::PredictionHistory factor_tab_history;
        recognizer_impl::PredictionHistory campaign_tab_history;

        recognizer_impl::CropInfo crop_info{};

        auto started = std::chrono::steady_clock::now();

        const auto now = chrono_util::local_now();
        const auto utc_now = chrono_util::to_datetime_string(now);
        const auto timestamp = chrono_util::to_timestamp(now);

        record::CharaDetailRecord record{};

        status_header_recognizer.recognize(skill_frame, record_info, record, status_header_history);
        skill_tab_recognizer.recognize(skill_frame, record_info, record, skill_tab_history);
        factor_tab_recognizer.recognize(factor_frame, record_info, record, crop_info, factor_tab_history);
        campaign_tab_recognizer.recognize(campaign_frame, record, campaign_tab_history);

        const auto version_info =
            json_util::read(module_root_dir / "version_info.json").get<recognizer_impl::VersionInfo>();

        if (isUpdateMode) {
            const auto old_record = json_util::read(record_path).get<record::CharaDetailRecord>();
            record.metadata = old_record.metadata;
            record.metadata.recognizer_version = version_info.recognizer_version;

            std::filesystem::copy_file(
                record_path,
                record_dir / ("record_" + std::to_string(timestamp) + ".json"),
                std::filesystem::copy_options::overwrite_existing);
        } else {
            // A friend's record has no recoverable owner trainer id, so attribute it to the
            // unknown-owner sentinel instead of the capturing player's id.
            const auto &owner_trainer_id =
                record::isFriend(record_info.record_type.value()) ? record::kUnknownTrainerId : trainer_id;
            record.metadata = {
                version_info.format_version,
                version_info.region,
                {record_info.record_id},
                owner_trainer_id,
                utc_now,
                version_info.recognizer_version,
                "active",
                (!record.races.empty() ? record.races.front().strategy : 0),
                std::nullopt,
                record_info.record_type,
            };
        }

        auto elapsed =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count();
        vlog_debug(elapsed);

        json_util::write(record_path, record, 4);

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
            on_update_completed->send(record_info);
        } else {
            on_recognize_completed->send(record_info);
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

    const event_util::Listener<RecordInfo> on_recognize_ready;
    const event_util::Sender<RecordInfo> on_recognize_completed;

    const event_util::Listener<RecordInfo> on_update_requested;
    const event_util::Sender<RecordInfo> on_update_completed;

    const event_util::Listener<Frame, RecordInfo> on_factor_probe_ready;
    const event_util::Sender<std::vector<record::Factor>> on_factor_probe_completed;
};

}  // namespace uma::chara_detail
