// Mimic player (test harness, stages S2-S3): presents a recorded FFV1 clip inside a window that
// impersonates the Uma Musume game window, so the real Windows capture path (WinRT Graphics
// Capture on the HWND found by FindWindowA) can be driven from a recording instead of the game.
//
// The app locates its capture target by window class + title only -- exact class "UnityWndClass"
// and exact title "umamusume" / "UmamusumePrettyDerby_Jpn" (windows/runner/window_capturer.h,
// assets/config/platform.json). There is no pixel or content test, so a plain Win32 window with
// those two strings is indistinguishable from the game as far as capture is concerned.
//
// Fidelity contract: the client area is created at exactly the recording's frame size and every
// decoded frame is presented into it 1:1. No scaling, no letterbox, no chrome inside the client
// rect -- the app crops the captured surface to the client area, so anything shown there reaches
// the recognition pipeline verbatim. A capture of this window must therefore be bit-identical to
// the frames of the source recording; tool/live_capture_test/compare_frames.py asserts it, driven
// end to end by tool/live_capture_test/fidelity_run.sh.
//
// Decoding goes through ClipDecoder (clip_decoder.h), which reuses the recorder's own AVIO bridge
// and its BGR0 <-> BGR mapping, so the pixels presented here are the recorder's pixels and the
// timestamps are the recorder's millisecond timestamps. See that header for why the seekable reader
// lives in tool/ instead of being bolted onto uma::video::Ffv1Reader.
//
// The window is a plain captioned WS_OVERLAPPEDWINDOW, exactly like the game's, because the web
// front end captures the game through the browser's window share and gets the whole window,
// chrome included. Frames are presented into its client area through a DXGI flip-model swap chain;
// present() explains why that, and not GDI or a layered window.
//
// Windows-only by construction (Win32 windowing + D3D11/DXGI). It lives under native/tool/ rather
// than native/src/ so it stays outside the web-pin source-digest roots; see native/CMakeLists.txt.
//
// Flags:
//   --record <path>     input FFV1 .mkv                        (required)
//   --class <name>      window class name                      (default UnityWndClass)
//   --title <text>      window title                           (default umamusume)
//   --x <px> --y <px>   window position                        (default 100 100)
//   --loop              restart from the first frame of the active range at its end
//   --duration <sec>    stop automatically after N seconds     (0 = until EOS / Ctrl-C / close)
//   --stop-file <path>  stop cleanly when this file appears; a stale one is cleared at startup
//   --control           enable the stdin/stdout control channel (see below)
//
// --duration and --stop-file mirror `capture`'s options of the same names, including clearing a
// stale stop-file at startup so a leftover cannot end the run immediately. That clearing removes an
// EMPTY REGULAR FILE only, and refuses to start on anything else -- see tool/stop_file_guard.h for
// why the sentinel is recognised by carrying no bytes rather than by its name. `capture` uses the
// same guard, so the two options of the same name still behave the same way.
//
// ---------------------------------------------------------------------------------------------
// Control channel (--control)
// ---------------------------------------------------------------------------------------------
//
// Commands are newline-delimited words on stdin. Every command produces exactly one line on stdout,
// and that line is written only AFTER the command's effect is on screen -- a harness that blocks on
// the reply therefore needs no sleeps and no polling. Without --control nothing reads stdin and the
// player behaves exactly as it did in S2 (play through once, or forever with --loop, then exit).
//
//   pause                 hold the current frame
//   resume                continue playing from the frame after the held one
//   step [n]              advance exactly n source frames (default 1) and hold; implies pause
//   seek <seconds>        hold/continue at the frame whose timestamp is nearest <seconds>
//   range <from> <to>     restrict playback to [from, to] seconds; repositions if outside
//   pause-at <spec> [tag] arm a breakpoint: pause automatically on reaching <spec>
//   rate <factor>         change the playback speed now (1.0 = the clip's own timestamps)
//   rate-at <spec> <f> [tag]  arm a speed change: apply <f> automatically on reaching <spec>
//   status                report the current state; changes nothing
//   quit                  shut down
//
// Reply grammar, one line per command:
//   ok <command> index=<i> ts=<ms> state=playing|paused range=<from>..<to> count=<n> presents=<n>
//                pending=<armed breakpoints> rate=<factor> pending_rate=<armed speed changes>
//   err <command> <reason>
// Four unsolicited lines use the same field list with a different leading token: `ready ...` once
// the window is up and the first frame is on screen, `event eos ...` when playback reaches the end
// of the active range with --loop off, `event pause-at ... at=<frame> label=<tag>` when an
// armed breakpoint fires, and `event rate-at ... at=<frame> to=<factor> label=<tag>` when an armed
// speed change fires. A reader that only accepts lines starting with `ok ` or `err ` as replies
// is therefore never confused by them.
//
// ---------------------------------------------------------------------------------------------
// Breakpoints (`pause-at`), stage S6b
// ---------------------------------------------------------------------------------------------
//
// A harness that wants to hold the clip on a particular frame cannot poll the position and then
// send `pause`: playback advances on the playback thread between the `status` reply and the
// `pause` command, so the frame it stops on is a race. `pause-at` arms the stop IN ADVANCE and the
// playback thread applies it itself, at the same place it presents, so the frame it stops on is
// exact by construction and playback in between still runs at the clip's own real-time cadence.
//
//   pause-at 62            frame index 62
//   pause-at frame=62      the same, written explicitly
//   pause-at sec=2.44      the frame whose timestamp is nearest 2.44 s
//   pause-at 62 tab0       any of the above with a label echoed back in the event
//   pause-at clear         disarm every pending breakpoint
//
// Any number of breakpoints may be armed at once (this clip needs three, one per tab). They fire in
// frame order; a breakpoint whose frame is already behind the current position fires on the next
// presented frame rather than being silently dropped. Firing is: the frame is presented (once,
// by the normal playback path), the player switches to Paused -- which keeps re-presenting the held
// frame, so the capture is not starved -- and `event pause-at` is emitted. `resume` continues from
// the frame after it, exactly as after a manual `pause`.
//
// --control starts PAUSED on frame 0, so a harness can set up capture before any motion.
//
// Pause keeps presenting. It does not stop drawing: a window that stops presenting stops feeding
// the capture (measured while this was written; the measurement log is machine-local and is not in
// the repository, so the conclusion is stated here rather than pointed at), and the pipeline's
// FrameStallWatchdog force-closes an in-progress scene after 2000 ms without a frame. A paused
// player therefore re-presents the held frame at the clip's own median frame interval, which is
// indistinguishable to the capture from a game screen that simply is not changing.
//
// ---------------------------------------------------------------------------------------------
// Playback rate (`rate`, `rate-at`), stage S6c
// ---------------------------------------------------------------------------------------------
//
// The rate is a SPEED multiplier applied to the clip's own inter-frame timestamps: 1.0 plays the
// recording at real time, 0.5 takes twice as long per frame, 2.0 half. It never changes WHICH
// frames are presented or in what order -- only when the next one is due -- so the fidelity
// contract (every frame presented exactly once, in order, bit-identical) is untouched.
//
//   rate 0.5              apply immediately
//   rate-at 63 0.5        apply on reaching frame index 63
//   rate-at sec=2.48 0.5  ... the frame nearest 2.48 s; `frame=` is accepted too
//   rate-at 127 1.0 end0  any of the above with a label echoed back in the event
//   rate-at clear         disarm every pending speed change
//
// `rate-at` exists for the same reason `pause-at` does: a harness cannot poll the position and then
// send `rate` without racing the playhead. Armed changes fire on the playback thread immediately
// after the frame that reached them is presented, i.e. the new speed governs the NEXT interval, and
// the event is written after the effect is in force -- the same ack-after-effect discipline as
// every other reply. `<=` rather than `==`, so a change armed behind the playhead still fires.
//
// Pausing is deliberately NOT scaled: a paused player keeps re-presenting at the clip's median
// interval clamped to [8, 50] ms whatever the rate is, because that cadence exists to keep the
// capture fed and the pipeline's 2000 ms stall watchdog quiet, which has nothing to do with speed.

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <future>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "clip_decoder.h"
#include "spec_parse.h"
#include "stop_file_guard.h"
#include "util/logger_util.h"

