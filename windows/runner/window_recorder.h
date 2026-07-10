#pragma once

#include <chrono>
#include <optional>
#include <stdexcept>
#include <thread>

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
    std::optional<bool> force_resize;
    std::optional<Size<int>> minimum_size;
    std::optional<std::vector<WindowTarget>> window_targets;
    std::optional<std::vector<CropProfile>> crop_profiles;

    EXTENDED_JSON_TYPE_NDC(WindowRecorder, recording_fps, force_resize, minimum_size, window_targets, crop_profiles);
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
        const std::vector<windows_config::CropProfile> &crop_profiles,
        const Size<int> &minimum_size,
        const int fps,
        const bool force_resize)
        : sender(sender)
        , capturer(std::make_unique<WindowCapturer>(window_targets, crop_profiles, minimum_size, force_resize))
        , minimum_size(minimum_size)
        , window_targets(window_targets)
        , crop_profiles(crop_profiles)
        , force_resize(force_resize)
        , time_keeper(fps) {}

    void setFps(const int fps) { time_keeper.setFps(fps); }

    void setForceResize(const bool enable) {
        force_resize = enable;
        rebuildCapturer();
    }

    void setWindowTargets(const std::vector<windows_config::WindowTarget> &targets) {
        window_targets = targets;
        rebuildCapturer();
    }

    void setCropProfiles(const std::vector<windows_config::CropProfile> &profiles) {
        crop_profiles = profiles;
        rebuildCapturer();
    }

    std::string takeScreenshot(const std::filesystem::path &path) const {
        // Screenshots are a debug-only, infrequent operation. Build a dedicated capturer from the config this
        // thread already holds instead of sharing the recording capturer: that capturer is driven by run() on
        // this worker thread, and its D3D context / WinRT session are not free-threaded, so touching it from the
        // platform (method-channel) thread would race. A separate WindowCapturer owns its own D3D device/context/
        // session, so this keeps the capture hot path lock-free and stall-free. Reading the config members is
        // race-free because takeScreenshot and the config setters both run on the platform thread.
        WindowCapturer screenshot_capturer(window_targets, crop_profiles, minimum_size, force_resize);

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
        capturer = std::make_unique<WindowCapturer>(window_targets, crop_profiles, minimum_size, force_resize);
        if (was_running) {
            start();
        }
    }

    const event_util::Sender<Frame, Size<int>> sender;
    std::unique_ptr<WindowCapturer> capturer;
    const Size<int> minimum_size;

    std::vector<windows_config::WindowTarget> window_targets;
    std::vector<windows_config::CropProfile> crop_profiles;
    bool force_resize;
    TimeKeeper time_keeper;
};

}  // namespace windows_impl

class WindowRecorder {
public:
    explicit WindowRecorder(const event_util::Sender<Frame, Size<int>> &sender)
        : frame_captured(sender) {}

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
            if (!config.recording_fps.has_value() || !config.minimum_size.has_value() ||
                !config.window_targets.has_value() || !config.force_resize.has_value()) {
                throw std::invalid_argument(
                    "WindowRecorder initial config missing a required field "
                    "(recording_fps / minimum_size / window_targets / force_resize)");
            }
            recording_thread = std::make_unique<windows_impl::RecordingThread>(
                frame_captured,
                config.window_targets.value(),
                config.crop_profiles.value_or(std::vector<windows_config::CropProfile>{}),
                config.minimum_size.value(),
                config.recording_fps.value(),
                config.force_resize.value());
        } else {
            if (config.recording_fps.has_value()) {
                recording_thread->setFps(config.recording_fps.value());
            }
            if (config.window_targets.has_value()) {
                recording_thread->setWindowTargets(config.window_targets.value());
            }
            if (config.crop_profiles.has_value()) {
                recording_thread->setCropProfiles(config.crop_profiles.value());
            }
            if (config.force_resize.has_value()) {
                recording_thread->setForceResize(config.force_resize.value());
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
        if (!recording_thread) {
            return "Failed to take screenshot. recorder not initialized.";
        }
        return recording_thread->takeScreenshot(path);
    }

private:
    std::unique_ptr<windows_impl::RecordingThread> recording_thread;
    event_util::Sender<Frame, Size<int>> frame_captured;
};

}  // namespace uma::windows
