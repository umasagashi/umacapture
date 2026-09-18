#pragma once

#include <algorithm>
#include <array>
#include <cctype>
#include <filesystem>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

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
#include "util/thread_util.h"

namespace uma::chara_detail {

namespace recognizer_impl {

struct VersionInfo {
    std::string format_version;
    std::string region;
    std::string recognizer_version;

    EXTENDED_JSON_TYPE_NDC(VersionInfo, format_version, region, recognizer_version);
};

// The recognized value of a Chara/CharaRank prediction: the Result type of Predictor<Chara>, produced by
// CharaDecoder (recognizer_prediction.h).
struct Chara {
    int icon;
    int chara;
    int card;
    bool rental;
    int record_type;

    EXTENDED_JSON_TYPE_NDC(Chara, icon, chara, card, rental, record_type);
};

// The recognized value of a RacePlace prediction: the Result type of Predictor<RacePlace>, produced by
// RacePlaceDecoder (recognizer_prediction.h).
struct RacePlace {
    int place;
    int ground;
    int distance;
    int variation;

    EXTENDED_JSON_TYPE_NDC(RacePlace, place, ground, distance, variation);
};

// Formats a raw YYYYMMDD integer as "YYYY/MM/DD", degrading to the raw stringified value on any malformed
// input. DateTimeDecoder (recognizer_prediction.h) calls it on the label it reads; it stands alone so this
// pure string logic (which carries the edge-case fixes below) can be unit-tested without a prediction.
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
        log_warning("DateTimeDecoder: unexpected date value '{}'", short_str);
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

// A predictor that more than one pipeline stage calls, admitted one call at a time in the order the calls
// arrive.
//
// An inference predictor is not safe to call from two threads at once (recognizer::Model::predict mutates
// hidden session state), and the factor tab's two row models are shared by two stages (see FactorRowReader).
// The queue is a FIFO rather than a std::mutex so that a caller's wait is bounded by the calls queued ahead of
// it, not by how often the other stage happens to re-acquire; thread_util::FifoAdmission states the difference.
// Each predictor carries its own admission because the thread-safety contract belongs to the instance.
template<typename Result>
class AdmittedPredictor : public recognizer::Predictor<Result> {
public:
    explicit AdmittedPredictor(std::unique_ptr<const recognizer::Predictor<Result>> inner)
        : inner(std::move(inner)) {}

    [[nodiscard]] recognizer::Predicted<Result> predict(const Frame &frame) const override {
        const auto pass = admission.admit();
        return inner->predict(frame);
    }

    [[nodiscard]] const std::string &name() const override { return inner->name(); }

private:
    std::unique_ptr<const recognizer::Predictor<Result>> inner;
    mutable thread_util::FifoAdmission admission;
};

// WHAT A SINGLE LIVE FRAME IS READ FOR, as one record layout defines it: where the factor tab's scroll area sits
// on that frame, and how many of the trainee's own factors are read at most. Both are properties of the layout
// (scene_scraper.json's common or friend_common), whose choice has one owner, CharaDetailSceneScraper::
// constructSession; fromLayout is the one place a window is made from a layout, so the two consumers of a single-frame
// read (the early duplicate probe and the character-switch rule) cannot be handed windows that differ.
//
// `factor_limit` is the layout's self_factor_prefix_length. The read stops once it holds that many factors.
// The value is sized so that its rows lie inside the layout's scroll area with room left below them (the derivation
// is in native/tool/builder/chara_detail_scene_scraper_builder.h); nothing is promised about the rows further
// down, so they are not read at all rather than read and then compared. A list SHORTER than the limit
// therefore ended on this frame -- the detail screen's layout is the same on portrait and landscape panes, so the
// threshold's rows always fit -- and that is the fact the probe's `below_threshold` carries to the front end
// (messages::factorProbe).
//
// Unsigned so that no window can hold a negative limit. The conversion in fromLayout is safe because
// CharaDetailSceneScraperConfig refuses a layout whose threshold is below 1 while it is deserialized.
struct SelfFactorWindow {
    Rect<double> scroll_area;
    std::size_t factor_limit;

