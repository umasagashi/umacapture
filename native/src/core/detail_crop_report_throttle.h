#pragma once

// Rate limit for the detail-crop calibration report (messages::detailCropReported).
//
// WHY IT EXISTS
//   DetailCropTracker only suppresses UNCHANGED values, so a rect that genuinely moves pixel by pixel while
//   the dialog animates in can produce one report per frame. This is what bounds that to something a
//   settings page can render.
//
// THE ONE EXCEPTION
//   A change of `latched` is never throttled. That transition carries the final, frozen value -- the one
//   the user is actually waiting to see -- and it happens at most once per session, so dropping it to save
//   a message would trade away the only report that matters. Everything else is provisional by
//   construction: it is followed either by more measurements or by the latch.
//
// LIFETIME
//   reset() must be called at each session start. Without it the state persists across sessions, and a
//   session begun less than `interval` after the previous one silently drops its first report -- which,
//   combined with the tracker's own change-dedup, can leave the settings page showing the previous
//   session's value indefinitely.
//
// Pure and clock-injected (the caller passes `now`), so the rule above is testable without a pipeline.
// Not thread-safe: the caller drives it from the distributor thread only.

#include <chrono>

namespace uma::app {

class DetailCropReportThrottle {
public:
    using clock = std::chrono::steady_clock;

    explicit DetailCropReportThrottle(clock::duration interval)
        : interval(interval) {}

    // Whether a report carrying `latched` should be sent at `now`. Updates the internal state when it
    // returns true, so callers must send exactly when this says so.
    [[nodiscard]] bool shouldReport(bool latched, clock::time_point now) {
        if (reported && latched == last_latched && now - last_reported < interval) {
            return false;
        }
        reported = true;
        last_reported = now;
        last_latched = latched;
        return true;
    }

    // Forgets everything, so the next report passes whatever its timing and latch state. Called at session
    // start; see LIFETIME above.
    void reset() { reported = false; }

private:
    const clock::duration interval;

    // `reported` is what makes "nothing sent yet" distinct from "sent at the clock's origin", so a fresh
    // (or just-reset) throttle never depends on how far steady_clock's epoch happens to be from now.
    bool reported = false;
    clock::time_point last_reported;
    bool last_latched = false;
};

}  // namespace uma::app