namespace uma::mimic {

namespace {

using Clock = std::chrono::steady_clock;

std::filesystem::path g_record_path;
std::string g_class_name = "UnityWndClass";
std::string g_title = "umamusume";
int g_pos_x = 100;
int g_pos_y = 100;
bool g_loop = false;
bool g_control = false;
int g_duration_seconds = 0;
std::filesystem::path g_stop_file;

// Set by the stop conditions (main thread, console handler, `quit`) and polled by the playback
// thread.
std::atomic<bool> g_stop_requested{false};
// Set when playback finishes on its own (end of stream without --loop), so main can exit.
std::atomic<bool> g_playback_done{false};
std::atomic<unsigned long long> g_presented{0};

// The capture target: a plain captioned top-level window, structurally identical to the game's
// (WS_OVERLAPPEDWINDOW, DWM-drawn caption and border). It never draws anything itself.
HWND g_hwnd = nullptr;
int g_client_w = 0;
int g_client_h = 0;

std::unique_ptr<ClipDecoder> g_decoder;

// Presentation resources. A DXGI flip-model swap chain bound to the window presents into exactly
// the window's CLIENT area, leaving the caption and border to DWM; see present() for why this is a
// swap chain and not GDI. The staging texture is the CPU-writable copy the decoded frame is
// converted into. The mutex covers the pixel write, the present, and teardown together: presenting
// runs on the playback thread while the message thread owns the window, and an ID3D11DeviceContext
// must not be used from two threads at once.
std::mutex g_surface_mutex;
Microsoft::WRL::ComPtr<ID3D11Device> g_device;
Microsoft::WRL::ComPtr<ID3D11DeviceContext> g_context;
Microsoft::WRL::ComPtr<IDXGISwapChain1> g_swap_chain;
Microsoft::WRL::ComPtr<ID3D11Texture2D> g_staging;

// stdout is the reply channel, so every write goes through one mutex and is flushed immediately:
// the pipe a harness reads is block-buffered otherwise, which would defeat the whole point of an
// ack that arrives when the effect lands.
std::mutex g_stdout_mutex;

void emit(const std::string &line) {
    std::lock_guard<std::mutex> lock(g_stdout_mutex);
    std::fputs(line.c_str(), stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
}

// One parsed control command plus the handshake the reader thread blocks on. The playback thread
// prints the reply itself and only then satisfies the promise, so "the reply was written" and "the
// effect is in place" cannot be observed out of order no matter how the two threads interleave.
struct Command {
    std::string name;
    std::vector<std::string> args;
    std::promise<void> done;
};

std::mutex g_command_mutex;
std::condition_variable g_command_cv;
std::deque<std::shared_ptr<Command>> g_command_queue;

// Builds the presentation chain: a D3D11 device, a flip-model swap chain bound to the window, and
// one CPU-writable staging texture the decoded frames are converted into.
//
// Everything here is chosen so the presented bytes are the decoded bytes:
//   * DXGI_FORMAT_B8G8R8A8_UNORM, matching the BGRA the frame is converted to -- not the _SRGB
//     variant, which would make the compositor gamma-convert the samples.
//   * DXGI_SCALING_NONE with the buffer size equal to the client size, so no resampling can occur.
//   * DXGI_ALPHA_MODE_IGNORE, so the alpha byte cvtColor writes cannot blend anything.
bool createPresenter(HWND hwnd, int width, int height) {
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0, D3D11_SDK_VERSION, &g_device, nullptr,
        &g_context);
    if (FAILED(hr)) {
        std::printf("mimic: D3D11CreateDevice failed: 0x%08lX\n", hr);
        return false;
    }

    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    Microsoft::WRL::ComPtr<IDXGIFactory2> factory;
    if (FAILED(g_device.As(&dxgi_device)) || FAILED(dxgi_device->GetAdapter(&adapter)) ||
        FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) {
        std::printf("mimic: could not reach IDXGIFactory2\n");
        return false;
    }

    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = static_cast<UINT>(width);
    desc.Height = static_cast<UINT>(height);
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;  // minimum for the flip model
    desc.Scaling = DXGI_SCALING_NONE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    hr = factory->CreateSwapChainForHwnd(g_device.Get(), hwnd, &desc, nullptr, nullptr, &g_swap_chain);
    if (FAILED(hr)) {
        std::printf("mimic: CreateSwapChainForHwnd failed: 0x%08lX\n", hr);
        return false;
    }
    // DXGI otherwise watches the window's message queue and can change the window on Alt+Enter.
    // This fixture's whole point is that its window keeps the exact shape it was created with.
    factory->MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER | DXGI_MWA_NO_WINDOW_CHANGES);

