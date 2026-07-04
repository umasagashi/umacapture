#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <functional>
#include <thread>

#include "util/logger_util.h"
#include "util/thread_util.h"

namespace uma::distributor {

// Fires a callback once the live frame stream stops delivering frames for longer than the timeout.
//
// The scene-end debounce in CharaDetailSceneContext advances on frame timestamps, so it can only close a
// scene while frames keep arriving. If the frame source stalls outright -- the captured window is closed
// or minimized -- a scene opened in live capture would otherwise stay open forever. This watchdog supplies
// that missing "frames stopped" signal so the scene can be closed.
//
// It measures elapsed real time with steady_clock, so it must run in LIVE capture only. In video replay
// frames are fed in bursts as fast as the pipeline drains them, and a wall-clock gap between bursts is not
// a real stall; gating the watchdog to live mode keeps offline replay deterministic.
class FrameStallWatchdog : public thread_util::ThreadBase {
public:
    FrameStallWatchdog(const std::chrono::milliseconds &timeout, const std::function<void()> &on_stalled)
        : timeout(timeout)
        , poll_interval(std::min(timeout, std::chrono::milliseconds(100)))
        , on_stalled(on_stalled)
        , last_frame(std::chrono::steady_clock::now()) {}

    ~FrameStallWatchdog() override { join(); }

    // Re-baseline the last-frame timestamp before launching the poll thread. The watchdog is constructed
    // during pipeline startup but started only after every runner spins up; a slow cold start (loading ONNX
    // models) between construction and here could otherwise exceed the timeout and fire a spurious stall
    // before the first real frame arrives. Hides ThreadBase::start() (called on the concrete type).
    void start() {
        last_frame.store(std::chrono::steady_clock::now(), std::memory_order_relaxed);
        thread_util::ThreadBase::start();
    }

    // Called from the capture thread for every delivered frame.
    void notifyFrame() { last_frame.store(std::chrono::steady_clock::now(), std::memory_order_relaxed); }

protected:
    void run() override {
        while (isRunning()) {
            std::this_thread::sleep_for(poll_interval);
            if (!isRunning()) {
                break;
            }
            const auto elapsed = std::chrono::steady_clock::now() - last_frame.load(std::memory_order_relaxed);
            if (elapsed >= timeout) {
                // Fire once per stall; rearm only after frames resume, so the callback is not spammed every poll.
                if (!stalled) {
                    stalled = true;
                    // The callback must not escape this worker thread, or it would terminate the process.
                    try {
                        on_stalled();
                    } catch (const std::exception &e) {
                        log_error("frame stall watchdog callback threw: {}", e.what());
                    } catch (...) {
                        log_error("frame stall watchdog callback threw an unknown exception");
                    }
                }
            } else {
                stalled = false;
            }
        }
    }

private:
    const std::chrono::milliseconds timeout;
    const std::chrono::milliseconds poll_interval;
    const std::function<void()> on_stalled;
    std::atomic<std::chrono::steady_clock::time_point> last_frame;
    bool stalled = false;
};

}  // namespace uma::distributor
