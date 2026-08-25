#pragma once

#include <chrono>
#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <functional>
#include <optional>
#include <thread>
#include <utility>
#include <vector>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <windows.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>

#include <opencv2/opencv.hpp>

#include "cv/frame.h"
#include "cv/frame_shaper.h"
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

}  // namespace windows_config

namespace windows_impl {

using ShapingSelector = frame_shaper::ShapingSelector;

// How this capturer ACQUIRES pixels, which is a Windows concern: CropPixels narrows the GPU copy region to the
// latched pane (the normal live-capture optimization), AnchorOnly copies the untouched client area. capture
// --record uses AnchorOnly so the FFV1 stream remains a full-frame input that replay can run through detection
// and calibration again. The corresponding SHAPING is frame_shaper::ShapingMode, derived in captureStableFrame:
// a narrowed GPU copy is a CopiedRegion, a full copy is AnchorOnly.
enum class ShapingMode {
    CropPixels,
    AnchorOnly,
};

// Window information structure
struct WindowInfo {
    HWND hwnd{nullptr};
    Rect<int> window_rect;  // Window bounds, including frames.
    Rect<int> client_rect;  // Client area in screen coordinates.
    Rect<int> capture_rect;  // Full client area in capture-texture coordinates.

    [[nodiscard]] inline bool isValid() const { return hwnd != nullptr; }
};

class WindowCapturer {
public:
    WindowCapturer(
        const std::vector<windows_config::WindowTarget> &window_targets,
        ShapingSelector shaping_selector,
        ShapingMode shaping_mode = ShapingMode::CropPixels)
        : window_targets(window_targets)
        , shaping_selector(std::move(shaping_selector))
        , shaping_mode(shaping_mode) {
        initializeGraphicsCapture();
    }

    ~WindowCapturer() { cleanup(); }

    [[nodiscard]] Frame capture() {
        const auto window_info = findTargetWindow();
        if (!window_info.hwnd) {
            return {};
        }

        if (!ensureCaptureSession(window_info)) {
            return {};
        }
        return captureStableFrame(window_info);
    }