    D3D11_TEXTURE2D_DESC tex{};
    tex.Width = static_cast<UINT>(width);
    tex.Height = static_cast<UINT>(height);
    tex.MipLevels = 1;
    tex.ArraySize = 1;
    tex.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    tex.SampleDesc.Count = 1;
    tex.Usage = D3D11_USAGE_DYNAMIC;  // Map(WRITE_DISCARD) each frame, then CopyResource to the back buffer
    tex.BindFlags = D3D11_BIND_SHADER_RESOURCE;  // a dynamic texture must be bindable somewhere
    tex.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    hr = g_device->CreateTexture2D(&tex, nullptr, &g_staging);
    if (FAILED(hr)) {
        std::printf("mimic: CreateTexture2D failed: 0x%08lX\n", hr);
        return false;
    }
    return true;
}

void destroyPresenter() {
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    g_staging.Reset();
    g_swap_chain.Reset();
    g_context.Reset();
    g_device.Reset();
}

// Writes one decoded frame into the staging texture and puts it on screen.
//
// Presentation is a flip-model swap chain Present, not a GDI blit into the window DC, because only
// the former is ATOMIC as far as the capture is concerned. Measured, in order:
//
//   * BitBlt from the playback thread, outside a paint cycle:        5.3% of captured frames torn
//   * the same BitBlt moved inside BeginPaint/EndPaint:              3.5%
//   * plus DwmFlush + GdiFlush immediately around it:                0-5%, run to run
//
// Torn means the captured frame was source frame N above some row and frame N-1 below it. The
// boundary rows landed on multiples of 8, i.e. the split happens in the compositor's block copy of
// the window's REDIRECTION SURFACE, below the level any GDI-side flushing can reach. That is the
// common cause of all three failures above: every one of them ends in GDI writing the redirection
// surface while DWM is copying it. A flip-model swap chain does not use the redirection surface at
// all -- Present hands DWM a finished back buffer and the compositor picks up whole buffers -- so a
// capture can only ever observe a complete frame.
//
// UpdateLayeredWindow is atomic for the same reason and was measured tear-free too, but it costs
// the window its identity: a layered window's bitmap replaces the ENTIRE window rect, non-client
// area included, so the window has to become a caption-less WS_POPUP. This fixture exists to be
// structurally indistinguishable from the game window, chrome included, because the web front end
// captures the whole window through the browser's window share. A swap chain presents into exactly
// the CLIENT area and leaves the caption and border to DWM, which is what makes it the one option
// that satisfies both.
void present(const cv::Mat &bgr) {
    std::lock_guard<std::mutex> lock(g_surface_mutex);
    if (g_swap_chain == nullptr || g_staging == nullptr) {
        return;
    }
    if (bgr.cols != g_client_w || bgr.rows != g_client_h || bgr.type() != CV_8UC3) {
        // A recording whose frame size changes mid-stream would break the 1:1 contract silently.
        log_error("mimic: unexpected frame {}x{} type {}", bgr.cols, bgr.rows, bgr.type());
        return;
    }

    D3D11_MAPPED_SUBRESOURCE mapped{};
    HRESULT hr = g_context->Map(g_staging.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped);
    if (FAILED(hr)) {
        log_error("mimic: Map failed: {:#x}", static_cast<unsigned>(hr));
        return;
    }
    // The driver's row pitch is not necessarily width*4, so the destination Mat carries it as step.
    cv::Mat surface(g_client_h, g_client_w, CV_8UC4, mapped.pData, static_cast<size_t>(mapped.RowPitch));
    cv::cvtColor(bgr, surface, cv::COLOR_BGR2BGRA);
    g_context->Unmap(g_staging.Get(), 0);

    Microsoft::WRL::ComPtr<ID3D11Texture2D> back;
    // With FLIP_DISCARD only buffer 0 is accessible, and it must be re-acquired after every Present.
    hr = g_swap_chain->GetBuffer(0, IID_PPV_ARGS(&back));
    if (FAILED(hr)) {
        log_error("mimic: GetBuffer failed: {:#x}", static_cast<unsigned>(hr));
        return;
    }
    g_context->CopyResource(back.Get(), g_staging.Get());
    // Sync interval 0: pace comes from the recording's own timestamps, not from the display's
    // refresh. Frames the compositor never gets to show are simply missed by the capture, exactly
    // as they already are between DWM composition boundaries.
    hr = g_swap_chain->Present(0, 0);
    if (FAILED(hr)) {
        log_error("mimic: Present failed: {:#x}", static_cast<unsigned>(hr));
        return;
    }
    g_presented.fetch_add(1);
}

// The capture target's proc. It must never paint the client area: the swap chain owns every client
// pixel, and anything drawn underneath would only be a source of flicker. Erasing is suppressed for
// the same reason. Non-client painting is left to DefWindowProc, i.e. to DWM, so the caption and
// border are the stock ones.
LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
        case WM_PAINT: {
            PAINTSTRUCT ps;
            BeginPaint(hwnd, &ps);
            EndPaint(hwnd, &ps);
            return 0;
        }
        case WM_ERASEBKGND: return 1;
        // The window is resizable because the game's is (WS_THICKFRAME is part of the style being
        // impersonated), but a resize would break the 1:1 client-area contract mid-capture. Pinning
        // the tracking size keeps the style identical while making the size effectively fixed.
        case WM_GETMINMAXINFO: {
            if (g_client_w > 0 && g_client_h > 0 && g_hwnd != nullptr) {
                RECT frame{0, 0, g_client_w, g_client_h};
                AdjustWindowRectExForDpi(
                    &frame, static_cast<DWORD>(GetWindowLongPtrA(g_hwnd, GWL_STYLE)), FALSE,
                    static_cast<DWORD>(GetWindowLongPtrA(g_hwnd, GWL_EXSTYLE)), GetDpiForWindow(g_hwnd));
                auto *info = reinterpret_cast<MINMAXINFO *>(lp);
                info->ptMinTrackSize = POINT{frame.right - frame.left, frame.bottom - frame.top};
                info->ptMaxTrackSize = info->ptMinTrackSize;
            }
            return 0;
        }
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
        case WM_CLOSE:
        case WM_DESTROY: g_stop_requested.store(true); return 0;
        default: return DefWindowProcA(hwnd, msg, wp, lp);
    }
}

