// THE INVARIANT THE FINE SENSOR RESTS ON: inside the factor-header probe band, the green "因子" header row is
// the ONLY row of the scroll-area crop whose green fraction clears green_fraction_threshold.
//
// factorHeaderTopY returns the FIRST row that clears it and stops there, so if any other row could clear it,
// the sensor would silently return that row instead. The factor tab's head judgment asks whether that row lies
// inside the run the recognizer's banner search found (condition c2), so a wrong row reads "scrolled" on a frame
// that never moved -- a silent misread of the judgment fragment #0, Rule 3 and the UI's position word rest on.
//
// It is an invariant about CONTENT, not about code: the rows that compete with the header are the green
// factor pills, which are game data. A future game update that adds a wider green element to a factor row can
// break it without a line of this repository changing, which is precisely why it is measured against real
// footage on every run rather than argued about once.
//
// IT ALSO REACHES THE BAND, which nothing else did. `band_start` / `band_end` do not move the row
// factorHeaderTopY returns on good footage, so no golden record changes when they do, and the ruled band
// [0.12, 0.93] had no test at all. Measured here, the runner-up [0.12, 0.88] turns this case red on
// player_standard_factor_tiny_scroll_switch (a non-header row at 0.5027, 27 frames with a second answering
// run). That is a consequence and not the whole guard, because the width also buys occlusion tolerance that
// no corpus statistic can see; the edges themselves are stated in the second case below.

#include <doctest/doctest.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "types/color.h"
#include "cv/video_loader.h"
#include "types/shape.h"
#include "util/event_util.h"
#include "util/fake_predictor.h"
#include "util/json_util.h"
#include "util/video_backend_guard.h"

#ifndef TEST_ASSET_CONFIG_DIR
#error "TEST_ASSET_CONFIG_DIR must be defined by the build (see native/CMakeLists.txt)."
#endif
#ifndef TEST_GOLDEN_CLIP_DIR
#error "TEST_GOLDEN_CLIP_DIR must be defined by the build (see native/CMakeLists.txt)."
#endif

