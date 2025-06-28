#pragma once

#include <optional>
#include <thread>
#include <utility>
#include <windows.h>

#include <opencv2/opencv.hpp>

#include "cv/frame.h"
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
    std::optional<Rect<double>> crop_rect;

    [[nodiscard]] const char *windowClassOrNull() const {
        return (window_class && !window_class->empty()) ? window_class->c_str() : nullptr;
    }
    [[nodiscard]] const char *windowTitleOrNull() const {
        return (window_title && !window_title->empty()) ? window_title->c_str() : nullptr;
    }

    EXTENDED_JSON_TYPE_NDC(WindowProfile, window_class, window_title, crop_rect);
};

struct WindowRecorder {
    std::optional<int> recording_fps;
    std::optional<bool> force_resize;
    std::optional<Size<int>> minimum_size;
    std::optional<std::vector<WindowProfile>> window_profiles;

    EXTENDED_JSON_TYPE_NDC(WindowRecorder, recording_fps, force_resize, minimum_size, window_profiles);
};

}  // namespace windows_config

namespace windows_impl {

inline Size<int> getRatioFixedSize(const Size<int> &source, const Size<int> &fitTo) {
    const auto &sd = source.cast<double>();
    const auto &fd = fitTo.cast<double>();
    return {
        source.width(),
        std::lround(sd.width() * fd.height() / fd.width()),
    };
}

class WindowCapturer {
public:
    WindowCapturer(
        const std::vector<windows_config::WindowProfile> &window_profiles,
        const Size<int> &minimum_size,
        const bool force_resize)
        : window_profiles(window_profiles)
        , minimum_size(minimum_size)
        , force_resize(force_resize)
        , last_window_size({}) {}

    std::pair<Rect<int>, Rect<int>> findWindow() {
        for (const auto &profile : window_profiles) {
            if (const auto window_rect = findWindowOf(profile); !window_rect.empty()) {
                last_window_size = window_rect.size();
                const auto window_anchor = FrameAnchor::intersect(window_rect.size());
                const auto client_crop_rect = window_anchor.mapToFrame(profile.crop_rect.value());
                return std::make_pair(window_rect, client_crop_rect + window_rect.topLeft());
            }
        }
        return {};
    }

    [[nodiscard]] Frame capture() {
        const auto [_, capture_rect] = findWindow();
        if (capture_rect.empty()) {
            return {};
        }

        // const Size<int> &circumscribe_size =
        //     window_profile.fixed_aspect_ratio ? minimum_size : getCircumscribedSize(rect.size(), minimum_size);
        // const Size<int> &scaled_size =
        //     force_resize ? circumscribe_size : getRatioFixedSize(rect.size(), circumscribe_size);
        const Size<int> &scaled_size =
            force_resize ? minimum_size : getRatioFixedSize(capture_rect.size(), minimum_size);

        const auto &image = capture(GetDesktopWindow(), capture_rect, scaled_size);
        return {image, chrono_util::timestamp()};
    }

    [[nodiscard]] Frame takeScreenshot() {
        const auto [window_rect, _] = findWindow();
        if (window_rect.empty()) {
            return {};
        }

        const auto &image = capture(GetDesktopWindow(), window_rect, window_rect.size());
        return {image, chrono_util::timestamp()};
    }

    [[nodiscard]] Size<int> lastSize() const { return last_window_size; }

private:
    [[nodiscard]] Rect<int> findWindowOf(const windows_config::WindowProfile &profile) const {
        const HWND window = FindWindowA(profile.windowClassOrNull(), profile.windowTitleOrNull());
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

        // return {cv::Point(top_left.x, top_left.y), cv::Size(rect.right, rect.bottom)};
        return {Point<int>{top_left.x, top_left.y}, Size<int>{rect.right, rect.bottom}};
    }

    cv::Mat capture(const HWND window, const Rect<int> &src_rect, const Size<int> &dest_size) {
        /**
         * Most of the code for this method was taken from the official doc below.
         * https://docs.microsoft.com/en-us/windows/win32/gdi/capturing-an-image
         */
        if (src_rect.size() != plain_mat.size()) {
            plain_mat = cv::Mat(src_rect.size().toCVSize(), CV_8UC4);
        }
        if (dest_size != scaled_mat.size()) {
            scaled_mat = cv::Mat(dest_size.toCVSize(), CV_8UC4);
        }

        const HDC window_dc = GetDC(window);
        const HDC memory_dc = CreateCompatibleDC(window_dc);
        const HBITMAP bitmap = CreateCompatibleBitmap(window_dc, src_rect.width(), src_rect.height());
        const HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);