BOOL WINAPI consoleHandler(DWORD ctrl_type) {
    switch (ctrl_type) {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
        case CTRL_CLOSE_EVENT:
        case CTRL_LOGOFF_EVENT:
        case CTRL_SHUTDOWN_EVENT: g_stop_requested.store(true); return TRUE;
        default: return FALSE;
    }
}

enum class Mode { Playing, Paused };

// The playback state machine. It owns the decoder and is the ONLY thread that presents, so every
// command's effect is applied and observed on one thread and the reply cannot describe a state that
// was never on screen.
class Player {
public:
    explicit Player(ClipDecoder &decoder)
        : decoder_(decoder)
        , to_(decoder.frameCount() - 1)
        // A paused player re-presents at the clip's own median frame interval. Clamped so a clip
        // with a pathological timeline cannot make the hold either a busy loop or slow enough to
        // approach the pipeline's 2000 ms stall timeout.
        , hold_(std::clamp<long long>(decoder.medianIntervalMs(), 8, 50))
        , mode_(g_control ? Mode::Paused : Mode::Playing) {}

    void run() {
        presentIndex(current_);
        resetPacing();
        if (g_control) {
            emit(describe("ready", ""));
        }
        while (!g_stop_requested.load()) {
            if (const auto command = takeCommand()) {
                execute(*command);
                command->done.set_value();
                continue;
            }
            if (mode_ == Mode::Playing) {
                if (!tickPlaying()) {
                    break;
                }
            } else {
                tickPaused();
            }
        }
    }

private:
    // One armed `pause-at`. Kept sorted by frame, so firing is a front-of-vector test.
    struct Breakpoint {
        int frame;
        std::string label;
    };

    // One armed `rate-at`. Same shape and same firing rule as a breakpoint, plus the speed to
    // switch to. Kept in its own vector so the two never reorder each other.
    struct RatePoint {
        int frame;
        double rate;
        std::string label;
    };

    // Rates are printed with a fixed precision so a reply is always parseable as a number and a
    // harness can compare the echoed value with what it asked for.
    [[nodiscard]] static std::string formatRate(double rate) {
        std::ostringstream out;
        out << std::fixed << std::setprecision(3) << rate;
        return out.str();
    }

    std::shared_ptr<Command> takeCommand() {
        std::lock_guard<std::mutex> lock(g_command_mutex);
        if (g_command_queue.empty()) {
            return nullptr;
        }
        auto command = g_command_queue.front();
        g_command_queue.pop_front();
        return command;
    }

    // Idles until the next scheduled present, but wakes immediately if a command arrives, so the
    // reply latency of a command is never the frame interval.
    void waitForCommand(Clock::duration limit) {
        const auto capped = std::min<Clock::duration>(limit, std::chrono::milliseconds(2));
        if (capped <= Clock::duration::zero()) {
            return;
        }
        std::unique_lock<std::mutex> lock(g_command_mutex);
        g_command_cv.wait_for(lock, capped, [] { return !g_command_queue.empty(); });
    }

    void presentIndex(int index) {
        present(decoder_.frameAt(index));
        last_present_ = Clock::now();
    }

    // Re-anchors the wall clock to the current frame, so playback from here on honours the clip's
    // own inter-frame timestamps regardless of how long the player sat paused or where it seeked to.
    void resetPacing() {
        anchor_ = Clock::now();
        anchor_ts_ = decoder_.relativeMs(current_);
    }

