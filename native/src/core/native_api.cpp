#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "chara_detail/chara_detail_scene_stitcher.h"
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

    const auto chara_detail_updated_connection = scraper_runner->makeConnection<Frame, chara_detail::SceneInfo>();
    const auto chara_detail_opened_connection = scraper_runner->makeConnection<>();
    const auto chara_detail_closed_connection = scraper_runner->makeConnection<>();

    chara_detail_opened_connection->listen([this]() { notifyCharaDetailStarted(); });

    {
        const auto scene_context = std::make_shared<chara_detail::CharaDetailSceneContext>(
            condition::serializer::conditionFromJson(config_json["chara_detail"]["scene_context"]),
            chara_detail_opened_connection,
            chara_detail_updated_connection,
            chara_detail_closed_connection,
            std::chrono::milliseconds(1000));

        frame_distributor = std::make_unique<distributor::FrameDistributor>(
            std::vector<std::shared_ptr<distributor::SceneContext>>{
                scene_context,
            },
            frame_captured_connection,
            nullptr);
    }

    const auto stitcher_runner =
        event_util::makeSingleThreadRunner(event_util::QueueLimitMode::NoLimit, detach_callback, "stitcher");
    event_runners->add(stitcher_runner);

    const auto closed_before_completed_connection = event_util::makeDirectConnection<std::string>();
    closed_before_completed_connection->listen([this](const std::string &id) {
        notifyCharaDetailFinished(id, false);
        notifyError("closed_before_completed");
    });

    const auto scroll_ready_connection = event_util::makeDirectConnection<int>();
    scroll_ready_connection->listen([this](int index) { notifyScrollReady(index); });

    const auto scroll_updated_connection = event_util::makeDirectConnection<int, double>();
    scroll_updated_connection->listen([this](int index, double progress) { notifyScrollUpdated(index, progress); });

    const auto page_ready_connection = event_util::makeDirectConnection<int>();
    page_ready_connection->listen([this](int index) { notifyPageReady(index); });

    const auto stitch_ready_connection = stitcher_runner->makeConnection<std::string>();
    on_stitch_ready = stitch_ready_connection;

    lap_time_wrapper = event_util::makeDirectConnection<Frame, chara_detail::SceneInfo>();
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

    const auto scraping_dir = json_util::decodePath(config_json["directory"]["temp_dir"]) / "chara_detail";

    chara_detail_scene_scraper = std::make_unique<chara_detail::CharaDetailSceneScraper>(
        chara_detail_opened_connection,
        lap_time_wrapper,
        chara_detail_closed_connection,
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

    const auto recognize_ready_connection = recognizer_runner->makeConnection<std::string>();
    on_recognize_ready = recognize_ready_connection;

    const auto update_ready_connection = recognizer_runner->makeConnection<std::string>();
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

    const auto recognize_completed_connection = event_util::makeDirectConnection<std::string>();
    recognize_completed_connection->listen([this](const auto &id) { notifyCharaDetailFinished(id, true); });

    const auto update_completed_connection = event_util::makeDirectConnection<std::string>();
    update_completed_connection->listen([this](const auto &id) { notifyCharaDetailUpdated(id); });

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
}

void NativeApi::joinEventLoop() {
    vlog_debug(isRunning());
    if (!isRunning()) {
        return;
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

void NativeApi::updateFrame(const cv::Mat &image, const cv::Size &original_size, uint64 timestamp) {
    on_frame_captured->send({image, timestamp});
    const auto &now = std::chrono::steady_clock::now();
    if (now - last_size_reported > report_interval) {
        notifyFrameSizeReported(original_size);
        last_size_reported = now;
    }
}

void NativeApi::updateRecord(const std::string &id) {
    assert_(isRunning());
    on_update_ready->send(id);
}

[[maybe_unused]] void NativeApi::_dummyForSuppressingUnusedWarning() {
    log_fatal("Do not use this method.");
    NativeApi::instance();
    startEventLoop({});
    joinEventLoop();
    updateFrame({}, {}, 0);
    setNotifyCallback({});
    setDetachCallback({});
    setMkdirCallback({});
    setRmdirCallback({});
    setLoggingCallback({});
    notifyCaptureStarted();
    notifyCaptureStopped();
    updateRecord({});
    std::cout << (frame_distributor == nullptr);
    std::cout << (chara_detail_scene_scraper == nullptr);
    std::cout << (chara_detail_scene_stitcher == nullptr);
    std::cout << (chara_detail_recognizer == nullptr);
    std::cout << (on_recognize_ready == nullptr);
}

}  // namespace uma::app
