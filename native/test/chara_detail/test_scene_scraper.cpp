// Behavioral tests for BaseFrameCatcher in chara_detail_scene_scraper.cpp.
//
// BaseFrameCatcher gates the capture of the character-detail "base" image on two independent facts: the
// base region must hold still (a wrapped StationaryFrameCatcher, covered on its own in
// test_scraper_estimators.cpp) AND the green title-bar banner must have been fully visible on the header
// scan line continuously for a threshold -- the proxy for "the post-capture snackbar has cleared". The
// snackbar gate is the part unique to this class and is otherwise only exercised by the golden integration
// test (skipped in CI). These pin it directly: readiness needs both gates, the visible-since window
// restarts when the header drops, a non-monotonic (backward) frame timestamp cannot clear the snackbar
// early, and once ready a later frame is ignored so the captured image is kept.
//
// The frames are hand-built solid CV_8UC3 mats through Frame::fixed (whose anchor normalizes both axes by
// the frame width). A solid frame is simultaneously stationary against an identical predecessor and either
// fully inside or fully outside the header color range, which is exactly the two signals this class reads.

#include <doctest/doctest.h>

#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "types/color.h"
#include "types/range.h"
#include "types/shape.h"
#include "util/cv_test_helpers.h"
#include "util/event_util.h"
#include "util/json_util.h"

#ifndef TEST_ASSET_CONFIG_DIR
#error "TEST_ASSET_CONFIG_DIR must be defined by the build (see native/CMakeLists.txt)."
#endif

namespace uma::chara_detail {
namespace {

using scraper_impl::BaseFrameCatcher;
using scraper_impl::StationaryFrameCatcher;

// A green the header range accepts (the banner) and a black it rejects (header not visible).
const Color kBanner{0, 200, 0};
const Color kNoBanner{0, 0, 0};
const Range<Color> kHeaderRange{Color(0, 150, 0), Color(80, 255, 80)};

// A horizontal scan line across the frame, kept strictly inside a fixed 100px frame (see the estimator
// tests: on a fixed frame normalized y maps to pixel y*width, so 0.99 is the last in-bounds row).
const Line<double> kHeaderScanLine{Point<double>(0.1, 0.1), Point<double>(0.9, 0.1)};
const Rect<double> kWhole{};  // empty rect => the whole frame, for the stationary base region
const Rect<double> kBaseImageRect{Point<double>(0.0, 0.0), Point<double>(0.5, 0.5)};

Frame frameOf(const Color &color, uint64 timestamp) {
    return Frame::fixed(testutil::solid(100, color), timestamp);
}

// A base catcher whose two gates can be tuned independently by their time thresholds. minimum_color /
// stationary_ratio are set so two identical frames read as stationary and any color change resets it: the
// ratio budget is below one pixel's share of the 100x100 frame (1e-4), so a single changed pixel restarts
// the window. Production uses 1.4e-5 -- see chara_detail_scene_scraper_builder.h for its derivation.
BaseFrameCatcher makeCatcher(uint64 stationary_time, uint64 header_visible_time) {
    return BaseFrameCatcher{
        StationaryFrameCatcher{stationary_time, /*minimum_color=*/10, /*stationary_ratio=*/1e-9, kWhole},
        kBaseImageRect,
        kHeaderScanLine,
        kHeaderRange,
        header_visible_time,
    };
}

TEST_CASE("readiness requires both the base to be stationary and the banner to persist") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/50, /*header_visible_time=*/50);

    catcher.update(frameOf(kBanner, 0));  // first frame: baselines the stationary region, banner since=0
    CHECK_FALSE(catcher.ready());  // base needs a second frame to measure stillness

    catcher.update(frameOf(kBanner, 100));  // identical 100ms later: base stationary AND banner visible >50ms
    CHECK(catcher.ready());
}

TEST_CASE("the banner must stay visible for the threshold even once the base is stationary") {
    // stationary_time=0 makes the base ready after two identical frames immediately, isolating the snackbar
    // (banner) time gate.
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/100);

    catcher.update(frameOf(kBanner, 0));  // banner since=0
    catcher.update(frameOf(kBanner, 50));  // base stationary, but banner only visible 50ms (<=100)
    CHECK_FALSE(catcher.ready());

    catcher.update(frameOf(kBanner, 150));  // banner now visible 150ms (>100)
    CHECK(catcher.ready());
}

TEST_CASE("the banner-visible window restarts when the header drops out") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/50);

    catcher.update(frameOf(kBanner, 0));  // banner since=0
    catcher.update(frameOf(kNoBanner, 20));  // header gone: clears since (and changes the region)
    catcher.update(frameOf(kBanner, 40));  // banner reappears: since restarts @40, region re-baselined
    catcher.update(frameOf(kBanner, 70));  // banner visible only 30ms since @40 (<=50) -> not ready
    CHECK_FALSE(catcher.ready());

    catcher.update(frameOf(kBanner, 100));  // 60ms since @40 (>50) -> ready
    CHECK(catcher.ready());
}

