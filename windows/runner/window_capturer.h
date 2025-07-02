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

struct WindowProfile {
    std::optional<std::string> window_class;
    std::optional<std::string> window_title;
    std::optional<Size<int>> window_aspect_ratio;
    std::optional<Rect<double>> crop_rect;

    [[nodiscard]] const char *windowClassOrNull() const {
        return (window_class && !window_class->empty()) ? window_class->c_str() : nullptr;
    }
    [[nodiscard]] const char *windowTitleOrNull() const {
        return (window_title && !window_title->empty()) ? window_title->c_str() : nullptr;
    }

    EXTENDED_JSON_TYPE_NDC(WindowProfile, window_class, window_title, window_aspect_ratio, crop_rect);
};

}  // namespace windows_config

namespace windows_impl {

// Window information structure
struct WindowInfo {
    HWND hwnd{nullptr};
    Rect<int> window_rect;  // Actual window bounds (excluding shadows)
    Rect<int> client_rect;  // Client area in screen coordinates
    Rect<int> content_rect;  // Content area without letterbox (in screen coordinates)
    Rect<int> capture_rect;  // Final capture region in window coordinates
    bool is_client_area_only{false};
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
        const std::vector<windows_config::WindowProfile> &window_profiles,
        const Size<int> &minimum_size,
        const bool force_resize)
        : m_window_profiles(window_profiles)
        , m_minimum_size(minimum_size)
        , m_force_resize(force_resize) {
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

        cv::Mat image = captureRegion(window_info);
        if (image.empty()) {
            return {};
        }

        return applyResize(image, window_info.capture_rect.size());
    }

    [[nodiscard]] Frame takeScreenshot() {
        auto window_info = findTargetWindow();
        if (!window_info.hwnd) {
            return {};
        }

        // For screenshot, capture content area (without letterbox)
        window_info.is_client_area_only = true;
        window_info.capture_rect = Rect<int>{
            window_info.content_rect.topLeft() - window_info.window_rect.topLeft(), window_info.content_rect.size()};

        if (!ensureCaptureSession(window_info.hwnd)) {
            return {};
        }

        // Try to capture with retries (max 3 seconds)
        const auto start_time = std::chrono::steady_clock::now();
        constexpr auto max_duration = std::chrono::seconds(3);
        constexpr auto retry_interval = std::chrono::milliseconds(100);

        Frame result;
        while (true) {
            if (const cv::Mat image = captureRegion(window_info); !image.empty()) {
                result = {image, chrono_util::timestamp()};
                break;
            }

            // Check if timeout
            if (const auto elapsed = std::chrono::steady_clock::now() - start_time; elapsed >= max_duration) {
                break;
            }

            // Wait before retry
            std::this_thread::sleep_for(retry_interval);
        }

        // Clean up resources after screenshot
        cleanup();

        return result;
    }

    void cleanup() {
        if (m_session) {
            try {
                m_session.Close();
            } catch (...) {
            }
            m_session = nullptr;
        }

        if (m_framePool) {
            try {
                m_framePool.Close();
            } catch (...) {
            }
            m_framePool = nullptr;
        }

        m_item = nullptr;
        m_current_window = nullptr;
        m_current_process_id = 0;
    }

    [[nodiscard]] Size<int> lastWindowSize() const { return m_last_window_info.content_rect.size(); }

private:
    void initializeGraphicsCapture() {
        // Initialize WinRT
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (...) {
        }

        // Create Direct3D11 device
        D3D_FEATURE_LEVEL featureLevels[] = {
            D3D_FEATURE_LEVEL_11_1,
            D3D_FEATURE_LEVEL_11_0,
            D3D_FEATURE_LEVEL_10_1,
            D3D_FEATURE_LEVEL_10_0,
        };

        HRESULT hr = D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            featureLevels,
            ARRAYSIZE(featureLevels),
            D3D11_SDK_VERSION,
            m_device.put(),
            nullptr,
            m_context.put());

        if (FAILED(hr)) {
            throw std::runtime_error("Failed to create D3D11 device");
        }

