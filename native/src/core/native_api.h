#pragma once

#include <filesystem>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <utility>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic ppop

#include "chara_detail/record_info.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "util/event_util.h"
#include "util/json_util.h"

namespace uma::chara_detail {
class CharaDetailSceneScraper;
class CharaDetailSceneStitcher;
class CharaDetailRecognizer;
}  // namespace uma::chara_detail

namespace uma::app {

using MessageCallback = void(const std::string &);
using PathCallback = void(const std::filesystem::path &);
using VoidCallback = void();

class NativeApi {
public:
    NativeApi();

    ~NativeApi();

    void startEventLoop(const std::string &config);
    void joinEventLoop();
    [[nodiscard]] bool isRunning() const;

    void updateFrame(const Frame &frame, const Size<int> &original_size);

    void notifyScreenshotTaken(const std::string &path, const std::string &resultCode) {
        notify(json_util::Json{{"type", "onScreenshotTaken"}, {"path", path}, {"result", resultCode}}.dump());
    }

    void stitch(const chara_detail::RecordInfo &info) const { on_stitch_ready->send(info); }

    void recognize(const chara_detail::RecordInfo &info) const { on_recognize_ready->send(info); }
    void recognize(const std::string &record_id) const { on_recognize_ready->send({record_id, std::nullopt}); }

    void setNotifyCallback(const std::function<MessageCallback> &method) { notify_callback = method; }

    void notifyError(const std::string &message) {
        notify(json_util::Json{{"type", "onError"}, {"message", message}}.dump());
    }

    void notifyCaptureStarted() { notify(json_util::Json{{"type", "onCaptureStarted"}}.dump()); }
    void notifyCaptureStopped() { notify(json_util::Json{{"type", "onCaptureStopped"}}.dump()); }

    void notifyScrollReady(int index) { notify(json_util::Json{{"type", "onScrollReady"}, {"index", index}}.dump()); }

    void notifyScrollUpdated(int index, double progress) {
        notify(json_util::Json{{"type", "onScrollUpdated"}, {"index", index}, {"progress", progress}}.dump());
    }

    void notifyPageReady(int index) { notify(json_util::Json{{"type", "onPageReady"}, {"index", index}}.dump()); }

    void notifyCharaDetailStarted() { notify(json_util::Json{{"type", "onCharaDetailStarted"}}.dump()); }
    void notifyCharaDetailFinished(const chara_detail::RecordInfo &info, bool success) {
        notify(json_util::Json{{"type", "onCharaDetailFinished"}, {"id", info.record_id}, {"success", success}}.dump());
    }

    void updateRecord(const chara_detail::RecordInfo &info) const;
    void notifyCharaDetailUpdated(const chara_detail::RecordInfo &info) {
        notify(json_util::Json{{"type", "onCharaDetailUpdated"}, {"id", info.record_id}}.dump());
    }

    void notifyFrameRateReported(double fps) {
        notify(json_util::Json{{"type", "onFrameRateReported"}, {"fps", fps}}.dump());
    }

    void notifyFrameSizeReported(const Size<int> &size) {
        notify(json_util::Json{{"type", "onFrameSizeReported"}, {"size", size}}.dump());
    }

    void setDetachCallback(const std::function<VoidCallback> &method) { detach_callback = method; }

    void setMkdirCallback(const std::function<PathCallback> &method) { mkdir_callback = method; }
    void mkdir(const std::filesystem::path &path) const {
        log_debug(path.string());
        mkdir_callback(path);
    }

    void setRmdirCallback(const std::function<PathCallback> &method) { rmdir_callback = method; }
    void rmdir(const std::filesystem::path &path) const {
        log_debug(path.string());
        rmdir_callback(path);
    }

    void setLoggingCallback(const std::function<MessageCallback> &method) { logging_callback = method; }
    void log(const std::string &message) {
        // Do not use logger here.
        logging_callback(message);
    }

private:
    void notify(const std::string &message) {
        log_trace(message);
        notify_callback(message);
    }

    std::function<MessageCallback> notify_callback = [](const auto &) { throw std::logic_error("Not Assigned."); };
    std::function<MessageCallback> logging_callback = [](const auto &message) { std::cout << message << std::flush; };
    std::function<VoidCallback> detach_callback = []() {};
    std::function<PathCallback> mkdir_callback = [](const auto &path) { std::filesystem::create_directories(path); };
    std::function<PathCallback> rmdir_callback = [](const auto &path) { std::filesystem::remove_all(path); };

    // debug interface
    event_util::Sender<chara_detail::RecordInfo> on_stitch_ready;
    event_util::Sender<chara_detail::RecordInfo> on_recognize_ready;

    event_util::Sender<chara_detail::RecordInfo> on_update_ready;

    event_util::Sender<Frame> on_frame_captured;
    event_util::EventRunnerController event_runners;

    std::unique_ptr<distributor::FrameDistributor> frame_distributor;
    std::unique_ptr<chara_detail::CharaDetailSceneScraper> chara_detail_scene_scraper;
    std::unique_ptr<chara_detail::CharaDetailSceneStitcher> chara_detail_scene_stitcher;
    std::unique_ptr<chara_detail::CharaDetailRecognizer> chara_detail_recognizer;

    const std::chrono::milliseconds report_interval = std::chrono::milliseconds(1000);
    event_util::Connection<Frame, chara_detail::SceneState> lap_time_wrapper;
    event_util::Connection<> lap_discard_wrapper;
    std::chrono::steady_clock::time_point last_size_reported;
    std::list<std::chrono::steady_clock::time_point> lap_time_buffer;

public:
    [[maybe_unused]] void _dummyForSuppressingUnusedWarning();

    static NativeApi &instance() {
        static NativeApi app;
        return app;
    }
};

}  // namespace uma::app