    // Returns false when the run is over (end of stream with neither --loop nor --control).
    bool tickPlaying() {
        const int next = current_ + 1;
        if (next > to_) {
            if (g_loop) {
                current_ = from_;
                presentIndex(current_);
                resetPacing();
                fireRatePoints();
                fireBreakpoints();
                return true;
            }
            if (g_control) {
                // Under control the process must stay alive and controllable past the end of the
                // range, or the harness would lose the window it is still capturing.
                mode_ = Mode::Paused;
                emit(describe("event", "eos"));
                return true;
            }
            return false;
        }
        // The clip's own elapsed time to [next], divided by the speed multiplier. At rate 1.0 the
        // division is exact on an integer millisecond count, so real-time playback schedules
        // exactly the instants it scheduled before rates existed.
        const auto scaled =
            static_cast<long long>(std::llround(static_cast<double>(decoder_.relativeMs(next) - anchor_ts_) / rate_));
        const auto due = anchor_ + std::chrono::milliseconds(scaled);
        const auto now = Clock::now();
        if (now >= due) {
            // Behind schedule (slow decode) presents immediately: dropping the frame would break
            // presentation order, which is the property the fidelity check asserts.
            current_ = next;
            presentIndex(current_);
            fireRatePoints();
            fireBreakpoints();
            return true;
        }
        waitForCommand(due - now);
        return true;
    }

    // Applies any breakpoint the frame just presented has reached. Called only from the playing
    // path, immediately after presentIndex, so:
    //   * the frame the event names is already on screen when the event is written -- the same
    //     ack-after-effect discipline every command reply follows;
    //   * the frame is presented exactly once (by the normal playback path), so nothing about the
    //     presented sequence changes and the fidelity contract is untouched;
    //   * the switch to Paused takes effect before the next tick, i.e. no further frame is
    //     presented after the stop frame until the harness resumes.
    // `<=` rather than `==` so a breakpoint armed behind the playhead fires on the next frame
    // instead of being pending forever, which would deadlock a harness waiting for its event.
    void fireBreakpoints() {
        while (!breakpoints_.empty() && breakpoints_.front().frame <= current_) {
            const Breakpoint hit = breakpoints_.front();
            breakpoints_.erase(breakpoints_.begin());
            mode_ = Mode::Paused;
            std::ostringstream out;
            out << describe("event", "pause-at") << " at=" << hit.frame << " label=" << hit.label;
            emit(out.str());
        }
    }

    // Applies any armed speed change the frame just presented has reached. Called from the same
    // place as fireBreakpoints -- on the playback thread, immediately after presentIndex -- so the
    // new rate is in force for the next interval before its event is written, and firing it cannot
    // interleave with a command. resetPacing re-anchors, so the new speed measures from this frame.
    void fireRatePoints() {
        while (!rate_points_.empty() && rate_points_.front().frame <= current_) {
            const RatePoint hit = rate_points_.front();
            rate_points_.erase(rate_points_.begin());
            rate_ = hit.rate;
            resetPacing();
            std::ostringstream out;
            out << describe("event", "rate-at") << " at=" << hit.frame << " to=" << formatRate(hit.rate)
                << " label=" << hit.label;
            emit(out.str());
        }
    }

    // Shared by `pause-at` and `rate-at`: `<n>`, `frame=<n>` or `sec=<t>` to a clamped frame index,
    // or -1 when the spec does not parse. BOTH branches are parsed strictly (spec_parse.h): a spec
    // that is not wholly a number is an error, never frame 0. The index is still clamped into the
    // clip once it HAS parsed -- clamping a number the caller wrote is not the same as inventing one.
    [[nodiscard]] int resolveSpec(const std::string &raw) const {
        std::string spec = raw;
        bool by_seconds = false;
        if (spec.rfind("frame=", 0) == 0) {
            spec = spec.substr(6);
        } else if (spec.rfind("sec=", 0) == 0) {
            spec = spec.substr(4);
            by_seconds = true;
        }
        int frame = 0;
        if (by_seconds) {
            const auto seconds = parseWholeDouble(spec);
            if (!seconds.has_value()) {
                return -1;
            }
            frame = decoder_.nearestIndex(seconds.value());
        } else {
            const auto parsed = parseWholeInt(spec);
            if (!parsed.has_value()) {
                return -1;
            }
            frame = parsed.value();
        }
        return std::clamp(frame, 0, decoder_.frameCount() - 1);
    }

    // A speed multiplier must be finite and strictly positive; the upper bound keeps a typo from
    // turning into a schedule the player would burn a core on. Returns 0.0 on a spec that does not
    // parse, which is not a legal rate and so is unambiguous.
    [[nodiscard]] static double parseRate(const std::string &raw) {
        const double value = std::atof(raw.c_str());
        if (!std::isfinite(value) || value <= 0.0 || value > 1000.0) {
            return 0.0;
        }
        return value;
    }

    // `pause-at <spec> [label]`. Returns the resolved frame and writes the effective label to
    // [label_out], or returns -1 on a spec that does not parse. The vector is kept sorted, so the
    // armed entry is not necessarily the last one -- hence the out-parameter.
    int armBreakpoint(const Command &command, std::string &label_out) {
        const int resolved = resolveSpec(command.args[0]);
        if (resolved < 0) {
            return -1;
        }
        label_out = command.args.size() > 1 ? command.args[1] : std::to_string(resolved);
        breakpoints_.push_back(Breakpoint{resolved, label_out});
        std::sort(breakpoints_.begin(), breakpoints_.end(), [](const Breakpoint &a, const Breakpoint &b) {
            return a.frame < b.frame;
        });
        return resolved;
    }

    // `rate-at <spec> <factor> [label]`. Same contract as armBreakpoint; [rate_out] carries the
    // parsed multiplier back so the reply can echo exactly what was armed.
    int armRatePoint(const Command &command, std::string &label_out, double &rate_out) {
        const int resolved = resolveSpec(command.args[0]);
        if (resolved < 0) {
            return -1;
        }
        rate_out = parseRate(command.args[1]);
        if (rate_out <= 0.0) {
            return -1;
        }
        label_out = command.args.size() > 2 ? command.args[2] : std::to_string(resolved);
        rate_points_.push_back(RatePoint{resolved, rate_out, label_out});
        std::sort(rate_points_.begin(), rate_points_.end(), [](const RatePoint &a, const RatePoint &b) {
            return a.frame < b.frame;
        });
        return resolved;
    }