        // Create WinRT device
        const auto dxgiDevice = m_device.as<IDXGIDevice>();
        winrt::com_ptr<::IInspectable> inspectable;
        hr = CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.get(), inspectable.put());

        if (FAILED(hr)) {
            throw std::runtime_error("Failed to create Direct3D11 device");
        }

        m_winrtDevice = inspectable.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();
    }

    // Helper function to detect and remove letterbox
    Rect<int> removeLetterbox(const Rect<int> &client_rect, const Size<int> &expected_aspect) const {
        if (expected_aspect.width() <= 0 || expected_aspect.height() <= 0) {
            return client_rect;
        }

        const double expected_ratio = static_cast<double>(expected_aspect.width()) / expected_aspect.height();
        const double client_ratio = static_cast<double>(client_rect.width()) / client_rect.height();

        // Calculate expected dimensions based on aspect ratio
        int expected_width, expected_height;

        if (client_ratio > expected_ratio) {
            // Letterbox on left/right
            expected_height = client_rect.height();
            expected_width = static_cast<int>(std::round(expected_height * expected_ratio));
        } else {
            // Letterbox on top/bottom
            expected_width = client_rect.width();
            expected_height = static_cast<int>(std::round(expected_width / expected_ratio));
        }

        // Check if the difference is within tolerance (3 pixels)
        const int width_diff = std::abs(client_rect.width() - expected_width);
        const int height_diff = std::abs(client_rect.height() - expected_height);

        if (width_diff <= 3 && height_diff <= 3) {
            // Within tolerance, treat as no letterbox
            return client_rect;
        }

        // Calculate centered content area
        const int content_width = std::min(client_rect.width(), expected_width);
        const int content_height = std::min(client_rect.height(), expected_height);

        // Center the content area
        const int offset_x = (client_rect.width() - content_width) / 2;
        const int offset_y = (client_rect.height() - content_height) / 2;

        return {
            client_rect.topLeft() + Size<int>{offset_x, offset_y},
            Size<int>{content_width, content_height},
        };
    }

    WindowInfo findTargetWindow() {
        for (const auto &profile : m_window_profiles) {
            HWND hwnd = FindWindowA(profile.windowClassOrNull(), profile.windowTitleOrNull());
            if (!hwnd || !IsWindow(hwnd) || IsIconic(hwnd)) {
                continue;
            }

            WindowInfo info;
            info.hwnd = hwnd;

            // Get accurate window bounds using DWM
            RECT dwm_rect;
            const HRESULT hr = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &dwm_rect, sizeof(RECT));
            if (FAILED(hr)) {
                // Fallback to GetWindowRect
                RECT window_rect;
                if (!GetWindowRect(hwnd, &window_rect)) {
                    continue;
                }
                dwm_rect = window_rect;
            }

            info.window_rect =
                Rect<int>{Point<int>{dwm_rect.left, dwm_rect.top}, Point<int>{dwm_rect.right, dwm_rect.bottom}};

            // Get client area
            RECT client_rect;
            if (!GetClientRect(hwnd, &client_rect)) {
                continue;
            }

            POINT client_origin{0, 0};
            if (!ClientToScreen(hwnd, &client_origin)) {
                continue;
            }

            info.client_rect = {
                Point<int>{client_origin.x, client_origin.y},
                Size<int>{client_rect.right, client_rect.bottom},
            };

            // Remove letterbox if aspect ratio is specified
            if (profile.window_aspect_ratio.has_value()) {
                info.content_rect = removeLetterbox(info.client_rect, profile.window_aspect_ratio.value());
            } else {
                info.content_rect = info.client_rect;
            }

            // Convert from screen coordinates to window coordinates
            const Point<int> window_origin = info.window_rect.topLeft();
            if (profile.crop_rect.has_value()) {
                // Use content area (without letterbox) as the base for crop calculation
                const auto anchor = FrameAnchor::intersect(info.content_rect.size());
                const auto crop_rect = anchor.mapToFrame(profile.crop_rect.value());

                // Convert crop rect to window coordinates
                const Point<int> crop_origin =
                    info.content_rect.topLeft() + Size<int>{crop_rect.left(), crop_rect.top()};
                info.capture_rect = Rect<int>{crop_origin - window_origin, crop_rect.size()};
            } else {
                // Capture content area by default
                info.capture_rect = Rect<int>{info.content_rect.topLeft() - window_origin, info.content_rect.size()};
            }

            m_last_window_info = info;
            return info;
        }

        return {};
    }

    bool ensureCaptureSession(const HWND hwnd) {
        if (!isCurrentWindowValid() || hwnd != m_current_window) {
            cleanup();
            return initializeCapture(hwnd);
        }
        return true;
    }

    bool isCurrentWindowValid() const {
        if (!m_current_window)
            return false;

        DWORD process_id = 0;
        GetWindowThreadProcessId(m_current_window, &process_id);
        return IsWindow(m_current_window) && process_id == m_current_process_id;
    }

    bool initializeCapture(const HWND hwnd) {
        if (!hwnd || !IsWindow(hwnd) || IsIconic(hwnd)) {
            return false;
        }

        GetWindowThreadProcessId(hwnd, &m_current_process_id);
        m_current_window = hwnd;

        // Create GraphicsCaptureItem
        const auto factory = winrt::get_activation_factory<winrt::Windows::Graphics::Capture::GraphicsCaptureItem>();
        const auto interop = factory.as<IGraphicsCaptureItemInterop>();

        try {
            const HRESULT hr = interop->CreateForWindow(
                hwnd, winrt::guid_of<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>(), winrt::put_abi(m_item));

            if (FAILED(hr) || !m_item) {
                return false;
            }
        } catch (...) {
            return false;
        }

        // Validate and get size
        winrt::Windows::Graphics::SizeInt32 size;
        try {
            size = m_item.Size();
            if (size.Width <= 0 || size.Height <= 0) {
                m_item = nullptr;
                return false;
            }
        } catch (...) {
            m_item = nullptr;
            return false;
        }

        // Create frame pool
        try {
            m_framePool = winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
                m_winrtDevice, winrt::Windows::Graphics::DirectX::DirectXPixelFormat::B8G8R8A8UIntNormalized, 1, size);

            if (!m_framePool) {
                m_item = nullptr;
                return false;
            }
        } catch (...) {
            m_item = nullptr;
            return false;
        }

        // Create capture session
        try {
            m_session = m_framePool.CreateCaptureSession(m_item);
            if (!m_session) {
                cleanup();
                return false;
            }

            m_session.IsCursorCaptureEnabled(false);
            m_session.StartCapture();
        } catch (...) {
            cleanup();
            return false;
        }

        return true;
    }

    cv::Mat captureRegion(const WindowInfo &window_info) const {
        if (!m_session || !m_framePool)
            return {};

        // Get frame
        winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame frame{nullptr};
        try {
            frame = m_framePool.TryGetNextFrame();
        } catch (...) {
            return {};
        }

        if (!frame)
            return {};

        cv::Mat result;
        try {
            // Get Direct3D surface
            const auto surface = frame.Surface();
            if (!surface) {
                frame.Close();
                return {};
            }

            const auto access = surface.as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            winrt::com_ptr<ID3D11Texture2D> source_texture;
            HRESULT hr = access->GetInterface(IID_PPV_ARGS(&source_texture));
            if (FAILED(hr) || !source_texture) {
                frame.Close();
                return {};
            }

            // Get source texture description
            D3D11_TEXTURE2D_DESC source_desc;
            source_texture->GetDesc(&source_desc);

            // Create staging texture for the cropped region
            D3D11_TEXTURE2D_DESC staging_desc = {};
            staging_desc.Width = window_info.capture_rect.width();
            staging_desc.Height = window_info.capture_rect.height();
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
            hr = m_device->CreateTexture2D(&staging_desc, nullptr, staging_texture.put());
            if (FAILED(hr) || !staging_texture) {
                frame.Close();
                return {};
            }

            // Copy only the required region using CopySubresourceRegion
            D3D11_BOX source_box;
            source_box.left = std::max(0, window_info.capture_rect.left());
            source_box.top = std::max(0, window_info.capture_rect.top());
            source_box.right = std::min(static_cast<int>(source_desc.Width), window_info.capture_rect.right());
            source_box.bottom = std::min(static_cast<int>(source_desc.Height), window_info.capture_rect.bottom());
            source_box.front = 0;
            source_box.back = 1;

            // Ensure valid box dimensions
            if (source_box.right > source_box.left && source_box.bottom > source_box.top) {
                m_context->CopySubresourceRegion(
                    staging_texture.get(),
                    0,  // Destination subresource
                    0,  // Destination X
                    0,  // Destination Y
                    0,  // Destination Z
                    source_texture.get(),
                    0,  // Source subresource
                    &source_box);
            } else {
                frame.Close();
                return {};
            }

            // Map and convert to cv::Mat
            D3D11_MAPPED_SUBRESOURCE mapped;
            hr = m_context->Map(staging_texture.get(), 0, D3D11_MAP_READ, 0, &mapped);
            if (SUCCEEDED(hr)) {
                const cv::Mat bgra_image(
                    staging_desc.Height, staging_desc.Width, CV_8UC4, mapped.pData, mapped.RowPitch);
                cv::cvtColor(bgra_image, result, cv::COLOR_BGRA2BGR);

                m_context->Unmap(staging_texture.get(), 0);
            }
        } catch (...) {
            // Handle any exceptions
        }

        frame.Close();
        return result;
    }

    Frame applyResize(cv::Mat &image, const Size<int> &original_size) const {
        const Size<int> &target_size =
            m_force_resize ? m_minimum_size : getRatioFixedSize(original_size, m_minimum_size);

        if (image.size() != target_size.toCVSize()) {
            cv::Mat resized;
            cv::resize(image, resized, target_size.toCVSize(), 0, 0, cv::INTER_LINEAR);
            image = resized;
        }

        return {image, chrono_util::timestamp()};
    }

    // Configuration
    const std::vector<windows_config::WindowProfile> m_window_profiles;
    const Size<int> m_minimum_size;
    const bool m_force_resize;
    WindowInfo m_last_window_info;

    // Windows Graphics Capture resources
    winrt::com_ptr<ID3D11Device> m_device;
    winrt::com_ptr<ID3D11DeviceContext> m_context;
    winrt::Windows::Graphics::Capture::GraphicsCaptureItem m_item{nullptr};
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool m_framePool{nullptr};
    winrt::Windows::Graphics::Capture::GraphicsCaptureSession m_session{nullptr};
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice m_winrtDevice{nullptr};

    // Window tracking
    HWND m_current_window{nullptr};
    DWORD m_current_process_id{0};
};

}  // namespace windows_impl

}  // namespace uma::windows
