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
#include <cmath>
#include <cstddef>
#include <filesystem>
#include <functional>
#include <limits>
#include <memory>
#include <optional>
#include <random>
#include <stdexcept>
#include <string>
#include <system_error>
#include <tuple>
#include <utility>
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

// Records the paths passed to the injected directory hooks (the same fake as test_scraping_box.cpp). The
// scraping directory is per-session and named after the record id, so this is also how a test learns the id
// the scraper generated for itself.
//
// It ALSO creates the directory for real, under a per-process root the harness removes when it goes away.
// Most cases here are built so nothing ever latches and no image is written, but a case that drives a tab into
// capturing deliberately -- which is the only way to observe the wait ending on the accepted path -- reaches
// PageScrapingBox::addScrollArea, and that writes a PNG. Recording the mkdir without performing it made that
// throw "failed to open image for write", which reads as a broken test rather than as the missing directory it
// is. The recording half is unchanged, so the identity assertions above still read the same list.
struct HookRecorder {
    std::vector<std::filesystem::path> made;
    std::vector<std::filesystem::path> removed;
    // Set to make every later mkdir fail the way a full disk or a denied directory does: the path goes to
    // `refused` instead of `made`, and the call throws what std::filesystem::create_directories throws.
    bool refuse = false;
    std::vector<std::filesystem::path> refused;
    // Set to make the mkdir of the directory with this name succeed and record as usual WITHOUT creating it, so
    // the session builds and every write into that tab fails the way a full disk or a revoked permission makes
    // it fail. Frame::save has no hook of its own, so this is the only seam that puts a failing fragment write
    // in reach of a case without touching production code. A tab's directory is created with its parents, so
    // silencing one tab still leaves the session's own directory there (the other two tabs make it).
    std::optional<std::filesystem::path> silent_stem;

    [[nodiscard]] io_util::DirectoryHooks hooks() {
        io_util::DirectoryHooks h;
        h.mkdir = [this](const std::filesystem::path &path) {
            if (refuse) {
                refused.push_back(path);
                throw std::filesystem::filesystem_error(
                    "refused by the test", path, std::make_error_code(std::errc::no_space_on_device));
            }
            made.push_back(path);
            if (silent_stem.has_value() && path.filename() == silent_stem.value()) {
                return;
            }
            std::filesystem::create_directories(path);
        };
        h.rmdir = [this](const std::filesystem::path &path) {
            removed.push_back(path);
            std::filesystem::remove_all(path);
        };
        return h;
    }
};

// A scratch directory unique to this PROCESS. ScraperHarness below writes real fragment files under it
// through injected mkdir hooks, so a path shared by two umacapture_tests processes running in the same
// directory would have them race the same location, and one would fail with "failed to open image for
// write". The random token separates processes the same way
// test_scraper_estimators.cpp's uniqueHarnessDir() does -- there is no pid helper in this tree, and this
// needs no platform header. A single token is enough here (no per-call counter): every case in this file
// shares the one root, and doctest runs them one at a time within a process.
std::filesystem::path uniqueScrapingRoot() {
    static const std::string token = std::to_string(std::random_device{}());
    return std::filesystem::temp_directory_path() / ("unit_test_scraping_root_" + token);
}
const std::filesystem::path kScrapingRoot = uniqueScrapingRoot();

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
    event_util::Connection<int, bool, std::optional<bool>> tab_awaiting_head =
        event_util::makeDirectConnection<int, bool, std::optional<bool>>();
    event_util::Connection<bool> factor_switch_armed = event_util::makeDirectConnection<bool>();
    event_util::Connection<int> page_ready = event_util::makeDirectConnection<int>();
    event_util::Connection<RecordInfo> completed = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<Frame, RecordInfo, recognizer_impl::SelfFactorWindow, bool> factor_probe =
        event_util::makeDirectConnection<Frame, RecordInfo, recognizer_impl::SelfFactorWindow, bool>();
    event_util::Connection<scraper_impl::FactorSwitchVerdict> factor_switch_judged =
        event_util::makeDirectConnection<scraper_impl::FactorSwitchVerdict>();
    event_util::Connection<RecordInfo> started = event_util::makeDirectConnection<RecordInfo>();
    event_util::Connection<DiscardedSession, RecordInfo> restarted =
        event_util::makeDirectConnection<DiscardedSession, RecordInfo>();
    event_util::Connection<RecordInfo> session_failed = event_util::makeDirectConnection<RecordInfo>();

    std::vector<DiscardedSession> discards;
    // The session each reset BEGAN, in the order of `discards`, and every session build() announced. What lets a
    // case state which id a new attempt is announced under.
    std::vector<RecordInfo> rebuilt;
    std::vector<RecordInfo> starts;
    // The identity every on_session_failed carried, in order: the id an attempt that could not be built ends
    // under. What lets a case state that a refused directory ends the attempt instead of crashing on it.
    std::vector<RecordInfo> failures;
    // The identity every on_completed carried, in order: the id a session's record finishes under.
    std::vector<RecordInfo> completed_infos;
    // Every verdict the character-switch rule stated, in order, each with how many sessions had been discarded when
    // it was stated. The stream NativeApi counts for the CLI's run summary; the second field is what lets a case
    // state that a resetting verdict is announced BEFORE the discard it causes.
    std::vector<std::pair<scraper_impl::FactorSwitchVerdict, std::size_t>> verdicts;
    // Every on_tab_refused message, in order, as {index, refused, reason}.
    std::vector<std::tuple<int, bool, std::string>> refusals;
    // Every on_tab_awaiting_head message, in order, as {index, awaiting}, and every on_scroll_ready index.
    // Recorded as SEQUENCES rather than as a final level because what the wait tests assert is that the level
    // is withdrawn on a path that emits no cue at all -- a final-state check could not tell "withdrawn" from
    // "never stated", and the missing cue is the other half of the pair.
    std::vector<std::pair<int, bool>> awaiting;
    // The `scroll_bar` each of those messages carried, in the same order (nullopt = the key was absent).
    std::vector<std::optional<bool>> awaiting_scroll_bars;
    std::vector<int> scroll_readies;
    // Every on_factor_switch_armed level, in order.
    std::vector<bool> armed;
    // Every on_scroll_updated message, in order, as {index, progress}. The ring reset a rebuild sends is one of them.
    std::vector<std::pair<int, double>> scroll_updates;
    // The messages whose ORDER a case asserts, as one sequence of words: "started", "restarted",
    // "page_ready:<tab>", "armed:<true|false>", "awaiting:<tab>:<true|false>". One recorder, because an order
    // between two streams cannot be read off two separate vectors.
    std::vector<std::string> sequence;

    // WHAT A FRONT END HOLDS after the messages so far: the last level per key, dropped when a session is announced
    // (a front end resets its copy on onCharaDetailStarted / onCharaDetailRestarted). Read by
    // witnessInvariantHolds after every frame this harness drives.
    struct FrontEndView {
        std::array<std::optional<bool>, kAllTabPages.size()> awaiting{};
        std::array<std::optional<bool>, kAllTabPages.size()> scroll_bar{};
        std::array<bool, kAllTabPages.size()> refused{};
        std::optional<bool> armed;
    };
    FrontEndView view;
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
    // Every frame the factor duplicate probe was armed with, in order. Kept as FRAMES rather than as a count
    // because "the probe fired" and "the probe was handed fragment #0's own pixels" are different claims, and
    // the offset exit is exactly where they come apart.
    std::vector<Frame> probe_frames;
    // The `cue_owed` carried by each of those probes, in the same order. A third claim again: the probe fired,
    // it carried fragment #0's pixels, and it said whether the exit that latched them owed the user a chime.
    // The front end reads exactly this to decide whether to sound the factor tab's cue.
    std::vector<bool> probe_cues;
    // The scroll area each of those probes carried. A fourth claim, and the one the recognizer cannot
    // recover on its own: it scans a LIVE frame, whose scroll area moves with the record layout, while its
    // own config only knows where the stitcher puts it. What is asserted is that the rect is the one THIS
    // session resolved (common vs friend_common), not a constant.
    std::vector<Rect<double>> probe_areas;
    // The factor limit each of those probes' windows carried. A fifth claim, with the same shape as the fourth:
    // the read stops at this many factors and the wire's below_threshold is stated against it, and it is sized to
    // the rows the SESSION'S layout shows, so what is asserted is that it is that layout's value and not one
    // layout's value for every session.
    std::vector<std::size_t> probe_limits;

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

    // `config` defaults to the shipped one; a case that needs one layout property out of the way passes an edited
    // copy.
    explicit ScraperHarness(const scraper_config::CharaDetailSceneScraperConfig &config = shippedScraperConfig())
        : scraper(
              opened,
              updated,
              closed,
              closed_before_completed,
              scroll_ready,
              scroll_updated,
              scroll_position,
              tab_refused,
              tab_awaiting_head,
              factor_switch_armed,
              page_ready,
              completed,
              factor_probe,
              factor_reader,
              factor_switch_judged,
              started,
              restarted,
              session_failed,
              config,
              kScrapingRoot,
              recorder.hooks()) {
        restarted->listen([this](const DiscardedSession &discarded, const RecordInfo &begun) {
            discards.push_back(discarded);
            rebuilt.push_back(begun);
            sequence.emplace_back("restarted");
            view = FrontEndView{};
        });
        started->listen([this](const RecordInfo &info) {
            starts.push_back(info);
            sequence.emplace_back("started");
            view = FrontEndView{};
        });
        session_failed->listen([this](const RecordInfo &info) {
            failures.push_back(info);
            sequence.emplace_back("session_failed");
        });
        factor_switch_judged->listen(
            [this](const scraper_impl::FactorSwitchVerdict verdict) { verdicts.emplace_back(verdict, discards.size()); });
        tab_refused->listen([this](int index, bool refused, const std::string &reason) {
            refusals.emplace_back(index, refused, reason);
            view.refused.at(static_cast<std::size_t>(index)) = refused;
        });
        tab_awaiting_head->listen([this](int index, bool value, const std::optional<bool> &scroll_bar) {
            awaiting.emplace_back(index, value);
            awaiting_scroll_bars.push_back(scroll_bar);
            sequence.push_back("awaiting:" + std::to_string(index) + (value ? ":true" : ":false"));
            view.awaiting.at(static_cast<std::size_t>(index)) = value;
            view.scroll_bar.at(static_cast<std::size_t>(index)) = scroll_bar;
        });
        factor_switch_armed->listen([this](bool value) {
            armed.push_back(value);
            sequence.emplace_back(value ? "armed:true" : "armed:false");
            view.armed = value;
        });
        scroll_ready->listen([this](int index) { scroll_readies.push_back(index); });
        scroll_updated->listen([this](int index, double progress) { scroll_updates.emplace_back(index, progress); });
        page_ready->listen([this](int index) {
            pages_ready.push_back(index);
            sequence.push_back("page_ready:" + std::to_string(index));
        });
        completed->listen([this](const RecordInfo &info) {
            completions++;
            completed_infos.push_back(info);
        });
        scroll_position->listen([this](int index, const std::string &word) { positions.emplace_back(index, word); });
        factor_probe->listen(
            [this](
                const Frame &frame, const RecordInfo &, const recognizer_impl::SelfFactorWindow &window, bool cue_owed) {
                probe_frames.push_back(frame);
                probe_cues.push_back(cue_owed);
                probe_areas.push_back(window.scroll_area);
                probe_limits.push_back(window.factor_limit);
            });
    }

    // Whatever the hooks created (see HookRecorder) goes away with the harness, so a case that captures a
    // fragment leaves nothing behind in the build directory.
    ~ScraperHarness() {
        std::error_code ignored;
        std::filesystem::remove_all(kScrapingRoot, ignored);
    }

    // THE ONE WAY THE CASES IN THIS FILE DRIVE A FRAME: the scraper's update, followed by the invariant every frame
    // must leave on the wire (witnessInvariantHolds). Checked after every frame of every case rather than in a case
    // of its own, so the Rule 3 cases, the no-scroll cases and the refusal cases all state it.
    void update(const Frame &frame, const SceneState &scene_state) {
        scraper.update(frame, scene_state);
        CHECK_MESSAGE(
            witnessInvariantHolds(view),
            "the factor tab is built, no longer awaits and is not refused, yet the wire does not say the switch rule "
            "is armed");
    }

    // A FACTOR TAB THAT IS BUILT, NO LONGER AWAITS AND IS NOT REFUSED HOLDS RULE 3'S WITNESS, as the wire states
    // it. This is the direction the front end depends on: it never shows a phase of the factor tab beside "no
    // switch possible". The converse does not hold and is not asked -- a factor page with no scroll bar is armed
    // from its content latch while it still awaits its completion.
    [[nodiscard]] static bool witnessInvariantHolds(const FrontEndView &state) {
        const auto factor = static_cast<std::size_t>(FactorPage);
        const bool built = state.scroll_bar[factor].has_value();
        const bool done_waiting = state.awaiting[factor] == std::optional<bool>(false);
        if (!built || !done_waiting || state.refused[factor]) {
            return true;
        }
        return state.armed == std::optional<bool>(true);
    }

    // The last level stated for `tab`, or nullopt when the wire has said nothing about it yet. The tests read
    // the level through this rather than counting messages, because the level is what a front end holds.
    [[nodiscard]] std::optional<bool> awaitingLevel(TabPage tab) const {
        std::optional<bool> level;
        for (const auto &[index, value] : awaiting) {
            if (index == static_cast<int>(tab)) {
                level = value;
            }
        }
        return level;
    }

    // Every awaiting level stated for `tab`, in order.
    [[nodiscard]] std::vector<bool> awaitingLevels(TabPage tab) const {
        std::vector<bool> levels;
        for (const auto &[index, value] : awaiting) {
            if (index == static_cast<int>(tab)) {
                levels.push_back(value);
            }
        }
        return levels;
    }

    // The `scroll_bar` of the last awaiting message for `tab`, as a word: "unstated" (no message yet), "absent"
    // (the key was omitted), "true" or "false". A word, because the three-way difference is the assertion.
    [[nodiscard]] std::string scrollBarWord(TabPage tab) const {
        std::string word = "unstated";
        for (std::size_t i = 0; i < awaiting.size(); i++) {
            if (awaiting[i].first == static_cast<int>(tab)) {
                const auto &value = awaiting_scroll_bars[i];
                word = !value.has_value() ? "absent" : (value.value() ? "true" : "false");
            }
        }
        return word;
    }

    // The last witness level stated, or nullopt when none was.
    [[nodiscard]] std::optional<bool> armedLevel() const {
        return armed.empty() ? std::nullopt : std::optional<bool>(armed.back());
    }

    // True when both words were recorded and the first `earlier` precedes the first `later`.
    [[nodiscard]] bool eventBefore(const std::string &earlier, const std::string &later) const {
        const auto a = std::find(sequence.begin(), sequence.end(), earlier);
        const auto b = std::find(sequence.begin(), sequence.end(), later);
        return a != sequence.end() && b != sequence.end() && a < b;
    }

    // The words recorded after the LAST occurrence of `word` (empty when it was never recorded).
    [[nodiscard]] std::vector<std::string> eventsAfterLast(const std::string &word) const {
        const auto last = std::find(sequence.rbegin(), sequence.rend(), word);
        if (last == sequence.rend()) {
            return {};
        }
        return {last.base(), sequence.end()};
    }

    // How many on_scroll_updated messages named `tab`.
    [[nodiscard]] std::size_t scrollUpdatesOf(TabPage tab) const {
        const auto names_tab = [tab](const auto &update) { return update.first == static_cast<int>(tab); };
        return static_cast<std::size_t>(std::count_if(scroll_updates.begin(), scroll_updates.end(), names_tab));
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
    h.scraper.build(SceneInfo{record::Standard});
    REQUIRE_FALSE(h.recorder.made.empty());
    const std::string discarded_id = h.sessionIdAt(0);
    const std::size_t made_before_reset = h.recorder.made.size();

    // A record type that persists past the dwell is a character switch: the layout changed, so the session
    // cannot continue. The first frame only opens the dwell window.
    h.update(solidFrameAt(0, kNoBanner), SceneState{FactorPage, record::FriendStandard});
    CHECK(h.discards.empty());
    h.update(solidFrameAt(kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard});

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
    // THE SAME TRAP, THE OTHER WAY ROUND. The reset also announces the attempt it began, and that announcement must
    // name the session it BUILT: a front end matches every later outcome against it, and naming the discarded one
    // would match the new attempt's record against the old attempt's id.
    REQUIRE(h.rebuilt.size() == 1);
    CHECK(h.rebuilt[0].record_id == rebuilt_id);
    CHECK(h.rebuilt[0].record_id != discarded_id);
    CHECK(h.rebuilt[0].record_type == record::FriendStandard);
    // A reset is announced as a restart only, never as a second start: the one start is the open's.
    CHECK(h.starts.size() == 1);
}