    [[nodiscard]] static SelfFactorWindow fromLayout(const scraper_config::SceneScraperConfig &layout) {
        return {layout.scroll_area_rect, static_cast<std::size_t>(layout.self_factor_prefix_length)};
    }
};

// Where the factor tab's green banner (the "因子" header) was found, as FactorRowReader::findBanner found it.
// Every integer is in the pixels of the frame that was searched, relative to the scroll area handed in:
// - `column` is the scanned column, counted from the scroll area's left edge;
// - `row` is the banner's top row, counted from the first scanned row (the scroll area's top edge, clamped to
//   the frame);
// - `search_rows` is how many rows the search was asked to scan (L), before any clamp to the frame;
// - `run_end_row` is the exclusive end of the non-background run that starts at `row` in the same column,
//   bounded by the scroll area's bottom edge (and the frame's).
// `top` is the same top edge as a normalized y, which is what the reading of the rows below the banner starts from.
struct BannerHit {
    double top;
    int column;
    int row;
    int search_rows;
    int run_end_row;
};

// Reads the factor tab's rows of (factor, star) off a frame, and owns the pipeline's only pair of factor models.
//
// ONE INSTANCE PER PIPELINE, SHARED BY TWO STAGES. NativeApi::startPipeline builds it once and hands the same
// shared_ptr to both of them:
// - the recognizer, which reads every factor list off the stitched image (FactorTabRecognizer::recognize) and
//   the self-factor prefix off the early duplicate probe's frame (CharaDetailRecognizer::probe);
// - the scene scraper, which reads the self-factor prefix off the reference and the judged frame when its
//   character-switch rule fires, synchronously, inside the processing of the judged frame. Reading there, and
//   not by asking the recognizer's runner, keeps an offline import a function of the clip: nothing about the
//   decision depends on when another thread gets round to answering.
// Both models are AdmittedPredictors, so the two stages may call concurrently and each call waits only for the
// calls queued before it.
//
// The production ctor builds both models through makePredictor (recognizer_prediction.h); the injection ctor
// takes them pre-built, so the scan can be unit-tested against fakes.
class FactorRowReader {
public:
    [[maybe_unused]] FactorRowReader(
        const std::filesystem::path &module_root_dir, const recognizer_config::FactorTabConfig &config);

    // Injection ctor. Wraps both predictors in their admissions, exactly as production does.
    FactorRowReader(
        const recognizer_config::FactorTabConfig &config,
        std::unique_ptr<const recognizer::Predictor<int>> factor_model,
        std::unique_ptr<const recognizer::Predictor<int>> factor_rank_model);