        BitBlt(
            memory_dc, 0, 0, src_rect.width(), src_rect.height(), window_dc, src_rect.left(), src_rect.top(), SRCCOPY);

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

        cv::resize(plain_mat, scaled_mat, dest_size.toCVSize(), cv::INTER_LINEAR);

        auto image = cv::Mat(scaled_mat.size(), CV_8UC3);
        cv::cvtColor(scaled_mat, image, cv::COLOR_BGRA2BGR);

        SelectObject(memory_dc, old_bitmap);
        DeleteObject(bitmap);
        DeleteObject(memory_dc);
        ReleaseDC(window, window_dc);

        return image;
    }

    const std::vector<windows_config::WindowProfile> window_profiles;
    const Size<int> minimum_size;
    const bool force_resize;

    cv::Mat plain_mat;
    cv::Mat scaled_mat;
    Size<int> last_window_size;
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
        const event_util::Sender<Frame, Size<int>> &sender,
        const std::vector<windows_config::WindowProfile> &window_profiles,
        const Size<int> &minimum_size,
        int fps,
        bool force_resize)
        : sender(sender)
        , capturer(std::make_unique<WindowCapturer>(window_profiles, minimum_size, force_resize))
        , minimum_size(minimum_size)
        , window_profiles(window_profiles)
        , force_resize(force_resize)
        , time_keeper(fps) {}

    void setFps(int fps) {
        // Changing fps should not cause any major problems without locking for now.
        time_keeper.setFps(fps);
    }

    void setForceResize(bool enable) {
        force_resize = enable;
        rebuildCapturer();
    }

    void setWindowProfiles(const std::vector<windows_config::WindowProfile> &profiles) {
        window_profiles = profiles;
        rebuildCapturer();
    }

    std::string takeScreenshot(const std::filesystem::path &path) {
        if (capturer == nullptr) {
            return "Failed to take screenshot. Capturer not initialized.";
        }
        const auto &frame = capturer->takeScreenshot();
        if (frame.empty()) {
            if (capturer->findWindow().first.empty()) {
                return "Failed to take screenshot. Window not found.";
            } else {
                return "Failed to take screenshot. Window found, but failed to capture.";
            }
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
                sender->send(frame, capturer->lastSize());
            }
        }

        log_debug("finished");
    }

private:
    void rebuildCapturer() {
        // Don't want to put a guard on the thread, so instead, kill and respawn the thread.
        const auto was_running = isRunning();
        if (was_running) {
            join();
        }
        this->capturer = std::make_unique<WindowCapturer>(window_profiles, minimum_size, force_resize);
        if (was_running) {
            start();
        }
    }

    const event_util::Sender<Frame, Size<int>> sender;
    std::unique_ptr<WindowCapturer> capturer;
    const Size<int> minimum_size;

    std::vector<windows_config::WindowProfile> window_profiles;
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
            assert(config.recording_fps.has_value());
            assert(config.minimum_size.has_value());
            assert(config.window_profiles.has_value());
            assert(config.force_resize.has_value());
            recording_thread = std::make_unique<windows_impl::RecordingThread>(
                frame_captured,
                config.window_profiles.value(),
                config.minimum_size.value(),
                config.recording_fps.value(),
                config.force_resize.value());
        } else {
            if (config.recording_fps.has_value()) {
                recording_thread->setFps(config.recording_fps.value());
            }
            if (config.window_profiles.has_value()) {
                recording_thread->setWindowProfiles(config.window_profiles.value());
            }
            if (config.force_resize.has_value()) {
                recording_thread->setForceResize(config.force_resize.value());
            }
        }
    }

    void startRecord() {
        log_debug("");
        if (recording_thread) {
            recording_thread->start();
        }
    }

    void stopRecord() {
        log_debug("");
        if (recording_thread) {
            recording_thread->join();
        }
    }

    std::string takeScreenshot(const std::filesystem::path &path) {
        if (recording_thread == nullptr) {
            return "Failed to take screenshot. recorder not initialized.";
        }
        return recording_thread->takeScreenshot(path);
    }

private:
    std::unique_ptr<windows_impl::RecordingThread> recording_thread;
    event_util::Sender<Frame, Size<int>> frame_captured;
};

}  // namespace uma::windows
