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

#include <algorithm>
#include <array>
#include <cstddef>
#include <filesystem>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include "chara_detail/chara_detail_scene_scraper.h"
#include "cv/frame.h"
#include "types/color.h"
#include "types/range.h"
#include "types/shape.h"
#include "util/cv_test_helpers.h"
#include "util/error_util.h"
#include "util/event_util.h"
#include "util/fake_predictor.h"
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
// session's own scraping directory. They use the record-type change, the one reset rule that reads no image: the
// scene context resolves it from its condition tree and hands it over as SceneState, so a test can state it
// directly. It is also the one rule that runs before any scraping on the frame that trips it, which is what keeps
// these frames free of image work. (The two rules that do read the image are driven by synthetic frames further
// down.)

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

// The scan config of the harness's FactorRowReader. NOT production geometry, on purpose: its background range is
// one colour none of this file's frames contain, so the banner search and every row search stop at their first
// sample and the scan reads rows on any frame. What the cases here pin is WHETHER and WHEN the switch rule reads,
// not what the rows say; the scan itself is test_factor_recognizer.cpp's subject. The rank cell sits inside the
// factor cell, so no crop the scan makes can leave a frame the factor cell fits in.
recognizer_config::FactorTabConfig readerScanConfig() {
    const auto rect = [](double left, double top, double right, double bottom) {
        return Rect<double>{Point<double>{left, top}, Point<double>{right, bottom}};
    };
    const recognizer_config::BasicModuleConfig unused_module{"unused", rect(0.0, 0.0, 0.05, 0.05)};
    return {
        "factor",  // module_path
        Range<Color>{Color(1, 2, 3), Color(1, 2, 3)},  // bg_color
        rect(0.0, 0.0, 1.0, 1.0),  // area
        rect(0.10, 0.0, 0.40, 0.08),  // left_rect
        rect(0.50, 0.0, 0.80, 0.08),  // right_rect
        0.06,  // vertical_delta
        0.30,  // vertical_banner_upper_gap
        0.02,  // vertical_banner_bottom_delta
        0.10,  // vertical_factor_gap
        0.03,  // vertical_chara_gap
        {"factor_rank", rect(0.0, 0.0, 0.05, 0.05)},  // factor_rank
        {unused_module, unused_module},  // trainee_icon
    };
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
    event_util::Connection<scraper_impl::FactorSwitchVerdict> factor_switch_judged =
        event_util::makeDirectConnection<scraper_impl::FactorSwitchVerdict>();
    event_util::Connection<DiscardedSession> restarted = event_util::makeDirectConnection<DiscardedSession>();

    std::vector<DiscardedSession> discards;
    // Every verdict the character-switch rule stated, in order, each with how many sessions had been discarded when
    // it was stated. The stream NativeApi counts for the CLI's run summary; the second field is what lets a case
    // state that a resetting verdict is announced BEFORE the discard it causes.
    std::vector<std::pair<scraper_impl::FactorSwitchVerdict, std::size_t>> verdicts;
    // Every on_tab_refused message, in order, as {index, refused, reason}.
    std::vector<std::tuple<int, bool, std::string>> refusals;
    // Every on_page_ready index, in order, and how many times on_completed fired. What lets a case state that a
    // tab -- or the whole session -- really was captured before it asserts what a switch rule did with it.
    std::vector<int> pages_ready;
    std::size_t completions = 0;
    // Every on_scroll_position message, in order, as {index, word}. A SEQUENCE, and of the WORD the core put
    // on the wire rather than of a bool derived from it: this channel is the one place the composite verdict
    // leaves the core, it is edge-triggered, and its whole contract is that the third state survives the trip
    // (see CharaDetailSceneScraper::on_scroll_position). "The core said unknown", "the core said at_top" and
    // "the core has said nothing about this tab" are three different claims, and a front end that resolves
    // fail-closed acts differently on each.
    std::vector<std::pair<int, std::string>> positions;
    // Every frame the factor duplicate probe was sent with, in order.
    std::vector<Frame> probe_frames;
    // Every call the factor model of the scraper's FactorRowReader received, in order: the timestamp of the frame
    // the cell was cropped from, how many sessions had been discarded at that instant, and where the cell sits in
    // that frame, in pixels. The second field is what lets a case state that a reading happened BEFORE the reset
    // rather than merely during the update. The third is what lets a case state WHICH REGION the reading scanned:
    // the reader hands the model a view into the frame it was given, and a view knows its own offset.
    struct FactorModelCall {
        uint64 timestamp;
        std::size_t discards_so_far;
        cv::Point cell_origin;
    };
    std::vector<FactorModelCall> factor_model_calls;
    // What the factor model does on each call after recording it; a case replaces it to make the reader fail.
    std::function<void()> factor_model_fault;
    // The id the factor model answers for a cell. Unset, every cell of every frame reads 101, so any two readings
    // of equal length are the same record; a case that needs two frames to read differently answers by the
    // cell's timestamp.
    std::function<int(const Frame &cell)> factor_model_answer;

    // The verdicts stated so far, in order, without the discard counts beside them.
    [[nodiscard]] std::vector<scraper_impl::FactorSwitchVerdict> verdictsStated() const {
        std::vector<scraper_impl::FactorSwitchVerdict> stated;
        for (const auto &[verdict, discards_so_far] : verdicts) {
            stated.push_back(verdict);
        }
        return stated;
    }

    // How many cells the factor model was handed from the frame stamped `timestamp`. One reading of one frame is
    // one fixed number of cells here (readerScanConfig finds the same rows on every frame of one size), so this
    // is how a case tells "read once" from "read twice".
    [[nodiscard]] std::size_t factorCallsOn(uint64 timestamp) const {
        std::size_t calls = 0;
        for (const auto &call : factor_model_calls) {
            calls += call.timestamp == timestamp ? 1 : 0;
        }
        return calls;
    }

    // The frames the factor model read, in order, with consecutive calls on one frame folded into one entry.
    [[nodiscard]] std::vector<uint64> framesRead() const {
        std::vector<uint64> frames;
        for (const auto &call : factor_model_calls) {
            if (frames.empty() || frames.back() != call.timestamp) {
                frames.push_back(call.timestamp);
            }
        }
        return frames;
    }

    // THE READER the scraper's character-switch rule reads with, built through the injection ctor exactly as
    // production builds it (both models behind their admissions). Its scan config is readerScanConfig(), under
    // which the scan finds rows on any of this file's frames, so a reading always reaches the factor model and
    // is observable in factor_model_calls.
    std::shared_ptr<const recognizer_impl::FactorRowReader> factor_reader =
        std::make_shared<const recognizer_impl::FactorRowReader>(
            readerScanConfig(),
            testutil::functionPredictor<int>(
                "factor",
                [this](const Frame &cell) {
                    cv::Size whole;
                    cv::Point origin;
                    cell.data().locateROI(whole, origin);
                    factor_model_calls.push_back(FactorModelCall{cell.timestamp(), discards.size(), origin});
                    if (factor_model_fault) {
                        factor_model_fault();
                    }
                    return recognizer::Predicted<int>{factor_model_answer ? factor_model_answer(cell) : 101, 1.0f, {}};
                }),
            testutil::constantPredictor<int>("factor_rank", 2));

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
              factor_reader,
              factor_switch_judged,
              restarted,
              shippedScraperConfig(),
              "unit_test_scraping_root",
              recorder.hooks()) {
        restarted->listen([this](const DiscardedSession &discarded) { discards.push_back(discarded); });
        factor_switch_judged->listen(
            [this](const scraper_impl::FactorSwitchVerdict verdict) { verdicts.emplace_back(verdict, discards.size()); });
        tab_refused->listen([this](int index, bool refused, const std::string &reason) {
            refusals.emplace_back(index, refused, reason);
        });
        page_ready->listen([this](int index) { pages_ready.push_back(index); });
        completed->listen([this](const RecordInfo &) { completions++; });
        scroll_position->listen([this](int index, const std::string &word) { positions.emplace_back(index, word); });
        factor_probe->listen([this](const Frame &frame, const RecordInfo &) { probe_frames.push_back(frame); });
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

    // THE `true` DIRECTION is asserted further down, by the Rule 3 cases that discard a completed session.
    // `completed` is `ready()`, which is `scraping_state == Ready`, which only checkForCompleted sets and only
    // when the whole SceneScrapingBox is ready -- all three tabs captured plus the base image. Synthetic frames
    // reach that: a tab with no scroll bar is captured from one stationary frame, and the base image latches on
    // frames carrying the title-bar banner. On real footage the same bit is asserted by the integration
    // manifest: `expect_discarded_incomplete` (native/test/integration/cases.json) states zero on every
    // ordinary clip, so a build that stopped setting the bit turns those cases red.
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
// [layout] is the shipped coordinate set the session under test resolved -- `common` for every record type
// but one, `friend_common` for a friend's full record, whose scroll area sits ~136 px lower (and whose tab
// bar sits ~133 px lower -- the two are separate measurements, see friendCommon in the builder). The
// bar has to be painted where THAT layout looks for it, or the frame is simply a bar-less one.
Frame scrollBarFrameIn(
    const scraper_config::SceneScraperConfig &layout, uint64 timestamp, int exposed_rows, int nonce) {
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

Frame scrollBarFrameAt(uint64 timestamp, int exposed_rows, int nonce) {
    return scrollBarFrameIn(shippedScraperConfig().common, timestamp, exposed_rows, nonce);
}

// The same frame with a TRANSLATING CONTENT TEXTURE painted over the scroll area, left of the scroll-bar scan
// line. This is what makes the OFFSET exit reachable at this level: that exit needs the scroll-area content to
// translate past initial_scroll_threshold while the stationary catcher never latches, and a band painted only
// with bar levels can express neither (it is uniform along every row it does not move, so the image estimator
// has nothing to match, and two such frames are pixel-identical and latch immediately).
//
// The shipped scroll_area_rect and scroll_bar_rect are the same region, so the two sensors would otherwise
// fight over the same pixels; the texture stops at 90% of the width and the scan line sits at 0.9693, so the
// bar reading is untouched and `exposed_rows` still decides the head-of-list verdict independently.
//
// `content_shift` moves the texture UP by that many rows -- i.e. it is the scroll offset in pixels, the same
// sense test_scraper_estimators.cpp's contentAndScrollBar uses. The per-row grey comes from a multiplicative
// hash rather than a short modular ramp: the band is ~392 rows tall here, so a period-200 ramp would give the
// image estimator two identical copies to lock onto and the offset would be decided by an alias.
// [layout] as in scrollBarFrameIn: the texture goes where THAT layout's scroll area is.
// `frame` with that texture painted over `layout`'s scroll area, shifted by `content_shift`. Whatever the frame
// carries in the scroll bar's scan column is left as it was, so a frame with no scroll bar keeps having none.
Frame withContentTexture(const Frame &frame, const scraper_config::SceneScraperConfig &layout, int content_shift) {
    cv::Mat pixels = frame.data().clone();
    const Rect<int> band_rect = frame.anchor().mapToFrame(layout.scroll_area_rect);
    const int texture_width = band_rect.width() * 9 / 10;
    for (int r = 0; r < band_rect.height(); r++) {
        const unsigned hashed = static_cast<unsigned>(r + content_shift) * 2654435761u;
        const auto value = static_cast<uchar>((hashed >> 24) % 200 + 28);
        pixels(cv::Rect(band_rect.left(), band_rect.top() + r, texture_width, 1))
            .setTo(cv::Scalar(value, value, value));
    }
    return Frame(pixels, frame.timestamp());
}

Frame scrollingBandFrameIn(
    const scraper_config::SceneScraperConfig &layout, uint64 timestamp, int content_shift, int exposed_rows, int nonce) {
    return withContentTexture(scrollBarFrameIn(layout, timestamp, exposed_rows, nonce), layout, content_shift);
}

Frame scrollingBandFrameAt(uint64 timestamp, int content_shift, int exposed_rows, int nonce) {
    return scrollingBandFrameIn(shippedScraperConfig().common, timestamp, content_shift, exposed_rows, nonce);
}

// A head-of-list frame ON WHICH THE HARNESS'S READER FINDS NO ROWS: the same texture region as
// scrollingBandFrameAt, filled instead with readerScanConfig's background colour, so the banner search runs out
// of span without leaving the background and the reading comes back empty. The scroll bar is untouched, so the
// frame is still flush at the top, and against a scroll-bar reference it is still a large pixel change.
Frame emptyReadingFrameAt(uint64 timestamp, int nonce) {
    const Frame bar = scrollBarFrameAt(timestamp, /*exposed_rows=*/0, nonce);
    cv::Mat pixels = bar.data().clone();
    const Rect<int> band_rect = bar.anchor().mapToFrame(shippedScraperConfig().common.scroll_area_rect);
    fill(pixels(cv::Rect(band_rect.left(), band_rect.top(), band_rect.width() * 9 / 10, band_rect.height())),
         readerScanConfig().bg_color.min());
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

// The crop row the tests paint the green "因子" header on. Which row does not matter to the header sensor, which
// compares the row it finds against the row the factor probe read on the same page; it only has to be one row
// for every frame of a page that has not moved, and inside the crop.
constexpr int kHeaderCropRow = 12;

// `frame` with the green "因子" SECTION HEADER painted into the scroll-area crop at `crop_row`, across the
// configured probe band. This is what makes the fine sensor reachable at this level: a frame painted only with
// bar levels carries no header at all, so topOfContent's factor arm answers Unknown on it and every one of these
// tests would be reading the coarse sensor no matter what the fine one did.
//
// The band stops at band_end (0.93 of the crop width) and the bar's scan line sits at 0.9693, so the coarse
// reading is untouched and `exposed_rows` still decides it independently.
Frame withFactorHeaderAt(const Frame &frame, int crop_row) {
    const auto &config = shippedScraperConfig();
    cv::Mat pixels = frame.data().clone();
    const Rect<int> band = frame.anchor().mapToFrame(config.common.scroll_area_rect);
    // Solidly inside the configured range ({70,150,0}..{190,255,85}), so the row's green FRACTION is 1.0 over
    // the probe band and the threshold is not what is being tested here.
    const Color green{130, 200, 40};
    const int left = band.left() + static_cast<int>(std::lround(config.factor_header.band_start * band.width()));
    const int right = band.left() + static_cast<int>(std::lround(config.factor_header.band_end * band.width()));
    constexpr int kHeaderRows = 24;  // the header's measured height at these capture widths
    fill(pixels(cv::Rect(left, band.top() + crop_row, right - left, kHeaderRows)), green);
    return Frame(pixels, frame.timestamp());
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

TEST_CASE("a tab not built yet says so on the wire, rather than being resolved here") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    // The first frame of a tab is judged BEFORE the tab is built from it (SceneScraper::build runs later in the
    // same update), so there is no thumb to measure and no structure to ask. On a campaign frame there is no
    // header either, so nothing has anything to say. (A frame of a BUILT, scrollable tab that neither sensor can
    // read says "unknown" too; see "a frame of a scrollable factor page that shows neither ..." below, which also
    // pins what Rule 3 does with it.)
    h.scraper.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{CampaignPage, record::Standard});

    // The word, not a bool. "unknown" is the whole point: resolved to either answer here, this reads as one
    // of the other two and the consumer that needed the distinction never sees it.
    CHECK(h.positionWords(CampaignPage) == std::vector<std::string>{"unknown"});
}

TEST_CASE("a tab whose page cannot scroll is at the head of its content on the wire, whatever its frames show") {
    // A PAGE WITH NO SCROLL BAR CANNOT BE ANYWHERE BUT THE HEAD OF ITS CONTENT, and the core says so from the
    // structure the tab was built with, not from a sensor. Before, a skill or campaign page with no scroll bar
    // says "unknown" on every frame (no thumb), and a factor page says whatever its header says -- "unknown" when
    // the header is covered, its green missed, or no reference row has been read yet, "scrolled" when it sits off
    // the row its factor probe read. Rule 3 resolves both as "scrolled" and then never judges the page the user
    // can switch on.
    //
    // Four pages, and two of them are not the factor tab, so an answer keyed on the tab's name stays red.
    TabPage tab = SkillPage;
    std::function<Frame(uint64, int)> page;
    std::string sensors_word;  // the first frame's word, taken before the tab is built (see the case above)
    SUBCASE("a skill page") {
        tab = SkillPage;
        page = noScrollBarFrameAt;
        sensors_word = "unknown";
    }
    SUBCASE("a campaign page") {
        tab = CampaignPage;
        page = noScrollBarFrameAt;
        sensors_word = "unknown";
    }
    SUBCASE("a factor page whose header is not drawn") {
        tab = FactorPage;
        page = noScrollBarFrameAt;
        sensors_word = "unknown";
    }
    SUBCASE("a factor page whose header is drawn") {
        // Before the latch no reference row exists, so the header sensor has nothing to compare and the first
        // word is the thumb's -- and there is no thumb.
        tab = FactorPage;
        page = [](uint64 timestamp, int nonce) {
            return withFactorHeaderAt(noScrollBarFrameAt(timestamp, nonce), kHeaderCropRow);
        };
        sensors_word = "unknown";
    }
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    // The page latches on the second frame; the third shows the answer holds after that too.
    h.scraper.update(page(0, /*nonce=*/0), SceneState{tab, record::Standard});
    h.scraper.update(page(kPastStationary, /*nonce=*/0), SceneState{tab, record::Standard});
    h.scraper.update(page(kPastStationary + kPastDwell, /*nonce=*/0), SceneState{tab, record::Standard});

    CHECK(h.positionWords(tab) == std::vector<std::string>{sensors_word, "at_top"});
    CHECK(h.discards.empty());
}

TEST_CASE("a tab a sensor CAN read says which way it measured") {
    // The positive control for the "unknown" cases: without it, "unknown" would be indistinguishable from a wire
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

// --- the reading Rule 3 takes once its pixel diff has said "a different character" -------------------------
//
// WHAT THIS PROTECTS is not a verdict. Rule 3 decides from pixels alone and, when it is wrong, throws away a
// capture the user has already paid for; the reading pinned here is what will let it look at what the two
// frames actually show before paying that price. It is taken with the pipeline's shared FactorRowReader,
// SYNCHRONOUSLY, inside the update() that judges the frame -- so these cases need no runner, no answer to
// deliver and no count to wait on: when update() returns, the reading has happened or it has not.
//
// The pixel diff only nominates a frame. What decides is scraper_impl::factorSwitchVerdict over the two readings:
// Same keeps the session and makes the judged frame the reference; Different, Empty and Unreadable reset. Each of
// those four is its own case below, because a case that covered two of them could stay green with the two
// swapped.
//
// The harness's reader answers 101 for every cell unless a case says otherwise, so by default every pair of
// readings is Same. A case that wants a reset has to make it happen, which keeps "it reset" from being the
// harness's default rather than the rule's decision.

// The factor tab's head latch on `layout`: two identical frames settled at the head of the list, which latch
// fragment #0 and so arm the rule with its reference (nothing before that latch can reach the diff at all).
// Returns the timestamp of the latched frame, which is the reference's.
uint64 latchFactorHead(
    ScraperHarness &h,
    uint64 base,
    int nonce,
    const scraper_config::SceneScraperConfig &layout,
    record::RecordType record_type) {
    h.scraper.update(scrollBarFrameIn(layout, base, /*exposed_rows=*/0, nonce), SceneState{FactorPage, record_type});
    h.scraper.update(
        scrollBarFrameIn(layout, base + kPastStationary, /*exposed_rows=*/0, nonce + 1),
        SceneState{FactorPage, record_type});
    return base + kPastStationary;
}

using FrameAt = std::function<Frame(uint64 timestamp, int nonce)>;

// Holds the frames `frame_at` builds for a dwell, starting at `at`: the first opens the window and the second,
// a dwell later, is the one the rule judges. Returns the judged frame's timestamp. Every frame here must stay
// flush at the top (exposed_rows 0), because the rule is gated on that and would never look at the pixels
// otherwise.
uint64 holdFactorDivergence(
    ScraperHarness &h, uint64 at, int nonce, const FrameAt &frame_at, record::RecordType record_type) {
    h.scraper.update(frame_at(at, nonce), SceneState{FactorPage, record_type});
    h.scraper.update(frame_at(at + kPastDwell, nonce + 1), SceneState{FactorPage, record_type});
    return at + kPastDwell;
}

// The two Standard-layout frames the round-trip cases alternate between: the scroll bar's flat levels (what the
// head latch holds) and a content texture over the scroll area. Either one diffs against the other far past
// kFactorChangeRatioThreshold; two of the same kind diff by nothing, because the nonce only repaints above the
// scroll area.
Frame latchedLook(uint64 timestamp, int nonce) {
    return scrollBarFrameAt(timestamp, /*exposed_rows=*/0, nonce);
}
Frame texturedLook(uint64 timestamp, int nonce) {
    return scrollingBandFrameAt(timestamp, /*content_shift=*/0, /*exposed_rows=*/0, nonce);
}

// Drives one Standard factor-tab session from a fresh latch to the judged frame of a divergence into the
// textured look, and returns that frame's timestamp. Whether it resets is the reader's answer, not this helper's.
uint64 driveFactorDivergence(ScraperHarness &h, uint64 base, int nonce) {
    const uint64 latched = latchFactorHead(h, base, nonce, shippedScraperConfig().common, record::Standard);
    return holdFactorDivergence(h, latched + 100, nonce + 2, texturedLook, record::Standard);
}

TEST_CASE("the switch verdict is Same only for two non-empty readings that agree in length and every element") {
    using scraper_impl::FactorSwitchReading;
    const auto verdict = [](const std::optional<FactorSwitchReading> &reading) {
        return std::string(scraper_impl::factorSwitchVerdictTag(scraper_impl::factorSwitchVerdict(reading)));
    };
    const record::Factor a{101, 3};
    const record::Factor b{202, 1};

    CHECK(verdict(FactorSwitchReading{{a, b}, {a, b}}) == "same");
    // A reader failure is not a reading, and says so rather than passing for an empty one.
    CHECK(verdict(std::nullopt) == "unreadable");
    // An empty side is never Same -- not even against another empty side -- and is not Different either: a count
    // of real mismatches must not absorb "nothing was found".
    CHECK(verdict(FactorSwitchReading{{}, {}}) == "empty");
    CHECK(verdict(FactorSwitchReading{{a}, {}}) == "empty");
    CHECK(verdict(FactorSwitchReading{{}, {a}}) == "empty");
    // Length: one reading a prefix of the other is not the same list.
    CHECK(verdict(FactorSwitchReading{{a}, {a, b}}) == "different");
    CHECK(verdict(FactorSwitchReading{{a, b}, {a}}) == "different");
    // Every element, both fields, in order.
    CHECK(verdict(FactorSwitchReading{{a, b}, {a, record::Factor{203, 1}}}) == "different");
    CHECK(verdict(FactorSwitchReading{{a, b}, {a, record::Factor{202, 2}}}) == "different");
    CHECK(verdict(FactorSwitchReading{{a, b}, {b, a}}) == "different");
}

TEST_CASE("a candidate switch whose two readings differ discards the session, having read both frames first") {
    ScraperHarness h;
    // The latched frame reads 101s and every later frame reads 102s.
    h.factor_model_answer = [](const Frame &cell) { return cell.timestamp() > kPastStationary ? 102 : 101; };
    h.scraper.buildSession(record::Standard);
    REQUIRE_FALSE(h.recorder.made.empty());
    const std::string first_session = h.sessionIdAt(0);

    const uint64 judged_at = driveFactorDivergence(h, 0, /*nonce=*/0);

    REQUIRE(h.discards.size() == 1);
    CHECK(h.discards.front().info.record_id == first_session);

    // The reference is the frame the head latch armed the rule with, which is the frame the probe was handed.
    REQUIRE(h.probe_frames.size() == 1);
    const uint64 reference_at = h.probe_frames.front().timestamp();
    REQUIRE(reference_at == kPastStationary);
    // Exactly two readings: the reference, then the judged frame. Not on the frames that only latched the head or
    // opened the dwell, and not after the reset on the fresh session's behalf.
    CHECK(h.framesRead() == std::vector<uint64>{reference_at, judged_at});
    // ...and all of it before the session was discarded: the reading is part of judging the frame, not an
    // afterthought of the reset.
    std::size_t calls_after_a_discard = 0;
    for (const auto &call : h.factor_model_calls) {
        calls_after_a_discard += call.discards_so_far != 0 ? 1 : 0;
    }
    CHECK(calls_after_a_discard == 0);
    // Stated as Different, once, and before the discard it caused.
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Different});
    CHECK(h.verdicts.front().second == 0);
}

TEST_CASE("a candidate switch read as the same record keeps the session and asks nothing more of the frames that follow") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);
    const std::string first_session = h.sessionIdAt(0);

    const uint64 judged_at = driveFactorDivergence(h, 0, /*nonce=*/0);

    // The rule did read -- the verdict is the reader's, not a pixel diff that never fired...
    REQUIRE(h.framesRead() == std::vector<uint64>{kPastStationary, judged_at});
    // ...and kept the session: no discard, no fresh session, no second probe.
    CHECK(h.discards.empty());
    CHECK(h.sessionIdAt(h.recorder.made.size() - 1) == first_session);
    CHECK(h.probe_frames.size() == 1);
    // ...and said so: a Same is the one verdict no other channel shows, so the stream is its only trace.
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Same});

    // THE JUDGED FRAME IS NOW THE REFERENCE, observed from both sides. The textured look is held for two more
    // dwells: against the latched frame that would reopen the window and be read again, against the judged frame
    // it is no change at all.
    const std::size_t calls_after_verdict = h.factor_model_calls.size();
    for (int i = 0; i < 3; i++) {
        h.scraper.update(
            texturedLook(judged_at + 100 + static_cast<uint64>(i) * kPastDwell, /*nonce=*/10 + i),
            SceneState{FactorPage, record::Standard});
    }
    CHECK(h.factor_model_calls.size() == calls_after_verdict);
    // And the latched look, which the rule had been treating as "no change" until now, is a divergence again.
    const uint64 back_at =
        holdFactorDivergence(h, judged_at + 100 + 3 * kPastDwell, /*nonce=*/20, latchedLook, record::Standard);
    CHECK(h.framesRead().back() == back_at);
    CHECK(h.discards.empty());
}

