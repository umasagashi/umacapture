#include "util/common.h"

#include "native_api.h"

namespace {

void _dummyForSuppressingUnusedWarning() {
    auto &app = NativeApi::instance();
    app.startEventLoop();
    app.joinEventLoop();
    app.updateFrame({}, 0);
    app.setConfig({});
    app.setCallback({});
}

}  // namespace

NativeApi::NativeApi() {
    {
        auto connection = connection::make_connection<connection::QueuedConnection<Frame>>();
        frame_captured = connection;
        frame_supplier = connection;
        recorder_runner = connection::make_runner(connection, [this]() { finalizer(); });
    }

    {
        auto connection = connection::make_connection<connection::QueuedConnection<Frame, chara_detail::SceneInfo>>();
        chara_detail_updated = connection;
        stitcher_runner = connection::make_runner(connection, [this]() { finalizer(); });
        stitcher_runner->start();
        connection->listen([](const Frame &frame, const chara_detail::SceneInfo &info) {
            std::cout << "chara_detail_updated: " << info.tab_page << std::endl;
        });
    }

    {
        auto connection = connection::make_connection<connection::DirectConnection<>>();
        chara_detail_opened = connection;
        chara_detail_closed = connection;
        connection->listen([]() { std::cout << "chara_detail_opened/closed" << std::endl; });
    }

    timestamp_for_debug = std::chrono::steady_clock::now();
}

NativeApi::~NativeApi() {
    joinEventLoop();
    stitcher_runner->join();
}

void NativeApi::setConfig(const std::string &native_config) {
    std::cout << __FUNCTION__ << ": " << native_config << std::endl;
    auto config_json = json_utils::Json::parse(native_config);

    auto directory = config_json.find("directory");
    if (directory != config_json.end()) {
        path_for_debug = directory->get<std::string>();
    }

    auto context = config_json.find("context");
    if (context != config_json.end()) {
        const auto context_dir = std::filesystem::path(context->get<std::string>());

        const auto chara_detail_path = (context_dir / "chara_detail.json").generic_string();
        const auto chara_detail_context = std::make_shared<chara_detail::CharaDetailSceneContext>(
            serializer::conditionFromJson(json_utils::Json::parse(io::read(chara_detail_path))),
            chara_detail_opened,
            chara_detail_updated,
            chara_detail_closed,
            std::chrono::milliseconds(1000));

        frame_distributor = std::make_unique<FrameDistributor>(
            std::vector<std::shared_ptr<chara_detail::CharaDetailSceneContext>>{chara_detail_context}, frame_supplier, nullptr);
    }

    this->config = native_config;
}

void NativeApi::setCallback(const std::function<MessageCallback> &method) {
    this->callback_to_ui = method;
}

void NativeApi::setFinalizer(const std::function<FinalizerCallback> &method) {
    this->finalizer = method;
}

void NativeApi::updateFrame(const cv::Mat &image, uint64 timestamp) {
    // TODO: Count number of queued frames.
    // If background threads are not keeping up, frame has to be discarded rather than queued.
    frame_captured->send({image, timestamp});
}

void NativeApi::startEventLoop() {
    std::cout << __FUNCTION__ << std::endl;
    assert(frame_distributor);

    recorder_runner->start();
}

void NativeApi::joinEventLoop() {
    std::cout << __FUNCTION__ << std::endl;

    recorder_runner->join();
}

void NativeApi::notify(const std::string &message) {
    this->callback_to_ui(message);
}

void NativeApi::notifyCaptureStarted() {
    notify(json_utils::Json{{"type", "onCaptureStarted"}}.dump());
}

void NativeApi::notifyCaptureStopped() {
    notify(json_utils::Json{{"type", "onCaptureStopped"}}.dump());
}