TEST_CASE("a session discarded before it completed says so") {
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(solidFrameAt(0, kNoBanner), SceneState{FactorPage, record::FriendStandard});
    h.update(solidFrameAt(kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard});

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
    h.scraper.build(SceneInfo{record::InheritanceOnly});
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

// The scroll-bar colours, and the two anti-aliased cap rows that decide an at-top reading. Deliberately the
// same five levels test_scraper_estimators.cpp paints: see the table and the per-constant "which edge does
// this guard" notes on kTrackCap there for the measured ranges, which extreme each level is, and which box
// edges these do NOT bound. Keeping the two files on the same levels is what makes this one a scraper-level
// re-run of the same reading rather than a second, differently calibrated synthetic. The boxes themselves
// come from the shipped config.
const Color kBarMargin{241, 241, 241};
const Color kBarTrack{210, 210, 210};
const Color kBarTrackCap{230, 230, 230};
const Color kBarThumbCap{226, 226, 226};
const Color kBarThumb{60, 60, 60};

void fill(cv::Mat mat, const Color &color) {
    mat.setTo(cv::Scalar(color.b(), color.g(), color.r()));
}

// THE FACTOR TAB'S HEAD, AS THIS FILE'S SCRAPER READS IT. The scraper judges the factor tab at its head when the
// thumb reads the head and, behind it, the banner search of ITS FactorRowReader -- the harness's, under
// readerScanConfig -- finds the banner at a row in [1, factorHeadLastRowOn(frame)] and the run found there
// contains the green sensor's first row (scraper_impl::factorHeadReading). readerScanConfig's background is a colour no other pixel
// here has, so a frame that paints nothing in it gives the banner search row 0 -- a cut banner, refused. A head
// frame therefore paints the rows above the banner in that background.
//
// kFactorHeadRow is where the harness paints the banner at the head of the list: inside the window with room on
// both sides (real 540 px footage puts it at row 8, too), so no case here rests on an edge of the window unless it
// says so.
constexpr int kFactorHeadRow = 8;
// The header's measured height at these capture widths.
constexpr int kFactorHeaderRows = 24;

// The last banner row the harness's scraper reads as the head on a frame of this size: its reader's banner
// search window, less the shipped reserve. Derived the way the judgment derives it, from the same two numbers.
int factorHeadLastRowOn(const Frame &frame) {
    const int search_rows = frame.anchor().scaleToPixels(readerScanConfig().vertical_banner_upper_gap);
    return scraper_impl::factorHeadLastRow(
        search_rows, shippedScraperConfig().factor_header.banner_window_reserve);
}

// `frame` with the green "因子" SECTION HEADER's top at `crop_row` of `layout`'s scroll area, `header_rows` tall,
// and the rows above it in the harness reader's background. Both are painted from the scroll area's left edge
// to the probe band's right end (band_end, 0.93 of the crop width): that covers the reader's banner column
// (0.10 of the width) and the green sensor's band, and stays clear of the scroll bar's scan line (0.9693), so
// the thumb reading -- `exposed_rows` -- is untouched and still decides c3 independently.
Frame withFactorHeaderAt(
    const Frame &frame,
    int crop_row,
    const scraper_config::SceneScraperConfig &layout = shippedScraperConfig().common,
    int header_rows = kFactorHeaderRows) {
    const auto &config = shippedScraperConfig();
    cv::Mat pixels = frame.data().clone();
    const Rect<int> band = frame.anchor().mapToFrame(layout.scroll_area_rect);
    // Solidly inside the configured range ({70,150,0}..{190,255,85}), so the row's green FRACTION is 1.0 over
    // the probe band and the threshold is not what is being tested here.
    const Color green{130, 200, 40};
    const int right = band.left() + static_cast<int>(std::lround(config.factor_header.band_end * band.width()));
    if (crop_row > 0) {
        fill(pixels(cv::Rect(band.left(), band.top(), right - band.left(), crop_row)),
             readerScanConfig().bg_color.min());
    }
    fill(pixels(cv::Rect(band.left(), band.top() + crop_row, right - band.left(), header_rows)), green);
    return Frame(pixels, frame.timestamp());
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
// which is the band itself. The title-bar banner is absent on every frame, so the base-frame catcher likewise
// never latches.
// [layout] is the shipped coordinate set the session under test resolved -- `common` for every record type
// but one, `friend_common` for a friend's full record, whose scroll area sits ~136 px lower (and whose tab
// bar sits ~133 px lower -- the two are separate measurements, see friendCommon in the builder). The
// bar has to be painted where THAT layout looks for it, or the frame is simply a bar-less one.
//
// This one draws NO factor header: see scrollBarFrameIn for the frame a factor tab at its head shows.
Frame bareScrollBarFrameIn(
    const scraper_config::SceneScraperConfig &layout, uint64 timestamp, int exposed_rows, int nonce) {
    cv::Mat pixels(960, 540, CV_8UC3, cv::Scalar(kNoBanner.b(), kNoBanner.g(), kNoBanner.r()));
    // Ask the frame itself where the config rect lands, rather than restating pixel coordinates that would
    // silently stop matching the shipped config.
    const Rect<int> band_rect = Frame(pixels, timestamp).anchor().mapToFrame(layout.scroll_bar_rect);
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

// The same frame with the factor header at the head of the list (kFactorHeadRow). This is what every factor-tab
// frame of this file shows unless a case says otherwise: a factor frame without it is not at the head of its
// content, whatever the thumb says. The header lies left of the scroll bar's scan line, so `exposed_rows` still
// decides the thumb's reading on its own.
Frame scrollBarFrameIn(
    const scraper_config::SceneScraperConfig &layout, uint64 timestamp, int exposed_rows, int nonce) {
    return withFactorHeaderAt(bareScrollBarFrameIn(layout, timestamp, exposed_rows, nonce), kFactorHeadRow, layout);
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
// The texture covers whatever header the frame carried; a caller that wants one paints it afterwards.
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

// A textured frame of a factor list at its head: the texture is the list, and the header sits above it at
// kFactorHeadRow, where it stays whatever `content_shift` is (the texture below it is what the offset estimator
// matches).
Frame scrollingBandFrameIn(
    const scraper_config::SceneScraperConfig &layout, uint64 timestamp, int content_shift, int exposed_rows, int nonce) {
    return withFactorHeaderAt(
        withContentTexture(bareScrollBarFrameIn(layout, timestamp, exposed_rows, nonce), layout, content_shift),
        kFactorHeadRow,
        layout);
}

Frame scrollingBandFrameAt(uint64 timestamp, int content_shift, int exposed_rows, int nonce) {
    return scrollingBandFrameIn(shippedScraperConfig().common, timestamp, content_shift, exposed_rows, nonce);
}

// A head-of-list frame ON WHICH THE HARNESS'S READER FINDS NO ROWS: the same texture region as
// scrollingBandFrameAt, filled instead with readerScanConfig's background colour, with a header only a few rows
// tall at the head row. The banner search finds the header and the judgment reads the frame at its head, but
// the first factor row is looked for below the header's end (vertical_banner_bottom_delta is 11 rows here), in
// the background, so the reading comes back empty. The scroll bar is untouched, so the frame is still flush at
// the top, and against a scroll-bar reference it is still a large pixel change.
Frame emptyReadingFrameAt(uint64 timestamp, int nonce) {
    const Frame bar = bareScrollBarFrameIn(shippedScraperConfig().common, timestamp, /*exposed_rows=*/0, nonce);
    cv::Mat pixels = bar.data().clone();
    const Rect<int> band_rect = bar.anchor().mapToFrame(shippedScraperConfig().common.scroll_area_rect);
    fill(pixels(cv::Rect(band_rect.left(), band_rect.top(), band_rect.width() * 9 / 10, band_rect.height())),
         readerScanConfig().bg_color.min());
    constexpr int kThinHeaderRows = 4;
    return withFactorHeaderAt(
        Frame(pixels, timestamp), kFactorHeadRow, shippedScraperConfig().common, kThinHeaderRows);
}

// The grey level scrollingBandFrameAt paints into the scroll area's first row below the header for a given
// shift. Used to tell WHICH frame the probe was armed with apart from "a probe happened".
int firstBandRow(const Frame &frame) {
    const Rect<int> band_rect = frame.anchor().mapToFrame(shippedScraperConfig().common.scroll_area_rect);
    return frame.data().at<cv::Vec3b>(band_rect.top() + kFactorHeadRow + kFactorHeaderRows, band_rect.left())[0];
}

// The same frame with NO SCROLL BAR AT ALL: the band is uniformly the near-white page margin, so the
// background run down the scan line never reaches a thumb and hasScrollbar answers false. That is the real
// shape of an inheritance-only record's skill tab, and it is what makes SceneScraper::build install the
// non-scrollable interpreter -- the one that is handed no scroll-ready sender. No factor header either.
Frame noScrollBarFrameAt(uint64 timestamp, int nonce) {
    cv::Mat pixels(960, 540, CV_8UC3, cv::Scalar(kNoBanner.b(), kNoBanner.g(), kNoBanner.r()));
    const Rect<int> band_rect =
        Frame(pixels, timestamp).anchor().mapToFrame(shippedScraperConfig().common.scroll_bar_rect);
    fill(pixels(cv::Rect(0, 0, pixels.cols, band_rect.top())),
         Color(static_cast<int>(nonce % 2) * 120 + 10, 0, 0));
    fill(pixels(cv::Rect(band_rect.left(), band_rect.top(), band_rect.width(), band_rect.height())), kBarMargin);
    return Frame(pixels, timestamp);
}

// A scroll-bar frame (thumb at `exposed_rows`) whose header is at `crop_row` instead of the head row. Painted on
// the bare frame, so `crop_row` is the only header there is.
Frame factorHeaderFrameAt(uint64 timestamp, int exposed_rows, int nonce, int crop_row) {
    return withFactorHeaderAt(
        bareScrollBarFrameIn(shippedScraperConfig().common, timestamp, exposed_rows, nonce), crop_row);
}

// Past the shipped stationary_time_threshold, so two frames this far apart latch. Read from the config rather
// than restated, for the same reason the rect above is.
const uint64 kPastStationary = shippedScraperConfig().common.stationary_time_threshold + 100;

TEST_CASE("a tab whose capture would not start at the head of the list is refused, on the wire") {
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    // A settled screen that is ALREADY scrolled by one tip pixel. Nothing moves, so the pre-existing
    // premature-scroll branch cannot see it: the catcher latches, and without this mechanism the cue would
    // sound over a capture whose head is missing.
    h.update(scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    CHECK(h.refusals.empty());
    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{FactorPage, record::Standard});

    REQUIRE(h.refusals.size() == 1);
    CHECK(std::get<0>(h.refusals.front()) == static_cast<int>(FactorPage));
    CHECK(std::get<1>(h.refusals.front()) == true);
    CHECK(std::get<2>(h.refusals.front()) == "scrolled");
    // The session is NOT failed: the other tabs are still capturable and this one is retryable.
    CHECK(h.discards.empty());
}

TEST_CASE("the factor tab's head-of-content word is checked by the header once the thumb reads the head") {
    // THE DEFECT THIS EXISTS FOR, and it is a defect of SHAPE rather than of arithmetic. The fine sensor used
    // to be a difference against a reference row captured at the factor probe. Nothing captures that reference
    // until a tab has latched its fragment #0, so on every frame before then the fine sensor had nothing to say
    // and the word on the wire came from the scroll thumb alone -- on the one tab that carries a finer landmark,
    // during the one stretch where the user is most likely to have nudged the list. The second subcase is a
    // frame the thumb reads as a genuine head and the header reads as displaced, which is exactly the case a
    // reference-row comparison cannot reach: it is the coarse sensor's own blind spot (kExposedTrackTopMargin puts it at
    // tens of content pixels on a short thumb), and no reference exists yet to resolve it.
    //
    // The header is asked only behind a thumb at the head (scraper_impl::factorHeadReading), so the words below
    // are the words of two frames: the first is judged before the tab is built and has no thumb reading, which
    // is "unknown" on this tab as on every other; the second has a thumb, and a thumb at the head goes on to
    // the header. Both frames come before any latch.
    //
    // Asserted on the WIRE rather than on the verdict function, because what changed is which frames the
    // composition can answer at all -- a unit test of the verdict cannot see a call site that never made it.
    const auto &config = shippedScraperConfig();

    // The words of a session's first two frames, both showing the header at `row` under a thumb at the head.
    const auto firstWords = [](int row) {
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        h.update(factorHeaderFrameAt(0, 0, /*nonce=*/0, row), SceneState{FactorPage, record::Standard});
        h.update(factorHeaderFrameAt(1, 0, /*nonce=*/1, row), SceneState{FactorPage, record::Standard});
        for (const auto &[index, word] : h.positions) {
            CHECK(index == static_cast<int>(FactorPage));
        }
        return h.positionWords(FactorPage);
    };
    const int last = factorHeadLastRowOn(scrollBarFrameAt(0, 0, 0));
    const std::vector<std::string> kHead{"unknown", "at_top"};

    SUBCASE("a banner anywhere in the window reads at_top, before anything has latched") {
        CHECK(firstWords(kFactorHeadRow) == kHead);
        CHECK(firstWords(1) == kHead);
        CHECK(firstWords(last) == kHead);
        // A displacement a one-capture-pixel window would refuse: two rows above the head row.
        CHECK(firstWords(kFactorHeadRow - 2) == kHead);
    }

    SUBCASE("a banner cut by the scroll area's top, or past the window, reads scrolled while the thumb says head") {
        // exposed_rows = 0 is a genuine head to the thumb once it can read, so on the second frame the only
        // thing that can produce "scrolled" here is the banner's own position.
        for (const int row : {0, last + 1}) {
            CAPTURE(row);
            CHECK(firstWords(row) == std::vector<std::string>{"unknown", "scrolled"});
        }
    }

    SUBCASE("a factor frame showing no banner reads scrolled under a thumb at the head") {
        // UNDER A THUMB AT THE HEAD, THE HEADER DOES NOT DEFER. A frame on which the banner search finds nothing
        // in its window is a frame whose record would not be read from its banner, so it is not at the head --
        // whether the content moved or something covers the banner (that case is not special-cased; see
        // factorHeadReading). Two frames: the first has no thumb reading and says "unknown", as every tab's
        // first frame does; the second has a thumb that reads a genuine head, and the word says scrolled.
        // Two looks: no header drawn (the banner search's first non-background row is row 0 under this harness's
        // reader), and a scroll area the banner search finds nothing in at all.
        using Look = std::function<Frame(uint64, int)>;
        const Look no_header = [&config](uint64 timestamp, int nonce) {
            return bareScrollBarFrameIn(config.common, timestamp, /*exposed_rows=*/0, nonce);
        };
        const Look nothing_found = [&config](uint64 timestamp, int nonce) {
            const Frame bar = bareScrollBarFrameIn(config.common, timestamp, /*exposed_rows=*/0, nonce);
            cv::Mat pixels = bar.data().clone();
            const Rect<int> band = bar.anchor().mapToFrame(config.common.scroll_area_rect);
            fill(pixels(cv::Rect(band.left(), band.top(), band.width() * 9 / 10, band.height())),
                 readerScanConfig().bg_color.min());
            return Frame(pixels, timestamp);
        };
        const auto wordsOn = [](const Look &look, bool banner_found) {
            ScraperHarness h;
            h.scraper.build(SceneInfo{record::Standard});
            const auto banner =
                h.factor_reader->findBanner(look(0, 0), shippedScraperConfig().common.scroll_area_rect);
            REQUIRE(banner.has_value() == banner_found);
            h.update(look(0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
            h.update(look(1, /*nonce=*/1), SceneState{FactorPage, record::Standard});
            return h.positionWords(FactorPage);
        };
        CHECK(wordsOn(no_header, true) == std::vector<std::string>{"unknown", "scrolled"});
        CHECK(wordsOn(nothing_found, false) == std::vector<std::string>{"unknown", "scrolled"});
    }

    SUBCASE("a thumb that reads scrolled refuses a banner at the head row") {
        // The thumb, on the wire: the banner conditions hold (the head row), the thumb shows one tip pixel of
        // track. The first frame has no thumb reading and is unknown; the header's head row does not change that.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        h.update(
            scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{FactorPage, record::Standard});
        h.update(
            scrollBarFrameAt(1, /*exposed_rows=*/1, /*nonce=*/1), SceneState{FactorPage, record::Standard});
        CHECK(h.positionWords(FactorPage) == std::vector<std::string>{"unknown", "scrolled"});
    }
}

TEST_CASE("a tab at the head of the list is not refused") {
    // The negative control. Without it, "refused" would be indistinguishable from "this synthetic bar refuses
    // everything", which is exactly how a threshold that is too tight would look.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{FactorPage, record::Standard});

    CHECK(h.refusals.empty());
}

// --- fragment #0 is accepted by the same judgment every other consumer asks ---------------------------------
//
// ScrollableScrapingInterpreter::startScrolling judging the frame it latches by the scroll thumb alone would leave
// the factor tab's banner judgment out of the one decision that decides what gets captured, so a factor list
// pre-scrolled by less than one thumb pixel's worth of content would be latched as fragment #0 and read, silently,
// from the wrong rows. makeTabScraper therefore hands every tab's interpreter
// CharaDetailSceneScraper::topOfContent bound to the tab; these cases pin that on the wire (the refusal, the
// probe), for the factor tab and for the two tabs that must keep judging by the thumb.

// The thumb's reading of `frame` under the shipped common layout, as topOfContent's coarse arm takes it.
scraper_impl::TopOfContent thumbReadingOf(const Frame &frame) {
    const auto &layout = shippedScraperConfig().common;
    const scraper_impl::ScrollBarOffsetEstimator thumb(
        layout.scroll_bar_bg_color,
        layout.scroll_bar_scan_line,
        layout.scroll_bar_margin_color,
        layout.scroll_bar_track_color,
        layout.viewport,
        layout.cap_offset,
        layout.scroll_bar_thumb_probe);
    return CharaDetailSceneScraper::thumbTopOfContent(thumb.topMargin(frame.copy(layout.scroll_bar_rect)));
}

// The row the harness's reader finds the banner's top at, on the common layout's scroll area.
std::optional<int> bannerRowOf(const ScraperHarness &h, const Frame &frame) {
    const auto hit = h.factor_reader->findBanner(frame, shippedScraperConfig().common.scroll_area_rect);
    return hit.has_value() ? std::optional<int>(hit->row) : std::nullopt;
}

// A factor list at its head, then scrolled down by `scroll` content pixels: the content texture moves up by
// `scroll`, and so does the header, which the scroll area's top edge cuts once it passes the head row (only the
// rows still below the edge are drawn, from row 0). The thumb is drawn independently at `exposed_rows`: on a long
// list a thumb is short, and one thumb pixel is worth up to ~27 content px (see kExposedTrackTopMargin), so a
// scroll of that size still shows exposed_rows == 0. This harness does not model that ratio geometrically -- it
// states its outcome, a thumb that reads the head while the content has moved, which is the case the thumb
// cannot catch.
Frame prescrolledFactorFrame(uint64 timestamp, int scroll, int exposed_rows, int nonce) {
    const auto &layout = shippedScraperConfig().common;
    const Frame textured =
        withContentTexture(bareScrollBarFrameIn(layout, timestamp, exposed_rows, nonce), layout, scroll);
    const int header_top = kFactorHeadRow - scroll;
    if (header_top >= 0) {
        return withFactorHeaderAt(textured, header_top, layout);
    }
    return withFactorHeaderAt(textured, 0, layout, std::max(kFactorHeaderRows + header_top, 1));
}

using RefusalLog = std::vector<std::tuple<int, bool, std::string>>;

RefusalLog refusedAs(TabPage tab, const std::string &reason) {
    return {{static_cast<int>(tab), true, reason}};
}

TEST_CASE("the factor tab refuses a fragment #0 whose banner is cut at the top, although the thumb reads the head") {
    // The factor tab's fragment #0 is decided by the thumb when the thumb is not at its head, and by the banner
    // when it is. The thumb is at its head on every frame here (exposed_rows 0); only the banner row differs, so
    // the banner is what decides. Row 0 is a banner cut by the scroll area's top edge; row 1 is the first row the
    // window accepts, the control that keeps "refused" from meaning "this harness refuses everything".
    const auto capture = [](ScraperHarness &h, int banner_row) {
        h.scraper.build(SceneInfo{record::Standard});
        const Frame first = factorHeaderFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0, banner_row);
        REQUIRE(thumbReadingOf(first) == scraper_impl::TopOfContent::AtTop);
        REQUIRE(bannerRowOf(h, first) == std::optional<int>(banner_row));
        h.update(first, SceneState{FactorPage, record::Standard});
        h.update(
            factorHeaderFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1, banner_row),
            SceneState{FactorPage, record::Standard});
        // The wait is over either way -- latched or refused -- so the stationary exit really was taken.
        REQUIRE(h.awaitingLevel(FactorPage) == std::optional<bool>(false));
    };

    SUBCASE("row 1 is latched") {
        ScraperHarness h;
        capture(h, 1);
        CHECK(h.refusals.empty());
        REQUIRE(h.probe_frames.size() == 1);
        CHECK(h.probe_frames.front().timestamp() == kPastStationary);
    }

    SUBCASE("row 0 is refused as scrolled, and nothing is latched") {
        ScraperHarness h;
        capture(h, 0);
        CHECK(h.refusals == refusedAs(FactorPage, "scrolled"));
        CHECK(h.probe_frames.empty());
        CHECK(h.discards.empty());
    }
}

TEST_CASE("a long factor list pre-scrolled by 24 to 27 px, which its thumb cannot show, is refused on both exits") {
    // The failure this wiring exists for: on the friend max-rental list a thumb pixel is worth ~27 content px, so
    // a pre-scroll of 24..27 px reads as the head to the thumb, and, judged by the thumb alone, fragment #0 would be
    // latched and read from the wrong rows with no warning. Each pre-scroll is checked against both halves of its premise first -- the
    // thumb reads the head, the banner is cut -- so the refusal cannot come from anything else.
    for (const int scroll : {24, 25, 26, 27}) {
        CAPTURE(scroll);
        {
            // The stationary exit.
            ScraperHarness h;
            h.scraper.build(SceneInfo{record::Standard});
            const Frame first = prescrolledFactorFrame(0, scroll, /*exposed_rows=*/0, /*nonce=*/0);
            REQUIRE(thumbReadingOf(first) == scraper_impl::TopOfContent::AtTop);
            REQUIRE(bannerRowOf(h, first) == std::optional<int>(0));
            h.update(first, SceneState{FactorPage, record::Standard});
            h.update(
                prescrolledFactorFrame(kPastStationary, scroll, /*exposed_rows=*/0, /*nonce=*/1),
                SceneState{FactorPage, record::Standard});
            CHECK(h.refusals == refusedAs(FactorPage, "scrolled"));
            CHECK(h.probe_frames.empty());
        }
        {
            // The motion exit: the user keeps scrolling before anything settles, so the offset exit latches the
            // first, pre-scrolled frame, several updates old.
            ScraperHarness h;
            h.scraper.build(SceneInfo{record::Standard});
            h.update(
                prescrolledFactorFrame(0, scroll, /*exposed_rows=*/0, /*nonce=*/0),
                SceneState{FactorPage, record::Standard});
            REQUIRE(h.refusals.empty());
            REQUIRE(h.awaitingLevel(FactorPage) == std::optional<bool>(true));
            h.update(
                prescrolledFactorFrame(50, scroll + 10, /*exposed_rows=*/0, /*nonce=*/1),
                SceneState{FactorPage, record::Standard});
            CHECK(h.refusals == refusedAs(FactorPage, "scrolled"));
            CHECK(h.probe_frames.empty());
            CHECK(h.scroll_readies.empty());
        }
    }
}

TEST_CASE("the pre-scroll frames are latched when they are at the head, on both exits") {
    // The controls for the case above, on the same frame builder. Stationary: no pre-scroll. Motion: no pre-scroll
    // on the latched frame while the CURRENT frame is already scrolled past the head (its banner is cut) -- so this
    // is also what fails if acceptance judged "now" rather than the frame it latches.
    ScraperHarness still;
    still.scraper.build(SceneInfo{record::Standard});
    still.update(prescrolledFactorFrame(0, 0, 0, 0), SceneState{FactorPage, record::Standard});
    still.update(prescrolledFactorFrame(kPastStationary, 0, 0, 1), SceneState{FactorPage, record::Standard});
    CHECK(still.refusals.empty());
    CHECK(still.probe_frames.size() == 1);

    ScraperHarness moving;
    moving.scraper.build(SceneInfo{record::Standard});
    moving.update(prescrolledFactorFrame(0, 0, 0, 0), SceneState{FactorPage, record::Standard});
    const Frame current = prescrolledFactorFrame(50, 10, 0, 1);
    REQUIRE(bannerRowOf(moving, current) == std::optional<int>(0));
    moving.update(current, SceneState{FactorPage, record::Standard});
    CHECK(moving.refusals.empty());
    REQUIRE(moving.probe_frames.size() == 1);
    CHECK(moving.probe_frames.front().timestamp() == 0);
    CHECK(moving.scroll_readies.empty());
}

TEST_CASE("the skill and campaign tabs still accept fragment #0 by the thumb alone") {
    // Fragment #0 acceptance by the thumb alone on the bannerless tabs. These tabs have no banner, and their downstream tolerance is unmeasured, so the wiring must not change
    // what they accept. The first two looks are the ones a banner-reading acceptance would decide differently: a
    // frame with no factor header at all, and one whose "header" is cut at row 0.
    struct Look {
        const char *name;
        std::function<Frame(uint64, int)> frame;
        std::optional<std::string> refusal;  // nullopt: latched
    };
    const std::vector<Look> looks{
        {"no header, thumb at the head",
         [](uint64 t, int n) { return bareScrollBarFrameIn(shippedScraperConfig().common, t, 0, n); },
         std::nullopt},
        {"a header cut at row 0, thumb at the head",
         [](uint64 t, int n) { return factorHeaderFrameAt(t, 0, n, 0); },
         std::nullopt},
        {"a header at the head row, thumb one tip pixel down",
         [](uint64 t, int n) { return scrollBarFrameAt(t, 1, n); },
         std::string("scrolled")},
    };
    for (const TabPage tab : {SkillPage, CampaignPage}) {
        CAPTURE(static_cast<int>(tab));
        for (const auto &look : looks) {
            CAPTURE(look.name);
            ScraperHarness h;
            h.scraper.build(SceneInfo{record::Standard});
            h.update(look.frame(0, 0), SceneState{tab, record::Standard});
            h.update(look.frame(kPastStationary, 1), SceneState{tab, record::Standard});
            REQUIRE(h.awaitingLevel(tab) == std::optional<bool>(false));
            if (look.refusal.has_value()) {
                CHECK(h.refusals == refusedAs(tab, look.refusal.value()));
                CHECK(h.scroll_readies.empty());
            } else {
                CHECK(h.refusals.empty());
                CHECK(h.scroll_readies == std::vector<int>{static_cast<int>(tab)});
            }
        }

        // A thumb that vanishes before the latch: the reading reaches the refusal unresolved, so
        // kMissingReadingIsScrolled refuses it and the reason still says the thumb could not be read. The first
        // frame builds the tab with a scroll bar.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        h.update(scrollBarFrameAt(0, 0, 0), SceneState{tab, record::Standard});
        h.update(noScrollBarFrameAt(kPastStationary, 1), SceneState{tab, record::Standard});
        h.update(noScrollBarFrameAt(2 * kPastStationary, 1), SceneState{tab, record::Standard});
        CHECK(h.refusals == refusedAs(tab, "unknown"));
    }
}

TEST_CASE("switching away from a refused tab rebuilds it and withdraws the refusal") {
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    REQUIRE(h.refusals.size() == 1);

    // Leaving the refused tab must discard it. A refused tab has never set is_scrolling, so the switch
    // handler's `started()` test alone would leave it in place: the user would come back to the same refused
    // scraper, the tab would never complete, and the notice would never be withdrawn.
    h.update(
        scrollBarFrameAt(2 * kPastStationary, /*exposed_rows=*/1, /*nonce=*/2),
        SceneState{CampaignPage, record::Standard});

    REQUIRE(h.refusals.size() == 2);
    CHECK(std::get<0>(h.refusals.back()) == static_cast<int>(FactorPage));
    CHECK(std::get<1>(h.refusals.back()) == false);
    // The withdrawal travels on the same message, so a front end holding one value per tab needs no second
    // type; an empty reason is what "not refused" carries.
    CHECK(std::get<2>(h.refusals.back()).empty());
}

// --- "do not scroll yet" is a level this core states, not the absence of the cue --------------------------
//
// THE FAILURE THESE GUARD AGAINST: a front end deriving "the user must not scroll yet" from the fact that no
// scroll-ready has arrived for the displayed tab. The cue is an ANNOUNCEMENT, and this core reaches "the
// head is latched, scrolling may begin" by paths that announce nothing:
//
//   * ScrollableScrapingInterpreter::updateBefore's OFFSET exit, which begins capture without a stationary
//     frame ("didn't get a stationary image, so won't send a ready") -- measured on real footage at 1 of 63
//     tab captures;
//   * a REFUSED tab, where startScrolling returns false and the cue is deliberately withheld;
//   * NonScrollableScrapingInterpreter, which is not given a cue sender at all.
//
// On every one of those such a card says 「まだスクロールしないでください」, in a caution colour, for as long as
// the tab is displayed -- over a capture that is proceeding normally. A page with no scroll bar does still have
// a wait -- it holds until the tab is complete -- but it is not a wait for a cue, and the level says which kind of
// page it is (`scroll_bar`) so the front end can word it without mentioning scrolling.
//
// WHY THESE ARE HERE AND NOT IN DART. Every Dart test in this area hand-builds the message it feeds to the
// handler, so it can only ever assert what Dart does with a message it was given; a core that stopped sending
// this level, or never sent it on one of the paths above, leaves the whole Dart suite green. These drive the
// real scraper and read what it actually puts on the wire.
//
// WHAT THESE PARTICULAR CASES DO NOT REACH: the offset exit itself. For the AWAITING-HEAD level that is
// covered by construction -- ScrollableScrapingInterpreter::awaitingHead reads is_scrolling, which is what
// that exit sets -- and empirically on the clip that exhibits it. That equivalence is about awaitingHead and
// about nothing else: it does NOT extend to anything keyed to the cue, which that exit never sends. The probe
// case further down drives the offset exit for real (scrollingBandFrameAt), because for the probe the two
// exits are not equivalent and prose could not stand in for a case.

TEST_CASE("a tab states that it is awaiting its head, and withdraws that when capture begins") {
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{SkillPage, record::Standard});

    // The level is stated for EVERY tab on the first frame, not just the displayed one: a front end holding one
    // value per tab would otherwise have to assume the other two, which is the assumption this message exists
    // to remove.
    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(true));
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));
    CHECK(h.awaitingLevel(CampaignPage) == std::optional<bool>(true));
    CHECK(h.scroll_readies.empty());
    // The page's structure rides on the same first-frame statement: the tab that was built says it has a scroll
    // bar, and the two that were not say nothing about it (the key is absent, not false).
    CHECK(h.scrollBarWord(SkillPage) == "true");
    CHECK(h.scrollBarWord(FactorPage) == "absent");
    CHECK(h.scrollBarWord(CampaignPage) == "absent");

    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{SkillPage, record::Standard});

    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(false));
    // The control that makes the line above mean something: the level is per tab, so the two tabs the user has
    // not looked at are still waiting.
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));
    CHECK(h.awaitingLevel(CampaignPage) == std::optional<bool>(true));
    // This is the LATCHED exit, so the cue does sound here -- the positive control for the two cases below,
    // where the level moves and the cue does not.
    CHECK(h.scroll_readies == std::vector<int>{static_cast<int>(SkillPage)});
}