    // THE READING RULE every single-frame consumer takes: the trainee's own factors on a single, non-stitched
    // factor-tab frame (no scrolling), read by recognizeOne and therefore only from rows whose cells lie wholly
    // inside [window.scroll_area] on this frame, and never more than [window.factor_limit] of them. Today those
    // consumers are the early duplicate probe (recognizer stage) and the character-switch rule (scraper stage).
    // The returned list is a prefix of the self-factors the full pipeline would read. It ends at whichever comes
    // first: the end of the list, the scroll area's bottom edge (a row that is cut off, or not on screen at all,
    // is never read), or the limit (see SelfFactorWindow for why rows past it are not read). Only this read is
    // limited; the stitched record's read (FactorTabRecognizer::recognize) reads every factor.
    //
    // It is one method of this class rather than something each consumer repeats because the probe's list is
    // matched against stored records on the Dart side, and the switch rule's two lists against each other;
    // written once per consumer -- the limit applied by one and not the other, say -- the lists would agree until
    // the first time one of them was adjusted, and a comparison between them would then be between two different
    // quantities.
    //
    // [window.scroll_area] is the factor tab's scroll area ON THIS FRAME, and the caller must supply it:
    // config.area cannot be used here. That rect is a STITCHED-image rect -- the stitcher always pastes
    // content at one fixed offset, so FactorTabRecognizer::recognize is right to use it -- whereas a live
    // frame's scroll area sits wherever the record's layout puts it. The Friend full-record layout drops it by
    // the height of the "register practice partner" button, which is ~136 px at a 736 px anchor unit:
    // three times the banner gap, so a scan anchored to config.area finds nothing and the probe comes
    // back empty. Lengthening the gap is not the fix either -- the stretch in between holds the tab bar,
    // which the scan would latch onto and read as the factor header.
    // CharaDetailSceneScraper::constructSession is the single owner of the layout choice (common vs
    // friend_common), so the window is handed down from there rather than re-derived from the record type
    // against a second copy of the layout constants.
    [[nodiscard]] std::vector<record::Factor> visibleSelfPrefix(const Frame &frame, const SelfFactorWindow &window) const;

    // THE BANNER SEARCH, the one every reading of the factor tab starts from: the stitched record's read
    // (FactorTabRecognizer::recognize) and the single-frame read (visibleSelfPrefix) both call this and nothing
    // else to find the green banner. It walks one column -- this reader's left_rect's left edge -- down from
    // [scroll_area]'s top edge for vertical_banner_upper_gap, and returns the first row that leaves this reader's
    // bg_color, or nullopt when every scanned row stays in the background.
    //
    // It takes the WHOLE frame and the scroll area's rect on it, never a crop of the scroll area. The column and
    // the scan length are scaled by the frame's anchor unit, and a crop's unit is not the frame's: a crop of the
    // scroll area is one pixel narrower than the intersection (its right edge is IntersectPixelEnd), so the same
    // fractions land on a different column at some units (736 is one of them: 179 on the frame, 178 on the crop).
    // Keeping the crop out of the signature is what keeps a live frame and the stitched image, which carries the
    // live crop's pixels unscaled, on the same column and the same row (test_scene_stitcher.cpp asserts it).
    //
    // [scroll_area] is the scroll area on THIS frame: the layout's rect on a live frame, config.area on the
    // stitched image (see visibleSelfPrefix for why the two differ).
    [[nodiscard]] std::optional<BannerHit> findBanner(const Frame &frame, const Rect<double> &scroll_area) const;

    // Reads one factor list (self, parent1 or parent2) from [scan_top] down, advancing [scan_top] past it.
    //
    // [factor_limit], when set, ends the list once it holds that many factors; the cells below are not handed to
    // the models. Only the single-frame read sets it (visibleSelfPrefix). A limited read may stop inside the list,
    // so [scan_top] is then NOT past it and must not be used to read the next list; the stitched path, which does
    // read the next list, passes std::nullopt.
    //
    // THE SCROLL AREA IS REQUIRED ON EVERY PATH, and a row is read only while BOTH cells handed to the models --
    // the name cell and the star cell, derived once in cellsAt -- lie inside [scroll_area] intersected with the
    // frame. The scan stops at the first cell that does not; a row whose left cell fits and whose right cell
    // does not keeps its left factor and ends the list there.
    //
    // Why the frame alone is not the bound: a live frame's scroll area ends above the bottom UI, and the row-top
    // search only asks where the background colour gives way. Measured on player_standard at a 736 px unit, a
    // faint shadow just below the scroll area's bottom edge (y 1129) has one pixel row (y 1134) one level under
    // the background range; the search took it for the top of a ninth row, whose cells were the blank bottom UI
    // and read as a real factor id at low confidence. On friend_standard the sixth row's name cell fits but its
    // star cell crosses that same edge. Neither is a pixel the stitched record is ever given, because the
    // stitcher builds it only from this rect. The stitched path passes config.area, which spans the pasted
    // content, so one rule covers both instead of the stitched path relying on its canvas being tall enough.
    [[nodiscard]] std::vector<record::Factor> recognizeOne(
        const Frame &frame,
        const Rect<double> &scroll_area,
        double &scan_top,
        PredictionHistory &history,
        std::optional<std::size_t> factor_limit) const;