TEST_CASE("a candidate switch on which the reader finds no rows discards the session") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    const uint64 latched = latchFactorHead(h, 0, /*nonce=*/0, shippedScraperConfig().common, record::Standard);
    const uint64 judged_at = holdFactorDivergence(h, latched + 100, /*nonce=*/2, emptyReadingFrameAt, record::Standard);

    CHECK(h.discards.size() == 1);
    // Empty, and not Different or Unreadable: the reference WAS read and found rows, the judged frame yielded not
    // one cell, and the reader did not fail (a failure would have left nothing read at all).
    CHECK(h.factorCallsOn(latched) > 0);
    CHECK(h.factorCallsOn(judged_at) == 0);
    // And stated as Empty -- not folded into Different or Unreadable, although it resets like both.
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Empty});
    CHECK(h.verdicts.front().second == 0);
}

TEST_CASE("the reference is read once, and a reference installed by a Same verdict is not read at all") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    const uint64 latched = latchFactorHead(h, 0, /*nonce=*/0, shippedScraperConfig().common, record::Standard);
    // Not at the latch: a latch that never diverges must not pay for a reading.
    CHECK(h.factor_model_calls.empty());

    const uint64 first_judged = holdFactorDivergence(h, latched + 100, /*nonce=*/2, texturedLook, record::Standard);
    const std::size_t one_reading = h.factorCallsOn(latched);
    REQUIRE(one_reading > 0);
    REQUIRE(h.factorCallsOn(first_judged) == one_reading);

    // The second candidate switch compares against first_judged, whose reading was taken as the judged frame.
    const uint64 second_judged =
        holdFactorDivergence(h, first_judged + 100, /*nonce=*/4, latchedLook, record::Standard);
    REQUIRE(h.discards.empty());
    CHECK(h.factorCallsOn(second_judged) == one_reading);
    CHECK(h.factorCallsOn(first_judged) == one_reading);  // not read a second time as the reference
    CHECK(h.factorCallsOn(latched) == one_reading);
    CHECK(h.factor_model_calls.size() == 3 * one_reading);
}