TEST_CASE("a refused tab stops awaiting its head, with no cue on the wire at all") {
    // A path where the two facts come apart. startScrolling refuses, so it returns false and updateBefore never
    // sends the cue; the wait is nonetheless over, because nothing on this interpreter can end it any more.
    // Read off the cue, this tab would have been "still settling" until the user left it.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{SkillPage, record::Standard});
    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(true));

    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{SkillPage, record::Standard});

    REQUIRE(h.refusals.size() == 1);
    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(false));
    CHECK(h.scroll_readies.empty());
}

TEST_CASE("a tab with no scroll bar awaits until it completes, states it has no scroll bar, and owes no cue") {
    // NonScrollableScrapingInterpreter is constructed without a scroll-ready sender -- there is no line of code
    // that could ever announce this tab, and the list fits on one screen so there is nothing to scroll past. The
    // wait is real all the same: the core needs the page to hold still until the tab is complete. What the
    // front end must not do is word that wait as one for a scroll cue, and `scroll_bar == false` is what tells it
    // so. Real shape: the skill tab of an inheritance-only record.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::InheritanceOnly});

    h.update(noScrollBarFrameAt(0, /*nonce=*/0), SceneState{SkillPage, record::InheritanceOnly});

    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(true));
    CHECK(h.scrollBarWord(SkillPage) == "false");
    CHECK(h.pages_ready.empty());
    // The control: the same frame leaves the two tabs it did not build waiting with no structure stated, so the
    // answers above are this tab's own and not something the walk says about every index.
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));
    CHECK(h.scrollBarWord(FactorPage) == "absent");
    CHECK(h.awaitingLevel(CampaignPage) == std::optional<bool>(true));

    // The same pixels past the stationary threshold: the content and the tab button both settle, and the tab
    // completes on this frame.
    h.update(noScrollBarFrameAt(kPastStationary, /*nonce=*/0), SceneState{SkillPage, record::InheritanceOnly});

    CHECK(h.pages_ready == std::vector<int>{static_cast<int>(SkillPage)});
    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(false));
    CHECK(h.scrollBarWord(SkillPage) == "false");
    // The completion reaches the wire BEFORE the wait is withdrawn, so a front end goes from the wait straight to
    // "this tab is complete" with no state in between.
    CHECK(h.eventBefore("page_ready:0", "awaiting:0:false"));
    CHECK(h.scroll_readies.empty());
}

