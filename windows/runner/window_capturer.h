#pragma once

#include <chrono>
#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <optional>
#include <thread>
#include <utility>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>

#include <opencv2/opencv.hpp>

#include "cv/frame.h"
#include "types/shape.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/misc.h"

#pragma comment(lib, "windowsapp")
#pragma comment(lib, "dwmapi")

namespace uma::windows {

namespace windows_config {

struct WindowTarget {
    std::optional<std::string> window_class;
    std::optional<std::string> window_title;

    [[nodiscard]] const char *windowClassOrNull() const {
        return (window_class && !window_class->empty()) ? window_class->c_str() : nullptr;
    }
    [[nodiscard]] const char *windowTitleOrNull() const {
        return (window_title && !window_title->empty()) ? window_title->c_str() : nullptr;
    }

    EXTENDED_JSON_TYPE_NDC(WindowTarget, window_class, window_title);
};

struct CropProfile {
    std::optional<Range<double>> window_aspect_ratio;
    std::optional<Size<int>> client_aspect_ratio;
    std::optional<Rect<double>> crop_rect;

    EXTENDED_JSON_TYPE_NDC(CropProfile, window_aspect_ratio, client_aspect_ratio, crop_rect);
};

// Select the crop profile whose window_aspect_ratio range contains the given size's aspect ratio, or nullopt
// if none matches. Shared by the live WindowCapturer and the offline VideoLoader so both pick the same profile
// (a landscape game window vs. a portrait phone recording) from the frame dimensions alone.
[[nodiscard]] inline std::optional<CropProfile> matchCropProfile(
    const std::vector<CropProfile> &profiles, const Size<int> &size) {
    if (size.height() <= 0) {
        return {};
    }
    const double ratio = static_cast<double>(size.width()) / size.height();
    for (const auto &profile : profiles) {
        if (profile.window_aspect_ratio && profile.window_aspect_ratio->contains(ratio)) {
            return profile;
        }
    }
    return {};
}

}  // namespace windows_config

namespace windows_impl {

// Window information structure
struct WindowInfo {
    HWND hwnd{nullptr};
    Rect<int> window_rect;  // Window bounds, including frames.
    Rect<int> client_rect;  // Client area, including letterbox (in full-screen mode).
    Rect<int> content_rect;  // Client area, excluding letterbox (in full-screen mode).
    Rect<int> capture_rect;  // Final area of interest.

    [[nodiscard]] inline bool isValid() const { return hwnd != nullptr; }
};

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
        const std::vector<windows_config::WindowTarget> &window_targets,
        const std::vector<windows_config::CropProfile> &crop_profiles,
        const Size<int> &minimum_size,
        const bool force_resize)
        : window_targets(window_targets)
        , crop_profiles(crop_profiles)
        , minimum_size(minimum_size)
        , force_resize(force_resize) {
        initializeGraphicsCapture();
    }

    ~WindowCapturer() { cleanup(); }

    [[nodiscard]] Frame capture() {
        const auto window_info = findTargetWindow();
        if (!window_info.hwnd) {
            return {};
        }

        if (!ensureCaptureSession(window_info.hwnd)) {
            return {};
        }

        auto image = captureRegion(window_info.capture_rect);
        if (image.empty()) {
            return {};
        }

        // TODO: This should not be the minimum size, but rather the ideal size for image recognition.
        const Size<int> &target_size =
            force_resize ? minimum_size : getRatioFixedSize(window_info.capture_rect.size(), minimum_size);

        // Allow a small margin of error, since resizing even when the difference is minor can make the image blur.
        if (target_size.difference_max(image.size()) > 3) {
            cv::Mat resized;
            cv::resize(image, resized, target_size.toCVSize(), 0, 0, cv::INTER_LINEAR);
            image = resized;
        }

        // `image` is a freshly allocated cv::Mat every call (the cvtColor output in captureRegion, or the
        // resize output above), never a reused buffer. The pipeline relies on this: NativeApi::updateFrame
        // forwards the Frame downstream without cloning (see the Frame class doc ownership contract).
        return {image, chrono_util::to_timestamp(chrono_util::local_now())};
    }