TEST_CASE("going back and forth between two looks of one record costs one reading per transition") {
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);

    const uint64 latched = latchFactorHead(h, 0, /*nonce=*/0, shippedScraperConfig().common, record::Standard);
    std::vector<uint64> expected{latched};
    uint64 at = latched + 100;
    const std::array<FrameAt, 4> transitions{texturedLook, latchedLook, texturedLook, latchedLook};
    for (std::size_t i = 0; i < transitions.size(); i++) {
        const uint64 judged = holdFactorDivergence(h, at, static_cast<int>(2 + 2 * i), transitions[i], record::Standard);
        expected.push_back(judged);
        at = judged + 100;
    }

    CHECK(h.discards.empty());
    // One reference reading and one judged reading per transition; the frames that only opened each dwell are
    // never read.
    CHECK(h.framesRead() == expected);
    // One verdict per transition, every one Same: the count is of judgements, not of frames read.
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>(4, scraper_impl::FactorSwitchVerdict::Same));
}

// --- which region the switch reading scans, per layout ----------------------------------------------------------
//
// The reader scans a live frame from the rect it is handed, and only the scraper knows where this session's
// layout puts the scroll area. Scanning from anywhere else -- the recognizer's own config.area, which names the
// stitched image's Standard position, or common's rect on a friend's full record -- reads rows that are not the
// self factors, or none, and nothing downstream of the reader can tell. That is the failure stage 1 fixed for the
// probe; these pin it for the switch reading.
//
// Under readerScanConfig the banner search stops at its first sample, so a reading's first cell starts exactly
// vertical_banner_bottom_delta below the top of the rect the reader was handed. What is asserted is that window,
// measured from the top of THIS LAYOUT's scroll area on the frame -- one capture pixel of rounding on each side.
void checkSwitchReadingArea(const scraper_config::SceneScraperConfig &layout, record::RecordType record_type) {
    ScraperHarness h;
    h.factor_model_answer = [](const Frame &cell) { return cell.timestamp() > kPastStationary ? 102 : 101; };
    h.scraper.buildSession(record_type);

    const uint64 latched = latchFactorHead(h, 0, /*nonce=*/0, layout, record_type);
    const FrameAt textured_in_layout = [&layout](uint64 timestamp, int nonce) {
        return scrollingBandFrameIn(layout, timestamp, /*content_shift=*/0, /*exposed_rows=*/0, nonce);
    };
    const uint64 judged_at = holdFactorDivergence(h, latched + 100, /*nonce=*/2, textured_in_layout, record_type);
    REQUIRE(h.framesRead() == std::vector<uint64>{latched, judged_at});

    const Frame probe = scrollBarFrameIn(layout, 0, 0, 0);
    const int unit = probe.anchor().intersection().width();
    const int area_top = probe.anchor().mapToFrame(layout.scroll_area_rect).top();
    const int first_row_offset =
        static_cast<int>(std::lround(readerScanConfig().vertical_banner_bottom_delta * static_cast<double>(unit)));
    for (const uint64 frame_at : {latched, judged_at}) {
        int first_cell_top = std::numeric_limits<int>::max();
        for (const auto &call : h.factor_model_calls) {
            if (call.timestamp == frame_at) {
                first_cell_top = std::min(first_cell_top, call.cell_origin.y);
            }
        }
        CAPTURE(frame_at);
        CAPTURE(area_top);
        CHECK(first_cell_top >= area_top + first_row_offset - 1);
        CHECK(first_cell_top <= area_top + first_row_offset + 1);
    }
}