    // Pause is NOT "stop drawing". The held frame is re-presented at the clip's own cadence, so the
    // capture keeps receiving frames and the pipeline's frame-stall watchdog never fires. A window
    // that simply stops presenting starves WinRT Graphics Capture -- measured; see the file header
    // for why that measurement is quoted rather than linked.
    void tickPaused() {
        const auto due = last_present_ + hold_;
        const auto now = Clock::now();
        if (now >= due) {
            presentIndex(current_);
            return;
        }
        waitForCommand(due - now);
    }

    [[nodiscard]] std::string describe(const std::string &lead, const std::string &name) const {
        std::ostringstream out;
        out << lead;
        if (!name.empty()) {
            out << ' ' << name;
        }
        out << " index=" << current_ << " ts=" << decoder_.relativeMs(current_)
            << " state=" << (mode_ == Mode::Playing ? "playing" : "paused") << " range=" << from_ << ".." << to_
            << " count=" << decoder_.frameCount() << " presents=" << g_presented.load()
            << " pending=" << breakpoints_.size() << " rate=" << formatRate(rate_)
            << " pending_rate=" << rate_points_.size();
        return out.str();
    }

    // An omitted argument yields the default; a PRESENT argument that is not wholly a number yields
    // nullopt, which the caller must turn into an `err` line. `step abc` used to advance zero frames
    // and answer `ok` -- a reply the harness cannot tell from a step it asked for.
    [[nodiscard]] static std::optional<int> argInt(const Command &command, size_t position, int fallback) {
        if (position >= command.args.size()) {
            return fallback;
        }
        return parseWholeInt(command.args[position]);
    }

    // Every branch does the work FIRST and emits its reply LAST, which is the whole ack contract.
    void execute(const Command &command) {
        const std::string &name = command.name;
        if (name == "status") {
            emit(describe("ok", name));
        } else if (name == "pause") {
            mode_ = Mode::Paused;
            presentIndex(current_);
            emit(describe("ok", name));
        } else if (name == "resume") {
            resume();
            emit(describe("ok", name));
        } else if (name == "step") {
            const auto count = argInt(command, 0, 1);
            if (!count.has_value()) {
                emit("err step bad-count");
                return;
            }
            if (count.value() < 0) {
                emit("err step negative-count");
                return;
            }
            mode_ = Mode::Paused;
            current_ = std::min(current_ + count.value(), to_);
            presentIndex(current_);
            resetPacing();
            emit(describe("ok", name));
        } else if (name == "seek") {
            if (command.args.empty()) {
                emit("err seek missing-time");
                return;
            }
            current_ = std::clamp(decoder_.nearestIndex(std::atof(command.args[0].c_str())), from_, to_);
            presentIndex(current_);
            resetPacing();
            emit(describe("ok", name));
        } else if (name == "range") {
            if (command.args.size() < 2) {
                emit("err range missing-bounds");
                return;
            }
            int low = decoder_.nearestIndex(std::atof(command.args[0].c_str()));
            int high = decoder_.nearestIndex(std::atof(command.args[1].c_str()));
            if (high < low) {
                std::swap(low, high);
            }
            from_ = low;
            to_ = high;
            if (current_ < from_ || current_ > to_) {
                current_ = from_;
            }
            presentIndex(current_);
            resetPacing();
            emit(describe("ok", name));
        } else if (name == "pause-at") {
            if (command.args.empty()) {
                emit("err pause-at missing-spec");
                return;
            }
            if (command.args[0] == "clear") {
                breakpoints_.clear();
                emit(describe("ok", name) + " at=none label=cleared");
                return;
            }
            std::string label;
            const int resolved = armBreakpoint(command, label);
            if (resolved < 0) {
                emit("err pause-at bad-spec");
                return;
            }
            emit(describe("ok", name) + " at=" + std::to_string(resolved) + " label=" + label);
        } else if (name == "rate") {
            if (command.args.empty()) {
                emit("err rate missing-factor");
                return;
            }
            const double parsed = parseRate(command.args[0]);
            if (parsed <= 0.0) {
                emit("err rate bad-factor");
                return;
            }
            // Effect before reply: the multiplier is in force and the schedule re-anchored to the
            // frame on screen, so the very next interval already honours the new speed.
            rate_ = parsed;
            resetPacing();
            emit(describe("ok", name));
        } else if (name == "rate-at") {
            if (command.args.empty()) {
                emit("err rate-at missing-spec");
                return;
            }
            if (command.args[0] == "clear") {
                rate_points_.clear();
                emit(describe("ok", name) + " at=none to=none label=cleared");
                return;
            }
            if (command.args.size() < 2) {
                emit("err rate-at missing-factor");
                return;
            }
            std::string label;
            double armed = 0.0;
            const int resolved = armRatePoint(command, label, armed);
            if (resolved < 0) {
                emit("err rate-at bad-spec");
                return;
            }
            emit(describe("ok", name) + " at=" + std::to_string(resolved) + " to=" + formatRate(armed)
                 + " label=" + label);
        } else if (name == "quit") {
            emit(describe("ok", name));
            g_stop_requested.store(true);
        } else {
            emit("err " + name + " unknown-command");
        }
    }

    void resume() {
        if (current_ < to_) {
            current_ += 1;
        } else if (g_loop) {
            current_ = from_;
        } else {
            // Nothing left in the active range: report the unchanged paused state rather than
            // claiming a resume that cannot produce a frame.
            mode_ = Mode::Paused;
            return;
        }
        mode_ = Mode::Playing;
        presentIndex(current_);
        resetPacing();
    }