TEST_CASE("leaving a tab with no scroll bar before it latched restates its wait with its structure withdrawn") {
    // The rebuild replaces the interpreter, so nothing establishes the page's structure until the tab is shown
    // again. The level stays true across the rebuild; only the structure changes, and that change is an edge.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(noScrollBarFrameAt(0, /*nonce=*/0), SceneState{SkillPage, record::Standard});
    REQUIRE(h.scrollBarWord(SkillPage) == "false");

    h.update(noScrollBarFrameAt(kPastStationary, /*nonce=*/1), SceneState{CampaignPage, record::Standard});

    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(true));
    CHECK(h.scrollBarWord(SkillPage) == "absent");
    // Two statements, both waiting: the first frame's {awaiting, no scroll bar}, then the rebuild's {awaiting, absent}.
    CHECK(h.awaitingLevels(SkillPage) == std::vector<bool>{true, true});
}

TEST_CASE("on a page with a scroll bar the witness is stated in the frame the wait ends, ahead of it, on both exits") {
    SUBCASE("a latch on another tab arms nothing") {
        // The control: the witness is the factor tab's, so another tab's latch leaves the level where it was.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{SkillPage, record::Standard});
        h.update(
            scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{SkillPage, record::Standard});
        REQUIRE(h.awaitingLevel(SkillPage) == std::optional<bool>(false));
        CHECK(h.armed == std::vector<bool>{false});
    }

    SUBCASE("the stationary exit") {
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
        CHECK(h.armedLevel() == std::optional<bool>(false));
        CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));

        h.update(
            scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{FactorPage, record::Standard});
        CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(false));
        CHECK(h.armedLevel() == std::optional<bool>(true));
        CHECK(h.eventBefore("armed:true", "awaiting:1:false"));
    }

    SUBCASE("the motion exit") {
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        h.update(
            scrollingBandFrameAt(0, /*content_shift=*/0, /*exposed_rows=*/0, /*nonce=*/0),
            SceneState{FactorPage, record::Standard});
        CHECK(h.armedLevel() == std::optional<bool>(false));

        h.update(
            scrollingBandFrameAt(50, /*content_shift=*/10, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{FactorPage, record::Standard});
        // The exit is identified rather than assumed: the wait ended, nothing was refused, and the latched frame
        // is the first one (the motion exit latches initial_descriptor).
        REQUIRE(h.refusals.empty());
        REQUIRE(h.probe_frames.size() == 1);
        REQUIRE(h.probe_frames.front().timestamp() == 0);
        CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(false));
        CHECK(h.armedLevel() == std::optional<bool>(true));
        CHECK(h.eventBefore("armed:true", "awaiting:1:false"));
    }
}

TEST_CASE("leaving a factor tab that latched but did not complete withdraws the witness") {
    // The rebuild drops the witness together with the capture it belonged to. Left standing on the wire, the front
    // end would offer a switch the next time the factor tab is shown, before the fresh interpreter has latched
    // anything for the rule to compare with.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});
    h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    REQUIRE(h.armedLevel() == std::optional<bool>(true));
    REQUIRE(h.pages_ready.empty());

    h.update(
        scrollBarFrameAt(2 * kPastStationary, /*exposed_rows=*/0, /*nonce=*/2),
        SceneState{SkillPage, record::Standard});

    CHECK(h.armed == std::vector<bool>{false, true, false});
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));
    CHECK(h.scrollBarWord(FactorPage) == "absent");
}

TEST_CASE("a reset restates the witness on the next session's first frame") {
    // The memory goes back to "never stated", not to false, so the new session says it has no witness instead of
    // leaving the front end to assume it reset its own copy the same way.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});
    h.update(solidFrameAt(0, kNoBanner), SceneState{FactorPage, record::FriendStandard});
    REQUIRE(h.armed == std::vector<bool>{false});
    h.update(solidFrameAt(kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard});
    REQUIRE(h.discards.size() == 1);

    h.update(solidFrameAt(2 * kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard});

    CHECK(h.armed == std::vector<bool>{false, false});
    const auto after_reset = h.eventsAfterLast("restarted");
    CHECK(std::find(after_reset.begin(), after_reset.end(), "armed:false") != after_reset.end());
}

TEST_CASE("the witness invariant check sees a built, finished, unrefused factor tab without a witness") {
    // The positive control for the check every frame of this file runs: without it, a check that could never fail
    // would pass every case.
    ScraperHarness::FrontEndView view;
    const auto factor = static_cast<std::size_t>(FactorPage);
    view.scroll_bar[factor] = true;
    view.awaiting[factor] = false;
    view.armed = false;
    CHECK_FALSE(ScraperHarness::witnessInvariantHolds(view));
    view.armed = true;
    CHECK(ScraperHarness::witnessInvariantHolds(view));
    // The three exemptions.
    view.armed = false;
    view.refused[factor] = true;
    CHECK(ScraperHarness::witnessInvariantHolds(view));
    view.refused[factor] = false;
    view.awaiting[factor] = true;
    CHECK(ScraperHarness::witnessInvariantHolds(view));
    view.awaiting[factor] = false;
    view.scroll_bar[factor] = std::nullopt;
    CHECK(ScraperHarness::witnessInvariantHolds(view));
}

TEST_CASE("leaving a tab whose capture is in progress puts it back to awaiting its head") {
    // The withdrawal direction, and the reason the walk covers every tab rather than the displayed one: the
    // rebuild happens while the user is ALREADY on another tab, so the tab that goes back to waiting is not the
    // one being updated. A front end that re-derived this from the tab index instead would be holding a second
    // copy of a fact the wire already carries.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{SkillPage, record::Standard});
    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{SkillPage, record::Standard});
    REQUIRE(h.awaitingLevel(SkillPage) == std::optional<bool>(false));

    h.update(
        scrollBarFrameAt(2 * kPastStationary, /*exposed_rows=*/0, /*nonce=*/2),
        SceneState{CampaignPage, record::Standard});

    CHECK(h.awaitingLevel(SkillPage) == std::optional<bool>(true));
}

// --- an unfinished visit leaves nothing behind ------------------------------------------------------------
//
// THE FAILURE THIS GUARDS AGAINST: a switch handler that rebuilds only a tab that has `started()` or been
// refused, on the reasoning that "a brief glance that never settles into a stationary frame never sets
// is_scrolling, so it is not started and switching away from it discards nothing". A glance discards nothing
// only if the interpreter is holding nothing, and it is not: StationaryFrameCatcher::previous_frame is written on
// every update, and ScrollableScrapingInterpreter::initial_descriptor is written on the first one and never
// cleared. So such a tab keeps the pixels of the visit the user walked away from, and the FIRST frame of the next
// visit can latch -- or refuse -- against evidence gathered before the switch, i.e. against a stationarity
// claim spanning the time the user spent on another tab entirely.
//
// The tab is the same tab, so a "same pixels" test cannot tell the two visits apart; only the interpreter's
// lifetime can. That is why the handler rebuilds every tab you leave that is not ready(), and why this
// case reads the wire rather than any internal flag.
TEST_CASE("a tab left before it latched keeps nothing from the visit that was abandoned") {
    // All three tabs share ScrollableScrapingInterpreter and the same switch handler, so the retention was
    // never factor-specific. Each row leaves for a different tab, so the route is exercised in both
    // directions rather than only away from one fixed page.
    struct Route {
        TabPage glanced;
        TabPage elsewhere;
    };
    const Route routes[] = {
        {FactorPage, SkillPage},
        {SkillPage, FactorPage},
        {CampaignPage, FactorPage},
    };

    for (const auto &route : routes) {
        CAPTURE(static_cast<int>(route.glanced));
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});

        // Visit 1: ONE frame, on a screen that is already scrolled by a tip pixel. A single frame can latch
        // nothing -- the catcher needs a second, identical one -- so the tab is neither started nor refused,
        // which is exactly the state a started-or-refused guard would decline to rebuild.
        h.update(
            scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{route.glanced, record::Standard});
        REQUIRE(h.refusals.empty());

        // Leave. Nothing was captured and nothing was refused.
        h.update(
            scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1),
            SceneState{route.elsewhere, record::Standard});

        // Visit 2, FIRST frame back. Its scroll area is pixel-identical to visit 1's and its timestamp is far
        // enough past it to satisfy the stationary threshold, so a surviving interpreter latches here and
        // refuses on the spot. A rebuilt one is seeing its first frame and can do neither.
        h.update(
            scrollBarFrameAt(2 * kPastStationary, /*exposed_rows=*/1, /*nonce=*/2),
            SceneState{route.glanced, record::Standard});

        CHECK(h.refusals.empty());
        CHECK(h.awaitingLevel(route.glanced) == std::optional<bool>(true));

        // THE POSITIVE CONTROL, and the reason the two lines above are not merely a detector that stopped
        // working. A second frame WITHIN visit 2 gives the fresh interpreter its own stationary pair, and it
        // refuses -- same content, same threshold, evidence that no longer spans the switch.
        h.update(
            scrollBarFrameAt(3 * kPastStationary, /*exposed_rows=*/1, /*nonce=*/3),
            SceneState{route.glanced, record::Standard});

        REQUIRE(h.refusals.size() == 1);
        CHECK(std::get<0>(h.refusals.front()) == static_cast<int>(route.glanced));
        CHECK(std::get<1>(h.refusals.front()) == true);
        CHECK(std::get<2>(h.refusals.front()) == "scrolled");
    }
}