TEST_CASE("the switch reading scans the scroll area of a Standard session's layout") {
    checkSwitchReadingArea(shippedScraperConfig().common, record::Standard);
}

TEST_CASE("the switch reading scans the scroll area of a friend's full record, not Standard's") {
    const auto config = shippedScraperConfig();
    // The control that makes this case able to fail: at this frame size the two layouts' scroll areas are far
    // enough apart that no one window contains both. Without it, a friend session scanning common's rect could
    // land inside the friend window by coincidence.
    const Frame probe = scrollBarFrameIn(config.common, 0, 0, 0);
    REQUIRE(
        probe.anchor().mapToFrame(config.friend_common.scroll_area_rect).top()
            - probe.anchor().mapToFrame(config.common.scroll_area_rect).top()
        > 2);
    checkSwitchReadingArea(config.friend_common, record::FriendStandard);
}

TEST_CASE("the switch reading stops at the scroll area, so frames that differ only below it are one record") {
    // THE BOUND RULE 3 SHARES WITH THE PROBE. Under readerScanConfig the row search finds a row at every sample, so
    // a reading that were not bounded by the scroll area would run on towards the frame's bottom edge. The factor
    // model here answers the same on both frames for every cell inside the scroll area, and differently on the
    // judged frame for any cell reaching below it -- two frames whose only difference is where a live frame shows
    // the bottom UI. Read by the rule, they are Same. A reading bounded by anything but this session's scroll area
    // hands the model those cells, and the verdict becomes Different: a reset of the session being captured.
    ScraperHarness h;
    const Frame probe = scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0);
    const int area_bottom = probe.anchor().mapToFrame(shippedScraperConfig().common.scroll_area_rect).bottom();
    h.factor_model_answer = [area_bottom](const Frame &cell) {
        cv::Size whole;
        cv::Point origin;
        cell.data().locateROI(whole, origin);
        const bool reaches_below = origin.y + cell.height() > area_bottom;
        return cell.timestamp() > kPastStationary && reaches_below ? 102 : 101;
    };
    h.scraper.buildSession(record::Standard);

    const uint64 judged_at = driveFactorDivergence(h, 0, /*nonce=*/0);

    // The pixel diff did fire and both frames were read: the verdict is the reader's.
    REQUIRE(h.framesRead() == std::vector<uint64>{kPastStationary, judged_at});
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Same});
    CHECK(h.discards.empty());
}

