// THE INVARIANT THE FINE SENSOR RESTS ON: inside the factor-header probe band, the green "因子" header row is
// the ONLY row of the scroll-area crop whose green fraction clears green_fraction_threshold.
//
// factorHeaderTopY returns the FIRST row that clears it and stops there, so if any other row could clear it,
// the sensor would silently return that row instead. Nothing downstream could notice: the reference row is
// taken from one frame and compared against later ones in pixels, so a wrong-but-consistent row still reads
// "flush", and a wrong-and-inconsistent one reads "scrolled" on a frame that never moved. Both are silent
// misreads of a sensor two switch rules and the character-switch arrows now depend on.
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
#include <optional>
#include <string>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "types/color.h"
#include "cv/video_loader.h"
#include "types/shape.h"
#include "util/event_util.h"
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

// Green fraction of every row of the scroll-area crop, measured exactly as factorHeaderTopY measures it (same
// crop, same band, same row line), so this cannot drift from the sensor it is a statement about.
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

// The clips are gitignored test material (testdata/clips/golden/), so a machine without them skips -- the
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

// Where the green header sits INSIDE the scroll-area crop, on the frames the coarse sensor calls a genuine
// head of the factor list. One number per clip, plus the evidence that it is one number.
struct HeaderRowStats {
    // One entry per frame the coarse sensor called a genuine head of content.
    std::vector<int> rows;
    int unit = 0;
    // The scroll-area crop's UNROUNDED top edge in frame pixels, i.e. what Frame::view rounds before it crops.
    // Kept unrounded so the report can state how far the crop's own rounding moved this layout's rows: two
    // layouts at different anchor units round independently, which is the one row of slack the case allows.
    double exact_crop_top = 0.0;
};

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

// First row of the crop whose green fraction clears the threshold -- i.e. exactly what factorHeaderTopY
// returns, computed from the same rowFractions this file already uses for the invariant above.
std::optional<int> firstClearedRow(const std::vector<double> &fractions, double threshold) {
    for (int y = 0; y < static_cast<int>(fractions.size()); y++) {
        if (fractions[static_cast<std::size_t>(y)] > threshold) {
            return y;
        }
    }
    return std::nullopt;
}

HeaderRowStats measureHeaderRow(
    const std::filesystem::path &clip,
    const scraper_config::SceneScraperConfig &layout,
    const scraper_config::FactorHeaderConfig &header) {
    testutil::requireFfmpegDecodes(clip);
    // The production estimator, built from this layout's own shipped values -- so "at the head of the list"
    // here is the same reading the scraper acts on, not a restatement of it.
    const scraper_impl::ScrollBarOffsetEstimator estimator(
        layout.scroll_bar_bg_color,
        layout.scroll_bar_scan_line,
        layout.scroll_bar_margin_color,
        layout.scroll_bar_track_color,
        layout.viewport,
        layout.cap_offset,
        layout.scroll_bar_thumb_probe);

    HeaderRowStats stats;
    const auto frames = event_util::makeDirectConnection<Frame, Size<int>>();
    frames->listen([&](const Frame &frame, const Size<int> &) {
        // The gate below is what picks the head of content out of the frames that show a header at all.
        const auto row = firstClearedRow(
            rowFractions(frame, layout.scroll_area_rect, header), header.green_fraction_threshold);
        if (!row) {
            return;
        }
        const int unit = frame.anchor().intersection().width();
        const double exact_top = frame.anchor().absolute(layout.scroll_area_rect.topLeft()).y() * unit;
        stats.unit = unit;
        stats.exact_crop_top = exact_top;
        const auto top_margin = estimator.topMargin(frame.copy(layout.scroll_bar_rect));
        if (!top_margin || top_margin.value() != 0.0) {
            return;
        }
        stats.rows.push_back(row.value());
    });
    const video::VideoLoader loader(frames);
    static_cast<void>(loader.run(clip));
    return stats;
}

}  // namespace

TEST_CASE("the green header sits at the same crop row on both layouts, at the head of the list") {
    // WHAT THIS IS FOR: `viewport` is the only shipped number nothing asserts. The golden records cannot --
    // it reaches them solely as a far-outlier veto on the image offset estimate, so a 1.3 % move leaves every
    // record byte-identical (measured: friend_common.viewport 0.553 -> 0.560 keeps all four friend golden and
    // dual-decode cases green). Since the scroll-area rect's top edge is now derived from it, that silence
    // now covers a 5 px error in WHERE THE CROP STARTS as well, which is the frame of reference every header
    // row the factor tab reads is measured in.
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
        const HeaderRowStats stats = measureHeaderRow(kClipDir / c.clip, *c.layout, config.factor_header);
        const std::string clip_name{c.clip};
        CAPTURE(clip_name);
        const std::pair<int, int> modal = modalRow(stats.rows);
        MESSAGE(
            clip_name << ": at_top_frames=" << stats.rows.size() << " unit=" << stats.unit
                      << " modal_row=" << modal.first << " agreeing=" << modal.second << " crop_rounding_px="
                      << static_cast<double>(std::lround(stats.exact_crop_top)) - stats.exact_crop_top);

        REQUIRE(!stats.rows.empty());
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
        CHECK(modal.second * 2 > static_cast<int>(stats.rows.size()));
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

TEST_CASE("the factor-header probe band is stated here, because no other test can notice it moving") {
    // WHY THE EDGES ARE ASSERTED AS DATA, given that the case above already measures the band's behaviour.
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

}  // namespace uma::chara_detail
