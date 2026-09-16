// Characterization tests for the chara-detail config deserialization.
//
// The config structs in chara_detail_config.h are wired to JSON via the EXTENDED_JSON_TYPE_NDC macro and are
// only exercised indirectly through the recognizer/scraper pipeline. These lock the serialization contract of
// the actually-shipped config against the committed assets: parsing the real JSON and re-serializing it must
// be stable (get -> to_json -> get -> to_json produces identical JSON), the same round-trip invariant the CLI
// `build` subcommand asserts at runtime.
//
// This reads the repo-committed config JSON under assets/config/chara_detail via TEST_ASSET_CONFIG_DIR, which
// CMake injects. That is a deliberate, narrow exception to the "no game assets" rule in test/README.md: those
// files are small, versioned config (not screenshots or ONNX models) and are themselves the contract here.
//
// The last case is not about serialization. The shipped JSON is a BUILD OUTPUT of
// native/tool/builder/chara_detail_scene_scraper_builder.h, and nothing else in the suite looks at the value
// of a shipped rect: the scraper tests read whatever the file says and assert relationships against it, so a
// builder edit that regenerates the file wrongly -- or a builder edit that is never regenerated at all -- is
// invisible to them. That case states the one geometric relation between the two layouts' scroll areas that
// the game screen forces, so it is the file, not a copy of it, that has to satisfy it.

#include <doctest/doctest.h>

#include <cmath>
#include <filesystem>
#include <stdexcept>
#include <string>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "condition/serializer.h"
#include "util/json_util.h"

#ifndef TEST_ASSET_CONFIG_DIR
#error "TEST_ASSET_CONFIG_DIR must be defined by the build (see native/CMakeLists.txt)."
#endif