TEST_CASE("a candidate switch the reader cannot read discards the session") {
    // THE FAILURE THE READING MUST NOT INTRODUCE. If an exception left update(), the runner's per-event
    // containment would stop it -- after it had skipped the reset -- and factor_change_pending_since would still be
    // set, so every following frame would read, throw and skip the reset again: the session would keep scraping a
    // different character. Driven directly, as here, an escaping exception reaches the case instead, which is
    // what CHECK_NOTHROW pins.
    //
    // The fault is the ONLY thing that makes these frames reset: the harness's reader otherwise answers the same
    // ids on both frames, which is a Same verdict and keeps the session (the case above). So a discard here is the
    // Unreadable arm deciding, not a Different verdict the fault happened to accompany.
    struct NotAStdException {};
    ScraperHarness h;
    SUBCASE("a failure that is not a std::exception, as WinRT and ONNX failures are not") {
        h.factor_model_fault = [] { throw NotAStdException{}; };
    }
    SUBCASE("a stop cancelling the inference") {
        h.factor_model_fault = [] { throw error_util::OperationAborted("test stop"); };
    }
    h.scraper.buildSession(record::Standard);

    uint64 reset_at = 0;
    CHECK_NOTHROW(reset_at = driveFactorDivergence(h, 0, /*nonce=*/0));
    // The fault was actually reached: a case whose reader was never called would pass the line above for nothing.
    REQUIRE_FALSE(h.factor_model_calls.empty());
    CHECK(h.discards.size() == 1);

    // Nothing is left armed by the failure: the session the reset built latches afresh and discards again.
    CHECK_NOTHROW(driveFactorDivergence(h, reset_at + 100, /*nonce=*/4));
    CHECK(h.discards.size() == 2);
    // Stated as Unreadable both times, each before its discard: a reader that always fails resets exactly as often
    // as a working one that always reads Different, and this stream is where the two differ.
    CHECK(
        h.verdictsStated()
        == std::vector<scraper_impl::FactorSwitchVerdict>{
            scraper_impl::FactorSwitchVerdict::Unreadable, scraper_impl::FactorSwitchVerdict::Unreadable});
    REQUIRE(h.verdicts.size() == 2);
    CHECK(h.verdicts[0].second == 0);
    CHECK(h.verdicts[1].second == 1);
}

// --- which rule watches a captured tab for a character switch --------------------------------------------------
//
// WHAT THIS GROUP CLAIMS: a captured tab is watched by Rule 3 whenever it holds a switch witness (the factor tab,
// from its head latch on, whether its page scrolls or has no scroll bar), before the session completes and after,
// and no other tab is watched in any state -- so a captured tab back at the head of its list is never, by itself, a
// reason to throw the capture away, and a switch made on another tab after completion is judged when the factor tab
// is next shown. CharaDetailSceneScraper::watchesFactorContent states why; these pin what it decides.
//
// A COMPLETED SESSION IS REACHABLE WITHOUT GAME PIXELS, which is what the cases that watch Rule 3 after completion
// need:
//   * A skill or campaign tab with no scroll bar is captured WITHOUT SCROLLING: that builds the non-scrollable
//     interpreter, which latches one stationary frame and is done. From then on the tab reads at the head of its
//     content from that structure (CharaDetailSceneScraper::topOfContent), whatever a later frame draws -- so
//     the scroll bar some cases below render on later frames does not change the word.
//   * The factor tab is captured either way, and EITHER WAY ITS LATCH INSTALLS THE WITNESS: by scrolling (a head
//     latch, then one more frame of the same list carrying the green end bar, which ends the tab on a frame whose
//     offset is known -- even a zero one, PageScrapingBox::detectGreenTerminator), or on a factor page with no scroll
//     bar (its one settled frame). So no completed session has a factor tab without a witness.
//   * The base image latches on those same frames, because they carry the title-bar banner.

// Green inside both the shipped header_color_range and factor_end_green's range.
const Color kTitleGreen{130, 200, 40};

// `frame` with the green title-bar banner across the shipped header scan line, so the base catcher's banner gate
// opens. Painted where the frame itself maps that line, a few rows wider on each side, and above the scroll
// area, so no tab's reading changes.
Frame withBanner(const Frame &frame) {
    const Line<int> line = frame.anchor().mapToFrame(shippedScraperConfig().header_scan_line);
    const int top = std::min(line.p1().y(), line.p2().y()) - 2;
    const int bottom = std::max(line.p1().y(), line.p2().y()) + 3;
    cv::Mat pixels = frame.data().clone();
    fill(pixels(cv::Rect(0, top, pixels.cols, bottom - top)), kTitleGreen);
    return Frame(pixels, frame.timestamp());
}

// `frame` with the factor list's green end bar near the bottom of the scroll area, at the shipped end-bar scan
// column. On a frame that did not scroll the frontier is the bottom of the area, and the terminator looks within
// the terminating scan's length above it. Twenty by ten pixels: still the same list to the offset estimator,
// and below kFactorChangeRatioThreshold against the latched frame, so Rule 3 does not see it as a change.
Frame withFactorEndBar(const Frame &frame) {
    const auto config = shippedScraperConfig();
    const Rect<int> area = frame.anchor().mapToFrame(config.common.scroll_area_rect);
    const int x = area.left() + static_cast<int>(std::lround(config.factor_end_green.x * area.width()));
    cv::Mat pixels = frame.data().clone();
    fill(pixels(cv::Rect(x - 10, area.top() + area.height() - 30, 20, 10)), kTitleGreen);
    return Frame(pixels, frame.timestamp());
}

