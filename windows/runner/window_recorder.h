#pragma once

#include <chrono>
#include <optional>
#include <stdexcept>
#include <thread>
#include <utility>

#include "cv/frame.h"
#include "types/shape.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/misc.h"
#include "util/thread_util.h"

#include "window_capturer.h"

namespace uma::windows {

namespace windows_config {

struct WindowRecorder {
    std::optional<int> recording_fps;
    // Accepted but consumed by no capture path (kept optional below, not required, for exactly that reason). If
    // supplied, keep it aligned with the recognizer's independent 540x960 reference dimensions; it is not the
    // source of FrameAnchor::base_size or either 540-pixel resize constant.
    std::optional<Size<int>> minimum_size;
    std::optional<std::vector<WindowTarget>> window_targets;

    EXTENDED_JSON_TYPE_NDC(WindowRecorder, recording_fps, minimum_size, window_targets);
};

}  // namespace windows_config

namespace windows_impl {

constexpr int64 nano_scale = std::nano::den / std::nano::num;

class TimeKeeper {
public:
    explicit TimeKeeper(const int fps) { setFps(fps); }

    void start() { previous = std::chrono::steady_clock::now(); }

    void setFps(const int fps) { interval = std::chrono::nanoseconds(nano_scale / fps); }

    void waitLap() {
        const auto proper_time = previous + interval;
        std::this_thread::sleep_until(proper_time);
        previous = proper_time;
    }

private:
    std::chrono::duration<int64, std::nano> interval = {};
    std::chrono::steady_clock::time_point previous;
};

class RecordingThread : public thread_util::ThreadBase {
public:
    RecordingThread(
        const event_util::Sender<Frame, Size<int>> &sender,
        const std::vector<windows_config::WindowTarget> &window_targets,
        ShapingSelector shaping_selector,
        ShapingMode shaping_mode,
        const int fps)
        : sender(sender)
        , shaping_selector(std::move(shaping_selector))
        , shaping_mode(shaping_mode)
        , capturer(std::make_unique<WindowCapturer>(window_targets, this->shaping_selector, shaping_mode))
        , window_targets(window_targets)
        , time_keeper(fps) {}

    void setFps(const int fps) { time_keeper.setFps(fps); }

    void setWindowTargets(const std::vector<windows_config::WindowTarget> &targets) {
        window_targets = targets;
        rebuildCapturer();
    }

    std::string takeScreenshot(const std::filesystem::path &path) const {
        // Screenshots are a debug-only, infrequent operation. Build a dedicated capturer from the config this
        // thread already holds instead of sharing the recording capturer: that capturer is driven by run() on
        // this worker thread, and its D3D context / WinRT session are not free-threaded, so touching it from the
        // platform (method-channel) thread would race. A separate WindowCapturer owns its own D3D device/context/
        // session, so this keeps the capture hot path lock-free and stall-free.
        //
        // READING THE CONFIG MEMBERS IS NO LONGER ORDERED BY A THREAD RULE, and nothing here synchronizes them.
        // In the CLI it still is -- native/src/core/cli.cpp drives setConfig and takeScreenshot from its one
        // main thread -- so what follows is about the Flutter app, which is where the two split apart.
        // takeScreenshot runs on the PLATFORM thread ("takeScreenshot" is a plain, non-deferred handler in
        // native_controller.h), while the config setters run on the capture_lifecycle worker (applyConfig /
        // mergeConfigDelta). So window_targets below -- and WindowRecorder::recording_thread one level up, which
        // the same handler dereferences -- are written on one thread and read on another with no lock:
        // capture_mutex is held by the writers only and this path never takes it.
        //
        // What keeps that from being a live race is DATA, not this comment. The only setConfig is the one
        // PlatformController sends once from its constructor, which takes the !recording_thread branch and never
        // reaches setWindowTargets; the only setPlatformConfig deltas (frame_resize, detail_crop_calibration)
        // carry no `platform` key, so mergeConfigDelta's window_recorder branch never runs. A runtime
        // window_recorder delta would reintroduce the race for real: setWindowTargets reassigns the vector this
        // copy-constructs from, and rebuildCapturer() joins and restarts the recording thread underneath it.
        // Adding one means first either routing this handler onto the capture worker as well, or guarding both
        // members -- do not treat the absence of a crash today as permission.
        //
        // AnchorOnly regardless of the recording mode: this is the "Report screen" attachment, and a pane
        // latch survives session teardown (it is released only at the next startCapture), so CropPixels would
        // silently hand a bug report the pane alone -- exactly the region under suspicion in a "the window is
        // not detected" / "the crop is wrong" report, with all surrounding context removed. The web twin saves
        // the whole shared surface (lib/src/core/platform_channel_web.dart takeScreenshot), so the full client
        // area is also what keeps the two front ends converged. Recognition geometry is untouched: this
        // capturer feeds no pipeline, and the pane still travels as the frame's anchor.
        WindowCapturer screenshot_capturer(window_targets, shaping_selector, ShapingMode::AnchorOnly);

        const auto &frame = screenshot_capturer.takeScreenshot();
        if (frame.empty()) {
            return "Failed to take screenshot.";
        }

        frame.save(path);
        return {};
    }

protected:
    void run() override {
        log_debug("started");

        time_keeper.start();
        while (isRunning()) {
            time_keeper.waitLap();
            const auto &frame = capturer->capture();
            if (!frame.empty()) {
                sender->send(frame, capturer->lastWindowSize());
            }
        }
        capturer->cleanup();

        log_debug("finished");
    }

private:
    void rebuildCapturer() {
        const auto was_running = isRunning();
        if (was_running) {
            join();
        }
        capturer = std::make_unique<WindowCapturer>(window_targets, shaping_selector, shaping_mode);
        if (was_running) {
            start();
        }
    }