    ClipDecoder &decoder_;
    std::vector<Breakpoint> breakpoints_;
    std::vector<RatePoint> rate_points_;
    // Speed multiplier on the clip's own timestamps. 1.0 is real time and is what every run that
    // never sends `rate` gets, bit-for-bit as before rates existed.
    double rate_ = 1.0;
    int from_ = 0;
    int to_ = 0;
    int current_ = 0;
    const std::chrono::milliseconds hold_;
    Mode mode_;
    Clock::time_point anchor_{};
    long long anchor_ts_ = 0;
    Clock::time_point last_present_{};
};

void playbackThread() {
    try {
        Player player(*g_decoder);
        player.run();
    } catch (const std::exception &e) {
        log_error("mimic: playback failed: {}", e.what());
    }
    // Whatever ended the run, no further command will ever be executed. Release anyone blocked on a
    // reply instead of leaving the reader thread waiting on a promise nobody will satisfy.
    {
        std::lock_guard<std::mutex> lock(g_command_mutex);
        while (!g_command_queue.empty()) {
            emit("err " + g_command_queue.front()->name + " player-stopped");
            g_command_queue.front()->done.set_value();
            g_command_queue.pop_front();
        }
    }
    g_playback_done.store(true);
}

// Reads commands and blocks on each one's reply before reading the next, so a harness's writes are
// never buffered ahead of the effects it is waiting for. Runs detached: it spends its life inside a
// blocking read, and end-of-input is itself a stop condition.
void controlThread() {
    std::string line;
    while (std::getline(std::cin, line)) {
        auto command = std::make_shared<Command>();
        std::istringstream in(line);
        if (!(in >> command->name)) {
            continue;  // blank line
        }
        std::string token;
        while (in >> token) {
            command->args.push_back(token);
        }
        const bool quitting = command->name == "quit";
        auto done = command->done.get_future();
        {
            std::lock_guard<std::mutex> lock(g_command_mutex);
            g_command_queue.push_back(std::move(command));
        }
        g_command_cv.notify_all();
        done.wait();
        if (quitting || g_playback_done.load()) {
            return;
        }
    }
    // stdin closed: the harness is gone, so end the run rather than leaving an orphan window.
    g_stop_requested.store(true);
}

void parseArgs(int argc, char **argv) {
    const auto next = [&](int &i) -> const char * { return (i + 1 < argc) ? argv[++i] : ""; };
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--record") == 0) {
            g_record_path = next(i);
        } else if (std::strcmp(argv[i], "--class") == 0) {
            g_class_name = next(i);
        } else if (std::strcmp(argv[i], "--title") == 0) {
            g_title = next(i);
        } else if (std::strcmp(argv[i], "--x") == 0) {
            g_pos_x = std::atoi(next(i));
        } else if (std::strcmp(argv[i], "--y") == 0) {
            g_pos_y = std::atoi(next(i));
        } else if (std::strcmp(argv[i], "--loop") == 0) {
            g_loop = true;
        } else if (std::strcmp(argv[i], "--control") == 0) {
            g_control = true;
        } else if (std::strcmp(argv[i], "--duration") == 0) {
            g_duration_seconds = std::atoi(next(i));
        } else if (std::strcmp(argv[i], "--stop-file") == 0) {
            g_stop_file = next(i);
        } else {
            std::printf("mimic: unknown argument: %s\n", argv[i]);
        }
    }
}