namespace uma::chara_detail {
namespace {

// What one clip's frames say about the band, accumulated across every frame of it.
struct BandStats {
    int frames = 0;
    // Frames on which at least one row cleared the threshold.
    int frames_with_header = 0;
    // Tallest contiguous run of cleared rows seen on any frame. The header is ~25 px tall at native capture
    // width, so a run far above that would mean the band is answering to something other than the header.
    int tallest_run = 0;
    // Frames whose cleared rows formed more than one run. THE LOAD-BEARING COUNT: a second run is another row
    // answering, and factorHeaderTopY would return whichever came first.
    int frames_with_two_runs = 0;
    // Highest green fraction reached by any row OUTSIDE the first run, and lowest reached by a row inside it.
    // Together these are the margin the threshold sits in.
    double non_header_max = 0.0;
    double header_min = 1.0;
    // The same as non_header_max, but ignoring the rows that ABUT the run. The header's own top and bottom
    // edges are anti-aliased, so the row just outside it is partly header and scores high through no fault of
    // the content -- reported separately so "the nearest competitor is the header's own edge" and "a factor
    // pill is closing in on the threshold" are not the same number.
    double far_max = 0.0;
};

// Rows this far from the header run are content rather than the header's own anti-aliased edge. Two rows is
// already generous for a bilinear edge; it is a reporting boundary, not a calibrated constant.
constexpr int kEdgeRows = 2;

// The real shipped scraper config: the band under test is the one that ships, not a restatement of it.
scraper_config::CharaDetailSceneScraperConfig shippedScraperConfig() {
    const auto path = std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / "scene_scraper.json";
    return json_util::read(path).get<scraper_config::CharaDetailSceneScraperConfig>();
}

// Green fraction of every row of the scroll-area crop, measured the way scraper_impl::firstHeaderGreenRow
// measures it (same crop, same band, same row line). This is a COPY of that row loop, not a call into it, so it
// can drift: a change to how firstHeaderGreenRow measures a row has to be repeated here.
std::vector<double> rowFractions(
    const Frame &frame, const Rect<double> &scroll_area_rect, const scraper_config::FactorHeaderConfig &header) {
    const Frame area = frame.view(scroll_area_rect);
    const int height = area.height();
    std::vector<double> fractions;
    fractions.reserve(static_cast<std::size_t>(height));
    for (int y = 0; y < height; y++) {
        const double normalized_y = area.anchor().scaleFromPixels(y);
        const Line<double> row = {{header.band_start, normalized_y}, {header.band_end, normalized_y}};
        fractions.push_back(area.fractionIn(header.color_range, row));
    }
    return fractions;
}

void accumulate(BandStats &stats, const std::vector<double> &fractions, double threshold) {
    stats.frames++;
    int first_run_begin = -1;
    int first_run_end = -1;  // exclusive
    int runs = 0;
    bool in_run = false;
    for (int y = 0; y < static_cast<int>(fractions.size()); y++) {
        const bool cleared = fractions[static_cast<std::size_t>(y)] > threshold;
        if (cleared && !in_run) {
            runs++;
            if (runs == 1) {
                first_run_begin = y;
            }
        }
        if (!cleared && in_run && runs == 1) {
            first_run_end = y;
        }
        in_run = cleared;
    }
    if (in_run && runs == 1) {
        first_run_end = static_cast<int>(fractions.size());
    }
    if (runs == 0) {
        return;
    }
    stats.frames_with_header++;
    stats.tallest_run = std::max(stats.tallest_run, first_run_end - first_run_begin);
    if (runs > 1) {
        stats.frames_with_two_runs++;
    }
    for (int y = 0; y < static_cast<int>(fractions.size()); y++) {
        const double value = fractions[static_cast<std::size_t>(y)];
        if (y >= first_run_begin && y < first_run_end) {
            stats.header_min = std::min(stats.header_min, value);
            continue;
        }
        stats.non_header_max = std::max(stats.non_header_max, value);
        if (y < first_run_begin - kEdgeRows || y >= first_run_end + kEdgeRows) {
            stats.far_max = std::max(stats.far_max, value);
        }
    }
}

// Decodes the whole clip through the SHARED offline producer (VideoLoader, the one the CLI's `video`
// subcommand and the Windows video import both drive), so the frames measured here are anchored exactly as
// the ones the scraper sees.
BandStats measureClip(
    const std::filesystem::path &clip,
    const Rect<double> &scroll_area_rect,
    const scraper_config::FactorHeaderConfig &header) {
    testutil::requireFfmpegDecodes(clip);
    BandStats stats;
    const auto frames = event_util::makeDirectConnection<Frame, Size<int>>();
    frames->listen([&](const Frame &frame, const Size<int> &) {
        accumulate(stats, rowFractions(frame, scroll_area_rect, header), header.green_fraction_threshold);
    });
    const video::VideoLoader loader(frames);
    static_cast<void>(loader.run(clip));  // the media timestamp of the last frame; not what this measures
    return stats;
}

const std::filesystem::path kClipDir = std::filesystem::path(TEST_GOLDEN_CLIP_DIR);

// The clips are gitignored test material in the golden clip directory, so a machine without them skips -- the
// same conditional shape every golden case here has.
bool clipAvailable(const std::string &name) {
    return std::filesystem::exists(kClipDir / name);
}

}  // namespace

TEST_CASE("no row but the green factor header clears the header threshold, on real footage") {
    const auto config = shippedScraperConfig();

    // Two layouts and two adversaries. player_standard_factor_tiny_scroll_switch is the Player layout with the
    // header at several distances from the top of the crop; friend_standard_many_rental is the Friend layout
    // carrying the longest rental-factor list in the corpus, i.e. the most green pills competing with the
    // header, and it reads the Friend geometry (friend_common) rather than the Player one.
    struct Case {
        const char *clip;
        const Rect<double> *scroll_area_rect;
    };
    const Case cases[] = {
        {"player_standard_factor_tiny_scroll_switch.mp4", &config.common.scroll_area_rect},
        {"friend_standard_many_rental.mp4", &config.friend_common.scroll_area_rect},
    };

    int measured = 0;
    for (const auto &c : cases) {
        if (!clipAvailable(c.clip)) {
            MESSAGE("skipped (clip not on this machine): " << c.clip);
            continue;
        }
        measured++;
        const BandStats stats = measureClip(kClipDir / c.clip, *c.scroll_area_rect, config.factor_header);
        // As std::string: doctest stringifies a bare const char* member as a pointer, which turns the one
        // piece of context a failure needs -- WHICH clip -- into "1".
        const std::string clip_name{c.clip};
        CAPTURE(clip_name);
        MESSAGE(
            clip_name << ": frames=" << stats.frames << " with_header=" << stats.frames_with_header
                      << " tallest_run=" << stats.tallest_run << " two_runs=" << stats.frames_with_two_runs
                      << " non_header_max=" << stats.non_header_max << " far_max=" << stats.far_max
                      << " header_min=" << stats.header_min);

        REQUIRE(stats.frames > 0);
        REQUIRE(stats.frames_with_header > 0);
        // THE INVARIANT. Not "the header is found" -- that a golden would notice -- but that nothing ELSE is.
        CHECK(stats.frames_with_two_runs == 0);
        CHECK(stats.non_header_max < config.factor_header.green_fraction_threshold);
        CHECK(stats.far_max < config.factor_header.green_fraction_threshold);
        CHECK(stats.header_min > config.factor_header.green_fraction_threshold);
        // The run is the header and not a green REGION: the header is ~25 px tall at the capture widths in
        // this corpus, and both clips measure 24. A band that started answering to something taller -- a
        // solid green panel, a transition wipe -- would still satisfy every line above while returning a row
        // that is not the header at all.
        CHECK(stats.tallest_run <= 30);
    }
    if (measured == 0) {
        // Same conditional shape as every golden case: the clips are gitignored test material, and a machine
        // without them cannot state this. It is reported, not passed off as a pass.
        MESSAGE("no clip of this invariant is present on this machine; nothing was measured");
    }
}

namespace {

// The recognizer's shipped config: the banner search the head judgment reads is the recognizer's own, so its
// window, column and background come from recognizer.json and not from a restatement.
recognizer_config::CharaDetailRecognizerConfig shippedRecognizerConfig() {
    const auto path = std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / "recognizer.json";
    return json_util::read(path).get<recognizer_config::CharaDetailRecognizerConfig>();
}

// The production FactorRowReader on the shipped factor-tab config. findBanner reads no model, so the predictors
// are constants.
recognizer_impl::FactorRowReader shippedFactorReader() {
    return recognizer_impl::FactorRowReader(
        shippedRecognizerConfig().factor_tab,
        testutil::constantPredictor<int>("factor", 0),
        testutil::constantPredictor<int>("factor_rank", 0));
}

// What the three conditions of the factor tab's head judgment read on one decoded frame, every one of them
// through the production reading: the recognizer's banner search, the green sensor's scan (unbounded here, so
// the row is known even when it lies past the banner's run), and the production thumb estimator judged by the
// shipped policy.
struct FactorFrameReading {
    int index = 0;  // decode order, from 0
    std::optional<recognizer_impl::BannerHit> banner;
    std::optional<int> green_row;
    scraper_impl::TopOfContent coarse = scraper_impl::TopOfContent::Unknown;