TEST_CASE("a backward frame timestamp cannot clear the snackbar early") {
    // A large header threshold keeps the snackbar uncleared under normal timing, so the only way ready()
    // could flip is the unsigned-subtraction wrap the guard prevents.
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/1000);

    catcher.update(frameOf(kBanner, 100));  // banner since=100
    catcher.update(frameOf(kBanner, 120));  // base stationary; banner visible 20ms (<1000) -> not ready
    REQUIRE_FALSE(catcher.ready());

    // A non-monotonic step back to before `since`: without the guard, (50 - 100) would wrap to a huge
    // unsigned value and clear the snackbar instantly. The guard reports zero elapsed instead.
    catcher.update(frameOf(kBanner, 50));
    CHECK_FALSE(catcher.ready());

    catcher.update(frameOf(kBanner, 2000));  // 1900ms since @100 (>1000) -> recovers
    CHECK(catcher.ready());
}

TEST_CASE("once ready the captured base is kept and later frames are ignored") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/0);

    catcher.update(frameOf(kBanner, 0));
    catcher.update(frameOf(kBanner, 10));
    REQUIRE(catcher.ready());

    // A frame that would drop both gates (no banner, different pixels) must not un-ready the catcher:
    // update() early-returns while ready so the latched base image survives.
    catcher.update(frameOf(kNoBanner, 20));
    CHECK(catcher.ready());
}

TEST_CASE("frame() crops the latched base image to the base rect") {
    BaseFrameCatcher catcher = makeCatcher(/*stationary_time=*/0, /*header_visible_time=*/0);

    catcher.update(frameOf(kBanner, 0));
    catcher.update(frameOf(kBanner, 10));
    REQUIRE(catcher.ready());

    const Frame base = catcher.frame();  // view of a [0,0]-[0.5,0.5] rect on a 100px frame
    CHECK(base.width() == 50);
    CHECK(base.height() == 50);
}

// --- What a mid-scene reset reports ----------------------------------------------------------------------
//
// The scraper discards a session whenever it infers a character switch, and the event announcing that used to
// carry nothing -- leaving every front end unable to say that an import lost a character mid-clip. What it now
// carries is the session that was thrown away, and the hazard is entirely one of TIMING: the fields live in
// members that the discard itself clears (tab_completed) or that the session built immediately afterwards
// overwrites (the record id), so a report composed one line too late would describe the FRESH session and claim
// a discard that lost nothing -- silently, and only for real clips.
//
// So these drive the real class through the real shipped config and pin the reported identity against the
// session's own scraping directory. Only ONE of the three reset rules is reachable without game pixels: the
// record-type change, which the scene context resolves from its condition tree and hands over as SceneState, so
// a test can state it directly. It is also the one rule that runs before any scraping on the frame that trips
// it, which is what keeps these frames free of image work.

// Records the paths passed to the injected directory hooks instead of touching the filesystem (the same fake
// as test_scraping_box.cpp). The scraping directory is per-session and named after the record id, so this is
// also how a test learns the id the scraper generated for itself.
struct HookRecorder {
    std::vector<std::filesystem::path> made;
    std::vector<std::filesystem::path> removed;

    [[nodiscard]] io_util::DirectoryHooks hooks() {
        io_util::DirectoryHooks h;
        h.mkdir = [this](const std::filesystem::path &path) { made.push_back(path); };
        h.rmdir = [this](const std::filesystem::path &path) { removed.push_back(path); };
        return h;
    }
};

// <scraping root>/<record id>/<tab>: the session a created directory belongs to.
std::string sessionIdOf(const std::filesystem::path &made) {
    return made.parent_path().filename().string();
}

// The real shipped scraper config, so the geometry these frames are cropped against is production's rather
// than a hand-built one that could be wrong in the same direction as the code.
scraper_config::CharaDetailSceneScraperConfig shippedScraperConfig() {
    const auto path = std::filesystem::path(TEST_ASSET_CONFIG_DIR) / "chara_detail" / "scene_scraper.json";
    return json_util::read(path).get<scraper_config::CharaDetailSceneScraperConfig>();
}

// A solid 540x960 frame -- a real portrait capture size, so its aspect-ratio intersection is the whole frame
// and every normalized config rect lands inside it. Content is irrelevant here: the two frames below differ so
// that nothing ever latches as stationary, which is what keeps a scraped image from being written to disk.
Frame solidFrameAt(uint64 timestamp, const Color &color) {
    const cv::Mat pixels(960, 540, CV_8UC3, cv::Scalar(color.b(), color.g(), color.r()));
    return Frame(pixels, timestamp);
}

// Every connection CharaDetailSceneScraper's constructor takes, plus the discard stream these tests read.
struct ScraperHarness {
    HookRecorder recorder;