    [[nodiscard]] std::optional<double> findNext(const Frame &frame, const Point<double> &scan_top_left) const;

private:
    // The two cells a factor row hands the models: the name cell of the column and the star-rank cell inside it,
    // both absolute. Derived in ONE place so that the fit test in recognizeOne and the crops in predictFactor are
    // made from the same rects -- a fit test written against a second derivation would be testing cells the
    // models never see.
    struct FactorCells {
        Rect<double> name;
        Rect<double> star;
    };

    // [column_rect] is the column's absolute (ScreenStart) rect, [top] the row's top as found by findNext.
    [[nodiscard]] FactorCells cellsAt(const Rect<double> &column_rect, double top) const;

    [[nodiscard]] record::Factor
    predictFactor(const Frame &frame, const FactorCells &cells, PredictionHistory &history) const;

    const recognizer_config::FactorTabConfig config;

    const AdmittedPredictor<int> factor_model;
    const AdmittedPredictor<int> factor_rank_model;
};

class FactorTabRecognizer {
public:
    // `rows` is the pipeline's shared FactorRowReader (see there); a null one is refused at construction.
    [[maybe_unused]] FactorTabRecognizer(
        const std::filesystem::path &module_root_dir,
        const recognizer_config::FactorTabConfig &config,
        std::shared_ptr<const FactorRowReader> rows);

    // Injection ctor: takes pre-built predictors instead of building them through makePredictor
    // (recognizer_prediction.h), which loads the platform's models, so the scan logic can be unit-tested
    // against fakes.
    FactorTabRecognizer(
        const recognizer_config::FactorTabConfig &config,
        std::shared_ptr<const FactorRowReader> rows,
        std::unique_ptr<const recognizer::Predictor<Chara>> character_model,
        std::unique_ptr<const recognizer::Predictor<int>> character_rank_model);

    void recognize(
        const Frame &frame,
        const RecordInfo &record_info,
        record::CharaDetailRecord &record,
        CropInfo &crop_info,
        PredictionHistory &history) const;

private:
    [[nodiscard]] record::Character recognizeTrainee(
        const Frame &frame,
        const RecordInfo &record_info,
        const double scan_top,
        CropInfo &crop_info,
        PredictionHistory &history) const;

    const recognizer_config::FactorTabConfig config;

    const std::shared_ptr<const FactorRowReader> rows;
    std::unique_ptr<const recognizer::Predictor<Chara>> character_model;
    std::unique_ptr<const recognizer::Predictor<int>> character_rank_model;
};

// A FactorRowReader that must be there. Shared by the production and injection ctors of FactorTabRecognizer, so
// a null reader is refused by one rule rather than surfacing later as a dereference on a runner thread.
inline std::shared_ptr<const FactorRowReader> requireFactorRows(std::shared_ptr<const FactorRowReader> rows) {
    if (rows == nullptr) {
        throw std::invalid_argument("FactorTabRecognizer requires the pipeline's FactorRowReader");
    }
    return rows;
}

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
    // `factor_rows` is the pipeline's one FactorRowReader, which the scene scraper holds too (see there).
    CharaDetailRecognizer(
        const std::string &trainer_id,
        const std::filesystem::path &record_root_dir,
        const std::filesystem::path &module_root_dir,
        const std::shared_ptr<const recognizer_impl::FactorRowReader> &factor_rows,
        const event_util::Listener<RecordInfo> &on_recognize_ready,
        const event_util::Sender<RecordInfo> &on_recognize_completed,
        const event_util::Listener<RecordInfo> &on_update_requested,
        const event_util::Sender<RecordInfo> &on_update_completed,
        const event_util::Listener<Frame, RecordInfo, recognizer_impl::SelfFactorWindow, bool> &on_factor_probe_ready,
        const event_util::Sender<std::vector<record::Factor>, std::size_t, bool, RecordInfo> &on_factor_probe_completed,
        const event_util::Sender<std::string> &on_error,
        const recognizer_config::CharaDetailRecognizerConfig &config);