    [[nodiscard]] Frame takeScreenshot() {
        const auto window_info = findTargetWindow();
        if (!window_info.hwnd) {
            return {};
        }

        if (!ensureCaptureSession(window_info.hwnd)) {
            return {};
        }

        const auto capture_rect = Rect<int>{
            window_info.content_rect.topLeft() - window_info.window_rect.topLeft(),
            window_info.content_rect.size(),
        };

        // Try to capture with retries (max 3 seconds)
        const auto start_time = std::chrono::steady_clock::now();
        constexpr auto max_duration = std::chrono::seconds(3);
        constexpr auto retry_interval = std::chrono::milliseconds(100);

        while (true) {
            const auto image = captureRegion(capture_rect);
            if (!image.empty()) {
                // Successfully captured.
                cleanup();
                return {image, chrono_util::to_timestamp(chrono_util::local_now())};
            }

            if ((std::chrono::steady_clock::now() - start_time) >= max_duration) {
                // Failed to capture.
                cleanup();
                return {};
            }
            std::this_thread::sleep_for(retry_interval);
        }
    }

    void cleanup() {
        if (session) {
            try {
                session.Close();
            } catch (...) {
            }
            session = nullptr;
        }

        if (frame_pool) {
            try {
                frame_pool.Close();
            } catch (...) {
            }
            frame_pool = nullptr;
        }

        current_window = nullptr;
    }

    [[nodiscard]] Size<int> lastWindowSize() const { return last_window_size; }

private:
    void initializeGraphicsCapture() {
        // The thread that constructs the capturer is already COM-initialized as STA
        // (see CoInitializeEx in main.cpp). Newer Flutter Windows embedders dispatch
        // platform-channel handlers on that STA thread, so init_apartment(multi_threaded)
        // raises RPC_E_CHANGED_MODE. That is a winrt::hresult_error (not a std::exception),
        // so it would escape the method channel's std::exception handler and terminate the
        // process. COM is usable from either apartment for our capture path, so a
        // changed-mode result is benign and treated as success.
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (const winrt::hresult_error &error) {
            if (error.code() != RPC_E_CHANGED_MODE) {
                throw;
            }
        }

        D3D_FEATURE_LEVEL feature_levels[] = {
            D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL_10_1,
            D3D_FEATURE_LEVEL_10_0,
        };
        auto hr = D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            feature_levels,
            ARRAYSIZE(feature_levels),
            D3D11_SDK_VERSION,
            d3d_device.put(),
            nullptr,
            d3d_device_context.put());
        if (FAILED(hr)) {
            throw std::runtime_error("Failed to create D3D11 device");
        }