    const event_util::Sender<Frame, Size<int>> sender;
    const ShapingSelector shaping_selector;
    const ShapingMode shaping_mode;
    std::unique_ptr<WindowCapturer> capturer;

    std::vector<windows_config::WindowTarget> window_targets;
    TimeKeeper time_keeper;
};

}  // namespace windows_impl

class WindowRecorder {
public:
    WindowRecorder(
        const event_util::Sender<Frame, Size<int>> &sender,
        windows_impl::ShapingSelector shaping_selector,
        windows_impl::ShapingMode shaping_mode = windows_impl::ShapingMode::CropPixels)
        : frame_captured(sender)
        , shaping_selector(std::move(shaping_selector))
        , shaping_mode(shaping_mode) {}

    ~WindowRecorder() {
        if (recording_thread) {
            stopRecord();
        }
    }

    void setConfig(const windows_config::WindowRecorder &config) {
        if (!recording_thread) {
            // The first setConfig builds the recording thread and dereferences these required optionals.
            // assert() is a no-op under NDEBUG, so an incomplete config would throw bad_optional_access
            // with no context in a release build; fail loudly with the offending fields instead.
            //
            // minimum_size is deliberately NOT required here: no capture path consumes it (see the field
            // comment above), so a config that omits it is not actually incomplete.
            if (!config.recording_fps.has_value() || !config.window_targets.has_value()) {
                throw std::invalid_argument(
                    "WindowRecorder initial config missing a required field "
                    "(recording_fps / window_targets)");
            }
            recording_thread = std::make_unique<windows_impl::RecordingThread>(
                frame_captured,
                config.window_targets.value(),
                shaping_selector,
                shaping_mode,
                config.recording_fps.value());
        } else {
            if (config.recording_fps.has_value()) {
                recording_thread->setFps(config.recording_fps.value());
            }
            if (config.window_targets.has_value()) {
                recording_thread->setWindowTargets(config.window_targets.value());
            }
        }
    }

    void startRecord() const {
        log_debug("");
        if (recording_thread) {
            recording_thread->start();
        }
    }

    void stopRecord() const {
        log_debug("");
        if (recording_thread) {
            recording_thread->join();
        }
    }

    std::string takeScreenshot(const std::filesystem::path &path) const {
        // Called on the platform thread while recording_thread is assigned on the capture worker's first
        // setConfig, with no happens-before edge between the two -- see the threading paragraph on
        // RecordingThread::takeScreenshot for what actually keeps that from biting and what would break it.
        if (!recording_thread) {
            return "Failed to take screenshot. recorder not initialized.";
        }
        return recording_thread->takeScreenshot(path);
    }

private:
    std::unique_ptr<windows_impl::RecordingThread> recording_thread;
    event_util::Sender<Frame, Size<int>> frame_captured;
    const windows_impl::ShapingSelector shaping_selector;
    const windows_impl::ShapingMode shaping_mode;
};

}  // namespace uma::windows