    // Recognizes only the trainee's own factors visible on a single, non-stitched factor-tab frame -- the frame
    // the factor tab latched as its fragment #0, which is at the head of the list but not necessarily settled
    // (see CharaDetailSceneScraper's head_latched listener) -- so the duplicate check can run before scrolling.
    // Reads through the same FactorRowReader, and the same single-frame rule, as the character-switch rule
    // (FactorRowReader::visibleSelfPrefix): the result is a prefix of the self-factor list, at most
    // `window.factor_limit` long, and the front end compares every factor in it with the head of each stored
    // record.
    // `raw_info` is forwarded unchanged with the result: it names the session the frame belongs to.
    // `cue_owed` is not recognized, read or judged here: it is the scraper's statement about the exit that
    // latched this frame, forwarded to the front end alongside the result because the front end sounds the
    // factor tab's chime only when the latch owed one AND the character is not a duplicate. Carrying it
    // through keeps the two halves on one message instead of making the front end correlate two.
    //
    // `window` is the one this record's layout defines, as resolved by the scraper (SelfFactorWindow::fromLayout);
    // see FactorRowReader::visibleSelfPrefix for why its scroll area cannot be read off the recognizer config.
    // Its limit is sent on with the result, not as a number for the front end to apply, but so that the message
    // can state whether the list is shorter than the limit (messages::factorProbe) from the same value the read
    // stopped at.
    void probe(
        const Frame &frame, const RecordInfo &raw_info, const recognizer_impl::SelfFactorWindow &window, bool cue_owed)
        const;

    void recognize(const RecordInfo &raw_info, bool isUpdateMode) const;

private:
    const std::string trainer_id;
    const std::filesystem::path record_root_dir;
    const std::filesystem::path module_root_dir;
    const recognizer_config::CharaDetailRecognizerConfig config;

    // Declared before factor_tab_recognizer, which is built from it.
    const std::shared_ptr<const recognizer_impl::FactorRowReader> factor_rows;

    const recognizer_impl::StatusHeaderRecognizer status_header_recognizer;
    const recognizer_impl::SkillTabRecognizer skill_tab_recognizer;
    const recognizer_impl::FactorTabRecognizer factor_tab_recognizer;
    const recognizer_impl::CampaignTabRecognizer campaign_tab_recognizer;

    const event_util::Listener<RecordInfo> on_recognize_ready;
    const event_util::Sender<RecordInfo> on_recognize_completed;

    const event_util::Listener<RecordInfo> on_update_requested;
    const event_util::Sender<RecordInfo> on_update_completed;

    const event_util::Listener<Frame, RecordInfo, recognizer_impl::SelfFactorWindow, bool> on_factor_probe_ready;
    // factors, the window's factor_limit, cue_owed, and the session the probe frame was latched in -- the order
    // NativeApi::notifyFactorProbe takes them in. The session travels back out because this result is produced on
    // this runner's thread and can reach the front end after the next session was announced; its id is what lets
    // the front end tell the two apart.
    const event_util::Sender<std::vector<record::Factor>, std::size_t, bool, RecordInfo> on_factor_probe_completed;

    // Surfaces a terminal recognition failure (currently only the update path) as a human-readable message,
    // wired to NativeApi::notifyError so a failed re-recognition reaches the UI instead of stalling forever.
    const event_util::Sender<std::string> on_error;
};

}  // namespace uma::chara_detail