// --- the factor duplicate probe is armed by the latch, not by the announcement ----------------------------
//
// THE FAILURE THIS GUARDS AGAINST: a probe (Rule 3's reference, on_factor_probe) hung off the factor tab's
// scroll-ready cue, taking "whichever frame was current when the cue fired". On the stationary exit those are
// the same frame, so it would work -- by an accident of identity. The offset exit sends no cue at all, so on a
// premature scroll such a probe never fires: the early duplicate check never runs and Rule 3
// (maybeResetOnFactorChange) returns immediately for the rest of the session, because its reference is empty.
// Both failures are SILENT and both are fail-open.
//
// The two facts asserted here are (a) that the probe fires on both exits, and (b) that it is armed with
// fragment #0's OWN frame rather than the current one. (b) is not decoration: taking the current frame at the
// offset exit would arm the probe with a frame the user has already scrolled into, which displaces
// the reference pixels and hands the duplicate check rows that are not the self card -- a worse failure than
// the one being fixed, and one a count-only assertion would not see.
//
// The two controls are declared FIRST, deliberately: a failing REQUIRE aborts the whole doctest case rather
// than the subcase, so a control declared after the discriminating expectation would be unrun in exactly the
// run that needs it, and "the motion exit arms nothing" would be indistinguishable from "nothing arms
// anything".
TEST_CASE("the factor tab's duplicate probe is armed by the latch, from both of its exits") {
    SUBCASE("the stationary exit arms it, with the frame it latched") {
        // The positive control, and the path that already worked. Without it, a probe missing below could not
        // be told apart from a harness that never observes probes at all.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});

        h.update(
            scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
        h.update(
            scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{FactorPage, record::Standard});

        REQUIRE(h.probe_frames.size() == 1);
        // The latched frame is the second one -- StationaryFrameCatcher assigns previous_frame on every update,
        // so the frame that latches is the one handed in on the latching call.
        CHECK(h.probe_frames.front().timestamp() == kPastStationary);
        // ...and it carries the scroll area this session resolved. Standard's happens to equal the rect in the
        // recognizer's own config, which is exactly why this alone proves nothing -- see the friend subcase.
        REQUIRE(h.probe_areas.size() == 1);
        CHECK(h.probe_areas.front() == shippedScraperConfig().common.scroll_area_rect);
        // ...and the same layout's factor limit. Like the rect, Standard's value alone proves nothing about
        // WHICH layout it was read from; the friend subcase is the discriminating one.
        CHECK(
            h.probe_limits
            == std::vector<std::size_t>{
                static_cast<std::size_t>(shippedScraperConfig().common.self_factor_prefix_length)});
        // The factor tab's cue is withheld from the wire on purpose (makeTabScraper hands it the internal
        // factor_scroll_ready sink); the front end sounds it after the duplicate check clears. So even on the
        // exit that DOES announce, this tab puts nothing on on_scroll_ready.
        CHECK(h.scroll_readies.empty());
    }

    SUBCASE("a friend's full record arms it with the friend layout's scroll area") {
        // THE HALF THE RECOGNIZER CANNOT SUPPLY. visibleSelfPrefix scans a live frame from the rect it is
        // handed; its own config carries the stitched-image rect, which names the Standard position only. On
        // this layout that rect is ~136 px too high -- the banner gap lands above the tab bar and the probe
        // comes back empty, which is fail-open and silent (the early duplicate check simply never fires).
        // Asserted against the SHIPPED friend_common rather than a literal, so moving either layout's scroll
        // area keeps this honest.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::FriendStandard});
        const auto friend_layout = shippedScraperConfig().friend_common;

        h.update(
            scrollBarFrameIn(friend_layout, 0, /*exposed_rows=*/0, /*nonce=*/0),
            SceneState{FactorPage, record::FriendStandard});
        h.update(
            scrollBarFrameIn(friend_layout, kPastStationary, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{FactorPage, record::FriendStandard});

        REQUIRE(h.probe_areas.size() == 1);
        CHECK(h.probe_areas.front() == friend_layout.scroll_area_rect);
        CHECK_FALSE(h.probe_areas.front() == shippedScraperConfig().common.scroll_area_rect);
        // The limit follows the same choice. A probe that carried Standard's value here would read a friend's
        // full record past the rows its shorter scroll area promises, and state below_threshold against a count
        // that layout cannot show. The REQUIRE is the precondition that makes the second CHECK discriminate: if the
        // shipped layouts ever carried equal values, "the friend value" and "the common value" could not be
        // told apart and this subcase would pass for a scraper that ignored the layout.
        const int common_threshold = shippedScraperConfig().common.self_factor_prefix_length;
        REQUIRE(friend_layout.self_factor_prefix_length != common_threshold);
        CHECK(
            h.probe_limits
            == std::vector<std::size_t>{static_cast<std::size_t>(friend_layout.self_factor_prefix_length)});
    }

    SUBCASE("a latch on another tab arms nothing") {
        // The control for the consumer's factor-specificity. The latch event is per tab and every tab sends it,
        // so without this "the probe fired" could just mean "the probe fires for any latch".
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});

        h.update(
            scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{SkillPage, record::Standard});
        h.update(
            scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{SkillPage, record::Standard});

        REQUIRE(h.awaitingLevel(SkillPage) == std::optional<bool>(false));
        CHECK(h.scroll_readies == std::vector<int>{static_cast<int>(SkillPage)});
        CHECK(h.probe_frames.empty());
    }

    SUBCASE("the motion exit arms it too, with the frame it latched and not the current one") {
        // THE DISCRIMINATOR. The user starts scrolling before the screen ever settles: the stationary catcher
        // never latches, the content translates past initial_scroll_threshold, and updateBefore takes the
        // offset exit -- latching the tab's FIRST frame, several updates old, and sending no cue.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});

        h.update(
            scrollingBandFrameAt(0, /*content_shift=*/0, /*exposed_rows=*/0, /*nonce=*/0),
            SceneState{FactorPage, record::Standard});
        REQUIRE(h.probe_frames.empty());  // one frame is only initial_descriptor; nothing has latched yet
        h.update(
            scrollingBandFrameAt(50, /*content_shift=*/10, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{FactorPage, record::Standard});

        // The exit is identified rather than assumed: the wait ended (something latched), no cue was sent
        // (which the stationary exit would have sent for a non-factor tab and which this tab withholds anyway),
        // and nothing was refused.
        REQUIRE(h.refusals.empty());
        REQUIRE(h.awaitingLevel(FactorPage) == std::optional<bool>(false));
        CHECK(h.scroll_readies.empty());

        REQUIRE(h.probe_frames.size() == 1);
        // IDENTITY, twice over. The frame that became fragment #0 is the FIRST one (timestamp 0, shift 0); the
        // frame that was current when the latch happened is the second (timestamp 50, shift 10). Either
        // assertion alone separates "fragment #0's own pixels" from "whatever was current", which is the
        // substitution that would break the flush gate and the duplicate check.
        CHECK(h.probe_frames.front().timestamp() == 0);
        CHECK(firstBandRow(h.probe_frames.front()) == firstBandRow(scrollingBandFrameAt(0, 0, 0, 0)));
        CHECK(firstBandRow(h.probe_frames.front()) != firstBandRow(scrollingBandFrameAt(50, 10, 0, 1)));
    }
}

// --- the probe carries the cue its exit owed ---------------------------------------------------------------
//
// THE DEFECT THIS GUARDS AGAINST. The probe is armed from both exits, which gives the factor tab its duplicate
// check and Rule 3 on either -- and, because this tab's chime is not sounded by the core but synthesized by the
// front end off this very message, a probe that did not say which exit it came from would chime on the exit
// that must not chime. A user who scrolled before the cue would hear the cue after they started.
//
// No state test decides this: `cue_owed` is stated by the exit that latched, travels on the latch
// event and out on on_factor_probe, and the front end reads it. So what is asserted here is that the probe
// still fires on both exits (the duplicate check and Rule 3 stay alive) while the flag it carries differs.
// A test of the probe's presence alone cannot see this, and a test of the chime alone cannot tell "no chime"
// from "no probe" -- and each of the two can be fixed by breaking the other.
//
// Controls first again, for the reason the case above states: a fatal REQUIRE aborts the whole case.
TEST_CASE("the factor probe carries the cue its exit owed, so a premature scroll stays silent") {
    SUBCASE("the stationary exit's probe says a cue is owed") {
        // POSITIVE CONTROL. Without it, "the motion exit says false" would be indistinguishable from "the flag
        // is false always", which would silence the chime altogether -- the failure direction that costs the
        // user the capture rather than a noise.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});

        h.update(
            scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
        h.update(
            scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{FactorPage, record::Standard});

        REQUIRE(h.probe_cues.size() == 1);
        CHECK(h.probe_cues.front() == true);
        // Still withheld from the wire: the flag is how the front end learns the cue is owed, not a second
        // route onto on_scroll_ready.
        CHECK(h.scroll_readies.empty());
    }

    SUBCASE("a tab whose cue does reach the wire still chimes on one exit and not the other") {
        // CONTROL for what makes the flag possible: on_scroll_ready is sent from inside startScrolling under
        // `cue_owed`, rather than by the caller of the stationary exit. If that placement changed which exits
        // chime, every tab on the wire would be wrong and no factor-tab assertion would
        // say so, because the factor tab puts nothing on on_scroll_ready either way.
        {
            ScraperHarness settled;
            settled.scraper.build(SceneInfo{record::Standard});
            settled.update(
                scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{SkillPage, record::Standard});
            settled.update(
                scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1),
                SceneState{SkillPage, record::Standard});
            CHECK(settled.scroll_readies == std::vector<int>{static_cast<int>(SkillPage)});
        }
        {
            ScraperHarness moving;
            moving.scraper.build(SceneInfo{record::Standard});
            moving.update(
                scrollingBandFrameAt(0, /*content_shift=*/0, /*exposed_rows=*/0, /*nonce=*/0),
                SceneState{SkillPage, record::Standard});
            moving.update(
                scrollingBandFrameAt(50, /*content_shift=*/10, /*exposed_rows=*/0, /*nonce=*/1),
                SceneState{SkillPage, record::Standard});
            // The exit is identified, not assumed: something latched and nothing was refused.
            CHECK(moving.refusals.empty());
            CHECK(moving.awaitingLevel(SkillPage) == std::optional<bool>(false));
            CHECK(moving.scroll_readies.empty());
        }
    }

    SUBCASE("the motion exit's probe says no cue is owed, and still arms the probe") {
        // THE DISCRIMINATOR. Both halves matter and they pull in opposite directions: the probe must still
        // fire (that is what gives the early duplicate check and Rule 3 a reference on an exit that sends no
        // cue) and the chime must still be withheld (the front end decides this tab's chime). Asserting only one of them would let the other regress unnoticed.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});

        h.update(
            scrollingBandFrameAt(0, /*content_shift=*/0, /*exposed_rows=*/0, /*nonce=*/0),
            SceneState{FactorPage, record::Standard});
        h.update(
            scrollingBandFrameAt(50, /*content_shift=*/10, /*exposed_rows=*/0, /*nonce=*/1),
            SceneState{FactorPage, record::Standard});

        REQUIRE(h.refusals.empty());
        REQUIRE(h.awaitingLevel(FactorPage) == std::optional<bool>(false));
        // The duplicate check and Rule 3 are alive on this exit -- armed with fragment #0's own frame.
        REQUIRE(h.probe_cues.size() == 1);
        CHECK(h.probe_frames.front().timestamp() == 0);
        // ...and the message says the front end owes no chime for it.
        CHECK(h.probe_cues.front() == false);
        CHECK(h.scroll_readies.empty());
    }
}

// --- revisiting an unfinished factor tab probes again, and the second probe owes a cue too -----------------
//
// THE DEFECT THIS GUARDS AGAINST. A user who leaves the factor tab before its capture finishes and comes back to
// it is owed a "you may scroll now" chime on the second visit too. That tab's chime is not sounded by this core at all
// (makeTabScraper hands it the internal factor_scroll_ready sink); the front end synthesizes it off
// on_factor_probe's `cue_owed`. So "the core did not send a second probe" and "the core sent one and the front
// end swallowed it" would produce the identical symptom -- a silent second visit --, and only one of them is a defect in this file's subject.
//
// This case pins the CORE's half as a single measurement rather than as a composition of two other
// cases --"a tab left before it latched keeps nothing from the visit that was abandoned" (which drives the
// {FactorPage, SkillPage} route but returns to a screen ALREADY SCROLLED, so it ends in a refusal and never
// reaches a probe) and "the stationary exit's probe says a cue is owed" (which drives a first visit only). Two
// cases that each cover half of a claim do not cover the claim: neither observes a SECOND probe, and a
// core that emitted one probe per session would leave both of them green.
//
// The route is factor -> skill -> factor, the ordinary way a tab is left unfinished and revisited. The return is at the HEAD of the list,
// which is what the abandoned-visit case above deliberately is not, and is what a user who did not scroll
// before switching away actually sees.
TEST_CASE("coming back to an unfinished factor tab probes again, still owing the cue") {
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    // Visit 1: two identical frames at the head of the list. The stationary exit latches fragment #0 and arms
    // the probe, owing a cue -- the same pair "the stationary exit's probe says a cue is owed" drives.
    h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    REQUIRE(h.probe_cues.size() == 1);
    REQUIRE(h.probe_cues.front() == true);

    // Leave for the skill tab. ONE frame is enough: the switch handler rebuilds the factor tab on the frame the
    // user lands elsewhere, because the factor capture is not ready(). One frame also latches nothing on the
    // skill tab, which keeps the scroll_readies control below reading this route rather than the detour.
    h.update(
        scrollBarFrameAt(2 * kPastStationary, /*exposed_rows=*/0, /*nonce=*/2),
        SceneState{SkillPage, record::Standard});

    // Visit 2, back at the head of the list. The rebuilt interpreter is seeing its first frame, so it latches on
    // the second one exactly as visit 1 did.
    h.update(
        scrollBarFrameAt(3 * kPastStationary, /*exposed_rows=*/0, /*nonce=*/3),
        SceneState{FactorPage, record::Standard});
    h.update(
        scrollBarFrameAt(4 * kPastStationary, /*exposed_rows=*/0, /*nonce=*/4),
        SceneState{FactorPage, record::Standard});

    // THE ASSERTION. A second probe exists at all -- and it owes the cue, which is the bit the front end reads
    // to decide whether to sound this tab's chime. A count-only check would pass on a core that re-emitted the
    // probe with `cue_owed` stuck false, which sounds exactly like sending nothing.
    REQUIRE(h.probe_cues.size() == 2);
    CHECK(h.probe_cues[1] == true);
    // Nothing was refused on either visit, so the two probes are two head-of-list latches rather than one latch
    // and one error path.
    CHECK(h.refusals.empty());
    // The standing control this file states everywhere the factor tab latches: this tab puts NOTHING on
    // on_scroll_ready, on either visit. The chime is the front end's to synthesize from `cue_owed` above, so a
    // regression that "fixed" the revisit by putting the factor tab on the wire sender would sound the chime
    // ahead of the duplicate check it exists to gate.
    CHECK(h.scroll_readies.empty());
}

// --- What the core PUTS ON THE WIRE for "is this tab at the head of its content" ---------------------------
//
// The composite verdict is three-valued and leaves this process UNRESOLVED, because the two front-end
// consumers answer "no sensor could read this frame" in opposite directions (see
// CharaDetailSceneScraper::on_scroll_position). Two thirds of that contract are watched elsewhere -- the
// message's SHAPE by test_native_api_messages.cpp, the front end's resolution by the Dart suite -- and the
// third is watched here: the WORD this class chooses.
//
// Without these cases, resolving here with a fail-open policy would leave the whole suite green: the wire simply never carries "unknown" again and the
// fail-closed consumer is fail-open in practice, behind a message whose shape never changed. A golden cannot
// see it either -- the golden suite compares records, and this channel produces none.

TEST_CASE("a tab not built yet says so on the wire, rather than being resolved here") {
    // The first frame of a tab is judged BEFORE the tab is built from it (SceneScraper::build runs later in the
    // same update), so there is no thumb to measure and no structure to ask. The thumb is every tab's head
    // sensor, so that is "unknown" on every tab -- the factor tab included, even on a frame whose green header
    // sits at the head row: the header is asked only behind a thumb at the head, and never answers for a
    // thumb that has no reading. (A frame of a BUILT, scrollable tab whose thumb cannot be read says "unknown"
    // too; see "a frame of a scrollable factor page that shows neither ..." below, which also pins what Rule 3
    // does with it.)
    TabPage tab = CampaignPage;
    SUBCASE("a campaign frame") {
        tab = CampaignPage;
    }
    SUBCASE("a factor frame whose header is at the head row") {
        tab = FactorPage;
    }
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});
    // scrollBarFrameAt draws the factor header at the head row (factorHeaderFrameAt with kFactorHeadRow).
    h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{tab, record::Standard});

    // The word, not a bool. "unknown" is the whole point: resolved to either answer here, this reads as one
    // of the other two and the consumer that needed the distinction never sees it.
    CHECK(h.positionWords(tab) == std::vector<std::string>{"unknown"});
}

