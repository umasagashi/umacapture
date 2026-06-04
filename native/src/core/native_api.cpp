#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "chara_detail/chara_detail_scene_stitcher.h"
#include "chara_detail/record_info.h"
#include "util/logger_util.h"
#include "util/misc.h"

#include "native_api.h"

namespace uma::app {

NativeApi::NativeApi() = default;  // Do not use Native::instance() in this constructor.

NativeApi::~NativeApi() {
    // TODO: The event loop must be joined before this instance is deleted.
    //  Otherwise, for some reason, memory management will not work properly.
    assert_(!isRunning());
}

void NativeApi::startEventLoop(const std::string &native_config) {
    vlog_debug(native_config.length(), isRunning());
    if (isRunning()) {
        // TODO: Should be rebuilt when config is changed.
        return;
    }

    const auto config_json = json_util::Json::parse(native_config);
    const bool video_mode = config_json["video_mode"].get<bool>();
    vlog_debug(video_mode);

    log_debug("modules_dir={}", config_json["directory"]["modules_dir"].get<std::string>());
    log_debug("storage_dir={}", config_json["directory"]["storage_dir"].get<std::string>());
    log_debug("temp_dir={}", config_json["directory"]["temp_dir"].get<std::string>());

    const auto queue_limit_mode = video_mode ? event_util::QueueLimitMode::Block : event_util::QueueLimitMode::Discard;

    assert_(event_runners == nullptr);
    event_runners = event_util::makeRunnerController();

    const auto distributor_runner =
        event_util::makeSingleThreadRunner(queue_limit_mode, detach_callback, "distributor");
    event_runners->add(distributor_runner);
    const auto frame_captured_connection = distributor_runner->makeConnection<Frame>();
    on_frame_captured = frame_captured_connection;

    const auto scraper_runner = event_util::makeSingleThreadRunner(queue_limit_mode, detach_callback, "scraper");
    event_runners->add(scraper_runner);

    const auto chara_detail_updated_connection = scraper_runner->makeConnection<Frame, chara_detail::SceneState>();
    const auto chara_detail_opened_connection = scraper_runner->makeConnection<chara_detail::SceneInfo>();
    const auto chara_detail_closed_connection = scraper_runner->makeConnection<>();

    chara_detail_opened_connection->listen([this](const auto &info) { notifyCharaDetailStarted(info.record_type); });

    {
        const auto scene_context = std::make_shared<chara_detail::CharaDetailSceneContext>(
            condition::serializer::conditionFromJson(config_json["chara_detail"]["scene_context"]),
            chara_detail_opened_connection,
            chara_detail_updated_connection,
            chara_detail_closed_connection,
            std::chrono::milliseconds(200),
            std::chrono::milliseconds(1000));

        frame_distributor = std::make_unique<distributor::FrameDistributor>(
            std::vector<std::shared_ptr<distributor::SceneContext>>{
                scene_context,
            },
            frame_captured_connection,
            nullptr);
    }

    // Live capture only: close an open scene when frames stop arriving. The scene-end debounce keys off frame
    // timestamps and cannot advance once the frame source stalls (window closed/minimized). The watchdog detects
    // that stall on the wall clock and posts an idle event onto the distributor runner, so the scene context is
    // closed from the same thread that processes frames. In video mode frames arrive in bursts, so a wall-clock
    // gap is not a real stall; the watchdog is left null there to keep offline replay deterministic.
    if (!video_mode) {
        const auto frame_stalled_connection = distributor_runner->makeConnection<>();
        frame_stalled_connection->listen([this]() {
            if (frame_distributor != nullptr) {
                frame_distributor->onIdle();
            }
        });
        frame_stall_watchdog = std::make_unique<distributor::FrameStallWatchdog>(
            std::chrono::milliseconds(2000), [frame_stalled_connection]() { frame_stalled_connection->send(); });
    }

    const auto stitcher_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::NoLimit, detach_callback, "stitcher");
    event_runners->add(stitcher_runner);

    const auto closed_before_completed_connection = event_util::makeDirectConnection<chara_detail::RecordInfo>();
    closed_before_completed_connection->listen([this](const auto &info) {
        notifyCharaDetailFinished(info, false);
        notifyError("closed_before_completed");
    });

    const auto scroll_ready_connection = event_util::makeDirectConnection<int>();
    scroll_ready_connection->listen([this](int index) { notifyScrollReady(index); });

    const auto scroll_updated_connection = event_util::makeDirectConnection<int, double>();
    scroll_updated_connection->listen([this](int index, double progress) { notifyScrollUpdated(index, progress); });

    const auto page_ready_connection = event_util::makeDirectConnection<int>();
    page_ready_connection->listen([this](int index) { notifyPageReady(index); });

    const auto stitch_ready_connection = stitcher_runner->makeConnection<chara_detail::RecordInfo>();
    on_stitch_ready = stitch_ready_connection;

    lap_time_wrapper = event_util::makeDirectConnection<Frame, chara_detail::SceneState>();
    chara_detail_updated_connection->listen([this](const auto &frame, const auto &info) {
        lap_time_wrapper->send(frame, info);
        const auto &now = std::chrono::steady_clock::now();
        lap_time_buffer.push_back(now);
        if ((now - lap_time_buffer.front()) > report_interval) {
            notifyFrameRateReported(
                static_cast<double>(chrono_util::ms(report_interval) * lap_time_buffer.size())
                / static_cast<double>(chrono_util::ms(lap_time_buffer.back() - lap_time_buffer.front())));
            lap_time_buffer.clear();
        }
    });