        const auto dxgi_device = d3d_device.as<IDXGIDevice>();
        winrt::com_ptr<::IInspectable> inspectable;
        hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(), inspectable.put());
        if (FAILED(hr)) {
            throw std::runtime_error("Failed to create Direct3D11 device");
        }

        winrt_device = inspectable.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
    }

    Rect<int> removeLetterbox(const Rect<int> &client_rect, const Size<int> &expected_aspect) const {
        const double expected_ratio = static_cast<double>(expected_aspect.width()) / expected_aspect.height();
        const double client_ratio = static_cast<double>(client_rect.width()) / client_rect.height();

        int expected_width, expected_height;
        if (client_ratio > expected_ratio) {
            // Letterbox on left/right.
            expected_height = client_rect.height();
            expected_width = static_cast<int>(std::round(expected_height * expected_ratio));
        } else {
            // Letterbox on top/bottom.
            expected_width = client_rect.width();
            expected_height = static_cast<int>(std::round(expected_width / expected_ratio));
        }

        // Allow a small margin of error, since resizing even when the difference is minor can make the image blur.
        if (client_rect.size().difference_max({expected_width, expected_height}) <= 3) {
            // Within tolerance, treat as no letterbox.
            return client_rect;
        }

        // Calculate centered content area.
        const int content_width = std::min(client_rect.width(), expected_width);
        const int content_height = std::min(client_rect.height(), expected_height);
        const int offset_x = (client_rect.width() - content_width) / 2;
        const int offset_y = (client_rect.height() - content_height) / 2;
        return {
            client_rect.topLeft() + Size<int>{offset_x, offset_y},
            Size<int>{content_width, content_height},
        };
    }

    WindowInfo findWindow(const windows_config::WindowTarget &target) {
        HWND hwnd = FindWindowA(target.windowClassOrNull(), target.windowTitleOrNull());
        if (!hwnd || !IsWindow(hwnd) || IsIconic(hwnd)) {
            return {};
        }

        WindowInfo info;
        info.hwnd = hwnd;

        // Get accurate window bounds using DWM
        RECT dwm_rect;
        auto hr = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &dwm_rect, sizeof(RECT));
        if (FAILED(hr)) {
            // Fallback to GetWindowRect
            RECT window_rect;
            if (!GetWindowRect(hwnd, &window_rect)) {
                return {};
            }
            dwm_rect = window_rect;
        }

        info.window_rect = {
            Point<int>{dwm_rect.left, dwm_rect.top},
            Point<int>{dwm_rect.right, dwm_rect.bottom},
        };

        RECT client_rect;
        if (!GetClientRect(hwnd, &client_rect)) {
            return {};
        }

        POINT client_origin{0, 0};
        if (!ClientToScreen(hwnd, &client_origin)) {
            return {};
        }

        info.client_rect = {
            Point<int>{client_origin.x, client_origin.y},
            Size<int>{client_rect.right, client_rect.bottom},
        };

        return info;
    }

    std::optional<windows_config::CropProfile> findMatchingCropProfile(const Rect<int> &client_rect) const {
        return windows_config::matchCropProfile(crop_profiles, client_rect.size());
    }

    WindowInfo findTargetWindow() {
        // Phase 1: Find window from targets.
        WindowInfo info;
        for (const auto &target : window_targets) {
            info = findWindow(target);
            if (info.isValid()) {
                break;
            }
        }
        if (!info.isValid()) {
            return {};
        }

        // Phase 2: Select crop profile based on window aspect ratio.
        const auto &profile = findMatchingCropProfile(info.client_rect);
        if (!profile.has_value()) {
            // No matching profile means no cropping is needed.
            info.content_rect = info.client_rect;
            info.capture_rect = {info.content_rect.topLeft() - info.window_rect.topLeft(), info.content_rect.size()};
        } else {
            // Apply letterbox removal if client_aspect_ratio is specified.
            if (!profile->client_aspect_ratio.has_value()) {
                info.content_rect = info.client_rect;
            } else {
                info.content_rect = removeLetterbox(info.client_rect, profile->client_aspect_ratio.value());
            }

            // Apply crop_rect if specified.
            const auto window_origin = info.window_rect.topLeft();
            if (!profile->crop_rect.has_value()) {
                info.capture_rect = {info.content_rect.topLeft() - window_origin, info.content_rect.size()};
            } else {
                const auto anchor = FrameAnchor::intersect(info.content_rect.size());
                const auto crop_rect = anchor.mapToFrame(profile->crop_rect.value());
                const auto crop_origin = info.content_rect.topLeft() + Size<int>{crop_rect.left(), crop_rect.top()};
                info.capture_rect = {crop_origin - window_origin, crop_rect.size()};
            }
        }

        last_window_size = info.content_rect.size();
        return info;
    }

    bool ensureCaptureSession(const HWND hwnd) {
        if (hwnd != current_window) {
            cleanup();
            return initializeCapture(hwnd);
        }
        return true;
    }

    bool initializeCapture(const HWND hwnd) {
        try {
            winrt::Windows::Graphics::Capture::GraphicsCaptureItem capture_item{nullptr};

            const auto factory =
                winrt::get_activation_factory<winrt::Windows::Graphics::Capture::GraphicsCaptureItem>();
            const auto interop = factory.as<IGraphicsCaptureItemInterop>();
            const auto hr = interop->CreateForWindow(
                hwnd,
                winrt::guid_of<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>(),
                winrt::put_abi(capture_item));
            if (FAILED(hr) || !capture_item) {
                throw std::runtime_error("Failed to create GraphicsCaptureItem.");
            }

            frame_pool = winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
                winrt_device,
                winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized,
                1,
                capture_item.Size());
            if (!frame_pool) {
                throw std::runtime_error("Failed to create Direct3D11CaptureFramePool.");
            }

            session = frame_pool.CreateCaptureSession(capture_item);
            if (!session) {
                throw std::runtime_error("Failed to create CaptureSession.");
            }

            session.IsCursorCaptureEnabled(false);
            session.StartCapture();
            current_window = hwnd;
            return true;
        } catch (...) {
            // TODO: Error details should be reported to the app.
            cleanup();
            return false;
        }
    }

    cv::Mat captureRegion(const Rect<int> &rect) {
        if (!session || !frame_pool) {
            return {};
        }

        const auto frame = frame_pool.TryGetNextFrame();
        if (!frame)
            return {};

        try {
            const auto surface = frame.Surface();
            if (!surface) {
                throw std::runtime_error("Failed to get surface.");
            }

            const auto access = surface.as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            winrt::com_ptr<ID3D11Texture2D> source_texture;
            auto hr = access->GetInterface(IID_PPV_ARGS(&source_texture));
            if (FAILED(hr) || !source_texture) {
                throw std::runtime_error("Failed to get source texture.");
            }

            D3D11_TEXTURE2D_DESC source_desc;
            source_texture->GetDesc(&source_desc);

            D3D11_TEXTURE2D_DESC staging_desc = {};
            staging_desc.Width = rect.width();
            staging_desc.Height = rect.height();
            staging_desc.MipLevels = 1;
            staging_desc.ArraySize = 1;
            staging_desc.Format = source_desc.Format;
            staging_desc.SampleDesc.Count = 1;
            staging_desc.SampleDesc.Quality = 0;
            staging_desc.Usage = D3D11_USAGE_STAGING;
            staging_desc.BindFlags = 0;
            staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            staging_desc.MiscFlags = 0;

            winrt::com_ptr<ID3D11Texture2D> staging_texture;
            hr = d3d_device->CreateTexture2D(&staging_desc, nullptr, staging_texture.put());
            if (FAILED(hr) || !staging_texture) {
                throw std::runtime_error("Failed to create dest texture.");
            }

            // Copy only the required region.
            D3D11_BOX source_box;
            source_box.left = rect.left();
            source_box.top = rect.top();
            source_box.right = rect.right();
            source_box.bottom = rect.bottom();
            source_box.front = 0;
            source_box.back = 1;
            d3d_device_context->CopySubresourceRegion(
                staging_texture.get(), 0, 0, 0, 0, source_texture.get(), 0, &source_box);

            // Convert to cv::Mat.
            D3D11_MAPPED_SUBRESOURCE resource;
            hr = d3d_device_context->Map(staging_texture.get(), 0, D3D11_MAP_READ, 0, &resource);
            if (FAILED(hr)) {
                throw std::runtime_error("Failed to map resource.");
            }
            cv::Mat captured_image;
            const cv::Mat bgra_image(
                staging_desc.Height, staging_desc.Width, CV_8UC4, resource.pData, resource.RowPitch);
            cv::cvtColor(bgra_image, captured_image, cv::COLOR_BGRA2BGR);
            d3d_device_context->Unmap(staging_texture.get(), 0);

            frame.Close();
            return captured_image;
        } catch (...) {
            frame.Close();
            return {};
        }
    }

    const std::vector<windows_config::WindowTarget> window_targets;
    const std::vector<windows_config::CropProfile> crop_profiles;
    const Size<int> minimum_size;
    const bool force_resize;

    Size<int> last_window_size;
    HWND current_window{nullptr};

    winrt::com_ptr<ID3D11Device> d3d_device;
    winrt::com_ptr<ID3D11DeviceContext> d3d_device_context;
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool{nullptr};
    winrt::Windows::Graphics::Capture::GraphicsCaptureSession session{nullptr};
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device{nullptr};
};

}  // namespace windows_impl

}  // namespace uma::windows