TEST_CASE("a tab whose page cannot scroll is at the head of its content on the wire, whatever its frames show") {
    // A PAGE WITH NO SCROLL BAR CANNOT BE ANYWHERE BUT THE HEAD OF ITS CONTENT, and the core says so from the
    // structure the tab was built with, not from a sensor. Read from sensors, a skill or campaign page with no
    // scroll bar would say "unknown" on every frame (no thumb), and a factor page would say whatever its header
    // says -- "scrolled" when the banner is not found in its window or lands outside it, which a real
    // no-scroll-bar clip measured. Rule 3 acts only on "at_top", so it would never judge the page the user can
    // switch on.
    //
    // Four pages, and two of them are not the factor tab, so an answer keyed on the tab's name stays red.
    // The first frame's word is "unknown" on all four: it is taken before the tab is built, when no thumb can be
    // read (see the case above), and the factor tab's header is not asked without a thumb at the head.
    TabPage tab = SkillPage;
    std::function<Frame(uint64, int)> page;
    SUBCASE("a skill page") {
        tab = SkillPage;
        page = noScrollBarFrameAt;
    }
    SUBCASE("a campaign page") {
        tab = CampaignPage;
        page = noScrollBarFrameAt;
    }
    SUBCASE("a factor page whose header is not drawn") {
        tab = FactorPage;
        page = noScrollBarFrameAt;
    }
    SUBCASE("a factor page whose header is drawn just past the banner window") {
        tab = FactorPage;
        page = [](uint64 timestamp, int nonce) {
            const Frame bare = noScrollBarFrameAt(timestamp, nonce);
            return withFactorHeaderAt(bare, factorHeadLastRowOn(bare) + 1);
        };
    }
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    // The page latches on the second frame; the third shows the answer holds after that too.
    h.update(page(0, /*nonce=*/0), SceneState{tab, record::Standard});
    h.update(page(kPastStationary, /*nonce=*/0), SceneState{tab, record::Standard});
    h.update(page(kPastStationary + kPastDwell, /*nonce=*/0), SceneState{tab, record::Standard});

    CHECK(h.positionWords(tab) == std::vector<std::string>{"unknown", "at_top"});
    CHECK(h.discards.empty());
}

