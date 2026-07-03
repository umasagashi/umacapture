#pragma once

#include <filesystem>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/record_info.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "cv/frame_stall_watchdog.h"
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

    // The producer entry points below (called from the FFI/Dart thread) copy the target sender out under
    // pipeline_mutex, then send() on the local copy outside the lock. The shared_ptr copy keeps the
    // connection alive even if teardown() nulls the member concurrently, and sending outside the lock avoids
    // deadlocking teardown when a Block-mode queue is full. See updateFrame() for the same pattern.
    void stitch(const chara_detail::RecordInfo &info) const {
        event_util::Sender<chara_detail::RecordInfo> sender;
        {
            std::lock_guard<std::mutex> lock(pipeline_mutex);
            if (!isRunningLocked()) {
                return;
            }
            sender = on_stitch_ready;
        }
        sender->send(info);
    }

    void recognize(const chara_detail::RecordInfo &info) const {
        event_util::Sender<chara_detail::RecordInfo> sender;
        {
            std::lock_guard<std::mutex> lock(pipeline_mutex);
            if (!isRunningLocked()) {
                return;
            }
            sender = on_recognize_ready;
        }
        sender->send(info);
    }
    void recognize(const std::string &record_id) const {
        event_util::Sender<chara_detail::RecordInfo> sender;
        {
            std::lock_guard<std::mutex> lock(pipeline_mutex);
            if (!isRunningLocked()) {
                return;
            }
            sender = on_recognize_ready;
        }
        sender->send({record_id, std::nullopt});
    }

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

    void notifyScrollPosition(int index, bool at_top) {
        notify(json_util::Json{{"type", "onScrollPosition"}, {"index", index}, {"at_top", at_top}}.dump());
    }

    void notifyPageReady(int index) { notify(json_util::Json{{"type", "onPageReady"}, {"index", index}}.dump()); }

    void notifyFactorProbe(const std::vector<chara_detail::record::Factor> &factors, int record_type) {
        notify(json_util::Json{{"type", "onFactorProbe"}, {"factors", factors}, {"record_type", record_type}}.dump());
    }

    void notifyCharaDetailStarted() { notify(json_util::Json{{"type", "onCharaDetailStarted"}}.dump()); }
    // Mid-scene reset: the scraper discarded the current session (a character switch was inferred from
    // on-screen content) and rebuilt it, without the detail screen closing. The UI must reset its capture
    // progress just as it does for a fresh open.
    void notifyCharaDetailRestarted() { notify(json_util::Json{{"type", "onCharaDetailRestarted"}}.dump()); }
    void notifyCharaDetailFinished(const chara_detail::RecordInfo &info, bool success) {
        notify(json_util::Json{{"type", "onCharaDetailFinished"}, {"id", info.record_id}, {"success", success}}.dump());
    }
    // The detail screen was closed. The UI returns to waiting for the next detail screen (a completed
    // capture leaves its progress on screen until this fires; an incomplete one also emits an error).
    void notifyCharaDetailClosed() { notify(json_util::Json{{"type", "onCharaDetailClosed"}}.dump()); }

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

    // The mkdir/rmdir callbacks let the Dart side route directory operations through platform-specific
    // storage. They are read into an io_util::DirectoryHooks in startEventLoop and injected into the
    // pipeline components, so those components stay decoupled from this singleton (and unit-testable).
    void setMkdirCallback(const std::function<PathCallback> &method) { mkdir_callback = method; }
    void setRmdirCallback(const std::function<PathCallback> &method) { rmdir_callback = method; }

    void setLoggingCallback(const std::function<MessageCallback> &method) { logging_callback = method; }
    void log(const std::string &message) {
        // Never throw: invoked from a spdlog sink (CallbackSink::sink_it_) on arbitrary worker threads, where
        // an escaping exception would terminate the process. Do not route through the logger here (it would
        // recurse back into this sink).
        try {
            logging_callback(message);
        } catch (...) {
            // Swallow: there is no safe logging channel from inside the log sink.
        }
    }

private:
    // Builds and starts the whole pipeline. May throw (config parse, model load, ...); startEventLoop wraps
    // it so those failures are reported to Dart via notifyError instead of escaping the FFI boundary.
    void startPipeline(const std::string &native_config);

    // Tears down the whole pipeline, tolerating partial initialization. Shared by joinEventLoop() and the
    // startEventLoop() failure path so a throw mid-construction never leaves a half-built event loop behind.
    // Assumes pipeline_mutex is already held by the caller.
    void teardownLocked();

    // Running check without taking pipeline_mutex, for callers that already hold it.
    [[nodiscard]] bool isRunningLocked() const;

    void notify(const std::string &message) {
        log_trace(message);
        notify_callback(message);
    }

    // Must never throw: notify() runs on worker threads, where an escaping exception would terminate the
    // process. An unassigned callback logs instead of throwing.
    std::function<MessageCallback> notify_callback = [](const auto &) { log_error("notify_callback not assigned"); };
    std::function<MessageCallback> logging_callback = [](const auto &message) { std::cout << message << std::flush; };
    std::function<VoidCallback> detach_callback = []() {};
    std::function<PathCallback> mkdir_callback = [](const auto &path) { std::filesystem::create_directories(path); };
    std::function<PathCallback> rmdir_callback = [](const auto &path) { std::filesystem::remove_all(path); };

    // Serializes pipeline lifecycle (startPipeline/teardownLocked) against the producer entry points
    // (updateFrame/stitch/recognize/updateRecord). Producers copy the sender they need out under this lock,
    // then send() outside it. mutable so the const producer methods can lock it.
    mutable std::mutex pipeline_mutex;

    // debug interface
    event_util::Sender<chara_detail::RecordInfo> on_stitch_ready;
    event_util::Sender<chara_detail::RecordInfo> on_recognize_ready;

    event_util::Sender<chara_detail::RecordInfo> on_update_ready;

    event_util::Sender<Frame> on_frame_captured;
    event_util::EventRunnerController event_runners;

    std::unique_ptr<distributor::FrameDistributor> frame_distributor;
    std::unique_ptr<distributor::FrameStallWatchdog> frame_stall_watchdog;
    std::unique_ptr<chara_detail::CharaDetailSceneScraper> chara_detail_scene_scraper;
    std::unique_ptr<chara_detail::CharaDetailSceneStitcher> chara_detail_scene_stitcher;
    std::unique_ptr<chara_detail::CharaDetailRecognizer> chara_detail_recognizer;

    const std::chrono::milliseconds report_interval = std::chrono::milliseconds(1000);
    event_util::Connection<Frame, chara_detail::SceneState> lap_time_wrapper;
    event_util::Connection<> lap_discard_wrapper;
    std::chrono::steady_clock::time_point last_size_reported;
    std::list<std::chrono::steady_clock::time_point> lap_time_buffer;

public:
    static NativeApi &instance() {
        static NativeApi app;
        return app;
    }
};

}  // namespace uma::app
