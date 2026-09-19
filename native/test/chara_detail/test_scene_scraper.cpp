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
#include <tuple>
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
    event_util::Connection<int, std::string> scroll_position = event_util::makeDirectConnection<int, std::string>();
    event_util::Connection<int, bool, std::string> tab_refused =
        event_util::makeDirectConnection<int, bool, std::string>();
    event_util::Connection<bool> factor_switch_armed = event_util::makeDirectConnection<bool>();
    event_util::Connection<int> page_ready = event_util::makeDirectConnection<int>();
    event_util::Connection<RecordInfo> completed = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<Frame, RecordInfo> factor_probe = event_util::makeDirectConnection<Frame, RecordInfo>();
    event_util::Connection<DiscardedSession> restarted = event_util::makeDirectConnection<DiscardedSession>();

    std::vector<DiscardedSession> discards;
    // Every on_tab_refused message, in order, as {index, refused, reason}.
    std::vector<std::tuple<int, bool, std::string>> refusals;
    // Every on_scroll_position message, in order, as {index, word}. A SEQUENCE, and of the WORD the core put
    // on the wire rather than of a bool derived from it: this channel is the one place the composite verdict
    // leaves the core, it is edge-triggered, and its whole contract is that the third state survives the trip
    // (see CharaDetailSceneScraper::on_scroll_position). "The core said unknown", "the core said at_top" and
    // "the core has said nothing about this tab" are three different claims, and a front end that resolves
    // fail-closed acts differently on each.
    std::vector<std::pair<int, std::string>> positions;
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
              tab_refused,
              factor_switch_armed,
              page_ready,
              completed,
              factor_probe,
              restarted,
              shippedScraperConfig(),
              "unit_test_scraping_root",
              recorder.hooks()) {
        restarted->listen([this](const DiscardedSession &discarded) { discards.push_back(discarded); });
        tab_refused->listen([this](int index, bool refused, const std::string &reason) {
            refusals.emplace_back(index, refused, reason);
        });
        scroll_position->listen([this](int index, const std::string &word) { positions.emplace_back(index, word); });
    }

    // Every word stated for `tab`, in order. Not the last one: what the wire promises is that a tab which
    // becomes unreadable SAYS SO, and a final-state check cannot tell "said unknown" from "never spoke".
    [[nodiscard]] std::vector<std::string> positionWords(TabPage tab) const {
        std::vector<std::string> words;
        for (const auto &[index, word] : positions) {
            if (index == static_cast<int>(tab)) {
                words.push_back(word);
            }
        }
        return words;
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

// --- A tab refused because its capture did not start at the head of the list -----------------------------
//
// These drive the whole scraper -- not the interpreter -- because the two facts they pin live at this level
// only: that the refusal reaches the wire as a withdrawable per-tab level, and that leaving a refused tab
// rebuilds it. The second is the trap in "a tab switch retries the tab": a refused tab has NOT started
// scrolling, so the switch handler's original `started()` test would skip it, and the tab would stay refused
// forever with nothing on screen ever saying why.

// The scroll-bar colours, and the two anti-aliased cap rows that decide an at-top reading. Values measured on
// real 736 px footage; see the table on kTrackCap in test_scraper_estimators.cpp for which shipped colour box
// each one lands in, which is the whole mechanism. The boxes themselves come from the shipped config.
const Color kBarMargin{245, 245, 245};
const Color kBarTrack{210, 210, 210};
const Color kBarTrackCap{231, 231, 231};
const Color kBarThumbCap{199, 199, 199};
const Color kBarThumb{60, 60, 60};

void fill(cv::Mat mat, const Color &color) {
    mat.setTo(cv::Scalar(color.b(), color.g(), color.r()));
}

// A 540x960 frame carrying a RENDERED SCROLL BAR inside the shipped scroll-bar rect, so the estimator has
// something real to measure. `exposed_rows` is how many rows of placeholder track are visible above the
// thumb's own cap: 0 is a genuine head-of-list (the thumb's cap occludes the track's cap, as on real
// footage) and 1 is the smallest head start the widget can show -- one tip pixel, the thing this detector
// exists to catch. The scroll-area rect and the scroll-bar rect are the same region in the shipped config, so
// painting once serves both, and two frames built with the same arguments are pixel-identical and therefore
// latch as stationary.
//
// `nonce` must differ between consecutive frames. It repaints everything ABOVE the band, which is where the
// tab-button rect lives, so that catcher never latches and no scraped image is ever written to disk (the same
// device solidFrameAt uses, and the reason these tests need no filesystem). It cannot disturb the scroll area,
// which is the band itself. The header banner is absent on every frame, so the base-frame catcher likewise
// never latches.
Frame scrollBarFrameAt(uint64 timestamp, int exposed_rows, int nonce) {
    cv::Mat pixels(960, 540, CV_8UC3, cv::Scalar(kNoBanner.b(), kNoBanner.g(), kNoBanner.r()));
    // Ask the frame itself where the config rect lands, rather than restating pixel coordinates that would
    // silently stop matching the shipped config.
    const Rect<int> band_rect =
        Frame(pixels, timestamp).anchor().mapToFrame(shippedScraperConfig().common.scroll_bar_rect);
    fill(pixels(cv::Rect(0, 0, pixels.cols, band_rect.top())),
         Color(static_cast<int>(nonce % 2) * 120 + 10, 0, 0));
    cv::Mat band = pixels(cv::Rect(band_rect.left(), band_rect.top(), band_rect.width(), band_rect.height()));

    constexpr int kTrackInset = 30;  // comfortably inside the scan line's own small vertical inset
    constexpr int kThumbRows = 100;
    fill(band, kBarMargin);
    fill(band(cv::Rect(0, kTrackInset, band.cols, band.rows - 2 * kTrackInset)), kBarTrack);
    fill(band.row(kTrackInset), kBarTrackCap);
    const int thumb_cap = kTrackInset + exposed_rows;
    fill(band.row(thumb_cap), kBarThumbCap);
    fill(band(cv::Rect(0, thumb_cap + 1, band.cols, kThumbRows)), kBarThumb);
    return Frame(pixels, timestamp);
}

// The same frame with NO SCROLL BAR AT ALL: the band is uniformly the near-white page margin, so the
// background run down the scan line never reaches a thumb and hasScrollbar answers false. That is the real
// shape of an inheritance-only record's skill tab, and it is what makes SceneScraper::build install the
// non-scrollable interpreter -- the one that is handed no scroll-ready sender.
Frame noScrollBarFrameAt(uint64 timestamp, int nonce) {
    cv::Mat pixels(960, 540, CV_8UC3, cv::Scalar(kNoBanner.b(), kNoBanner.g(), kNoBanner.r()));
    const Rect<int> band_rect =
        Frame(pixels, timestamp).anchor().mapToFrame(shippedScraperConfig().common.scroll_bar_rect);
    fill(pixels(cv::Rect(0, 0, pixels.cols, band_rect.top())),
         Color(static_cast<int>(nonce % 2) * 120 + 10, 0, 0));
    fill(pixels(cv::Rect(band_rect.left(), band_rect.top(), band_rect.width(), band_rect.height())), kBarMargin);
    return Frame(pixels, timestamp);
}

// Past the shipped stationary_time_threshold, so two frames this far apart latch. Read from the config rather
// than restated, for the same reason the rect above is.
const uint64 kPastStationary = shippedScraperConfig().common.stationary_time_threshold + 100;

TEST_CASE("a tab whose capture would not start at the head of the list is refused, on the wire") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    // A settled screen that is ALREADY scrolled by one tip pixel. Nothing moves, so the pre-existing
    // premature-scroll branch cannot see it: the catcher latches, and without this mechanism the cue would
    // sound over a capture whose head is missing.
    h.scraper.update(scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    CHECK(h.refusals.empty());
    h.scraper.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{FactorPage, record::Standard});

    REQUIRE(h.refusals.size() == 1);
    CHECK(std::get<0>(h.refusals.front()) == static_cast<int>(FactorPage));
    CHECK(std::get<1>(h.refusals.front()) == true);
    CHECK(std::get<2>(h.refusals.front()) == "scrolled");
    // The session is NOT failed: the other tabs are still capturable and this one is retryable.
    CHECK(h.discards.empty());
}