// `page` as a factor page draws it at the head of its content: the green 因子 header on kHeaderCropRow, and the
// title-bar banner. On a page with no scroll bar the header is NOT what opens Rule 3's flush gate -- the page's
// structure is -- so the kinds below that draw no header, or draw it off its row, are judged all the same.
Frame asFactorPageAtHead(const Frame &page) {
    return withBanner(withFactorHeaderAt(page, kHeaderCropRow));
}

// `page` with the header two rows BELOW kHeaderCropRow, and the banner: past factor_header.flush_tolerance_px from
// the row a latch on asFactorPageAtHead reads, so the sensor reads it as scrolled on a page that cannot scroll --
// what a header partly covered, or drawn off its row, reads as.
Frame withFactorHeaderBelowHead(const Frame &page) {
    return withBanner(withFactorHeaderAt(page, kHeaderCropRow + 2));
}

// A factor page whose list fits on one screen: no scroll bar, the header at the head of its content, the banner.
Frame factorPageWithoutScrollBar(uint64 timestamp, int nonce) {
    return asFactorPageAtHead(noScrollBarFrameAt(timestamp, nonce));
}

// The same kind of page showing a different list: a content texture over the scroll area, left of the scroll bar's
// scan column, so the page still has no scroll bar. Diffs against factorPageWithoutScrollBar far past
// kFactorChangeRatioThreshold.
Frame texturedFactorPageWithoutScrollBar(uint64 timestamp, int nonce) {
    return asFactorPageAtHead(
        withContentTexture(noScrollBarFrameAt(timestamp, nonce), shippedScraperConfig().common, /*content_shift=*/0));
}

// Captures `tab` of a Standard session without scrolling, on a page with no scroll bar and no factor header -- the
// look of a skill or campaign page. Returns the timestamp of its last frame.
uint64 captureWithoutScrolling(ScraperHarness &h, TabPage tab, uint64 at) {
    h.scraper.update(withBanner(noScrollBarFrameAt(at, /*nonce=*/0)), SceneState{tab, record::Standard});
    h.scraper.update(
        withBanner(noScrollBarFrameAt(at + kPastStationary, /*nonce=*/0)), SceneState{tab, record::Standard});
    return at + kPastStationary;
}

// The timestamp of the witness either factor capture below installs when it starts at 0: the latched frame.
const uint64 kWitnessAt = kPastStationary;

// Captures the factor tab of a Standard session by scrolling, so it holds Rule 3's witness. The nonce stays fixed
// because the tab button has to latch too for the tab to count as captured. Returns the timestamp of the last
// frame; the witness is the latched frame, kPastStationary after `at`.
uint64 captureFactorByScrolling(ScraperHarness &h, uint64 at) {
    const auto look = [](uint64 timestamp) {
        return withBanner(scrollBarFrameAt(timestamp, /*exposed_rows=*/0, /*nonce=*/0));
    };
    h.scraper.update(look(at), SceneState{FactorPage, record::Standard});
    h.scraper.update(look(at + kPastStationary), SceneState{FactorPage, record::Standard});
    h.scraper.update(withFactorEndBar(look(at + kPastStationary + 100)), SceneState{FactorPage, record::Standard});
    return at + kPastStationary + 100;
}

// Captures the factor tab of a Standard session on a factor page with no scroll bar that looks like `look`. Its one
// settled frame is the tab's whole capture and its head latch, so it holds Rule 3's witness from that frame on,
// exactly as a scrolled capture does. Returns the timestamp of that frame, kPastStationary after `at`.
uint64 captureFactorPageLooking(ScraperHarness &h, uint64 at, const FrameAt &look) {
    h.scraper.update(look(at, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.scraper.update(look(at + kPastStationary, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    return at + kPastStationary;
}

uint64 captureFactorWithoutScrollBar(ScraperHarness &h, uint64 at) {
    return captureFactorPageLooking(h, at, factorPageWithoutScrollBar);
}

// A factor page with no scroll bar on which the header is not drawn (covered by a tap effect, or a green this
// source never matches), with the banner; and the same page showing a different list.
Frame factorPageWithoutScrollBarOrHeader(uint64 timestamp, int nonce) {
    return withBanner(noScrollBarFrameAt(timestamp, nonce));
}
Frame texturedFactorPageWithoutScrollBarOrHeader(uint64 timestamp, int nonce) {
    return withBanner(
        withContentTexture(noScrollBarFrameAt(timestamp, nonce), shippedScraperConfig().common, /*content_shift=*/0));
}
uint64 captureFactorWithoutScrollBarOrHeader(ScraperHarness &h, uint64 at) {
    return captureFactorPageLooking(h, at, factorPageWithoutScrollBarOrHeader);
}

// A factor page with no scroll bar whose header the sensor reads as scrolled (withFactorHeaderBelowHead); and the
// same page showing a different list.
Frame factorPageWithHeaderBelowHead(uint64 timestamp, int nonce) {
    return withFactorHeaderBelowHead(noScrollBarFrameAt(timestamp, nonce));
}
Frame texturedFactorPageWithHeaderBelowHead(uint64 timestamp, int nonce) {
    return withFactorHeaderBelowHead(
        withContentTexture(noScrollBarFrameAt(timestamp, nonce), shippedScraperConfig().common, /*content_shift=*/0));
}
uint64 captureFactorWithHeaderBelowHead(ScraperHarness &h, uint64 at) {
    return captureFactorPageLooking(h, at, factorPageWithHeaderBelowHead);
}

using CaptureFactorTab = uint64 (*)(ScraperHarness &, uint64);

// Completes a Standard session: the factor tab first, by `capture_factor`, then the other two without scrolling.
uint64 completeSession(ScraperHarness &h, CaptureFactorTab capture_factor) {
    uint64 at = capture_factor(h, 0);
    at = captureWithoutScrolling(h, SkillPage, at + 100);
    return captureWithoutScrolling(h, CampaignPage, at + 100);
}

TEST_CASE("the capture helpers really capture: a tab, the witness, and a whole session") {
    // The control every case below rests on. A helper that silently failed to capture would turn "no discard"
    // into "nothing was ever captured", and "Rule 3 discarded a completed session" into "it was never complete".
    SUBCASE("a skill or campaign page with no scroll bar latches, arms no probe and owes no cue") {
        TabPage tab = SkillPage;
        SUBCASE("the skill tab") {
            tab = SkillPage;
        }
        SUBCASE("the campaign tab") {
            tab = CampaignPage;
        }
        ScraperHarness h;
        h.scraper.buildSession(record::Standard);
        captureWithoutScrolling(h, tab, 0);
        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(tab)});
        CHECK(h.probe_frames.empty());
        CHECK(h.completions == 0);
    }
    SUBCASE("the factor tab by scrolling, which latches the witness owing the cue") {
        ScraperHarness h;
        h.scraper.buildSession(record::Standard);
        captureFactorByScrolling(h, 0);
        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});
        REQUIRE(h.probe_frames.size() == 1);
        CHECK(h.probe_frames.front().timestamp() == kWitnessAt);
        CHECK(h.completions == 0);
    }
    SUBCASE("a factor page with no scroll bar, which latches the witness on its one frame owing no cue") {
        // THE LATCH THAT USED TO INSTALL NOTHING. The page is captured and its head latched on the same frame, so
        // the probe is armed exactly as on a scrolled capture -- with the whole frame, this session's scroll area,
        // and no cue: there is nothing to scroll, so "you may scroll now" would be false, and it would arrive after
        // the tab's own completion.
        ScraperHarness h;
        h.scraper.buildSession(record::Standard);
        captureFactorWithoutScrollBar(h, 0);
        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});
        REQUIRE(h.probe_frames.size() == 1);
        CHECK(h.probe_frames.front().timestamp() == kWitnessAt);
        // The whole frame, not the content crop: Rule 3 compares its witness with later frames by size.
        CHECK(h.probe_frames.front().size() == factorPageWithoutScrollBar(0, 0).size());
        // A page that cannot scroll reads at the head of its content -- which is what lets Rule 3's flush gate open
        // on it at all.
        CHECK(h.positionWords(FactorPage).back() == "at_top");
        CHECK(h.completions == 0);
    }
    SUBCASE("a whole session, whichever way its factor tab was captured, with the witness") {
        CaptureFactorTab capture_factor = captureFactorByScrolling;
        SUBCASE("by scrolling") {
            capture_factor = captureFactorByScrolling;
        }
        SUBCASE("on a page with no scroll bar") {
            capture_factor = captureFactorWithoutScrollBar;
        }
        ScraperHarness h;
        h.scraper.buildSession(record::Standard);
        completeSession(h, capture_factor);
        CHECK(h.completions == 1);
        CHECK(h.probe_frames.size() == 1);
        CHECK(h.discards.empty());
    }
}

