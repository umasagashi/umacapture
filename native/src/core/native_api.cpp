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
    assert_(!isRunning());
}

void NativeApi::startEventLoop(const std::string &native_config) {
    vlog_debug(native_config.length(), isRunning());
    if (isRunning()) {
        return;
    }

    const auto config_json = json_util::Json::parse(native_config);
    const bool video_mode = config_json["video_mode"].get<bool>();
    vlog_debug(video_mode);

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

    const auto stitcher_runner = event_util::makeSingleThreadRunner(queue_limit_mode, detach_callback, "stitcher");
    event_runners->add(stitcher_runner);

    const auto closed_before_completed_connection = event_util::makeDirectConnection<std::string>();
    closed_before_completed_connection->listen([this](const std::string &id) { notifyCharaDetailFinished(id, false); });

    const auto scroll_ready_connection = event_util::makeDirectConnection<int>();
    scroll_ready_connection->listen([this](int index) { notifyScrollReady(index); });

    const auto scroll_updated_connection = event_util::makeDirectConnection<int, double>();
    scroll_updated_connection->listen([this](int index, double progress) { notifyScrollUpdated(index, progress); });

    const auto page_ready_connection = event_util::makeDirectConnection<int>();
    page_ready_connection->listen([this](int index) { notifyPageReady(index); });

    const auto stitch_ready_connection = stitcher_runner->makeConnection<std::string>();

    const auto scraping_dir = config_json["chara_detail"]["scraping_dir"].get<std::filesystem::path>();
    chara_detail_scene_scraper = std::make_unique<chara_detail::CharaDetailSceneScraper>(
        chara_detail_opened_connection,
        chara_detail_updated_connection,
        chara_detail_closed_connection,
        closed_before_completed_connection,
        scroll_ready_connection,
        scroll_updated_connection,
        page_ready_connection,
        stitch_ready_connection,
        config_json["chara_detail"]["scene_scraper"].get<chara_detail::scraper_config::CharaDetailSceneScraperConfig>(),
        scraping_dir);

    const auto recognizer_runner = event_util::makeSingleThreadRunner(queue_limit_mode, detach_callback, "recognizer");
    event_runners->add(recognizer_runner);

    const auto recognize_ready_connection = recognizer_runner->makeConnection<std::string>();

    const auto stitcher_dir = config_json["storage_dir"].get<std::filesystem::path>();
    chara_detail_scene_stitcher = std::make_unique<chara_detail::CharaDetailSceneStitcher>(
        scraping_dir,
        stitcher_dir,
        stitch_ready_connection,
        recognize_ready_connection,
        config_json["chara_detail"]["scene_stitcher"]
            .get<chara_detail::stitcher_config::CharaDetailSceneStitcherConfig>());

    const auto chara_detail_completed_connection = recognizer_runner->makeConnection<std::string>();
    chara_detail_completed_connection->listen([this](const std::string &id) {
        // for debug
        notifyCharaDetailFinished(id, true);
    });

    chara_detail_recognizer = std::make_unique<chara_detail::CharaDetailRecognizer>(
        config_json["trainer_id"].get<std::string>(),
        stitcher_dir,
        config_json["module_dir"].get<std::filesystem::path>(),
        recognize_ready_connection,
        chara_detail_completed_connection,
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

void NativeApi::updateFrame(const cv::Mat &image, uint64 timestamp) {
    on_frame_captured->send({image, timestamp});
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
    std::cout << (chara_detail_scene_stitcher == nullptr);
    std::cout << (chara_detail_recognizer == nullptr);
}

}  // namespace uma::app
