#pragma once

#include <optional>
#include <thread>
#include <utility>
#include <windows.h>

#include <opencv2/opencv.hpp>

#include "types/shape.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/misc.h"
#include "util/thread_util.h"

namespace cv {

[[maybe_unused]] inline void to_json(nlohmann::json &j, const Size &d) {
    j = nlohmann::json{
        {"width", d.width},
        {"height", d.height},
    };
}

[[maybe_unused]] inline void from_json(const nlohmann::json &j, Size &d) {
    j.at("width").get_to(d.width);
    j.at("height").get_to(d.height);
}

}  // namespace cv

namespace uma::windows {

namespace windows_config {

struct WindowProfile {
    std::optional<std::string> window_class;
    std::optional<std::string> window_title;
    bool fixed_aspect_ratio = false;

    [[nodiscard]] const char *windowClassOrNull() const {
        return (window_class && !window_class->empty()) ? window_class->c_str() : nullptr;
    }
    [[nodiscard]] const char *windowTitleOrNull() const {
        return (window_title && !window_title->empty()) ? window_title->c_str() : nullptr;
    }

    EXTENDED_JSON_TYPE_NDC(WindowProfile, window_class, window_title, fixed_aspect_ratio);
};

struct WindowRecorder {
    std::optional<WindowProfile> window_profile;
    std::optional<Size<int>> minimum_size;
    std::optional<int> recording_fps;

    EXTENDED_JSON_TYPE_NDC(WindowRecorder, window_profile, minimum_size, recording_fps);
};

}  // namespace windows_config

namespace windows_impl {

inline Size<int> getCircumscribedSize(const Size<int> &source, const Size<int> &fitTo) {
    const auto sd = source.cast<double>();
    const auto fd = fitTo.cast<double>();
    return (sd * std::max(fd.width() / sd.width(), fd.height() / sd.height())).round();
}

class WindowCapturer {
public:
    WindowCapturer(const windows_config::WindowProfile &window_profile, const Size<int> &minimum_size)
        : window_profile(window_profile)
        , minimum_size(minimum_size) {}

    [[nodiscard]] cv::Mat capture() {
        const cv::Rect &rect = findWindow();
        if (rect.empty()) {
            return {};
        }

        if (plain_mat.size() != rect.size()) {
            plain_mat = cv::Mat(rect.size(), CV_8UC4);
        }

        const Size<int> &scaled_size =
            window_profile.fixed_aspect_ratio ? minimum_size : getCircumscribedSize(rect.size(), minimum_size);
        if (scaled_size != scaled_mat.size()) {
            scaled_mat = cv::Mat(scaled_size.toCVSize(), CV_8UC4);
        }

        return capture(GetDesktopWindow(), rect);
    }

private:
    [[nodiscard]] cv::Rect findWindow() const {
        HWND window = FindWindowA(window_profile.windowClassOrNull(), window_profile.windowTitleOrNull());
        if (!window) {
            return {};
        }

        RECT rect;
        if (!GetClientRect(window, &rect)) {
            return {};
        }

        POINT top_left{0, 0};
        if (!ClientToScreen(window, &top_left)) {
            return {};
        }

        return {cv::Point(top_left.x, top_left.y), cv::Size(rect.right, rect.bottom)};
    }

    cv::Mat capture(HWND window, const cv::Rect &rect) const {
        /**
         * Most of the code for this method was taken from the official doc below.
         * https://docs.microsoft.com/en-us/windows/win32/gdi/capturing-an-image
         */
        HDC window_dc = GetDC(window);
        HDC memory_dc = CreateCompatibleDC(window_dc);
        HBITMAP bitmap = CreateCompatibleBitmap(window_dc, rect.width, rect.height);
        HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);

        BitBlt(memory_dc, 0, 0, rect.width, rect.height, window_dc, rect.x, rect.y, SRCCOPY);

        BITMAP bitmap_info;
        GetObject(bitmap, sizeof(BITMAP), &bitmap_info);