TEST_CASE("a captured skill or campaign tab at the head of its list is never a switch, whether or not the session is complete") {
    // THE DEFECT THIS GROUP EXISTS FOR. The tab was captured and reads at the head of its list for four dwells. The
    // user either scrolled back up or switched on a tab where nothing can compare the two records; neither is a
    // reason to throw captured tabs away, and after completion a real switch here is judged at the factor tab
    // instead ("after completion, a switch made on another tab ..." below). (The factor tab is Rule 3's from its
    // latch on; its version of this is "a captured factor page with no scroll bar that stays at its head ..." below.)
    TabPage tab = SkillPage;
    bool complete = false;
    SUBCASE("the skill tab") {
        tab = SkillPage;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    SUBCASE("the campaign tab") {
        tab = CampaignPage;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);
    const uint64 captured =
        complete ? completeSession(h, captureFactorWithoutScrollBar) : captureWithoutScrolling(h, tab, 0);
    REQUIRE(std::find(h.pages_ready.begin(), h.pages_ready.end(), static_cast<int>(tab)) != h.pages_ready.end());
    REQUIRE(h.completions == (complete ? 1 : 0));

    const uint64 first_top = captured + 100;
    for (int i = 0; i < 4; i++) {
        h.scraper.update(
            scrollBarFrameAt(first_top + static_cast<uint64>(i) * kPastDwell, /*exposed_rows=*/0, /*nonce=*/2 + i),
            SceneState{tab, record::Standard});
    }
    CHECK(h.discards.empty());
    CHECK(h.verdicts.empty());
    // No second record either: a completed session stays the one that completed.
    CHECK(h.completions == (complete ? 1 : 0));
    // The frames were read at the head, so "no discard" is no rule watching, not a sensor that saw nothing.
    CHECK(h.positionWords(tab).back() == "at_top");
}

// One kind of factor page: how its tab is captured, and the look that shows a different list on the same kind of
// page (a scroll bar stays a scroll bar, and a page without one stays without one).
struct FactorPageKind {
    CaptureFactorTab capture;
    FrameAt diverged;
};

const FactorPageKind kScrollableFactorPage{captureFactorByScrolling, texturedLook};
const FactorPageKind kFactorPageWithoutScrollBar{captureFactorWithoutScrollBar, texturedFactorPageWithoutScrollBar};
// The two looks of a page with no scroll bar on which the header sensor cannot say "at the head". Rule 3 judges them
// all the same, because the page's structure, and not its header, answers where it is.
const FactorPageKind kFactorPageWithoutScrollBarOrHeader{
    captureFactorWithoutScrollBarOrHeader, texturedFactorPageWithoutScrollBarOrHeader};
const FactorPageKind kFactorPageWithHeaderBelowHead{
    captureFactorWithHeaderBelowHead, texturedFactorPageWithHeaderBelowHead};

// Captures the factor tab of `page`'s kind and, when `complete`, the other two tabs without scrolling, then holds
// that kind's different look at the head of the factor list for a dwell. Returns the judged frame's timestamp.
uint64 divergeOnCapturedFactorTab(ScraperHarness &h, const FactorPageKind &page, bool complete) {
    h.scraper.buildSession(record::Standard);
    uint64 at = page.capture(h, 0);
    if (complete) {
        at = captureWithoutScrolling(h, SkillPage, at + 100);
        at = captureWithoutScrolling(h, CampaignPage, at + 100);
    }
    REQUIRE(h.pages_ready.front() == static_cast<int>(FactorPage));
    REQUIRE(h.completions == (complete ? 1 : 0));
    return holdFactorDivergence(h, at + 100, /*nonce=*/2, page.diverged, record::Standard);
}

TEST_CASE("a captured factor tab whose frames show the same record keeps its session, complete or not") {
    // The tab is captured and reads at the head for the dwell, and its list changed from the witness's look. Rule 3
    // holds the witness, reads both frames, and keeps the session -- on a page with no scroll bar too, whose one
    // settled frame is its witness.
    const FactorPageKind *page = &kScrollableFactorPage;
    bool complete = false;
    SUBCASE("a scrollable factor page") {
        page = &kScrollableFactorPage;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    SUBCASE("a factor page with no scroll bar") {
        page = &kFactorPageWithoutScrollBar;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    SUBCASE("a factor page with no scroll bar whose header is not drawn") {
        page = &kFactorPageWithoutScrollBarOrHeader;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    SUBCASE("a factor page with no scroll bar whose header reads as scrolled") {
        page = &kFactorPageWithHeaderBelowHead;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    ScraperHarness h;
    const uint64 judged_at = divergeOnCapturedFactorTab(h, *page, complete);

    CHECK(h.framesRead() == std::vector<uint64>{kWitnessAt, judged_at});
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Same});
    CHECK(h.discards.empty());
    // Judged at the head, on every kind: the word the front end holds agrees with what Rule 3 acted on.
    CHECK(h.positionWords(FactorPage).back() == "at_top");
}

TEST_CASE("a captured factor tab whose frames show a different record is discarded by Rule 3, complete or not") {
    const FactorPageKind *page = &kScrollableFactorPage;
    bool complete = false;
    SUBCASE("a scrollable factor page") {
        page = &kScrollableFactorPage;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    SUBCASE("a factor page with no scroll bar") {
        page = &kFactorPageWithoutScrollBar;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    SUBCASE("a factor page with no scroll bar whose header is not drawn") {
        page = &kFactorPageWithoutScrollBarOrHeader;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    SUBCASE("a factor page with no scroll bar whose header reads as scrolled") {
        page = &kFactorPageWithHeaderBelowHead;
        SUBCASE("while the other tabs are still to be captured") {
            complete = false;
        }
        SUBCASE("after the whole session is captured") {
            complete = true;
        }
    }
    ScraperHarness h;
    h.factor_model_answer = [](const Frame &cell) { return cell.timestamp() > kWitnessAt ? 102 : 101; };
    const uint64 judged_at = divergeOnCapturedFactorTab(h, *page, complete);

    CHECK(h.framesRead() == std::vector<uint64>{kWitnessAt, judged_at});
    CHECK(
        h.verdictsStated()
        == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Different});
    REQUIRE(h.discards.size() == 1);
    CHECK(h.discards.front().completed == complete);
    // Stated before the discard it caused, as on a tab still being captured.
    REQUIRE(h.verdicts.size() == 1);
    CHECK(h.verdicts.front().second == 0);
}

TEST_CASE("a captured factor page with no scroll bar that stays at its head is not discarded, however long it stays") {
    // THE RESET THIS CLOSES. Such a page is captured on the frame it settles on, and the user has nowhere to scroll
    // it, so it stays at the head of its content for as long as it is displayed. While its latch installed no
    // witness, a rule that took "a captured tab at the head for the dwell" for a switch discarded it with nobody
    // having switched. Rule 3 watches it now, and an unchanged page nominates nothing, however many dwells pass.
    bool complete = false;
    SUBCASE("while the other tabs are still to be captured") {
        complete = false;
    }
    SUBCASE("after the whole session is captured") {
        complete = true;
    }
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);
    uint64 at = captureFactorWithoutScrollBar(h, 0);
    if (complete) {
        at = captureWithoutScrolling(h, SkillPage, at + 100);
        at = captureWithoutScrolling(h, CampaignPage, at + 100);
    }
    REQUIRE(h.completions == (complete ? 1 : 0));

    for (int i = 0; i < 4; i++) {
        h.scraper.update(
            factorPageWithoutScrollBar(at + 100 + static_cast<uint64>(i) * kPastDwell, /*nonce=*/2 + i),
            SceneState{FactorPage, record::Standard});
    }
    CHECK(h.discards.empty());
    CHECK(h.verdicts.empty());
    // The frames were read at the head, so "no discard" is the rules declining, not a sensor that saw nothing.
    CHECK(h.positionWords(FactorPage).back() == "at_top");
}

TEST_CASE("a frame of a scrollable factor page that shows neither its header nor its scroll bar is not taken for the head") {
    // THE OTHER SIDE OF "a page with no scroll bar is at its head": that is a fact about the TAB, decided when it was
    // built, and never about one frame. A page that does scroll can show a frame on which neither sensor finds
    // anything -- something drawn over the bar and the header, a transition -- and that frame may well be scrolled.
    // Taken for the head because this frame shows no scroll bar, it would be diffed against the witness, and a
    // captured session discarded on a frame nobody could place.
    ScraperHarness h;
    h.factor_model_answer = [](const Frame &cell) { return cell.timestamp() > kWitnessAt ? 102 : 101; };
    h.scraper.buildSession(record::Standard);
    const uint64 captured = captureFactorByScrolling(h, 0);
    REQUIRE(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});

    // A different list, on frames that draw neither the scroll bar nor the header.
    const FrameAt unplaceable = [](uint64 timestamp, int nonce) {
        return withContentTexture(noScrollBarFrameAt(timestamp, nonce), shippedScraperConfig().common, 0);
    };
    holdFactorDivergence(h, captured + 100, /*nonce=*/2, unplaceable, record::Standard);
    // Unresolved on the wire, and resolved "scrolled" by Rule 3's gate.
    CHECK(h.positionWords(FactorPage).back() == "unknown");
    CHECK(h.framesRead().empty());
    CHECK(h.verdicts.empty());
    CHECK(h.discards.empty());

    // The control: the same list with its scroll bar back, at the head, is read and discarded -- so the silence
    // above is the flush gate, and not frames Rule 3 would have let pass anyway.
    const uint64 judged_at =
        holdFactorDivergence(h, captured + 100 + 2 * kPastDwell, /*nonce=*/4, texturedLook, record::Standard);
    CHECK(h.framesRead() == std::vector<uint64>{kWitnessAt, judged_at});
    CHECK(
        h.verdictsStated()
        == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Different});
    CHECK(h.discards.size() == 1);
}

TEST_CASE("a factor page that has not settled holds no witness, and nothing reads or discards it") {
    // WHAT IS LEFT WITHOUT A WITNESS once every latch installs one: the factor tab before its head latch. On a page
    // with no scroll bar that is the stationary wait, during which the page already reads at the head of its
    // content. This pins the core's side of that window as it is: no probe, no reading, no verdict, no discard. It is
    // not a claim that the window is safe -- a switch made inside it goes undetected, and the witness installed when
    // the page settles is then the new record's.
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);
    uint64 at = captureWithoutScrolling(h, SkillPage, 0);
    at = captureWithoutScrolling(h, CampaignPage, at + 100);

    // Alternating between two lists, so no two consecutive frames match and the page never settles.
    for (int i = 0; i < 4; i++) {
        const uint64 timestamp = at + 100 + static_cast<uint64>(i) * kPastDwell;
        h.scraper.update(
            i % 2 == 0 ? factorPageWithoutScrollBar(timestamp, /*nonce=*/2 + i)
                       : texturedFactorPageWithoutScrollBar(timestamp, /*nonce=*/2 + i),
            SceneState{FactorPage, record::Standard});
    }
    CHECK(h.pages_ready == std::vector<int>{static_cast<int>(SkillPage), static_cast<int>(CampaignPage)});
    CHECK(h.probe_frames.empty());
    CHECK(h.framesRead().empty());
    CHECK(h.verdicts.empty());
    CHECK(h.discards.empty());
    // At the head the whole time, so the silence above is not a closed flush gate.
    CHECK(h.positionWords(FactorPage).back() == "at_top");
}

TEST_CASE("after completion, a switch made on another tab is judged by Rule 3 once the factor tab is shown") {
    // THE ONE SWITCH DETECTION LEFT AFTER COMPLETION, in miniature (golden player_standard_sequential switches this way
    // on real footage). The
    // session completes; the user switches on the campaign tab, which the game shows at its head, and stays there.
    // Nothing watches that tab, so nothing is discarded while it is shown. The new record's factor tab then opens at
    // its head over a different list, and Rule 3 -- whose witness still holds the old record's list -- reads both
    // frames and discards a session whose record had already gone out.
    ScraperHarness h;
    h.factor_model_answer = [](const Frame &cell) { return cell.timestamp() > kWitnessAt ? 102 : 101; };
    h.scraper.buildSession(record::Standard);
    const uint64 completed_at = completeSession(h, captureFactorByScrolling);
    REQUIRE(h.completions == 1);

    const uint64 first_top = completed_at + 100;
    for (int i = 0; i < 4; i++) {
        h.scraper.update(
            scrollBarFrameAt(first_top + static_cast<uint64>(i) * kPastDwell, /*exposed_rows=*/0, /*nonce=*/2 + i),
            SceneState{CampaignPage, record::Standard});
    }
    // The line that a rule taking "a captured tab at the head" for a switch turns red: without it this case would
    // pass whether or not such a rule existed, because Rule 3 then discards anyway.
    CHECK(h.discards.empty());
    CHECK(h.verdicts.empty());
    CHECK(h.positionWords(CampaignPage).back() == "at_top");

    const uint64 judged_at = holdFactorDivergence(h, first_top + 4 * kPastDwell, /*nonce=*/6, texturedLook, record::Standard);
    CHECK(h.framesRead() == std::vector<uint64>{kWitnessAt, judged_at});
    CHECK(
        h.verdictsStated()
        == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Different});
    REQUIRE(h.discards.size() == 1);
    CHECK(h.discards.front().completed == true);
    // Stated before the discard it caused.
    REQUIRE(h.verdicts.size() == 1);
    CHECK(h.verdicts.front().second == 0);
}