    event_util::Connection<SceneInfo> opened = event_util::makeDirectConnection<SceneInfo>();
    event_util::Connection<Frame, SceneState> updated = event_util::makeDirectConnection<Frame, SceneState>();
    event_util::Connection<> closed = event_util::makeDirectConnection<>();
    event_util::Connection<RecordInfo> closed_before_completed = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<int> scroll_ready = event_util::makeDirectConnection<int>();
    event_util::Connection<int, double> scroll_updated = event_util::makeDirectConnection<int, double>();
    event_util::Connection<int, bool> scroll_position = event_util::makeDirectConnection<int, bool>();
    event_util::Connection<int> page_ready = event_util::makeDirectConnection<int>();
    event_util::Connection<RecordInfo> completed = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<Frame, RecordInfo> factor_probe = event_util::makeDirectConnection<Frame, RecordInfo>();
    event_util::Connection<DiscardedSession> restarted = event_util::makeDirectConnection<DiscardedSession>();

    std::vector<DiscardedSession> discards;
    CharaDetailSceneScraper scraper;

    ScraperHarness()
        : scraper(
              opened,
              updated,
              closed,
              closed_before_completed,
              scroll_ready,
              scroll_updated,
              scroll_position,
              page_ready,
              completed,
              factor_probe,
              restarted,
              shippedScraperConfig(),
              "unit_test_scraping_root",
              recorder.hooks()) {
        restarted->listen([this](const DiscardedSession &discarded) { discards.push_back(discarded); });
    }

    [[nodiscard]] std::string sessionIdAt(std::size_t made_index) const {
        return sessionIdOf(recorder.made.at(made_index));
    }
};

// Comfortably past the scraper's 250 ms switch dwell, which is private; any gap above it does.
constexpr uint64 kPastDwell = 1000;

TEST_CASE("a mid-scene reset reports the session it discarded, not the one it built") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);
    REQUIRE_FALSE(h.recorder.made.empty());
    const std::string discarded_id = h.sessionIdAt(0);
    const std::size_t made_before_reset = h.recorder.made.size();

    // A record type that persists past the dwell is a character switch: the layout changed, so the session
    // cannot continue. The first frame only opens the dwell window.
    h.scraper.update(solidFrameAt(0, kNoBanner), SceneState{FactorPage, record::FriendStandard});
    CHECK(h.discards.empty());
    h.scraper.update(solidFrameAt(kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard});

    REQUIRE(h.discards.size() == 1);
    // THE ORDERING ASSERTION. The reset rebuilt a session on the spot, with a fresh id and a fresh record type;
    // a report composed after that rebuild would name it and would be indistinguishable from a correct one
    // except on real footage.
    REQUIRE(h.recorder.made.size() > made_before_reset);
    const std::string rebuilt_id = h.sessionIdAt(made_before_reset);
    CHECK(rebuilt_id != discarded_id);
    CHECK(h.discards[0].info.record_id == discarded_id);
    CHECK(h.discards[0].info.record_id != rebuilt_id);
    CHECK(h.discards[0].info.record_type == record::Standard);
}

TEST_CASE("a session discarded before it completed says so") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    h.scraper.update(solidFrameAt(0, kNoBanner), SceneState{FactorPage, record::FriendStandard});
    h.scraper.update(solidFrameAt(kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard});

    REQUIRE(h.discards.size() == 1);
    // `completed` is what stops an ordinary two-character clip from reporting a loss, so the false case has to
    // be the one that is actually produced here rather than merely the field's default.
    CHECK(h.discards[0].completed == false);

    // THE `true` DIRECTION IS NOT REACHABLE FROM THIS TARGET, and that is a property of the bit rather than
    // an omission here. `completed` is `ready()`, which is `scraping_state == Ready`, which only
    // checkForCompleted sets and only when the whole SceneScrapingBox is ready -- i.e. all three tabs
    // captured plus the base image, which needs game pixels running through the real scrapers. So no
    // unit-level frame sequence can produce a discard that lost nothing, and nothing below this layer can
    // either: test_native_api_messages.cpp is handed the bit rather than producing it.
    // Where the `true` direction IS asserted is the integration manifest: `expect_discarded_incomplete`
    // (native/test/integration/cases.json) states zero on every ordinary clip, so a build that stopped
    // setting the bit turns those cases red -- which is the same regression this case guards from the other
    // side. If that key ever goes, this direction loses its only cover.
}

TEST_CASE("release reports the session it destroys, and announces nothing by itself") {
    ScraperHarness h;
    h.scraper.buildSession(record::InheritanceOnly);
    REQUIRE_FALSE(h.recorder.made.empty());
    const std::string built_id = h.sessionIdAt(0);

    const DiscardedSession discarded = h.scraper.release();

    CHECK(discarded.info.record_id == built_id);
    CHECK(discarded.info.record_type == record::InheritanceOnly);
    CHECK(discarded.completed == false);
    // A release is not by itself a discard event. The scene-closed path releases too, and its loss already
    // travels as closed_before_completed -- announcing it here as well would report one lost session twice.
    CHECK(h.discards.empty());
}

}  // namespace
}  // namespace uma::chara_detail