TEST_CASE("a tab a sensor CAN read says which way it measured") {
    // The positive control for the "unknown" cases: without it, "unknown" would be indistinguishable from a wire
    // that says "unknown" no matter what the sensors found. Both measured words are reachable from the same
    // frames the refusal cases use, so the two claims are pinned against the same synthetic bar. The skill tab
    // is the one read by the thumb alone; the factor tab is read by its banner as well.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    // Frame 1 builds the tab, so its scroll-bar estimator does not exist yet while the verdict for that frame
    // is taken -- a thumb-only tab is genuinely unreadable for exactly one frame, and the wire says so.
    h.update(scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{SkillPage, record::Standard});
    h.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{SkillPage, record::Standard});
    CHECK(h.positionWords(SkillPage) == std::vector<std::string>{"unknown", "at_top"});

    ScraperHarness scrolled;
    scrolled.scraper.build(SceneInfo{record::Standard});
    scrolled.update(
        scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{SkillPage, record::Standard});
    scrolled.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{SkillPage, record::Standard});
    CHECK(scrolled.positionWords(SkillPage) == std::vector<std::string>{"unknown", "scrolled"});

    // The factor tab on the same frames, and the same words. Its thumb is its head sensor too, so the first
    // frame, where the thumb has no reading yet, is "unknown" although the header sits at the head row. At the
    // head the second frame's thumb goes on to the header, which keeps at_top; at the one-tip-pixel frames the
    // thumb's scrolled is the answer.
    ScraperHarness factor;
    factor.scraper.build(SceneInfo{record::Standard});
    factor.update(
        scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    factor.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/0, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    CHECK(factor.positionWords(FactorPage) == std::vector<std::string>{"unknown", "at_top"});

    ScraperHarness factor_scrolled;
    factor_scrolled.scraper.build(SceneInfo{record::Standard});
    factor_scrolled.update(
        scrollBarFrameAt(0, /*exposed_rows=*/1, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    factor_scrolled.update(
        scrollBarFrameAt(kPastStationary, /*exposed_rows=*/1, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    CHECK(factor_scrolled.positionWords(FactorPage) == std::vector<std::string>{"unknown", "scrolled"});
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
    h.update(scrollBarFrameIn(layout, base, /*exposed_rows=*/0, nonce), SceneState{FactorPage, record_type});
    h.update(
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
    h.update(frame_at(at, nonce), SceneState{FactorPage, record_type});
    h.update(frame_at(at + kPastDwell, nonce + 1), SceneState{FactorPage, record_type});
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
    h.scraper.build(SceneInfo{record::Standard});
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
    h.scraper.build(SceneInfo{record::Standard});
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
        h.update(
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

TEST_CASE("a factor list displaced inside the head window is judged by Rule 3, and a Same takes it as the witness") {
    // Rule 3 sees a list displaced within the header's window. Behind a thumb at the head, the flush gate is the header's window, so a list a few rows off the row it was latched at is still at
    // its head: the gate opens, the diff against the witness nominates the frame, both frames are read, and the
    // Same verdict keeps the session and makes the displaced frame the witness. A gate narrower than the
    // recognizer's window would stay closed on such a frame and leave Rule 3 blind to it.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});
    const std::string first_session = h.sessionIdAt(0);
    const uint64 latched_at = latchFactorHead(h, 0, /*nonce=*/0, shippedScraperConfig().common, record::Standard);

    static constexpr int kDisplacement = 4;
    const FrameAt displaced = [](uint64 timestamp, int nonce) {
        return prescrolledFactorFrame(timestamp, kDisplacement, /*exposed_rows=*/0, nonce);
    };
    // The premise: the displaced frame's banner is off the latched row, and still inside the window.
    REQUIRE(bannerRowOf(h, h.probe_frames.at(0)) == std::optional<int>(kFactorHeadRow));
    REQUIRE(bannerRowOf(h, displaced(0, 0)) == std::optional<int>(kFactorHeadRow - kDisplacement));

    const uint64 judged_at = holdFactorDivergence(h, latched_at + 100, /*nonce=*/10, displaced, record::Standard);
    // REQUIRE: every line below reads what this reading left behind (framesRead().back() among them).
    REQUIRE(h.framesRead() == std::vector<uint64>{latched_at, judged_at});
    CHECK(
        h.verdictsStated()
        == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Same});
    CHECK(h.discards.empty());
    CHECK(h.sessionIdAt(h.recorder.made.size() - 1) == first_session);

    // THE DISPLACED FRAME IS NOW THE WITNESS: holding it again is no change at all, and the latched look is a
    // divergence again.
    const std::size_t calls_after_verdict = h.factor_model_calls.size();
    holdFactorDivergence(h, judged_at + 100, /*nonce=*/20, displaced, record::Standard);
    CHECK(h.factor_model_calls.size() == calls_after_verdict);
    const uint64 back_at =
        holdFactorDivergence(h, judged_at + 100 + 2 * kPastDwell, /*nonce=*/30, latchedLook, record::Standard);
    CHECK(h.framesRead().back() == back_at);
    CHECK(h.discards.empty());
}

TEST_CASE("a candidate switch on which the reader finds no rows discards the session") {
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

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
    h.scraper.build(SceneInfo{record::Standard});

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
    h.scraper.build(SceneInfo{record::Standard});

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
// Under readerScanConfig the banner search stops at the first row that leaves its background, which on these
// frames is the painted header at kFactorHeadRow, so a reading's first cell starts exactly
// vertical_banner_bottom_delta below that row of the rect the reader was handed. What is asserted is that window,
// measured from the top of THIS LAYOUT's scroll area on the frame -- one capture pixel of rounding on each side.
void checkSwitchReadingArea(const scraper_config::SceneScraperConfig &layout, record::RecordType record_type) {
    ScraperHarness h;
    h.factor_model_answer = [](const Frame &cell) { return cell.timestamp() > kPastStationary ? 102 : 101; };
    h.scraper.build(SceneInfo{record_type});

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
        CHECK(first_cell_top >= area_top + kFactorHeadRow + first_row_offset - 1);
        CHECK(first_cell_top <= area_top + kFactorHeadRow + first_row_offset + 1);
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
    //
    // The layout's factor limit is lifted for this case. With the shipped limit the reading stops at the limit
    // well above the scroll area's bottom edge (see the case below), so the bound would never be reached and this
    // case would pass for a reader that had no bound at all.
    auto config = shippedScraperConfig();
    config.common.self_factor_prefix_length = 1000;
    ScraperHarness h(config);
    const Frame probe = scrollBarFrameAt(0, /*exposed_rows=*/0, /*nonce=*/0);
    const int area_bottom = probe.anchor().mapToFrame(shippedScraperConfig().common.scroll_area_rect).bottom();
    h.factor_model_answer = [area_bottom](const Frame &cell) {
        cv::Size whole;
        cv::Point origin;
        cell.data().locateROI(whole, origin);
        const bool reaches_below = origin.y + cell.height() > area_bottom;
        return cell.timestamp() > kPastStationary && reaches_below ? 102 : 101;
    };
    h.scraper.build(SceneInfo{record::Standard});

    const uint64 judged_at = driveFactorDivergence(h, 0, /*nonce=*/0);

    // The pixel diff did fire and both frames were read: the verdict is the reader's.
    REQUIRE(h.framesRead() == std::vector<uint64>{kPastStationary, judged_at});
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Same});
    CHECK(h.discards.empty());
}

// THE LIMIT RULE 3 SHARES WITH THE PROBE. The switch rule reads each frame up to the session's layout limit, which
// is the limit the probe's window carries (the case "the factor tab's duplicate probe is armed by the latch" pins
// that side), so the lists Rule 3 compares are read exactly as the list the front end compares. Under
// readerScanConfig the scan finds a row at every sample, so without the limit a reading would run on to the scroll
// area's bottom edge; the REQUIREs establish that it would, on this very frame, so the count below can only be the
// limit's doing.
void checkSwitchReadingLimit(const scraper_config::SceneScraperConfig &layout, record::RecordType record_type) {
    const auto limit = static_cast<std::size_t>(layout.self_factor_prefix_length);
    const auto unlimited = [&layout](const Frame &frame) {
        const recognizer_impl::FactorRowReader reader{
            readerScanConfig(),
            testutil::constantPredictor<int>("factor", 101),
            testutil::constantPredictor<int>("factor_rank", 2),
        };
        return reader.visibleSelfPrefix(frame, recognizer_impl::SelfFactorWindow{layout.scroll_area_rect, 1000}).size();
    };

    ScraperHarness h;
    h.factor_model_answer = [](const Frame &cell) { return cell.timestamp() > kPastStationary ? 102 : 101; };
    h.scraper.build(SceneInfo{record_type});
    const uint64 latched = latchFactorHead(h, 0, /*nonce=*/0, layout, record_type);
    const FrameAt textured_in_layout = [&layout](uint64 timestamp, int nonce) {
        return scrollingBandFrameIn(layout, timestamp, /*content_shift=*/0, /*exposed_rows=*/0, nonce);
    };
    const uint64 judged_at = holdFactorDivergence(h, latched + 100, /*nonce=*/2, textured_in_layout, record_type);
    REQUIRE(h.framesRead() == std::vector<uint64>{latched, judged_at});
    REQUIRE(h.probe_frames.size() == 1);
    REQUIRE(unlimited(h.probe_frames.front()) > limit);
    REQUIRE(unlimited(textured_in_layout(judged_at, 3)) > limit);

    CHECK(h.probe_limits == std::vector<std::size_t>{limit});
    CHECK(h.factorCallsOn(latched) == limit);
    CHECK(h.factorCallsOn(judged_at) == limit);
}

TEST_CASE("the switch reading stops at a Standard session's factor limit, the limit its probe carries") {
    checkSwitchReadingLimit(shippedScraperConfig().common, record::Standard);
}

TEST_CASE("the switch reading stops at a friend's full record's factor limit, not Standard's") {
    const auto config = shippedScraperConfig();
    REQUIRE(config.friend_common.self_factor_prefix_length != config.common.self_factor_prefix_length);
    checkSwitchReadingLimit(config.friend_common, record::FriendStandard);
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
    h.scraper.build(SceneInfo{record::Standard});

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

// `page` as a factor page draws it at the head of its content: the green 因子 header on the head row
// (kFactorHeadRow), and the title-bar banner. On a page with no scroll bar the header is NOT what opens Rule 3's
// flush gate -- the page's structure is -- so the kinds below that draw no header, or draw it off its row, are
// judged all the same.
Frame asFactorPageAtHead(const Frame &page) {
    return withBanner(withFactorHeaderAt(page, kFactorHeadRow));
}

// `page` with the header one row past the banner window, and the title-bar banner: a header the judgment reads
// as scrolled on a page that cannot scroll -- what one drawn lower than any device draws it, or a cut banner,
// reads as.
Frame withFactorHeaderBelowHead(const Frame &page) {
    return withBanner(withFactorHeaderAt(page, factorHeadLastRowOn(page) + 1));
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
    h.update(withBanner(noScrollBarFrameAt(at, /*nonce=*/0)), SceneState{tab, record::Standard});
    h.update(
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
    h.update(look(at), SceneState{FactorPage, record::Standard});
    h.update(look(at + kPastStationary), SceneState{FactorPage, record::Standard});
    h.update(withFactorEndBar(look(at + kPastStationary + 100)), SceneState{FactorPage, record::Standard});
    return at + kPastStationary + 100;
}

// Captures the factor tab of a Standard session on a factor page with no scroll bar that looks like `look`. Its one
// settled frame is the tab's whole capture and its head latch, so it holds Rule 3's witness from that frame on,
// exactly as a scrolled capture does. Returns the timestamp of that frame, kPastStationary after `at`.
uint64 captureFactorPageLooking(ScraperHarness &h, uint64 at, const FrameAt &look) {
    h.update(look(at, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    h.update(look(at + kPastStationary, /*nonce=*/0), SceneState{FactorPage, record::Standard});
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
        h.scraper.build(SceneInfo{record::Standard});
        captureWithoutScrolling(h, tab, 0);
        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(tab)});
        CHECK(h.probe_frames.empty());
        CHECK(h.scroll_readies.empty());
        CHECK(h.completions == 0);
    }
    SUBCASE("the factor tab by scrolling, which latches the witness owing the cue") {
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        captureFactorByScrolling(h, 0);
        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});
        REQUIRE(h.probe_frames.size() == 1);
        CHECK(h.probe_frames.front().timestamp() == kWitnessAt);
        CHECK(h.probe_cues == std::vector<bool>{true});
        CHECK(h.completions == 0);
    }
    SUBCASE("a factor page with no scroll bar, which latches the witness on its one frame owing no cue") {
        // A LATCH WITH NO SCROLL BAR STILL INSTALLS THE WITNESS. The page is captured and its head latched on the same frame, so
        // the probe is armed exactly as on a scrolled capture -- with the whole frame, this session's scroll area,
        // and no cue: there is nothing to scroll, so "you may scroll now" would be false, and it would arrive after
        // the tab's own completion.
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        captureFactorWithoutScrollBar(h, 0);
        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});
        REQUIRE(h.probe_frames.size() == 1);
        CHECK(h.probe_frames.front().timestamp() == kWitnessAt);
        // The whole frame, not the content crop: Rule 3 compares its witness with later frames by size.
        CHECK(h.probe_frames.front().size() == factorPageWithoutScrollBar(0, 0).size());
        REQUIRE(h.probe_areas.size() == 1);
        CHECK(h.probe_areas.front() == shippedScraperConfig().common.scroll_area_rect);
        CHECK(h.probe_cues == std::vector<bool>{false});
        CHECK(h.scroll_readies.empty());
        // The tab completed on this frame (the nonce is fixed, so the tab button settled with the content), and on a
        // page with no scroll bar the completion is what ends the wait.
        CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(false));
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
        h.scraper.build(SceneInfo{record::Standard});
        completeSession(h, capture_factor);
        CHECK(h.completions == 1);
        CHECK(h.probe_frames.size() == 1);
        CHECK(h.discards.empty());
    }
}

TEST_CASE("an opened session announces the id its record finishes under, before anything else of it") {
    // THE FAILURE THIS GUARDS AGAINST: a start announced by a listener on the open event that runs before the
    // scraper builds the session cannot name the session at all, and a front end then has no way to tell the
    // record of the previous attempt, finishing late on another thread, from this attempt's.
    ScraperHarness h;
    h.opened->send(SceneInfo{record::Standard});

    REQUIRE(h.starts.size() == 1);
    REQUIRE_FALSE(h.recorder.made.empty());
    // The id is the session's own -- the one its scraping directory is named after -- and not a second mint.
    CHECK(h.starts[0].record_id == h.sessionIdAt(0));
    CHECK(h.starts[0].record_type == record::Standard);
    REQUIRE_FALSE(h.sequence.empty());
    CHECK(h.sequence.front() == "started");

    completeSession(h, captureFactorWithoutScrollBar);

    // ...and it is the id the record is handed on under, which is what onCharaDetailFinished carries.
    REQUIRE(h.completed_infos.size() == 1);
    CHECK(h.completed_infos[0].record_id == h.starts[0].record_id);
    CHECK(h.starts.size() == 1);
}
TEST_CASE("an opened attempt whose session cannot be built ends as a failure under the id it was announced with") {
    // Building a session creates its scraping directory, and that throws when the directory cannot be created. A
    // front end accepts an outcome only under an id it was told about, and the failure below reports the id the
    // refused session was given -- so unless that id was announced BEFORE the throw, the front end drops the
    // failure and keeps showing the previous attempt, with no failure and no sound. The frames that follow must
    // find no session to work on: the scrapers the construction never made are what the next frame would reach.
    ScraperHarness h;
    std::vector<RecordInfo> closed_unfinished;
    h.closed_before_completed->listen([&closed_unfinished](const RecordInfo &info) {
        closed_unfinished.push_back(info);
    });

    h.recorder.refuse = true;
    REQUIRE_NOTHROW(h.opened->send(SceneInfo{record::Standard}));
    REQUIRE(h.starts.size() == 1);
    REQUIRE_FALSE(h.recorder.refused.empty());
    CHECK(h.recorder.made.empty());
    CHECK(h.starts[0].record_id == sessionIdOf(h.recorder.refused.front()));

    // The attempt ends HERE, under the id it was announced with, instead of leaving a half-built session for the
    // next frame to dereference.
    REQUIRE(h.failures.size() == 1);
    CHECK(h.failures[0].record_id == h.starts[0].record_id);

    // Later frames are inert: nothing is scraped, nothing reaches the wire, and no directory is retried.
    const std::size_t refused_before = h.recorder.refused.size();
    REQUIRE_NOTHROW(h.update(solidFrameAt(0, kNoBanner), SceneState{FactorPage, record::Standard}));
    REQUIRE_NOTHROW(h.update(solidFrameAt(kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard}));
    CHECK(h.recorder.refused.size() == refused_before);
    CHECK(h.positions.empty());
    CHECK(h.starts.size() == 1);
    CHECK(h.rebuilt.empty());
    CHECK(h.failures.size() == 1);

    // And the close says nothing more: the attempt already reported its own, more specific outcome.
    h.closed->send();
    CHECK(closed_unfinished.empty());
}

TEST_CASE("a reset whose session cannot be built ends as a failure under the id the reset announced") {
    // The reset's twin of the case above: a reset begins an attempt too, and announces it on the restart.
    ScraperHarness h;
    std::vector<RecordInfo> closed_unfinished;
    h.closed_before_completed->listen([&closed_unfinished](const RecordInfo &info) {
        closed_unfinished.push_back(info);
    });

    h.opened->send(SceneInfo{record::Standard});
    REQUIRE(h.starts.size() == 1);
    h.recorder.refuse = true;
    // A record type that persists past the dwell resets the session; the first frame only opens the dwell.
    h.update(solidFrameAt(0, kNoBanner), SceneState{FactorPage, record::FriendStandard});
    REQUIRE_NOTHROW(h.update(solidFrameAt(kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard}));
    REQUIRE(h.rebuilt.size() == 1);
    REQUIRE_FALSE(h.recorder.refused.empty());
    CHECK(h.rebuilt[0].record_id == sessionIdOf(h.recorder.refused.front()));
    CHECK(h.rebuilt[0].record_id != h.starts[0].record_id);

    REQUIRE(h.failures.size() == 1);
    CHECK(h.failures[0].record_id == h.rebuilt[0].record_id);

    // The dwell that caused this reset is gone with the session, so a further frame of the same record type does
    // not announce a second attempt and does not retry the refused directory.
    const std::size_t refused_before = h.recorder.refused.size();
    REQUIRE_NOTHROW(h.update(solidFrameAt(2 * kPastDwell, kBanner), SceneState{FactorPage, record::FriendStandard}));
    CHECK(h.recorder.refused.size() == refused_before);
    CHECK(h.rebuilt.size() == 1);
    CHECK(h.failures.size() == 1);

    h.closed->send();
    CHECK(closed_unfinished.empty());
}

TEST_CASE("a tab rebuild whose directory cannot be recreated ends the attempt instead of retrying every frame") {
    // Leaving an incomplete tab recreates its directory: rmdir then mkdir (SceneScrapingBox::recreate). The mkdir
    // can be refused for exactly the reasons the session's own can, and this one happens on a session that is
    // fully built and capturing. Left to the runner's containment the tab would keep its old interpreter while
    // its directory stayed deleted, and the same rebuild would be retried -- and thrown out of -- on every later
    // frame, so the capture would never finish and nobody would be told why.
    ScraperHarness h;
    std::vector<RecordInfo> closed_unfinished;
    h.closed_before_completed->listen([&closed_unfinished](const RecordInfo &info) {
        closed_unfinished.push_back(info);
    });

    h.opened->send(SceneInfo{record::Standard});
    REQUIRE(h.starts.size() == 1);
    REQUIRE(h.failures.empty());
    // One frame on the skill tab is enough to make it the tab the next frame leaves.
    h.update(solidFrameAt(0, kNoBanner), SceneState{SkillPage, record::Standard});

    h.recorder.refuse = true;
    REQUIRE_NOTHROW(h.update(solidFrameAt(1, kNoBanner), SceneState{FactorPage, record::Standard}));
    REQUIRE_FALSE(h.recorder.refused.empty());
    REQUIRE(h.failures.size() == 1);
    CHECK(h.failures[0].record_id == h.starts[0].record_id);
    // The rebuild is not a new attempt: nothing was announced and nothing was discarded.
    CHECK(h.starts.size() == 1);
    CHECK(h.rebuilt.empty());

    const std::size_t refused_before = h.recorder.refused.size();
    REQUIRE_NOTHROW(h.update(solidFrameAt(2, kNoBanner), SceneState{FactorPage, record::Standard}));
    REQUIRE_NOTHROW(h.update(solidFrameAt(3, kNoBanner), SceneState{SkillPage, record::Standard}));
    CHECK(h.recorder.refused.size() == refused_before);
    CHECK(h.failures.size() == 1);

    h.closed->send();
    CHECK(closed_unfinished.empty());
}

// --- A fragment that could not be written ------------------------------------------------------------------
//
// One step later than the three cases above: the session was built, so what fails is a write INTO it. The
// commit is two steps -- persist the fragment, then record that it is persisted -- and updateUntilReady never
// asks a latch that has become ready() again, so a throw in between is unrepairable by any later frame. It
// breaks two ways and both are covered below: a latch whose flag was never set (a tab that can never be ready),
// and a fragment counter that was incremented while building the path (a tab that reports ready over a file
// that is not on disk, so the stitcher delivers a short record as a success).
//
// The negative control for the frame scripts here is "the capture helpers really capture", which drives the
// same helpers with the directories in place; the base case carries its own control, because its script is its
// own.

TEST_CASE("a base image that cannot be written ends the attempt under the id it was announced with") {
    ScraperHarness h;
    std::vector<RecordInfo> closed_unfinished;
    h.closed_before_completed->listen(
        [&closed_unfinished](const RecordInfo &info) { closed_unfinished.push_back(info); });

    bool directory_survives = false;
    SUBCASE("the session's directory goes away under the capture") {
        directory_survives = false;
    }
    SUBCASE("negative control: the same frames with the directory in place") {
        directory_survives = true;
    }

    h.opened->send(SceneInfo{record::Standard});
    REQUIRE(h.starts.size() == 1);
    const std::filesystem::path session_dir = kScrapingRoot / h.starts[0].record_id;

    // The skill tab first, on frames with NO banner: the base catcher's snackbar gate stays shut, so the tab's
    // own writes are the only ones so far and they all succeed.
    h.update(noScrollBarFrameAt(0, /*nonce=*/0), SceneState{SkillPage, record::Standard});
    h.update(noScrollBarFrameAt(kPastStationary, /*nonce=*/0), SceneState{SkillPage, record::Standard});
    REQUIRE(h.pages_ready == std::vector<int>{static_cast<int>(SkillPage)});
    REQUIRE(h.failures.empty());

    // The record directory removed under a running capture -- one of the causes in range -- leaves the base
    // image as the only write left, and the one that fails.
    if (!directory_survives) {
        std::filesystem::remove_all(session_dir);
    }

    // Banner frames now: identical, so the base region settles while the snackbar gate opens. Driven until the
    // gate is certain to have opened rather than pinned to one frame, and every frame after a failure is inert.
    for (int i = 1; i <= 4; i++) {
        CHECK_NOTHROW(h.update(
            withBanner(noScrollBarFrameAt(kPastStationary * static_cast<uint64>(i + 1), /*nonce=*/0)),
            SceneState{SkillPage, record::Standard}));
    }

    if (directory_survives) {
        CHECK(h.failures.empty());
        CHECK(std::filesystem::exists(session_dir / path_config.base.filename()));
    } else {
        REQUIRE(h.failures.size() == 1);
        CHECK(h.failures[0].record_id == h.starts[0].record_id);
        CHECK(h.completions == 0);
        // The attempt is over: a later frame does nothing, and the close adds no second, vaguer outcome.
        CHECK_NOTHROW(h.update(
            withBanner(noScrollBarFrameAt(kPastStationary * 8, /*nonce=*/0)), SceneState{SkillPage, record::Standard}));
        CHECK(h.failures.size() == 1);
        h.closed->send();
        CHECK(closed_unfinished.empty());
    }
}

TEST_CASE("a tab button that cannot be written ends the attempt under the id it was announced with") {
    ScraperHarness h;
    std::vector<RecordInfo> closed_unfinished;
    h.closed_before_completed->listen(
        [&closed_unfinished](const RecordInfo &info) { closed_unfinished.push_back(info); });

    // The skill tab's directory is recorded but never created, so writes into it fail while the session itself
    // is built exactly as usual.
    h.recorder.silent_stem = path_config.skill.stem();
    h.opened->send(SceneInfo{record::Standard});
    REQUIRE(h.starts.size() == 1);

    // A fixed nonce settles the tab-button crop together with the content, and SceneScraper::update asks the
    // button first, so addTabButton is the write that fails.
    CHECK_NOTHROW(captureWithoutScrolling(h, SkillPage, 0));

    REQUIRE(h.failures.size() == 1);
    CHECK(h.failures[0].record_id == h.starts[0].record_id);
    CHECK(h.pages_ready.empty());
    CHECK(h.completions == 0);

    CHECK_NOTHROW(captureWithoutScrolling(h, SkillPage, kPastStationary * 4));
    CHECK(h.failures.size() == 1);
    CHECK(h.pages_ready.empty());

    h.closed->send();
    CHECK(closed_unfinished.empty());
}

TEST_CASE("a scroll-area fragment that cannot be written ends the attempt, and no tab is reported ready") {
    // THE OUTCOME THAT IS NOT A STALL. saveIncremental increments the fragment count while BUILDING the path,
    // so a write that throws leaves the box counting a file that is not on disk; the tab then reads ready over
    // a fragment set with a hole in it, the session completes, and the stitcher hands back a record short by a
    // strip -- reported as a success. `pages_ready` staying empty is what pins that, and it is the assertion
    // this case exists for.
    ScraperHarness h;
    std::vector<RecordInfo> closed_unfinished;
    h.closed_before_completed->listen(
        [&closed_unfinished](const RecordInfo &info) { closed_unfinished.push_back(info); });

    h.recorder.silent_stem = path_config.skill.stem();
    h.opened->send(SceneInfo{record::Standard});
    REQUIRE(h.starts.size() == 1);

    // An alternating nonce repaints everything above the scroll area, so the tab-button crop never settles and
    // the content latch is the only write these frames drive.
    CHECK_NOTHROW(h.update(noScrollBarFrameAt(0, /*nonce=*/0), SceneState{SkillPage, record::Standard}));
    CHECK(h.failures.empty());
    CHECK_NOTHROW(h.update(noScrollBarFrameAt(kPastStationary, /*nonce=*/1), SceneState{SkillPage, record::Standard}));

    REQUIRE(h.failures.size() == 1);
    CHECK(h.failures[0].record_id == h.starts[0].record_id);
    CHECK(h.pages_ready.empty());
    CHECK(h.completions == 0);

    CHECK_NOTHROW(
        h.update(noScrollBarFrameAt(kPastStationary * 4, /*nonce=*/0), SceneState{SkillPage, record::Standard}));
    CHECK(h.failures.size() == 1);
    CHECK(h.pages_ready.empty());

    h.closed->send();
    CHECK(closed_unfinished.empty());
}

TEST_CASE("a crop that falls outside the frame still degrades for that frame alone") {
    // THE OTHER SIDE OF THE CATCH, and the reason it names a type instead of catching everything. A rect that
    // does not fit the frame is a property of the configuration and the frame size, not of the session: the
    // next frame is read again from scratch, nothing is half-written, and the attempt must survive it. A
    // catch(...) around the same calls would end the attempt here, which is what this case refuses.
    auto config = shippedScraperConfig();
    config.common.tab_button_rect = Rect<double>{Point<double>{0.0, 0.0}, Point<double>{4.0, 4.0}};
    ScraperHarness h(config);
    std::vector<RecordInfo> closed_unfinished;
    h.closed_before_completed->listen(
        [&closed_unfinished](const RecordInfo &info) { closed_unfinished.push_back(info); });

    h.opened->send(SceneInfo{record::Standard});
    REQUIRE(h.starts.size() == 1);

    // The tab-button catcher crops with that rect, inside the same call the fragment writes are reached
    // through, so the throw travels the exact path the catch sits on. Counted over the two frames the tab
    // needs rather than pinned to one, because which frame first reaches the crop is the catcher's business,
    // not this case's: what is pinned is that it reaches the CALLER, and that the attempt is still standing.
    int escaped = 0;
    for (const uint64 at : {uint64{0}, kPastStationary}) {
        try {
            h.update(withBanner(noScrollBarFrameAt(at, /*nonce=*/0)), SceneState{SkillPage, record::Standard});
        } catch (const std::out_of_range &) {
            escaped++;
        }
    }
    CHECK(escaped > 0);
    CHECK(h.failures.empty());

    // The session announced at the open is still the one in place: closing it reports an unfinished capture,
    // which an attempt ended by failSession does not.
    h.closed->send();
    REQUIRE(closed_unfinished.size() == 1);
    CHECK(closed_unfinished[0].record_id == h.starts[0].record_id);
}

TEST_CASE("a tab with no scroll bar keeps awaiting from its content latch until its tab button settles") {
    // THE GAP. The page's one fragment is latched when its CONTENT holds still, but the tab is complete only when its
    // tab-button crop has held still too. Between the two the core still needs the page left alone, so the wait
    // must not end at the latch. The nonce repaints everything above the scroll area, which is where the tab button
    // lives, so alternating it keeps the button moving while the content stays put.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});

    h.update(factorPageWithoutScrollBar(0, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));
    CHECK(h.scrollBarWord(FactorPage) == "false");
    // Not armed before the latch: there is nothing for the switch rule to compare with yet.
    CHECK(h.armedLevel() == std::optional<bool>(false));

    h.update(factorPageWithoutScrollBar(kPastStationary, /*nonce=*/1), SceneState{FactorPage, record::Standard});
    // Latched: the probe fired and the switch rule holds its witness, stated on the latch frame...
    REQUIRE(h.probe_frames.size() == 1);
    CHECK(h.probe_frames.front().timestamp() == kPastStationary);
    CHECK(h.armedLevel() == std::optional<bool>(true));
    // ...but the tab is not complete, so the wait stands.
    CHECK(h.pages_ready.empty());
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));

    h.update(factorPageWithoutScrollBar(2 * kPastStationary, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    CHECK(h.pages_ready.empty());
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(true));

    // The tab button now holds still past the threshold: the tab completes, and only now does the wait end.
    h.update(factorPageWithoutScrollBar(3 * kPastStationary, /*nonce=*/0), SceneState{FactorPage, record::Standard});
    CHECK(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});
    CHECK(h.awaitingLevel(FactorPage) == std::optional<bool>(false));
    CHECK(h.eventBefore("page_ready:1", "awaiting:1:false"));
    CHECK(h.armed == std::vector<bool>{false, true});
    CHECK(h.discards.empty());
    CHECK(h.probe_cues == std::vector<bool>{false});
}