namespace uma::chara_detail {
namespace {

using json_util::Json;

std::filesystem::path configPath(const std::string &relative) {
    return std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / relative;
}

// Parses the committed config JSON into Config, re-serializes, and re-parses. A stable serializer produces
// identical JSON on both serialization passes.
template<typename Config>
void checkConfigRoundTrip(const std::string &relative) {
    const Json on_disk = json_util::read(configPath(relative));
    const Json first = Json(on_disk.get<Config>());
    const Json second = Json(first.get<Config>());
    CHECK(first == second);
}

TEST_CASE("scene_scraper config round-trips") {
    checkConfigRoundTrip<scraper_config::CharaDetailSceneScraperConfig>("scene_scraper.json");
}

TEST_CASE("scene_stitcher config round-trips") {
    checkConfigRoundTrip<stitcher_config::CharaDetailSceneStitcherConfig>("scene_stitcher.json");
}

TEST_CASE("recognizer config round-trips") {
    checkConfigRoundTrip<recognizer_config::CharaDetailRecognizerConfig>("recognizer.json");
}

TEST_CASE("scene_context condition tree round-trips") {
    // The committed scene_context.json root is itself the tagged condition tree the scene context is built
    // from, so conditionFromJson consumes it directly (as startPipeline does).
    const Json on_disk = json_util::read(configPath("scene_context.json"));
    const Json first = condition::serializer::conditionFromJson(on_disk)->toJson();
    const Json second = condition::serializer::conditionFromJson(first)->toJson();
    CHECK(first == second);
}

// A layout's factor limit below 1 is refused while the config is deserialized. The limit ends every
// single-frame read of the factor tab, so 0 would read nothing on any frame -- the character-switch rule would
// go blind without a word -- and a negative value has no meaning (recognizer_impl::SelfFactorWindow holds it
// unsigned, so it would silently become a limit no list reaches).
TEST_CASE("a layout factor limit below 1 is rejected while the scraper config is deserialized") {
    const Json shipped = json_util::read(configPath("scene_scraper.json"));
    CHECK_NOTHROW(shipped.get<scraper_config::CharaDetailSceneScraperConfig>());

    for (const std::string layout : {"common", "friend_common"}) {
        for (const int value : {0, -1}) {
            CAPTURE(layout);
            CAPTURE(value);
            Json edited = shipped;
            edited[layout]["self_factor_prefix_length"] = value;
            CHECK_THROWS_AS(edited.get<scraper_config::CharaDetailSceneScraperConfig>(), std::invalid_argument);
        }
        // The boundary: 1 is a limit.
        Json one = shipped;
        one[layout]["self_factor_prefix_length"] = 1;
        CHECK_NOTHROW(one.get<scraper_config::CharaDetailSceneScraperConfig>());
    }
}

TEST_CASE("missing required keys are rejected") {
    const Json incomplete = {{"stretch_range", nullptr}};
    CHECK_THROWS(incomplete.get<stitcher_config::CharaDetailSceneStitcherConfig>());
}

// An empty scan sequence is the one malformed shape that used to pass deserialization: a missing key, a wrong
// type or broken JSON is already refused above, but `"skill_scans": []` parsed cleanly and only surfaced much
// later, inside the scraper runner thread, where nothing reports it to the user.
//
// This asserts the refusal AT THE DESERIALIZATION BOUNDARY, which is what makes it reportable: `.get<>()` is
// what startPipeline calls (core/native_api.cpp), so a throw here is caught by startEventLoopReportingError
// and handed to notifyError -- Dart's onError on Windows and web, a non-zero exit on the CLI. PageScrapingBox's
// own constructor rejects the same thing, but it runs too late and on the wrong thread to be seen; asserting
// that one instead would assert a throw nobody catches usefully.
TEST_CASE("an empty scan sequence is rejected while the scraper config is deserialized") {
    const Json shipped = json_util::read(configPath("scene_scraper.json"));

    // Positive control. Without it, a green below could equally mean this file stopped parsing at all, and the
    // premise: emptying a key is only a change if the key is a non-empty array to begin with.
    CHECK_NOTHROW(shipped.get<scraper_config::CharaDetailSceneScraperConfig>());

    for (const std::string key : {"skill_scans", "factor_scans", "campaign_scans"}) {
        CAPTURE(key);
        CHECK(shipped.at(key).is_array());
        CHECK_FALSE(shipped.at(key).empty());

        Json emptied = shipped;
        emptied[key] = Json::array();
        CHECK_THROWS_AS(emptied.get<scraper_config::CharaDetailSceneScraperConfig>(), std::invalid_argument);
    }
}

// The width the scraper's normalized geometry was calibrated at, used only to report a mismatch in the unit
// the calibration notes are written in. Every quantity compared below is width-normalized, so this scales the
// verdict; it does not decide it.
constexpr double kCalibrationWidthPx = 736.0;

TEST_CASE("the two shipped layouts' scroll areas differ only by their viewports") {
    // WHAT FORCES THIS. On the Friend full-record layout a green "register practice partner" button is
    // inserted above the tab bar, pushing the tab bar and the scroll area down the screen. The scroll area's
    // BOTTOM is not pushed anywhere: it stays anchored to the bottom of the screen, which is why both layouts
    // declare the same bottom_right. A shorter box with an unmoved bottom is a box whose top moved down by
    // exactly the height it lost -- and the height it lost is the difference of the two visible content
    // heights, which is what `viewport` carries. The surrounding white inset is the same widget on both
    // layouts and cancels out of the difference, so this holds even though `viewport` is deliberately NOT the
    // crop height (see chara_detail_config.h).
    //
    // The tab bar's own drop is a SEPARATE measurement and is deliberately not reused here; the last section
    // pins that the two really are different numbers.
    const auto config =
        json_util::read(configPath("scene_scraper.json")).get<scraper_config::CharaDetailSceneScraperConfig>();
    const auto &common = config.common;
    const auto &friend_common = config.friend_common;

    SUBCASE("both scroll areas end at the same bottom edge") {
        // The premise of the relation below. If this ever stops holding, the top is no longer derivable from
        // the viewports and the next subcase is asserting something meaningless rather than something false.
        CHECK(common.scroll_area_rect.bottomRight() == friend_common.scroll_area_rect.bottomRight());
        // Tops are compared as plain numbers below, which is only meaningful while both are anchored the same
        // way.
        CHECK(common.scroll_area_rect.topLeft().anchor() == friend_common.scroll_area_rect.topLeft().anchor());
    }

    SUBCASE("the friend scroll area's top is its viewport difference below common's") {
        const double drop = friend_common.scroll_area_rect.topLeft().y() - common.scroll_area_rect.topLeft().y();
        const double lost_viewport = common.viewport - friend_common.viewport;
        const double mismatch_px = (drop - lost_viewport) * kCalibrationWidthPx;
        // A tenth of a capture pixel at the calibration width: far below anything the crop rounding could
        // express, and far above double-rounding noise.
        CHECK(std::abs(mismatch_px) < 0.1);
    }

    SUBCASE("the scroll-bar band is the same region as the scroll area on both layouts") {
        // Not decoration: the band and the area are declared as one region per layout, and the scraper tests
        // paint a single rectangle to serve both sensors on that basis. Moving one layout's area without its
        // band would leave the band's position derived from nothing that was ever measured.
        CHECK(common.scroll_bar_rect == common.scroll_area_rect);
        CHECK(friend_common.scroll_bar_rect == friend_common.scroll_area_rect);
    }

    SUBCASE("the tab bar and the scroll area do not drop by the same amount") {
        // The Friend layout is not a rigid translation of the Standard one: the tab bar's drop is pinned from
        // the tab bar's own measured row, the scroll area's comes from the viewports, and the two land 3.4 px
        // apart at the calibration width. What is asserted is only that they are DIFFERENT NUMBERS, not how
        // far apart -- the distance is whatever two independent measurements happen to give, and pinning it
        // would turn an honest re-fit of the viewport into a failure here. Zero is the one value that cannot
        // be a measurement: it means a builder went back to driving both rects off one shared shift, which is
        // how the scroll area came to sit above the content it crops.
        const double tab_bar_drop =
            friend_common.tab_button_rect.topLeft().y() - common.tab_button_rect.topLeft().y();
        const double scroll_area_drop =
            friend_common.scroll_area_rect.topLeft().y() - common.scroll_area_rect.topLeft().y();
        const double disagreement_px = std::abs(scroll_area_drop - tab_bar_drop) * kCalibrationWidthPx;
        // A hundredth of a capture pixel: eleven orders of magnitude above double-rounding noise on these
        // values, and far below any difference two real measurements could report.
        CHECK(disagreement_px > 0.01);
    }
}

}  // namespace
}  // namespace uma::chara_detail
