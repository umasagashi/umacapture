// Wiring tests for NativeApi itself: the object the app runs, built by its own constructor and started with the
// shipped config, so what is under test is the pipeline assembly in src/core/native_api.cpp -- which stage is
// handed which connection, which counters a new run resets, and what a failure tells the front end.
//
// The predictors come from the test target's makePredictor (chara_detail/fake_predictor_factory.cpp), which loads
// no model, so a whole pipeline can be built and torn down without onnxruntime or a model set. No frames are
// produced: every case here drives a stage directly through the connection the production code gave it.
//
// WHAT THESE CASES CANNOT SEE. Two of the three connections that end an attempt -- closed_before_completed and
// scrape_failed -- are reachable only from inside CharaDetailSceneScraper, i.e. only from a real detail screen
// recognized out of real frames, so no case here can assert which listener startPipeline attached to them. What
// is asserted for all three is the listener's body, notifyAttemptFailed, and for stitch_failed also the
// attachment. Frame production, the preview emission, and everything in windows/runner and native/wasm remain
// outside this target.

#include <doctest/doctest.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <memory>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/fake_predictor_factory.h"
#include "chara_detail/record_info.h"
#include "core/native_api.h"
#include "core/native_api_test_access.h"
#include "util/json_util.h"

namespace uma::app {
namespace {

// A scratch root nothing else writes into. The pipeline creates its own directories under it; a case that wants
// a stitch to fail simply never puts fragments there.
std::filesystem::path scratchRoot() {
    static const auto root = std::filesystem::temp_directory_path()
                             / ("uma_native_api_wiring_" + std::to_string(std::random_device{}()));
    return root;
}

// The config a pipeline is built from, assembled out of the shipped assets/config JSONs -- the same files the
// app and the CLI hand to startEventLoop. Reading the shipped configuration is deliberate: a hand-written
// fixture would be a second answer to "what does the app run with", and the one place this test could then be
// green about a pipeline nobody ships.
json_util::Json shippedConfig(const std::string &scratch_name) {
    const auto config_dir = std::filesystem::path(TEST_ASSET_CONFIG_DIR);
    const auto output_dir = scratchRoot() / scratch_name;
    return {
        {"chara_detail",
         {
             {"scene_context", json_util::read(config_dir / "chara_detail" / "scene_context.json")},
             {"scene_scraper", json_util::read(config_dir / "chara_detail" / "scene_scraper.json")},
             {"scene_stitcher", json_util::read(config_dir / "chara_detail" / "scene_stitcher.json")},
             {"recognizer", json_util::read(config_dir / "chara_detail" / "recognizer.json")},
         }},
        {"video_mode", false},
        {"directory",
         {
             {"temp_dir", (output_dir / "temp").string()},
             {"storage_dir", (output_dir / "storage").string()},
             {"modules_dir", (output_dir / "modules").string()},
         }},
        {"trainer_id", "wiring-test-trainer"},
    };
}

// Collects every notify() payload the instance pushes, from whichever thread pushes it.
class NotifySpy {
public:
    void install(NativeApi &api) {
        api.setNotifyCallback([this](const std::string &message) {
            const std::lock_guard<std::mutex> lock(mutex);
            messages.push_back(json_util::Json::parse(message));
        });
    }

    [[nodiscard]] std::vector<json_util::Json> collected() const {
        const std::lock_guard<std::mutex> lock(mutex);
        return messages;
    }

    void clear() {
        const std::lock_guard<std::mutex> lock(mutex);
        messages.clear();
    }