TEST_CASE("a tab at the head of the list is not refused") {
    // The negative control. Without it, "refused" would be indistinguishable from "this synthetic bar refuses
    // everything", which is exactly how a threshold that is too tight would look.
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    h.scraper.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.scraper.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{FactorPage, record::Standard});

    CHECK(h.refusals.empty());
}

TEST_CASE("switching away from a refused tab rebuilds it and withdraws the refusal") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    h.scraper.update(scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.scraper.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    REQUIRE(h.refusals.size() == 1);

    // Leaving the refused tab must discard it. A refused tab has never set is_scrolling, so the switch
    // handler's `started()` test alone would leave it in place: the user would come back to the same refused
    // scraper, the tab would never complete, and the notice would never be withdrawn.
    h.scraper.update(
        scrollBarFrameAt(2 * kPastStationary, /*exposed_rows=*/1, /*nonce=*/2),
        SceneState{CampaignPage, record::Standard});

    REQUIRE(h.refusals.size() == 2);
    CHECK(std::get<0>(h.refusals.back()) == static_cast<int>(FactorPage));
    CHECK(std::get<1>(h.refusals.back()) == false);
    // The withdrawal travels on the same message, so a front end holding one value per tab needs no second
    // type; an empty reason is what "not refused" carries.
    CHECK(std::get<2>(h.refusals.back()).empty());
}

TEST_CASE("a tab no sensor can read says so on the wire, rather than being resolved here") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    // The factor tab of a record whose list does not scroll: the coarse sensor has no thumb to measure and
    // the fine one has no reference row (the header reference is taken at the factor probe, which only a
    // latch arms -- and a non-scrollable page never latches one). Both silent, on every frame.
    h.scraper.update(noScrollBarFrameAt(0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.scraper.update(noScrollBarFrameAt(kPastStationary, /*nonce=*/0), SceneState{FactorPage, record::Standard});

    // The word, not a bool. "unknown" is the whole point: resolved to either answer here, this reads as one
    // of the other two and the consumer that needed the distinction never sees it.
    CHECK(h.positionWords(FactorPage) == std::vector<std::string>{"unknown"});
}

TEST_CASE("a tab a sensor CAN read says which way it measured") {
    // The positive control for the case above: without it, "unknown" would be indistinguishable from a wire
    // that says "unknown" no matter what the sensors found. Both measured words are reachable from the same
    // frames the refusal cases use, so the two claims are pinned against the same synthetic bar.
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    // Frame 1 builds the tab, so its scroll-bar estimator does not exist yet while the verdict for that frame
    // is taken -- the tab is genuinely unreadable for exactly one frame, and the wire says so.
    h.scraper.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.scraper.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    CHECK(h.positionWords(FactorPage) == std::vector<std::string>{"unknown", "at_top"});

    ScraperHarness scrolled;
    scrolled.scraper.buildSession(record::Standard);
    scrolled.scraper.update(
        scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    scrolled.scraper.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    CHECK(scrolled.positionWords(FactorPage) == std::vector<std::string>{"unknown", "scrolled"});
}

}  // namespace
}  // namespace uma::chara_detail