    lap_discard_wrapper = event_util::makeDirectConnection<>();
    chara_detail_closed_connection->listen([this]() {
        lap_discard_wrapper->send();
        lap_time_buffer.clear();
    });

    const auto scraping_dir = json_util::decodePath(config_json["directory"]["temp_dir"]) / "chara_detail";

    chara_detail_scene_scraper = std::make_unique<chara_detail::CharaDetailSceneScraper>(
        chara_detail_opened_connection,
        lap_time_wrapper,
        lap_discard_wrapper,
        closed_before_completed_connection,
        scroll_ready_connection,
        scroll_updated_connection,
        page_ready_connection,
        stitch_ready_connection,
        config_json["chara_detail"]["scene_scraper"].get<chara_detail::scraper_config::CharaDetailSceneScraperConfig>(),
        scraping_dir);

    const auto recognizer_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::NoLimit, detach_callback, "recognizer");
    event_runners->add(recognizer_runner);

    const auto recognize_ready_connection = recognizer_runner->makeConnection<chara_detail::RecordInfo>();
    on_recognize_ready = recognize_ready_connection;

    const auto update_ready_connection = recognizer_runner->makeConnection<chara_detail::RecordInfo>();
    on_update_ready = update_ready_connection;

    const auto stitcher_dir =
        json_util::decodePath(config_json["directory"]["storage_dir"]) / "chara_detail" / "active";

    chara_detail_scene_stitcher = std::make_unique<chara_detail::CharaDetailSceneStitcher>(
        scraping_dir,
        stitcher_dir,
        stitch_ready_connection,
        recognize_ready_connection,
        config_json["chara_detail"]["scene_stitcher"]
            .get<chara_detail::stitcher_config::CharaDetailSceneStitcherConfig>());

    const auto recognize_completed_connection = event_util::makeDirectConnection<chara_detail::RecordInfo>();
    recognize_completed_connection->listen(
        [this](const auto &info) { notifyCharaDetailFinished(info, true); });

    const auto update_completed_connection = event_util::makeDirectConnection<chara_detail::RecordInfo>();
    update_completed_connection->listen([this](const auto &info) { notifyCharaDetailUpdated(info); });

    chara_detail_recognizer = std::make_unique<chara_detail::CharaDetailRecognizer>(
        config_json["trainer_id"].get<std::string>(),
        stitcher_dir,
        json_util::decodePath(config_json["directory"]["modules_dir"]),
        recognize_ready_connection,
        recognize_completed_connection,
        update_ready_connection,
        update_completed_connection,
        config_json["chara_detail"]["recognizer"].get<chara_detail::recognizer_config::CharaDetailRecognizerConfig>());

    event_runners->start();

    // Start after the runners so the stall callback never posts onto a runner that is not yet running.
    if (frame_stall_watchdog != nullptr) {
        frame_stall_watchdog->start();
    }
}

void NativeApi::joinEventLoop() {
    vlog_debug(isRunning());
    if (!isRunning()) {
        return;
    }

    // Stop the watchdog before the runners so it cannot post an idle event onto a runner being torn down.
    if (frame_stall_watchdog != nullptr) {
        frame_stall_watchdog->join();
        frame_stall_watchdog = nullptr;
    }

    assert_(event_runners != nullptr);
    event_runners->join();
    event_runners = nullptr;

    frame_distributor = nullptr;
    chara_detail_scene_scraper = nullptr;
    chara_detail_scene_stitcher = nullptr;
    chara_detail_recognizer = nullptr;
}

bool NativeApi::isRunning() const {
    return event_runners && event_runners->isRunning();
}

void NativeApi::updateFrame(const Frame &frame, const Size<int> &original_size) {
    on_frame_captured->send(frame);
    if (frame_stall_watchdog != nullptr) {
        frame_stall_watchdog->notifyFrame();
    }
    const auto &now = std::chrono::steady_clock::now();
    if (now - last_size_reported > report_interval) {
        notifyFrameSizeReported(original_size);
        last_size_reported = now;
    }
}

void NativeApi::updateRecord(const chara_detail::RecordInfo &info) const {
    assert_(isRunning());
    on_update_ready->send(info);
}

[[maybe_unused]] void NativeApi::_dummyForSuppressingUnusedWarning() {
    log_fatal("Do not use this method.");
    NativeApi::instance();
    startEventLoop({});
    joinEventLoop();
    updateFrame({}, {0, 0});
    setNotifyCallback({});
    setDetachCallback({});
    setMkdirCallback({});
    setRmdirCallback({});
    setLoggingCallback({});
    notifyCaptureStarted();
    notifyCaptureStopped();
    updateRecord({});
    notifyScreenshotTaken({}, {});
    std::cout << (frame_distributor == nullptr);
    std::cout << (chara_detail_scene_scraper == nullptr);
    std::cout << (chara_detail_scene_stitcher == nullptr);
    std::cout << (chara_detail_recognizer == nullptr);
    std::cout << (on_recognize_ready == nullptr);
}

}  // namespace uma::app