        BITMAPINFOHEADER bitmap_header;
        bitmap_header.biSize = sizeof(BITMAPINFOHEADER);
        bitmap_header.biWidth = bitmap_info.bmWidth;
        bitmap_header.biHeight = -bitmap_info.bmHeight;  // Negative height inverts the image upside down.
        bitmap_header.biPlanes = 1;
        bitmap_header.biBitCount = 32;
        bitmap_header.biCompression = BI_RGB;
        bitmap_header.biSizeImage = 0;
        bitmap_header.biXPelsPerMeter = 0;
        bitmap_header.biYPelsPerMeter = 0;
        bitmap_header.biClrUsed = 0;
        bitmap_header.biClrImportant = 0;

        GetDIBits(
            window_dc,
            bitmap,
            0,
            bitmap_info.bmHeight,
            plain_mat.data,
            reinterpret_cast<BITMAPINFO *>(&bitmap_header),
            DIB_RGB_COLORS);

        cv::resize(plain_mat, scaled_mat, scaled_mat.size(), cv::INTER_LINEAR);

        cv::Mat image = cv::Mat(scaled_mat.size(), CV_8UC3);
        cv::cvtColor(scaled_mat, image, cv::COLOR_BGRA2BGR);

        SelectObject(memory_dc, old_bitmap);
        DeleteObject(bitmap);
        DeleteObject(memory_dc);
        ReleaseDC(window, window_dc);

        return image;
    }

    const windows_config::WindowProfile window_profile;
    const Size<int> minimum_size;

    cv::Mat plain_mat;
    cv::Mat scaled_mat;
};

constexpr int64 nano_scale = std::nano::den / std::nano::num;

class TimeKeeper {
public:
    explicit TimeKeeper(int fps) { setFps(fps); }

    void start() { previous = std::chrono::steady_clock::now(); }

    void setFps(int fps) { interval = std::chrono::nanoseconds(nano_scale / fps); }

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
        const event_util::Sender<cv::Mat, uint64_t> &sender,
        const windows_config::WindowProfile &window_profile,
        const Size<int> &minimum_size,
        int fps)
        : sender(sender)
        , capturer(std::make_unique<WindowCapturer>(window_profile, minimum_size))
        , minimum_size(minimum_size)
        , time_keeper(fps) {}

    void setFps(int fps) {
        // Changing fps should not cause any major problems without locking for now.
        time_keeper.setFps(fps);
    }

    void setWindowProfile(const windows_config::WindowProfile &window_profile) {
        // Don't want to put a guard on the thread, so instead, kill and respawn the thread.
        const auto was_running = isRunning();
        if (was_running) {
            join();
        }
        this->capturer = std::make_unique<WindowCapturer>(window_profile, minimum_size);
        if (was_running) {
            start();
        }
    }

protected:
    void run() override {
        log_debug("started");

        time_keeper.start();
        while (isRunning()) {
            time_keeper.waitLap();
            const auto &frame = capturer->capture();
            if (!frame.empty()) {
                sender->send(frame, chrono_util::timestamp());
            }
        }

        log_debug("finished");
    }

private:
    const event_util::Sender<cv::Mat, uint64_t> sender;
    std::unique_ptr<WindowCapturer> capturer;
    const Size<int> minimum_size;
    TimeKeeper time_keeper;
};

}  // namespace windows_impl

class WindowRecorder {
public:
    explicit WindowRecorder(const event_util::Sender<cv::Mat, uint64_t> &sender)
        : frame_captured(sender) {}

    ~WindowRecorder() {
        if (recording_thread) {
            stopRecord();
        }
    }

    void setConfig(const windows_config::WindowRecorder &config) {
        if (!recording_thread) {
            assert(config.recording_fps.has_value());
            assert(config.minimum_size.has_value());
            assert(config.window_profile.has_value());
            recording_thread = std::make_unique<windows_impl::RecordingThread>(
                frame_captured,
                config.window_profile.value(),
                config.minimum_size.value(),
                config.recording_fps.value());
        } else {
            if (config.recording_fps.has_value()) {
                recording_thread->setFps(config.recording_fps.value());
            }
            if (config.window_profile.has_value()) {
                recording_thread->setWindowProfile(config.window_profile.value());
            }
        }
    }

    void startRecord() {
        log_debug("");
        assert(recording_thread);

        recording_thread->start();
    }

    void stopRecord() {
        log_debug("");
        assert(recording_thread);

        recording_thread->join();
    }

private:
    std::unique_ptr<windows_impl::RecordingThread> recording_thread;
    event_util::Sender<cv::Mat, uint64_t> frame_captured;
};

}  // namespace uma::windows