    [[nodiscard]] Frame takeScreenshot() {
        const auto window_info = findTargetWindow();
        if (!window_info.hwnd) {
            return {};
        }

        if (!ensureCaptureSession(window_info)) {
            return {};
        }

        // Screenshots do not have the queued consumer's stale-snapshot guard, so retry until one GPU copy was
        // made under a snapshot that is still current afterward. The same shaping path as live capture means
        // an unlatched screenshot is full, CropPixels saves the pane, and AnchorOnly keeps the full pixels.
        const auto start_time = std::chrono::steady_clock::now();
        constexpr auto max_duration = std::chrono::seconds(3);
        constexpr auto retry_interval = std::chrono::milliseconds(100);

        while (true) {
            auto frame = captureStableFrame(window_info);
            if (!frame.empty()) {
                cleanup();
                return frame;
            }

            if ((std::chrono::steady_clock::now() - start_time) >= max_duration) {
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
        session_window_size = {};
    }

    [[nodiscard]] Size<int> lastWindowSize() const { return last_window_size; }

private:
    // Captures one frame under a pane snapshot and cheaply rejects it if the snapshot changed during the GPU
    // copy. A change after the final check can still happen, so queued consumers remain authoritative by
    // validating the snapshot carried on the returned Frame.
    [[nodiscard]] Frame captureStableFrame(const WindowInfo &window_info) {
        const auto shaping_snapshot = shaping_selector(window_info.client_rect.size());
        const bool crop_pixels = shaping_mode == ShapingMode::CropPixels;
        // One value drives BOTH the narrowed GPU copy below and the anchor claimed for it in
        // frame_shaper::shapeCapturedFrame, so the two cannot drift apart.
        const auto copy_origin = crop_pixels ? frame_shaper::paneCopyOrigin(shaping_snapshot) : Point<int>{0, 0};
        auto capture_rect = window_info.capture_rect;
        if (crop_pixels && shaping_snapshot.rect.has_value()) {
            capture_rect = {window_info.capture_rect.topLeft() + copy_origin, shaping_snapshot.rect->size()};
        }

        auto image = captureRegion(capture_rect);
        if (image.empty()) {
            return {};
        }

        // `image` is the fresh cvtColor output from captureRegion, never a reused buffer -- unlike the
        // `bgra_image` wrapper captureRegion builds over the D3D mapped resource, which owns nothing and is
        // exactly what must not escape. The pipeline relies on that: NativeApi::updateFrame forwards the Frame
        // downstream without cloning, and both modes this producer asks for (AnchorOnly, CopiedRegion) forward
        // the buffer by shallow cv::Mat copy -- only CropPixels duplicates pixels, and this producer never asks
        // for it because the GPU already delivered exactly the region wanted. That reliance is enforced rather
        // than described: shapeCapturedFrame below throws unless frame_shaper::ownsPixelsSolely(image) holds.
        // Re-resolving the selector is a separate guarantee: it re-validates the pane decision across the GPU
        // copy, and a stale one yields an empty Frame, which callers treat as "no frame".
        const auto timestamp = chrono_util::to_timestamp(chrono_util::local_now());
        const auto shaped = frame_shaper::shapeCapturedFrame(
            image,
            timestamp,
            shaping_snapshot,
            crop_pixels ? frame_shaper::ShapingMode::CopiedRegion : frame_shaper::ShapingMode::AnchorOnly,
            copy_origin,
            shaping_selector);
        return shaped.ok() ? shaped.frame : Frame{};
    }

    void initializeGraphicsCapture() {
        // APARTMENT. This runs on whichever thread constructs the capturer, and those threads no longer share
        // one COM state. The whole codebase calls CoInitializeEx exactly once -- windows/runner/main.cpp,
        // COINIT_APARTMENTTHREADED, on the Flutter app's platform thread -- so:
        //   * The app's SCREENSHOT capturer, built on that platform thread ("takeScreenshot" in
        //     native_controller.h is a plain, non-deferred handler), meets an STA and
        //     init_apartment(multi_threaded) raises RPC_E_CHANGED_MODE. This is the ONLY constructor that
        //     does; the arm below exists for it alone.
        //   * The app's LIVE capturer is built on NativeController's capture_lifecycle worker (applyConfig /
        //     mergeConfigDelta -> WindowRecorder::setConfig -> the RecordingThread constructor), which is
        //     never CoInitialize'd, so init_apartment SUCCEEDS and joins the MTA. It stopped meeting the STA
        //     when config pushes moved off the platform thread; do not read the arm below as covering it.
        //   * The CLI builds both kinds on its own main thread (native/src/core/cli.cpp, capture and
        //     screenshot), which is likewise never CoInitialize'd -- the MTA branch again.
        // In each success case the apartment stays initialized for the life of that thread, which is the life
        // of the process here; nothing calls uninit_apartment.
        // RPC_E_CHANGED_MODE arrives as a winrt::hresult_error, which does NOT derive from std::exception, so
        // letting it escape would slip past the method channel's std::exception handler (platform_channel.h)
        // and terminate the process. COM is usable from either apartment for this capture path -- the frame
        // pool is created with CreateFreeThreaded -- so a changed-mode result is benign and treated as
        // success. Any other hresult is rethrown: it means COM is unusable, not that it was already set up.
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

        // Pane shaping is resolved per frame in capture(). Window discovery always describes the untouched
        // client area so lastWindowSize remains the pre-shaping size passed to NativeApi::updateFrame.
        info.capture_rect = {
            info.client_rect.topLeft() - info.window_rect.topLeft(),
            info.client_rect.size(),
        };
        last_window_size = info.client_rect.size();
        return info;
    }

    bool ensureCaptureSession(const WindowInfo &info) {
        // Rebuild the session when the target window changes OR resizes: frame_pool is fixed to the window
        // size at init, so a resized window would make source_box exceed the (stale) source texture and
        // D3D11 would silently copy nothing (garbage frame). The downstream recognition pipeline assumes a
        // constant frame size, so a full rebuild (rather than FramePool::Recreate) is the intended reset.
        if (info.hwnd != current_window || info.window_rect.size() != session_window_size) {
            cleanup();
            return initializeCapture(info);
        }
        return true;
    }

    bool initializeCapture(const WindowInfo &info) {
        const HWND hwnd = info.hwnd;
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
            session_window_size = info.window_rect.size();
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

            // Guard the copy region against the source texture bounds. ensureCaptureSession rebuilds on a
            // resize, but a resize landing between that check and TryGetNextFrame could still hand back a
            // frame smaller than `rect`. An out-of-bounds D3D11_BOX makes CopySubresourceRegion silently
            // copy nothing (no error), leaving the staging texture uninitialized -- a garbage frame. Skip
            // this frame instead; the next cycle rebuilds. Validate with the signed rect before assigning
            // to the UINT box fields so a negative bound can't wrap to a huge value.
            if (rect.left() < 0 || rect.top() < 0 || rect.width() <= 0 || rect.height() <= 0 ||
                rect.right() > static_cast<int>(source_desc.Width) ||
                rect.bottom() > static_cast<int>(source_desc.Height)) {
                return {};
            }

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
    const ShapingSelector shaping_selector;
    const ShapingMode shaping_mode;

    Size<int> last_window_size;
    HWND current_window{nullptr};
    // The target window's bounds when the current capture session was created. frame_pool is fixed to
    // that size, so a later resize of the same HWND must rebuild the session (see ensureCaptureSession).
    Size<int> session_window_size{};

    winrt::com_ptr<ID3D11Device> d3d_device;
    winrt::com_ptr<ID3D11DeviceContext> d3d_device_context;
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool{nullptr};
    winrt::Windows::Graphics::Capture::GraphicsCaptureSession session{nullptr};
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device{nullptr};
};

}  // namespace windows_impl

}  // namespace uma::windows