int run(int argc, char **argv) {
    parseArgs(argc, argv);
    if (g_record_path.empty()) {
        std::printf("usage: umacapture_mimic_player --record <ffv1.mkv> [--class N] [--title T] "
                    "[--x N] [--y N] [--loop] [--control] [--duration SEC] [--stop-file PATH]\n"
                    "  --stop-file PATH is a sentinel this run stops on. A stale EMPTY file there is "
                    "cleared at startup; anything else makes it refuse to start.\n");
        return 2;
    }

    // Before the clip is opened and the window created, because this can refuse: a path that already
    // holds something is not a stale sentinel, and the guard will not delete it (tool/stop_file_guard.h).
    // Refusing here costs a restart with a different path; the alternative cost an unrepeatable recording.
    if (!g_stop_file.empty()) {
        const auto clearance = uma::tool::clearStaleStopFile(g_stop_file);
        if (clearance.clearance == uma::tool::StopFileClearance::Refused) {
            std::printf("mimic: %s\n", clearance.reason.c_str());
            return 2;
        }
        if (clearance.clearance == uma::tool::StopFileClearance::Cleared) {
            std::printf("mimic: %s\n", clearance.reason.c_str());
        }
    }

    // Per-monitor DPI aware: a DPI-unaware process is virtualised by the OS, so the client area the
    // capture path sees would not be the size the recording needs it to be.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Opening the clip up front both builds the seek index and yields frame 0, whose size the
    // window's client area must be created at.
    g_decoder = std::make_unique<ClipDecoder>(g_record_path);
    const cv::Mat &first = g_decoder->frameAt(0);
    g_client_w = first.cols;
    g_client_h = first.rows;

    const HINSTANCE inst = GetModuleHandleA(nullptr);
    WNDCLASSA wc{};
    wc.lpfnWndProc = wndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = g_class_name.c_str();
    if (RegisterClassA(&wc) == 0) {
        std::printf("mimic: RegisterClassA failed: %lu\n", GetLastError());
        return 1;
    }
    // Exactly the game's style: 0x14CF0000 == WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPSIBLINGS
    // (USER32 adds the latter two), exstyle 0x100 == WS_EX_WINDOWEDGE (added because of WS_DLGFRAME).
    // Deliberately NOT WS_CLIPCHILDREN, which the game does not have either: the parent paints
    // nothing, so there is nothing to clip.
    const DWORD style = WS_OVERLAPPEDWINDOW;
    RECT want{0, 0, g_client_w, g_client_h};
    AdjustWindowRectExForDpi(&want, style, FALSE, 0, GetDpiForSystem());

    g_hwnd = CreateWindowExA(
        0, g_class_name.c_str(), g_title.c_str(), style, g_pos_x, g_pos_y, want.right - want.left,
        want.bottom - want.top, nullptr, nullptr, inst, nullptr);
    if (g_hwnd == nullptr) {
        std::printf("mimic: CreateWindowExA failed: %lu\n", GetLastError());
        return 1;
    }

    // Windows 11 rounds window corners in the compositor, and the rounding reaches INTO the client
    // area: measured against a capture of this window, the bottom two corners came back with ~24
    // blended pixels across the last 7 rows that no source frame contains. That alone breaks
    // bit-identity. Opting out keeps the client rect square, so the captured pixels are exactly the
    // ones blitted. Ignored (and harmless) on Windows 10, where the attribute is unknown.
    //
    // This is the one respect in which the window is knowingly not the game's: the game is rounded.
    // The corner preference is not part of the window's style, exstyle, rect, frame bounds or DPI,
    // so every metric the parity probe compares is unaffected -- what differs is ~24 blended pixels
    // in each bottom corner. Fidelity of the client area is a hard completion condition here and
    // corner shape is not, so it is traded away explicitly rather than silently.
    const DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_DONOTROUND;
    DwmSetWindowAttribute(g_hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));

    if (!createPresenter(g_hwnd, g_client_w, g_client_h)) {
        return 1;
    }
    // Present the clip's first frame before the window is shown, so a capture that samples before
    // playback starts sees a real source frame rather than whatever the back buffer started as.
    present(first);
    g_presented.store(0);

    ShowWindow(g_hwnd, SW_SHOWNORMAL);
    UpdateWindow(g_hwnd);

    // AdjustWindowRectExForDpi was given the system DPI, which is only the window's DPI once it is
    // placed. Correct the outer size by whatever the client area came out short/long, so the client
    // rect is the frame size on any monitor scaling. Usually a no-op.
    RECT actual{};
    GetClientRect(g_hwnd, &actual);
    if (actual.right != g_client_w || actual.bottom != g_client_h) {
        RECT outer{};
        GetWindowRect(g_hwnd, &outer);
        SetWindowPos(
            g_hwnd, nullptr, 0, 0, (outer.right - outer.left) + (g_client_w - actual.right),
            (outer.bottom - outer.top) + (g_client_h - actual.bottom), SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        GetClientRect(g_hwnd, &actual);
    }
    if (actual.right != g_client_w || actual.bottom != g_client_h) {
        // Fail loudly: a client area that is not the frame size silently invalidates every pixel
        // comparison downstream.
        std::printf(
            "mimic: client area is %ldx%ld but the recording is %dx%d\n", actual.right, actual.bottom, g_client_w,
            g_client_h);
        return 1;
    }
    std::printf(
        "mimic: hwnd=%p class=%s title=%s client=%dx%d pid=%lu frames=%d record=%s%s%s\n", (void *) g_hwnd,
        g_class_name.c_str(), g_title.c_str(), g_client_w, g_client_h, GetCurrentProcessId(), g_decoder->frameCount(),
        g_record_path.string().c_str(), g_loop ? " (loop)" : "", g_control ? " (control)" : "");
    std::fflush(stdout);

    SetConsoleCtrlHandler(&consoleHandler, TRUE);
    // The stale stop-file was already cleared (or refused) at the top of run(), before anything was
    // opened -- see there.

    std::thread playback(&playbackThread);
    if (g_control) {
        std::thread(&controlThread).detach();
    }

    const auto start = Clock::now();
    MSG msg;
    while (!g_stop_requested.load() && !g_playback_done.load()) {
        while (PeekMessageA(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                g_stop_requested.store(true);
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        if (g_duration_seconds > 0 && Clock::now() - start >= std::chrono::seconds(g_duration_seconds)) {
            break;
        }
        if (!g_stop_file.empty()) {
            std::error_code ec;
            if (std::filesystem::exists(g_stop_file, ec)) {
                break;
            }
        }
        Sleep(1);
    }

    g_stop_requested.store(true);
    g_command_cv.notify_all();
    // Keep pumping while the playback thread winds down. present() used to drive the blit through a
    // cross-thread RedrawWindow(RDW_UPDATENOW), which blocks until this thread dispatches the paint;
    // going straight to join() then deadlocked the process on every stop that was not end-of-stream
    // (--duration, --stop-file, Ctrl-C, close). The swap chain removed that dependency, but the
    // pump-while-joining is kept: it is correct regardless and costs nothing.
    while (!g_playback_done.load()) {
        while (PeekMessageA(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        Sleep(1);
    }
    playback.join();

    // The swap chain holds a reference to the window, so release it before destroying the window.
    destroyPresenter();
    DestroyWindow(g_hwnd);
    g_hwnd = nullptr;
    g_decoder.reset();
    std::printf("mimic: exiting after %llu presented frame(s)\n", g_presented.load());
    return 0;
}

}  // namespace

}  // namespace uma::mimic

int main(int argc, char **argv) {
    // No logger_util::init(): its translation unit pulls in NativeApi (the Dart-facing callback sink),
    // and this fixture deliberately links neither the pipeline nor ONNX/WinRT. spdlog's default
    // stderr logger is enough for the handful of diagnostics here.
    try {
        return uma::mimic::run(argc, argv);
    } catch (const std::exception &e) {
        std::printf("mimic: %s\n", e.what());
        return 1;
    }
}

#else

int main() {
    // Win32/GDI only: this harness impersonates a Windows game window, and there is nothing to
    // impersonate anywhere else. Kept compilable so a non-Windows configure never breaks.
    return 0;
}

#endif