    // Waits for `count` messages to arrive, polling rather than sleeping a fixed span: the stitcher answers on
    // its own thread, so the only thing to wait for is its answer.
    [[nodiscard]] std::vector<json_util::Json> waitFor(size_t count) const {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (std::chrono::steady_clock::now() < deadline) {
            auto snapshot = collected();
            if (snapshot.size() >= count) {
                return snapshot;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
        return collected();
    }

private:
    mutable std::mutex mutex;
    std::vector<json_util::Json> messages;
};

// Every NativeApi a case builds is joined here: a pipeline left running keeps its runner threads alive past the
// end of the case, and ~NativeApi would then be the first thing to notice.
struct PipelineUnderTest {
    std::unique_ptr<NativeApi> api = NativeApiTestAccess::create();
    NotifySpy spy;

    PipelineUnderTest() { spy.install(*api); }
    ~PipelineUnderTest() { api->joinEventLoop(); }

    PipelineUnderTest(const PipelineUnderTest &) = delete;
    PipelineUnderTest &operator=(const PipelineUnderTest &) = delete;
};

size_t occurrences(const std::vector<std::string> &names, const std::string &name) {
    return static_cast<size_t>(std::count(names.begin(), names.end(), name));
}

// ---------------------------------------------------------------------------
// A new run resets what the run produced -- at BOTH hook sites.
// ---------------------------------------------------------------------------

TEST_CASE("a pipeline start begins a new run's record count") {
    PipelineUnderTest pipeline;
    pipeline.api->notifyCharaDetailFinished({"previous-run-record", std::nullopt}, true);
    REQUIRE(pipeline.api->recordsProduced() == 1);

    pipeline.api->startEventLoop(shippedConfig("start_resets").dump());
    REQUIRE(pipeline.api->isRunning());

    CHECK(pipeline.api->recordsProduced() == 0);
}

TEST_CASE("a capture session that adopts a running loop also begins a new run") {
    // The site the local golden suite structurally cannot reach: its cases start the loop directly and own no
    // capture session, so nothing there ever adopts. An adoption skips startPipeline entirely, which is why the
    // reset has to exist in startCaptureSession as well.
    PipelineUnderTest pipeline;
    const auto config = shippedConfig("adopt_resets").dump();
    pipeline.api->startEventLoop(config);
    REQUIRE(pipeline.api->isRunning());

    pipeline.api->notifyCharaDetailFinished({"passenger-run-record", std::nullopt}, true);
    REQUIRE(pipeline.api->recordsProduced() == 1);

    // Emptied AFTER the loop is up, so any predictor built from here on can only come from a second
    // startPipeline. That is what tells an adoption apart from a rebuild, and without it this case would pass
    // either way -- a rebuild resets the count too.
    chara_detail::recognizer_impl::resetBuiltPredictorNames();
    const auto start = pipeline.api->startCaptureSession(CaptureSessionKind::Live, config);
    REQUIRE(start.verdict == CaptureSessionVerdict::Started);
    REQUIRE(chara_detail::recognizer_impl::builtPredictorNames().empty());

    CHECK(pipeline.api->recordsProduced() == 0);
    pipeline.api->endCaptureSession(CaptureSessionKind::Live);
}

// ---------------------------------------------------------------------------
// A terminal failure of one attempt.
// ---------------------------------------------------------------------------

TEST_CASE("a stitch failure finishes the attempt it names and reports the reason against that id") {
    PipelineUnderTest pipeline;
    pipeline.api->startEventLoop(shippedConfig("stitch_failure").dump());
    REQUIRE(pipeline.api->isRunning());

    // Announced first, so the id the failure carries has a source other than "the latest thing that happened".
    pipeline.api->notifyCharaDetailStarted({"attempt-alpha", std::nullopt});
    // A LATER attempt, announced before the earlier one's stitch is even attempted. The stitcher runs on its own
    // thread, so this is the real arrival order a front end has to survive, and the failure must still name
    // alpha.
    pipeline.api->notifyCharaDetailStarted({"attempt-beta", std::nullopt});
    pipeline.spy.clear();

    // Nothing ever scraped fragments for alpha, so the stitcher fails on its first read.
    REQUIRE(NativeApiTestAccess::sendStitchReady(*pipeline.api, {"attempt-alpha", std::nullopt}));

    const auto messages = pipeline.spy.waitFor(2);
    REQUIRE(messages.size() == 2);
    CHECK(messages[0].at("type") == "onCharaDetailFinished");
    CHECK(messages[0].at("id") == "attempt-alpha");
    CHECK(messages[0].at("success") == false);
    CHECK(messages[1].at("type") == "onError");
    CHECK(messages[1].at("message") == "stitch_failed");
    REQUIRE(messages[1].contains("record_id"));
    CHECK(messages[1].at("record_id") == "attempt-alpha");
}

TEST_CASE("every terminal attempt failure is one finish and one id-scoped error") {
    // The body all three of startPipeline's attempt-ending listeners run. The tag is what distinguishes them;
    // that a tag reaches the front end scoped to its own attempt is one answer, given once.
    PipelineUnderTest pipeline;
    for (const std::string tag: {"closed_before_completed", "scrape_failed", "stitch_failed"}) {
        pipeline.spy.clear();
        pipeline.api->notifyAttemptFailed({"attempt-" + tag, std::nullopt}, tag);

        const auto messages = pipeline.spy.collected();
        REQUIRE(messages.size() == 2);
        CHECK(messages[0].at("type") == "onCharaDetailFinished");
        CHECK(messages[0].at("id") == "attempt-" + tag);
        CHECK(messages[0].at("success") == false);
        CHECK(messages[1].at("type") == "onError");
        CHECK(messages[1].at("message") == tag);
        REQUIRE(messages[1].contains("record_id"));
        CHECK(messages[1].at("record_id") == "attempt-" + tag);
    }
    // A failure produced no record, so it must not raise the run's count.
    CHECK(pipeline.api->recordsProduced() == 0);
}

// ---------------------------------------------------------------------------
// A pipeline that cannot be built.
// ---------------------------------------------------------------------------

TEST_CASE("a pipeline that fails to build reports why and leaves nothing running") {
    PipelineUnderTest pipeline;
    auto config = shippedConfig("build_failure");
    config.erase("trainer_id");

    pipeline.api->startEventLoop(config.dump());

    const auto messages = pipeline.spy.collected();
    REQUIRE(messages.size() == 1);
    CHECK(messages[0].at("type") == "onError");
    // The reason, not merely that one arrived: a fixture that stopped parsing for an unrelated reason would
    // otherwise pass this case while testing nothing.
    CHECK(messages[0].at("message").get<std::string>().find("trainer_id") != std::string::npos);
    CHECK_FALSE(pipeline.api->isRunning());
}

// ---------------------------------------------------------------------------
// One factor-row reader per pipeline.
// ---------------------------------------------------------------------------

TEST_CASE("a pipeline builds the factor-tab models once and shares them between both readers of factor rows") {
    // startPipeline builds ONE FactorRowReader and hands it to both stages that read factor rows (the scene
    // scraper and the recognizer). A second reader would build that model set a second time -- invisible in any
    // recognition result, because two readers recognize identically; the whole cost is the duplicated model set.
    //
    // WHICH names those are is asked of a reader rather than listed here, so a model added to the factor tab is
    // covered without this case being edited. Names are compared per model and not globally: other stages
    // legitimately build predictors under the same name as each other (a record's character is read by more than
    // one recognizer), so "no name twice" is not the invariant.
    const auto config = shippedConfig("one_reader");
    const auto recognizer_config =
        config["chara_detail"]["recognizer"].get<chara_detail::recognizer_config::CharaDetailRecognizerConfig>();
    const auto modules_dir = json_util::decodePath(config["directory"]["modules_dir"]);

    chara_detail::recognizer_impl::resetBuiltPredictorNames();
    { const chara_detail::recognizer_impl::FactorRowReader reader(modules_dir, recognizer_config.factor_tab); }
    const auto reader_names = chara_detail::recognizer_impl::builtPredictorNames();
    REQUIRE_FALSE(reader_names.empty());

    chara_detail::recognizer_impl::resetBuiltPredictorNames();
    PipelineUnderTest pipeline;
    pipeline.api->startEventLoop(config.dump());
    REQUIRE(pipeline.api->isRunning());
    const auto pipeline_names = chara_detail::recognizer_impl::builtPredictorNames();

    for (const auto &name: reader_names) {
        const auto built = occurrences(pipeline_names, name);
        CHECK_MESSAGE(built == occurrences(reader_names, name),
                      "factor-tab model '" << name << "' was built " << built << " time(s) in one pipeline");
    }
}

}  // namespace
}  // namespace uma::app
