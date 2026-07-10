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
#include "core/native_api_messages.h"
#include "cv/frame.h"
#include "cv/frame_distributor.h"
#include "cv/frame_stall_watchdog.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/logger_util.h"

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
        notify(messages::screenshotTaken(path, resultCode));
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
        // A throw from send() (e.g. bad_alloc from enqueue) must not escape across the C ABI. Guard it and
        // surface the failure to Dart via notifyError so the UI does not wait forever for a completion that
        // will never arrive; notify() is const-callable because the callback member is mutable.
        try {
            sender->send(info);
        } catch (const std::exception &e) {
            log_error("stitch failed: {}", e.what());
            notifyError(std::string("stitch failed: ") + e.what());
        }
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
        try {
            sender->send(info);
        } catch (const std::exception &e) {
            log_error("recognize failed: {}", e.what());
            notifyError(std::string("recognize failed: ") + e.what());
        }
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
        try {
            sender->send({record_id, std::nullopt});
        } catch (const std::exception &e) {
            log_error("recognize failed: {}", e.what());
            notifyError(std::string("recognize failed: ") + e.what());
        }
    }

    void setNotifyCallback(const std::function<MessageCallback> &method) {
        // Enforce for real (assert_ is a no-op in Release): notify_callback is read unsynchronized from worker
        // threads via notify(), so overwriting it after start() is a torn-read data race. Ignore the late set.
        if (isRunning()) {
            log_warning("setNotifyCallback called while the event loop is running; ignoring");
            return;
        }
        notify_callback = method;
    }

    // Restore notify_callback to its default (unassigned) state. Call this when the object that installed the
    // callback is destroyed (e.g. the Windows NativeController, whose lambda captures `this`/`channel`): this
    // singleton has process lifetime and outlives that owner, so without a reset a late notify() would
    // dereference freed memory. Routes through setNotifyCallback, so it is a no-op while the loop is running
    // (by which point the owner is being torn down after joinEventLoop() anyway).
    void resetNotifyCallback() {
        setNotifyCallback([](const auto &) { log_error("notify_callback not assigned"); });
    }

    void notifyError(const std::string &message) const { notify(messages::error(message)); }

    void notifyCaptureStarted() { notify(messages::captureStarted()); }
    void notifyCaptureStopped() { notify(messages::captureStopped()); }

    void notifyScrollReady(int index) { notify(messages::scrollReady(index)); }

    void notifyScrollUpdated(int index, double progress) { notify(messages::scrollUpdated(index, progress)); }

    void notifyScrollPosition(int index, bool at_top) { notify(messages::scrollPosition(index, at_top)); }

    void notifyPageReady(int index) { notify(messages::pageReady(index)); }

    void notifyFactorProbe(const std::vector<chara_detail::record::Factor> &factors, int record_type) {
        notify(messages::factorProbe(factors, record_type));
    }

    void notifyCharaDetailStarted() { notify(messages::charaDetailStarted()); }
    // Mid-scene reset: the scraper discarded the current session (a character switch was inferred from
    // on-screen content) and rebuilt it, without the detail screen closing. The UI must reset its capture
    // progress just as it does for a fresh open.
    void notifyCharaDetailRestarted() { notify(messages::charaDetailRestarted()); }
    void notifyCharaDetailFinished(const chara_detail::RecordInfo &info, bool success) {
        notify(messages::charaDetailFinished(info.record_id, success));
    }
    // The detail screen was closed. The UI returns to waiting for the next detail screen (a completed
    // capture leaves its progress on screen until this fires; an incomplete one also emits an error).
    void notifyCharaDetailClosed() { notify(messages::charaDetailClosed()); }

    void updateRecord(const chara_detail::RecordInfo &info) const;
    void notifyCharaDetailUpdated(const chara_detail::RecordInfo &info) {
        notify(messages::charaDetailUpdated(info.record_id));
    }

    void notifyFrameRateReported(double fps) { notify(messages::frameRateReported(fps)); }

    void notifyFrameSizeReported(const Size<int> &size) { notify(messages::frameSizeReported(size)); }

    void setDetachCallback(const std::function<VoidCallback> &method) {
        if (isRunning()) {
            log_warning("setDetachCallback called while the event loop is running; ignoring");
            return;
        }
        detach_callback = method;
    }

    // The mkdir/rmdir callbacks let the Dart side route directory operations through platform-specific
    // storage. They are read into an io_util::DirectoryHooks in startEventLoop and injected into the
    // pipeline components, so those components stay decoupled from this singleton (and unit-testable).
    void setMkdirCallback(const std::function<PathCallback> &method) {
        if (isRunning()) {
            log_warning("setMkdirCallback called while the event loop is running; ignoring");
            return;
        }
        mkdir_callback = method;
    }
    void setRmdirCallback(const std::function<PathCallback> &method) {
        if (isRunning()) {
            log_warning("setRmdirCallback called while the event loop is running; ignoring");
            return;
        }
        rmdir_callback = method;
    }

    void setLoggingCallback(const std::function<MessageCallback> &method) {
        if (isRunning()) {
            log_warning("setLoggingCallback called while the event loop is running; ignoring");
            return;
        }
        logging_callback = method;
    }
    void log(const std::string &message) const {
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

    void notify(const std::string &message) const {
        log_trace(message);
        // Never throw: notify() runs on worker threads and FFI method handlers, where an escaping exception
        // would cross the C ABI into Dart/JVM and terminate the process. The assigned callback (channel->notify
        // on Windows, JNI on Android) can throw, so guard it just like log() does.
        try {
            notify_callback(message);
        } catch (...) {
            log_error("notify_callback threw; swallowing to keep the exception off the FFI boundary");
        }
    }

    // Set once before startEventLoop and never mutated afterward: notify()/log() read these on worker threads
    // with no synchronization, so re-assigning them while the pipeline runs would be a torn read (the setters
    // assert !isRunning() to enforce this in Debug). notify_callback/logging_callback are mutable so the const
    // notify()/log() paths (e.g. notifyError from the const stitch/recognize producers) can invoke them.
    // An unassigned notify_callback logs instead of throwing.
    mutable std::function<MessageCallback> notify_callback = [](const auto &) { log_error("notify_callback not assigned"); };
    mutable std::function<MessageCallback> logging_callback = [](const auto &message) { std::cout << message << std::flush; };
    std::function<VoidCallback> detach_callback = []() {};
    std::function<PathCallback> mkdir_callback = [](const auto &path) { std::filesystem::create_directories(path); };
    std::function<PathCallback> rmdir_callback = [](const auto &path) { std::filesystem::remove_all(path); };

    // Serializes pipeline lifecycle (startPipeline/teardownLocked) against the producer entry points
    // (updateFrame/stitch/recognize/updateRecord). Producers copy the sender they need out under this lock,
    // then send() outside it. mutable so the const producer methods can lock it.
    mutable std::mutex pipeline_mutex;

    // Senders into the recognizer/stitcher runners, driven by the public entry points (stitch/recognize/
    // updateRecord). Copied out under pipeline_mutex before send(), and nulled by teardownLocked().
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
