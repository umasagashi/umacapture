#include "chara_detail/chara_detail_scene_context.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "util/common.h"
#include "util/logger_util.h"

#include "native_api.h"

namespace uma {

NativeApi::NativeApi() = default;  // Do not use Native::instance() in this constructor.

NativeApi::~NativeApi() {
    assert_(!isRunning());
}

void NativeApi::startEventLoop(const std::string &native_config) {
    log_debug("");
    vlog_debug(native_config.length(), isRunning());
    if (isRunning()) {
        return;
    }

    assert_(event_runners == nullptr);
    event_runners = std::make_unique<EventRunnerController>();

    const auto config_json = json_utils::Json::parse(native_config);

    const auto distributor_runner = connection::event_runner::makeSingleThreadRunner(detach_callback, "distributor");
    event_runners->add(distributor_runner);
    const auto frame_captured_connection = distributor_runner->makeConnection<Frame>();
    on_frame_captured = frame_captured_connection;

    const auto scraper_runner = connection::event_runner::makeSingleThreadRunner(detach_callback, "scraper");
    event_runners->add(scraper_runner);

    const auto chara_detail_updated_connection = scraper_runner->makeConnection<Frame, chara_detail::SceneInfo>();
    const auto chara_detail_opened_connection = scraper_runner->makeConnection<>();
    const auto chara_detail_closed_connection = scraper_runner->makeConnection<>();

    {
        const auto scene_context = std::make_shared<chara_detail::CharaDetailSceneContext>(
            serializer::conditionFromJson(config_json["chara_detail"]["scene_context"]),
            chara_detail_opened_connection,
            chara_detail_updated_connection,
            chara_detail_closed_connection,
            std::chrono::milliseconds(1000));

        frame_distributor = std::make_unique<FrameDistributor>(
            std::vector<std::shared_ptr<chara_detail::CharaDetailSceneContext>>{
                scene_context,
            },
            frame_captured_connection,
            nullptr);
    }

    const auto stitcher_runner = connection::event_runner::makeSingleThreadRunner(detach_callback, "stitcher");
    event_runners->add(stitcher_runner);

    // TODO: Connect.
    const auto closed_before_completed_connection = connection::makeDirectConnection<>();
    closed_before_completed_connection->listen([]() { log_info("on_closed_before_completed"); });

    const auto scroll_ready_connection = connection::makeDirectConnection<>();
    scroll_ready_connection->listen([]() { log_info("on_scroll_ready"); });

    const auto page_ready_connection = connection::makeDirectConnection<>();
    page_ready_connection->listen([]() { log_info("on_page_ready"); });

    const auto stitch_ready_connection = stitcher_runner->makeConnection<std::string>();
    stitch_ready_connection->listen([](const std::string &id) { log_info("on_stitch_ready: {}", id); });

    chara_detail_scene_scraper = std::make_unique<chara_detail::CharaDetailSceneScraper>(
        chara_detail_opened_connection,
        chara_detail_updated_connection,
        chara_detail_closed_connection,
        closed_before_completed_connection,
        scroll_ready_connection,
        page_ready_connection,
        stitch_ready_connection,
        config_json["chara_detail"]["scene_scraper"].get<chara_detail::CharaDetailSceneScraperConfig>(),
        config_json["chara_detail"]["scraping_dir"].get<std::filesystem::path>());

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
}

bool NativeApi::isRunning() const {
    return event_runners && event_runners->isRunning();
}

void NativeApi::updateFrame(const cv::Mat &image, uint64 timestamp) {
    // TODO: Count number of queued frames.
    // If background threads are not keeping up, frame has to be discarded rather than queued.
    on_frame_captured->send({image, timestamp});
}

void NativeApi::notifyCaptureStarted() {
    log_debug("");
    notify(json_utils::Json{{"type", "onCaptureStarted"}}.dump());
}

void NativeApi::notifyCaptureStopped() {
    log_debug("");
    notify(json_utils::Json{{"type", "onCaptureStopped"}}.dump());
}

[[maybe_unused]] void NativeApi::_dummyForSuppressingUnusedWarning() {
    log_fatal("Do not use this method.");
    NativeApi::instance();
    startEventLoop({});
    joinEventLoop();
    updateFrame({}, 0);
    setNotifyCallback({});
    setDetachCallback({});
    setMkdirCallback({});
    setLoggingCallback({});
    notifyCaptureStarted();
    notifyCaptureStopped();
    std::cout << (frame_distributor == nullptr);
    std::cout << (chara_detail_scene_scraper == nullptr);
}

}