    [[nodiscard]] scraper_impl::TopOfContent verdict(double reserve) const {
        return scraper_impl::factorHeadVerdict(coarse, banner, green_row, reserve);
    }
    // The green header's two conditions alone: the judgment as it would be behind a thumb at the head, which is
    // the only place the header is asked. Tells which sensor decided.
    [[nodiscard]] bool bannerHolds(double reserve) const {
        return scraper_impl::factorHeadVerdict(scraper_impl::TopOfContent::AtTop, banner, green_row, reserve)
               == scraper_impl::TopOfContent::AtTop;
    }
};

struct ClipReadings {
    int unit = 0;
    std::vector<FactorFrameReading> frames;
};

ClipReadings readClip(
    const std::filesystem::path &clip,
    const scraper_config::SceneScraperConfig &layout,
    const scraper_config::FactorHeaderConfig &header,
    const recognizer_impl::FactorRowReader &reader) {
    testutil::requireFfmpegDecodes(clip);
    // The production estimator, built from this layout's own shipped values -- so "the thumb is at the head"
    // here is the same reading the scraper acts on, not a restatement of it.
    const scraper_impl::ScrollBarOffsetEstimator estimator(
        layout.scroll_bar_bg_color,
        layout.scroll_bar_scan_line,
        layout.scroll_bar_margin_color,
        layout.scroll_bar_track_color,
        layout.viewport,
        layout.cap_offset,
        layout.scroll_bar_thumb_probe);

    ClipReadings readings;
    int index = 0;
    const auto frames = event_util::makeDirectConnection<Frame, Size<int>>();
    frames->listen([&](const Frame &frame, const Size<int> &) {
        FactorFrameReading reading;
        reading.index = index++;
        reading.banner = reader.findBanner(frame, layout.scroll_area_rect);
        reading.green_row =
            scraper_impl::firstHeaderGreenRow(frame.view(layout.scroll_area_rect), header, std::nullopt);
        reading.coarse =
            CharaDetailSceneScraper::thumbTopOfContent(estimator.topMargin(frame.copy(layout.scroll_bar_rect)));
        readings.unit = frame.anchor().intersection().width();
        readings.frames.push_back(reading);
    });
    const video::VideoLoader loader(frames);
    static_cast<void>(loader.run(clip));
    return readings;
}

// The row the header sat on most often, and how many frames agreed. Returned together on purpose: a mode
// nothing agrees on is not a measurement, and the caller asserts the agreement rather than assuming it.
std::pair<int, int> modalRow(std::vector<int> rows) {
    std::sort(rows.begin(), rows.end());
    int best = -1;
    int best_count = 0;
    for (std::size_t i = 0; i < rows.size();) {
        std::size_t j = i;
        while (j < rows.size() && rows[j] == rows[i]) {
            j++;
        }
        if (static_cast<int>(j - i) > best_count) {
            best_count = static_cast<int>(j - i);
            best = rows[i];
        }
        i = j;
    }
    return {best, best_count};
}

// The green rows of the frames the thumb calls a genuine head of the list.
std::vector<int> greenRowsAtThumbHead(const ClipReadings &readings) {
    std::vector<int> rows;
    for (const auto &frame : readings.frames) {
        if (frame.green_row.has_value() && frame.coarse == scraper_impl::TopOfContent::AtTop) {
            rows.push_back(frame.green_row.value());
        }
    }
    return rows;
}

}  // namespace

TEST_CASE("the green header sits at the same crop row on both layouts, at the head of the list") {
    // WHAT THIS IS FOR: `viewport` is the only shipped number nothing asserts. The golden records cannot --
    // it reaches them solely as a far-outlier veto on the image offset estimate, so a 1.3 % move leaves every
    // record byte-identical (measured: friend_common.viewport 0.553 -> 0.560 keeps all four friend golden and
    // dual-decode cases green). Since the scroll-area rect's top edge is now derived from it, that silence
    // now covers a 5 px error in WHERE THE CROP STARTS as well, which is the quantity the head-of-content
    // judgment counts its rows from.
    //
    // So this states the thing the two layouts are supposed to have in common. The green "因子" header is
    // drawn at a fixed distance below the top of the scroll area by the game, on both layouts; if both crops
    // start at their own layout's true top, the header lands on the SAME row of the crop. That is a claim
    // about the crop, and the crop's top is `common.scroll_area_rect.top` on one side and
    // `common.top + (common.viewport - friend_common.viewport)` on the other -- so moving either viewport
    // without the other moves one row and not the other.
    //
    // Measured against the real clips rather than restated: nothing here copies a config value.
    const auto config = shippedScraperConfig();
    const auto reader = shippedFactorReader();

    struct Case {
        const char *clip;
        const scraper_config::SceneScraperConfig *layout;
    };
    const Case cases[] = {
        {"player_standard_factor_tiny_scroll_switch.mp4", &config.common},
        {"friend_standard_many_rental.mp4", &config.friend_common},
    };

    std::vector<int> rows;
    for (const auto &c : cases) {
        if (!clipAvailable(c.clip)) {
            MESSAGE("skipped (clip not on this machine): " << c.clip);
            continue;
        }
        const ClipReadings readings = readClip(kClipDir / c.clip, *c.layout, config.factor_header, reader);
        const std::vector<int> at_top = greenRowsAtThumbHead(readings);
        const std::string clip_name{c.clip};
        CAPTURE(clip_name);
        const std::pair<int, int> modal = modalRow(at_top);
        MESSAGE(
            clip_name << ": at_top_frames=" << at_top.size() << " unit=" << readings.unit
                      << " modal_row=" << modal.first << " agreeing=" << modal.second);

        REQUIRE(!at_top.empty());
        // The mode has to BE the reading, not merely the most popular of several. The gate above is the
        // coarse scroll-bar sensor, which answers on the OTHER TWO TABS' at-top frames as well; those carry
        // no green 因子 header, so whatever green they do carry is found wherever it happens to sit (measured
        // on player_standard_factor_tiny_scroll_switch: rows as deep as 452). A strict majority is what says
        // the agreeing frames are the factor tab's and the rest are that leakage.
        //
        // HOW MUCH ROOM THAT LEAVES, measured rather than assumed: on this clip the modal row holds 216 of 324
        // at-top frames (66.7 %), so the leakage could grow by another 108 frames -- half again as much as
        // there is now -- before a simple majority fails. friend_standard_many_rental is 74 of 75 and has
        // essentially none. The threshold is deliberately still a bare majority: what it is for is to stop a
        // mode that nothing agrees on from being read as a measurement, not to bound the leakage, which is a
        // property of how much of each clip is spent on the other two tabs.
        CHECK(modal.second * 2 > static_cast<int>(at_top.size()));
        rows.push_back(modal.first);
    }

    if (rows.size() < 2) {
        // Both clips are gitignored test material, so a machine with only one of them cannot make the
        // comparison. Reported rather than passed off as a pass -- as everywhere else in this file.
        MESSAGE("both layouts' clips are needed to compare them; nothing was compared");
        return;
    }

    // One row of slack, because the crop origin is rounded independently per layout and two layouts at
    // different anchor units can legitimately land a row apart. It is not slack for a wrong viewport: the
    // smallest viewport digit that ships is worth 0.74 px, and the mutation above (0.553 -> 0.560) moves the
    // friend crop by five rows.
    CHECK(std::abs(rows[0] - rows[1]) <= 1);
}

TEST_CASE("the head judgment accepts the real head of the list, with room on both sides of its banner row") {
    // WHAT NOTHING ELSE PINS ON REAL FOOTAGE. The judgment's own cases (test_scraper_estimators.cpp) state its
    // shape on readings handed in, and the geometry table below paints rows; the golden suite compares records
    // and cannot see a verdict at all. This asks the production readings -- the recognizer's banner search, the
    // green scan, the thumb estimator -- on decoded frames: is every frame the thumb and the green header agree
    // is the head of the list accepted, and does its banner row sit inside the window with room on BOTH sides
    // (so a device that draws the banner a little higher or lower is still accepted)?
    const auto config = shippedScraperConfig();
    const auto reader = shippedFactorReader();
    const double reserve = config.factor_header.banner_window_reserve;

    struct Case {
        const char *clip;
        const scraper_config::SceneScraperConfig *layout;
    };
    const Case cases[] = {
        {"player_standard_factor_tiny_scroll_switch.mp4", &config.common},
        {"friend_standard_many_rental.mp4", &config.friend_common},
        // A THIRD ANCHOR UNIT (737, not 736), so "one reserve at more than one capture width" is a claim this
        // case makes rather than one it assumes.
        {"player_standard_5.mkv", &config.common},
    };

    int measured = 0;
    for (const auto &c : cases) {
        if (!clipAvailable(c.clip)) {
            MESSAGE("skipped (clip not on this machine): " << c.clip);
            continue;
        }
        measured++;
        const ClipReadings readings = readClip(kClipDir / c.clip, *c.layout, config.factor_header, reader);
        const std::string clip_name{c.clip};
        CAPTURE(clip_name);
        const std::vector<int> at_top = greenRowsAtThumbHead(readings);
        REQUIRE(!at_top.empty());
        const std::pair<int, int> modal = modalRow(at_top);
        // Same gate as the case above, and for the same reason: the thumb answers on the other two tabs'
        // at-top frames too, and those carry no green 因子 header.
        REQUIRE(modal.second * 2 > static_cast<int>(at_top.size()));

        int head_frames = 0;
        int accepted = 0;
        std::vector<int> banner_rows;
        int search_rows = 0;
        for (const auto &frame : readings.frames) {
            if (frame.coarse != scraper_impl::TopOfContent::AtTop || frame.green_row != modal.first) {
                continue;
            }
            head_frames++;
            accepted += frame.verdict(reserve) == scraper_impl::TopOfContent::AtTop ? 1 : 0;
            if (frame.banner.has_value()) {
                banner_rows.push_back(frame.banner->row);
                search_rows = frame.banner->search_rows;
            }
        }
        const std::pair<int, int> banner_modal = modalRow(banner_rows);
        const int last = scraper_impl::factorHeadLastRow(search_rows, reserve);
        const auto [lowest, highest] = std::minmax_element(banner_rows.begin(), banner_rows.end());
        MESSAGE(
            clip_name << ": unit=" << readings.unit << " green_row=" << modal.first << " head_frames=" << head_frames
                      << " accepted=" << accepted << " banner_row=" << banner_modal.first << " ("
                      << banner_modal.second << "/" << banner_rows.size() << ", range " << *lowest << ".."
                      << *highest << ") window=1.." << last << " search_rows=" << search_rows);

        // 1. Every head frame is accepted -- counted with its denominator, so "no head frame" cannot pass.
        REQUIRE(head_frames > 0);
        CHECK(accepted == head_frames);
        // 2. Every head frame has a banner, and every banner row it shows has room on both sides of it inside the
        //    window. The row itself is not one row: the banner's top edge is faded, and a frame whose fade
        //    reaches the background threshold differently reads a row higher or lower than its neighbours
        //    (measured: 1 of 216 frames on player_standard_factor_tiny_scroll_switch, 8 of 74 on
        //    friend_standard_many_rental), while the green row does not move.
        REQUIRE(static_cast<int>(banner_rows.size()) == head_frames);
        CHECK(banner_modal.second * 2 > head_frames);
        CHECK(*lowest > 1);
        CHECK(*highest < last);

        // 3. The frames the banner search alone would place at the head -- a first non-background row inside the
        //    window, on a thumb at the head (the only thumb reading the header is asked behind) -- but whose run
        //    does not reach the green row are refused.
        //    These are frames whose first non-background row in that column is not the green header: factor
        //    frames scrolled past it (a factor row or the trainee icon comes first) and the other two tabs'
        //    frames, which the clip also shows. c2 is what refuses them. Counted and reported, so a clip where
        //    the population is empty says so.
        int banner_only = 0;
        int banner_only_refused = 0;
        for (const auto &frame : readings.frames) {
            const bool in_window =
                frame.banner.has_value() && scraper_impl::factorBannerInWindow(frame.banner.value(), reserve);
            const bool reaches = frame.banner.has_value()
                                 && scraper_impl::factorBannerReachesGreen(frame.banner.value(), frame.green_row);
            if (!in_window || reaches || frame.coarse != scraper_impl::TopOfContent::AtTop) {
                continue;
            }
            banner_only++;
            banner_only_refused += frame.verdict(reserve) == scraper_impl::TopOfContent::Scrolled ? 1 : 0;
        }
        MESSAGE(
            clip_name << ": frames the banner row alone places at the head without its run reaching green = "
                      << banner_only << ", refused = " << banner_only_refused);
        CHECK(banner_only_refused == banner_only);
    }
    if (measured == 0) {
        MESSAGE("no clip of this judgment is present on this machine; nothing was measured");
    }
}

TEST_CASE("the inheritance-history bar at the end of a long list is refused by the thumb, not by the banner") {
    // THE ONE THING THE BANNER CANNOT TELL APART. Scrolled to its end, the Friend max-rental factor list brings
    // the green "継承履歴" bar to the top of the scroll area, inside the banner window and in the same green:
    // on those frames c1 and c2 both hold. What refuses them is the thumb, which decides before the header is
    // asked and reads a list scrolled by its whole length (the dependency and its limit are written at
    // scraper_impl::factorHeadReading). This asserts that on the production estimator, on the frames where it
    // matters: decode
    // order 354..399 of friend_standard_many_rental in VideoLoader's order (46 frames; the design survey found the
    // same 46 with a stand-in thumb reading, numbered 360..405 by its own decoder).
    const auto config = shippedScraperConfig();
    const auto reader = shippedFactorReader();
    const double reserve = config.factor_header.banner_window_reserve;
    constexpr const char *kClip = "friend_standard_many_rental.mp4";
    constexpr int kFirst = 354;
    constexpr int kLast = 399;
    if (!clipAvailable(kClip)) {
        MESSAGE("skipped (clip not on this machine): " << kClip);
        return;
    }
    const ClipReadings readings = readClip(kClipDir / kClip, config.friend_common, config.factor_header, reader);
    REQUIRE(static_cast<int>(readings.frames.size()) > kLast);

    const std::string clip_name{kClip};
    int bar_frames = 0;
    int refused_by_thumb = 0;
    int lowest_row = std::numeric_limits<int>::max();
    int highest_row = std::numeric_limits<int>::min();
    for (const auto &frame : readings.frames) {
        if (frame.index < kFirst || frame.index > kLast) {
            continue;
        }
        CAPTURE(frame.index);
        bar_frames++;
        // The banner conditions hold -- otherwise this case would not be about the thumb at all.
        CHECK(frame.bannerHolds(reserve));
        CHECK(frame.coarse == scraper_impl::TopOfContent::Scrolled);
        if (frame.banner.has_value()) {
            lowest_row = std::min(lowest_row, frame.banner->row);
            highest_row = std::max(highest_row, frame.banner->row);
        }
        refused_by_thumb += frame.verdict(reserve) == scraper_impl::TopOfContent::Scrolled ? 1 : 0;
    }
    // No OTHER frame of this clip is one the banner conditions accept while the thumb refuses: the bar frames
    // are the whole of what the thumb's Scrolled refuses here that the header would accept, so a shift of the
    // range above is caught rather than absorbed.
    int other = 0;
    for (const auto &frame : readings.frames) {
        if ((frame.index < kFirst || frame.index > kLast) && frame.bannerHolds(reserve)
            && frame.coarse == scraper_impl::TopOfContent::Scrolled) {
            other++;
        }
    }
    MESSAGE(
        clip_name << ": bar frames=" << bar_frames << " refused=" << refused_by_thumb << " banner rows "
                  << lowest_row << ".." << highest_row
                  << "; other frames the banner accepts and the thumb refuses=" << other);
    CHECK(bar_frames == kLast - kFirst + 1);
    CHECK(refused_by_thumb == bar_frames);
    CHECK(other == 0);
}

TEST_CASE("the factor-header probe band is stated here, because no other test can notice it moving") {
    // WHY THE EDGES ARE ASSERTED AS DATA, given that the first case already measures the band's behaviour.
    // Because what the extra width BUYS is not separation, it is OCCLUSION BUDGET: a tap effect or a
    // transition wider than the band hides the probe entirely, and no clip corpus is obliged to contain one.
    // A change that trades budget away can therefore leave the measured case green, and the records notice
    // nothing either -- the band does not move the row factorHeaderTopY returns on unoccluded footage, so
    // every golden stays byte-identical across all three candidate bands. Whatever the case above happens to
    // catch, nothing states the DECISION but this.
    //
    // [0.12, 0.93], from the band-width x occlusion sweep. [0.05, 0.99] takes only 0.806 occupancy even with
    // zero occlusion and loses tolerance with it. [0.12, 0.88] was ruled out for a thin margin, cited as a
    // worst non-header row of 0.4347 -- which is this file's friend_standard_many_rental figure, reproduced
    // exactly. The other clip is worse than the ruling recorded: measured here, [0.12, 0.88] puts
    // player_standard_factor_tiny_scroll_switch's worst non-header row at 0.5027, i.e. OVER the threshold, on
    // 27 frames with a second answering run. So that band does not merely have a thin margin, it breaks the
    // invariant above, and the case above does go red on it. The margin figure a ruling quotes is per clip;
    // this one was not the binding one.
    //
    // The threshold is the third leg: the sweep confirmed 0.5 lies between "highest non-header row" and
    // "lowest header row" for every candidate band, so it did not have to move when the band did.
    const auto header = shippedScraperConfig().factor_header;
    CHECK(header.band_start == doctest::Approx(0.12));
    CHECK(header.band_end == doctest::Approx(0.93));
    CHECK(header.green_fraction_threshold == doctest::Approx(0.5));
}

namespace {

// One capture geometry the corpus was measured at, reproduced without the clip.
struct MeasuredGeometry {
    const char *measured_on;  // the clip this row was read off, for provenance
    int frame_width;
    int frame_height;
    int unit;  // the intersection WIDTH, which is what every normalized coordinate is scaled by
    int intersection_top;  // where that intersection starts down the frame
    double exact_crop_top;  // what the anchor must then put the scroll area's unrounded top at
    int head_row;  // the crop row the green header was MEASURED on, at the head of the list
    bool friend_layout;
};

// Measured on 2026-09-14 through umacapture_cli's `video` path -- i.e. downstream of the shared frame-resize
// band and the pane latch, which is the only place these units exist. `head_row` is the GREEN SENSOR's row on
// that footage; the banner search's row there is the same or one above it (the banner's top edge is faded).
//
// THE INTERSECTION IS CARRIED EXPLICITLY, not left to the aspect-ratio guess the public Frame constructors
// make. Half of these geometries do not come from the frame's shape at all: the resize band and the detail-crop
// tracker both hand the scraper a frame whose intersection was decided elsewhere, and a synthetic frame of the
// same dimensions would silently get a different one. Frame::reanchored is the same seam the detail-crop
// calibration uses, so these frames are anchored the way the measured ones were. That is also what lets units
// 735 and 651 appear here at all -- both are re-anchored, and neither is reproducible from a size.
//
// `intersection_top` is not a second measurement: it is exact_crop_top minus the layout's own normalized top
// times the unit, and it came out an exact integer on all ten, which is itself a check on the model. It is
// written down rather than recomputed so that the exact_crop_top assertion below still has something to say.
constexpr MeasuredGeometry kMeasuredGeometries[] = {
    {"grid/hq_540p.mp4", 540, 1260, 540, 150, 587.0220, 9, false},
    // A 1080 px phone recording that the resize band takes to 720. No clip in the doctest suite decodes to
    // this unit -- the band only runs inside the core -- so this row is the only place unit 720 is reached.
    {"grid/screen-20260802-214946.mp4", 720, 1680, 720, 201, 783.6960, 11, false},
    {"source/2026-08-04-2pane.mkv", 2059, 1158, 651, 0, 526.8543, 11, false},
    {"grid/hq_674p.mp4", 674, 1572, 674, 187, 732.4682, 12, false},
    {"golden/friend_inheritance_scroll_past_factor_header.mkv", 713, 1267, 713, 0, 577.0309, 12, false},
    {"source/manual_check_20260804.mkv", 718, 1276, 718, 0, 581.0774, 12, false},
    {"golden/friend_inheritance.mp4", 736, 1308, 735, 1, 595.8355, 12, false},
    {"golden/player_standard.mp4", 736, 1308, 736, 0, 595.6448, 12, false},
    {"golden/friend_standard_many_rental.mp4", 736, 1308, 736, 0, 731.8048, 12, true},
    {"golden/player_standard_5.mkv", 737, 1310, 737, 0, 596.4541, 13, false},
    {"grid/hq_810p.mp4", 810, 1890, 810, 225, 880.5330, 13, false},
};

// A white frame of the given size, anchored the way the measured frame was, with the green "因子" header
// painted across the probe band at `crop_row` of the scroll-area crop and nothing else anywhere. White is
// inside the recognizer's factor background and the band contains the banner search's column, so the banner
// search finds the painted row too (no fade row: the painted edge is hard).
Frame syntheticHeaderFrame(
    const MeasuredGeometry &geometry,
    const scraper_config::SceneScraperConfig &layout,
    const scraper_config::FactorHeaderConfig &header,
    int crop_row) {
    cv::Mat pixels(geometry.frame_height, geometry.frame_width, CV_8UC3, cv::Scalar(255, 255, 255));
    // Left-aligned on purpose: every quantity this case measures is vertical, and pinning a horizontal offset
    // would be inventing a number no measurement here constrains. Width is the unit and so always fits.
    const int height = geometry.frame_height - 2 * geometry.intersection_top;
    const Rect<int> intersection{
        Point<int>{0, geometry.intersection_top},
        Point<int>{geometry.unit, geometry.intersection_top + height}};
    const Frame frame = Frame(pixels, 0).reanchored(intersection);
    const Rect<int> crop = frame.anchor().mapToFrame(layout.scroll_area_rect);
    // Solidly inside the configured range ({70,150,0}..{190,255,85}), so the row's green fraction over the
    // band is 1.0 and the threshold is not what is under test here.
    const Color green{130, 200, 40};
    const int left = crop.left() + static_cast<int>(std::lround(header.band_start * crop.width()));
    const int right = crop.left() + static_cast<int>(std::lround(header.band_end * crop.width()));
    constexpr int kHeaderRows = 24;  // the header's measured height at these capture widths
    pixels(cv::Rect(left, crop.top() + crop_row, right - left, kHeaderRows))
        .setTo(cv::Scalar(green.b(), green.g(), green.r()));
    return frame;
}

}  // namespace

TEST_CASE("the head judgment's window holds at every measured capture geometry, without a clip") {
    // WHAT THIS ADDS THAT THE FOOTAGE CASES ABOVE CANNOT. Those need gitignored clips, so on a machine without
    // them -- every CI runner -- they report and pass without measuring anything. This one carries the
    // measured geometries as data and runs everywhere. It also reaches a unit the footage cases structurally
    // cannot: the doctest suite decodes through VideoLoader, which applies neither the frame-resize band nor
    // the pane latch, so a 1080 px clip arrives as unit 1080 here and as unit 720 in production.
    //
    // At each geometry, with the production readings on a painted frame: the measured head row is accepted; so
    // are row 1 and the window's last row (the two ends); the row past the last is refused although the
    // recognizer still finds the banner there (so the reserve is what refuses it); and the search window is the
    // recognizer's own, lround(vertical_banner_upper_gap * unit).
    const auto config = shippedScraperConfig();
    const auto recognizer = shippedRecognizerConfig();
    const auto reader = shippedFactorReader();
    const double reserve = config.factor_header.banner_window_reserve;

    for (const auto &geometry : kMeasuredGeometries) {
        const std::string measured_on{geometry.measured_on};
        CAPTURE(measured_on);
        const auto &layout = geometry.friend_layout ? config.friend_common : config.common;
        const auto readAt = [&](int crop_row) {
            const Frame frame = syntheticHeaderFrame(geometry, layout, config.factor_header, crop_row);
            FactorFrameReading reading;
            reading.banner = reader.findBanner(frame, layout.scroll_area_rect);
            reading.green_row = scraper_impl::firstHeaderGreenRow(
                frame.view(layout.scroll_area_rect), config.factor_header, std::nullopt);
            // No scroll bar is painted, so the thumb is handed in at the head: the header is asked only behind
            // one, and what this case measures is the header's window.
            reading.coarse = scraper_impl::TopOfContent::AtTop;
            return std::make_pair(frame, reading);
        };

        // THE TABLE IS CHECKED AGAINST THE ANCHOR BEFORE IT IS USED. A synthetic frame only reproduces the
        // clip's geometry if the anchor agrees about both numbers; if it does not, the rest of this iteration
        // would be measuring some other screen and quietly passing.
        const auto [head_frame, head] = readAt(geometry.head_row);
        const int unit = head_frame.anchor().intersection().width();
        REQUIRE(unit == geometry.unit);
        const double exact_top = head_frame.anchor().absolute(layout.scroll_area_rect.topLeft()).y() * unit;
        // A thousandth of a capture pixel: the table records four decimals, so exact equality would be
        // asserting the transcription rather than the geometry.
        REQUIRE(std::abs(exact_top - geometry.exact_crop_top) < 0.001);

        // The production readings find the painted row, and the window is the recognizer's.
        REQUIRE(head.banner.has_value());
        REQUIRE(head.green_row.has_value());
        CHECK(head.banner->row == geometry.head_row);
        CHECK(head.green_row.value() == geometry.head_row);
        const int search_rows = head.banner->search_rows;
        CHECK(search_rows
              == static_cast<int>(std::lround(recognizer.factor_tab.vertical_banner_upper_gap * unit)));
        const int last = scraper_impl::factorHeadLastRow(search_rows, reserve);
        MESSAGE(
            measured_on << ": unit=" << unit << " head_row=" << geometry.head_row << " window=1.." << last
                        << " search_rows=" << search_rows << " room_below=" << last - geometry.head_row);

        CHECK(head.verdict(reserve) == scraper_impl::TopOfContent::AtTop);
        for (const int row : {1, last}) {
            CAPTURE(row);
            const auto reading = readAt(row).second;
            REQUIRE(reading.banner.has_value());
            CHECK(reading.banner->row == row);
            CHECK(reading.verdict(reserve) == scraper_impl::TopOfContent::AtTop);
        }
        const auto past = readAt(last + 1).second;
        REQUIRE(past.banner.has_value());
        CHECK(past.banner->row == last + 1);
        CHECK(past.verdict(reserve) == scraper_impl::TopOfContent::Scrolled);
    }
}

}  // namespace uma::chara_detail