TEST_CASE("Rule 3's dwell does not resume across a frame of another tab") {
    // The same property from Rule 3's side, which a captured factor tab now needs: before, its dwell could be
    // left standing only on a tab still being captured, where leaving the tab rebuilt it and dropped the dwell.
    ScraperHarness h;
    h.scraper.buildSession(record::Standard);
    const uint64 completed_at = completeSession(h, captureFactorByScrolling);
    REQUIRE(h.completions == 1);

    const uint64 opened = completed_at + 100;
    h.scraper.update(texturedLook(opened, /*nonce=*/2), SceneState{FactorPage, record::Standard});
    // A campaign frame: a tab no rule watches, so the visit is nothing but a frame Rule 3 did not judge.
    h.scraper.update(noScrollBarFrameAt(opened + 10, /*nonce=*/3), SceneState{CampaignPage, record::Standard});
    h.scraper.update(texturedLook(opened + kPastDwell, /*nonce=*/4), SceneState{FactorPage, record::Standard});
    CHECK(h.framesRead().empty());
    CHECK(h.verdicts.empty());

    // The control: the dwell restarted on that frame, and a dwell later the frames are read.
    h.scraper.update(texturedLook(opened + 2 * kPastDwell, /*nonce=*/5), SceneState{FactorPage, record::Standard});
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Same});
    CHECK(h.discards.empty());
}

}  // namespace
}  // namespace uma::chara_detail
