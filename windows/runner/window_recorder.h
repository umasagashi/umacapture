#ifndef RUNNER_WINDOW_RECORDER_H_
#define RUNNER_WINDOW_RECORDER_H_

#include <optional>
#include <thread>
#include <utility>
#include <windows.h>

#include <opencv2/opencv.hpp>

#include "../../native/src/eventpp_util.h"
#include "../../native/src/json_utils.h"
#include "../../native/src/thread_util.h"

namespace config {

struct WindowProfile {
    std::optional<std::string> window_class;
    std::optional<std::string> window_title;

    [[nodiscard]] const char *windowClassOrNull() const {
        return (window_class && !window_class->empty()) ? window_class->c_str() : nullptr;
    }
    [[nodiscard]] const char *windowTitleOrNull() const {
        return (window_title && !window_title->empty()) ? window_title->c_str() : nullptr;
    }

    EXTENDED_JSON_TYPE_INTRUSIVE(WindowProfile, window_class, window_title);
};

struct WindowRecorder {
    std::optional<config::WindowProfile> window_profile;
    std::optional<int> recording_fps;

    EXTENDED_JSON_TYPE_INTRUSIVE(WindowRecorder, window_profile, recording_fps);
};

}  // namespace config

namespace {

class WindowCapturer {
public:
    explicit WindowCapturer(config::WindowProfile window_profile)
        : window_profile(std::move(window_profile)) {}

    [[nodiscard]] cv::Mat capture() {
        const auto &rect = findWindow();
        if (rect.empty()) {
            return {};
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

    static cv::Mat capture(HWND window, const cv::Rect &rect) {
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

        auto bitmap_size = ((bitmap_info.bmWidth * bitmap_header.biBitCount + 31) / 32) * 4 * bitmap_info.bmHeight;
        HANDLE buffer_handle = GlobalAlloc(GHND, bitmap_size);
        auto *buffer = GlobalLock(buffer_handle);

        GetDIBits(window_dc,
                  bitmap,
                  0,
                  bitmap_info.bmHeight,
                  buffer,
                  reinterpret_cast<BITMAPINFO *>(&bitmap_header),
                  DIB_RGB_COLORS);

        // Cloning removes the padding (if any) in each line and lets cv::Mat manage the memory buffer.
        cv::Mat image = cv::Mat(bitmap_info.bmHeight, bitmap_info.bmWidth, CV_8UC4, buffer).clone();

        GlobalUnlock(buffer_handle);
        GlobalFree(buffer_handle);
        SelectObject(memory_dc, old_bitmap);
        DeleteObject(bitmap);
        DeleteObject(memory_dc);
        ReleaseDC(window, window_dc);

        return image;
    }

    config::WindowProfile window_profile;
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

class RecordingThread : public threading::ThreadBase {
public:
    explicit RecordingThread(connection::Sender<const cv::Mat &> sender, const config::WindowProfile &window_profile,
                             int fps)
        : sender(std::move(sender))
        , capturer(std::make_unique<WindowCapturer>(window_profile))
        , time_keeper(fps) {}

    void setFps(int fps) {
        // Changing fps should not cause any major problems without locking for now.
        time_keeper.setFps(fps);
    }

    void setWindowProfile(const config::WindowProfile &window_profile) {
        // Don't want to put a guard on the thread, so instead, kill and respawn the thread.
        const auto was_running = isRunning();
        if (was_running) {
            join();
        }
        this->capturer = std::make_unique<WindowCapturer>(window_profile);
        if (was_running) {
            start();
        }
    }

protected:
    void run() override {
        std::cout << __FUNCTION__ << " started" << std::endl;
        time_keeper.start();
        while (isRunning()) {
            time_keeper.waitLap();
            sender->send(capturer->capture());
        }
        std::cout << __FUNCTION__ << " finished" << std::endl;
    }

private:
    const connection::Sender<const cv::Mat &> sender;
    std::unique_ptr<WindowCapturer> capturer;
    TimeKeeper time_keeper;
};

}  // namespace

namespace recording {

class WindowRecorder {
public:
    explicit WindowRecorder(connection::Sender<const cv::Mat &> sender)
        : frame_captured(std::move(sender)) {}

    void setConfig(const config::WindowRecorder &config) {
        if (!recording_thread) {
            assert(config.recording_fps.has_value());
            assert(config.window_profile.has_value());
            recording_thread = std::make_unique<RecordingThread>(
                frame_captured, config.window_profile.value(), config.recording_fps.value());
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
        assert(recording_thread);
        recording_thread->start();
    }

    void stopRecord() {
        assert(recording_thread);
        recording_thread->join();
    }

private:
    std::unique_ptr<RecordingThread> recording_thread;
    connection::Sender<const cv::Mat &> frame_captured;
};

}  // namespace recording

#endif  // RUNNER_WINDOW_RECORDER_H_