TEST_CASE("a completed tab stays completed for the rest of its session, whichever tab is shown in between") {
    // AN INVARIANT THE FRONT END RESTS ON. It holds "this tab is complete" from onPageReady until the session ends,
    // with no message to withdraw it, because the core has no transition that un-completes a tab within a session:
    // leaving a complete tab rebuilds nothing (handleTabSwitchInProgress), so its wait, its ring and its
    // completion stay as they were.
    SUBCASE("a page with no scroll bar") {
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        uint64 at = captureWithoutScrolling(h, SkillPage, 0);
        REQUIRE(h.pages_ready == std::vector<int>{static_cast<int>(SkillPage)});
        const auto updates_before = h.scrollUpdatesOf(SkillPage);

        h.update(withBanner(noScrollBarFrameAt(at + 100, /*nonce=*/1)), SceneState{CampaignPage, record::Standard});
        at = captureWithoutScrolling(h, SkillPage, at + 200);

        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(SkillPage)});
        CHECK(h.scrollUpdatesOf(SkillPage) == updates_before);
        CHECK(h.awaitingLevels(SkillPage) == std::vector<bool>{true, false});
    }
    SUBCASE("a factor page captured by scrolling, which also keeps its witness") {
        ScraperHarness h;
        h.scraper.build(SceneInfo{record::Standard});
        uint64 at = captureFactorByScrolling(h, 0);
        REQUIRE(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});
        const auto updates_before = h.scrollUpdatesOf(FactorPage);

        h.update(withBanner(noScrollBarFrameAt(at + 100, /*nonce=*/1)), SceneState{SkillPage, record::Standard});
        const auto look = withBanner(scrollBarFrameAt(at + 200, /*exposed_rows=*/0, /*nonce=*/0));
        h.update(look, SceneState{FactorPage, record::Standard});
        h.update(
            withBanner(scrollBarFrameAt(at + 200 + kPastStationary, /*exposed_rows=*/0, /*nonce=*/0)),
            SceneState{FactorPage, record::Standard});

        CHECK(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});
        CHECK(h.scrollUpdatesOf(FactorPage) == updates_before);
        CHECK(h.awaitingLevels(FactorPage) == std::vector<bool>{true, false});
        CHECK(h.armed == std::vector<bool>{false, true});
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
    h.scraper.build(SceneInfo{record::Standard});
    const uint64 captured =
        complete ? completeSession(h, captureFactorWithoutScrollBar) : captureWithoutScrolling(h, tab, 0);
    REQUIRE(std::find(h.pages_ready.begin(), h.pages_ready.end(), static_cast<int>(tab)) != h.pages_ready.end());
    REQUIRE(h.completions == (complete ? 1 : 0));

    const uint64 first_top = captured + 100;
    for (int i = 0; i < 4; i++) {
        h.update(
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
    h.scraper.build(SceneInfo{record::Standard});
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
    // THE RESET THIS GUARDS AGAINST. Such a page is captured on the frame it settles on, and the user has nowhere
    // to scroll it, so it stays at the head of its content for as long as it is displayed. A rule that took "a
    // captured tab at the head for the dwell" for a switch would discard it with nobody having switched. Its latch
    // installs a witness, so Rule 3 watches it, and an unchanged page nominates nothing, however many dwells pass.
    bool complete = false;
    SUBCASE("while the other tabs are still to be captured") {
        complete = false;
    }
    SUBCASE("after the whole session is captured") {
        complete = true;
    }
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});
    uint64 at = captureFactorWithoutScrollBar(h, 0);
    if (complete) {
        at = captureWithoutScrolling(h, SkillPage, at + 100);
        at = captureWithoutScrolling(h, CampaignPage, at + 100);
    }
    REQUIRE(h.completions == (complete ? 1 : 0));

    for (int i = 0; i < 4; i++) {
        h.update(
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
    h.scraper.build(SceneInfo{record::Standard});
    const uint64 captured = captureFactorByScrolling(h, 0);
    REQUIRE(h.pages_ready == std::vector<int>{static_cast<int>(FactorPage)});

    // A different list, on frames that draw neither the scroll bar nor the header.
    const FrameAt unplaceable = [](uint64 timestamp, int nonce) {
        return withContentTexture(noScrollBarFrameAt(timestamp, nonce), shippedScraperConfig().common, 0);
    };
    holdFactorDivergence(h, captured + 100, /*nonce=*/2, unplaceable, record::Standard);
    // No thumb on the frame: the factor tab reads "unknown", as any tab does whose thumb cannot be read, without
    // asking the header. Rule 3 resolves that fail-closed, so its gate stays shut.
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
    h.scraper.build(SceneInfo{record::Standard});
    uint64 at = captureWithoutScrolling(h, SkillPage, 0);
    at = captureWithoutScrolling(h, CampaignPage, at + 100);

    // Alternating between two lists, so no two consecutive frames match and the page never settles.
    for (int i = 0; i < 4; i++) {
        const uint64 timestamp = at + 100 + static_cast<uint64>(i) * kPastDwell;
        h.update(
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
    h.scraper.build(SceneInfo{record::Standard});
    const uint64 completed_at = completeSession(h, captureFactorByScrolling);
    REQUIRE(h.completions == 1);

    const uint64 first_top = completed_at + 100;
    for (int i = 0; i < 4; i++) {
        h.update(
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
    // The same property from Rule 3's side, which a captured factor tab needs: leaving a tab still being captured
    // rebuilds it and drops the dwell, but a captured tab is not rebuilt, so nothing else drops its dwell.
    ScraperHarness h;
    h.scraper.build(SceneInfo{record::Standard});
    const uint64 completed_at = completeSession(h, captureFactorByScrolling);
    REQUIRE(h.completions == 1);

    const uint64 opened = completed_at + 100;
    h.update(texturedLook(opened, /*nonce=*/2), SceneState{FactorPage, record::Standard});
    // A campaign frame: a tab no rule watches, so the visit is nothing but a frame Rule 3 did not judge.
    h.update(noScrollBarFrameAt(opened + 10, /*nonce=*/3), SceneState{CampaignPage, record::Standard});
    h.update(texturedLook(opened + kPastDwell, /*nonce=*/4), SceneState{FactorPage, record::Standard});
    CHECK(h.framesRead().empty());
    CHECK(h.verdicts.empty());

    // The control: the dwell restarted on that frame, and a dwell later the frames are read.
    h.update(texturedLook(opened + 2 * kPastDwell, /*nonce=*/5), SceneState{FactorPage, record::Standard});
    CHECK(h.verdictsStated() == std::vector<scraper_impl::FactorSwitchVerdict>{scraper_impl::FactorSwitchVerdict::Same});
    CHECK(h.discards.empty());
}

}  // namespace
}  // namespace uma::chara_detail
