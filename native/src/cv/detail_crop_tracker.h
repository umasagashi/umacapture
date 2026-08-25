#pragma once

// Live wiring for the detail-crop auto-calibration (cv/detail_crop_calibrator.h).
//
// WHAT THIS IS
//   calibrateDetailCrop() answers "where is the game's client rect in THIS image". This class decides WHEN to
//   ask, what to do with the answer, and when to throw it away -- i.e. it is the per-frame state machine that
//   turns a stateless scan into a stable pane-mode decision shared with frame producers.
//
// THE STATE MACHINE (one step per frame, driven from CharaDetailSceneContext::update)
//   1. Consume any pending release request; a release drops both the latch and the correction.
//   2. If already latched, trust a shaping producer's frame and anchor unchanged; a producer that does no
//      pane shaping (the offline CLI paths) gets the latched pane applied here as the frame's anchor.
//   3. Otherwise evaluate both geometry-derived pane candidates against the same full frame.
//   4. Zero successful candidates -> keep the current state. Two -> warn and keep the current state.
//   5. Exactly one successful candidate -> adopt its measured rect and latch immediately.
//   6. Publish the current state for the settings UI.
//
// WHY THE LATCH IS HARD
//   The first unambiguous calibration is frozen immediately. It is not refined on later frames; recovery from
//   an outlier is an explicit release (capture start, input-size change, or settings reset).
//
// CONTRACT
//   Never throws. It refuses only a producer frame whose pane snapshot became stale before consumption; using
//   that frame would be worse than dropping it because its pixels and anchor describe different latch states.
//   The only warning is the ambiguous case where both pane candidates calibrate successfully. The report callback
//   is fired from the same per-frame step and inherits that contract: it is what the settings UI shows, so
//   a throw from it would cost a capture session a display value. The containment gate is what keeps the
//   no-throw part true: an intersection reaching outside the image would make Frame::bgrAt throw deep inside
//   the condition tree, which the runner catches and logs at error level. The debug lines are gated on a
//   STATE CHANGE (a measured crop that differs from the current one, the latch, a release) and are never
//   emitted per frame; they are the only way to tell from a log what the calibration did, which is what
//   `umacapture_cli replay --calibrate` exists to exercise.
//
// THREADING
//   beginFrame/endFrame and the accessors run on the distributor thread only, and so does the report
//   callback. setReportCallback must therefore be called once, before any frame flows. The release entry
//   points (requestRelease/noteFrameSize) are callable from any thread. They release the mutex-protected pane
//   handoff immediately and arm an atomic request flag, which the next per-frame step consumes.

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/detail_crop_calibrator.h"
#include "cv/frame.h"
#include "cv/pane_mode.h"
#include "cv/pane_mode_latch.h"
#include "types/shape.h"
#include "util/logger_util.h"

namespace uma {

// A crop as one log token. Spelled out here because Rect<int> has no fmt formatter, and because the WIDTH is
// the number that matters: it is the `unit` every normalized coordinate is scaled by.
[[nodiscard]] inline std::string describeCrop(const Rect<int> &rect) {
    return "(" + std::to_string(rect.left()) + "," + std::to_string(rect.top()) + ")-(" + std::to_string(rect.right())
        + "," + std::to_string(rect.bottom()) + ") " + std::to_string(rect.width()) + "x"
        + std::to_string(rect.height());
}

// Smallest intersection WIDTH -- the anchor `unit` -- this gate will accept.
//
// A tiny unit is not merely useless, it is unsafe. The gate below admits a rect whose right/bottom edge sits
// exactly on the frame's, which is correct for the half-open coordinate space; but a normalized probe such
// as x=0.983 then rounds ONTO that edge once the unit is small enough, and Frame::bgrAt throws. An
// exhaustive sweep over frame/rect combinations put the largest unit that can throw at exactly 29, with
// nothing at 30 or above. 64 is that bound with room to spare, and is still an order of magnitude below any
// crop a real capture produces (the recognizer's reference width alone is 540). Reachability today is
// essentially nil -- the solved scale tracks the caller's estimate within a few percent -- so this closes
// the hole structurally rather than relying on that continuing to hold.
constexpr int kMinimumCropUnit = 64;

// The containment gate: may `rect` be installed as the intersection of a frame of `size`?
//
// Mandatory, not defensive. Every coordinate the condition tree, the scraper and the recognizer evaluate is
// derived from the intersection, and one that reaches outside the image turns an ordinary probe into a
// Frame::bgrAt throw -- which the event runner reports at error level and which would abort recognition of
// the record being scraped. A degenerate (non-positive) extent is rejected for the same reason: it yields a
// zero unit size, and every normalized coordinate then collapses onto the origin; kMinimumCropUnit extends
// that same argument to the merely-tiny ones.
[[nodiscard]] inline bool isCropInsideFrame(const Rect<int> &rect, const Size<int> &size) {
    return rect.left() >= 0 && rect.top() >= 0 && rect.width() >= kMinimumCropUnit && rect.height() > 0
        && rect.right() <= size.width() && rect.bottom() <= size.height();
}

class DetailCropTracker {
public:
    // The scan is injected so the state machine can be unit-tested without a real dialog image; the default
    // is the production calibrator.
    using ScanFunction = std::function<DetailCropResult(const cv::Mat &, const Rect<int> &)>;
    using CandidateFunction = std::function<std::array<pane::PaneCandidate, 2>(const Size<int> &)>;
    // Test seam for pausing immediately after the pending-release exchange. Production callers leave it empty.
    using PostReleaseExchangeHook = std::function<void()>;

    // Reports what the calibration currently amounts to, for the settings UI: the intersection the frame
    // would have had WITHOUT any correction, the one it actually has WITH it (identical while no correction
    // is adopted), and whether the value is latched.
    //
    // Fired only when that triple CHANGES. That is the whole rate-limiting story on this side: a re-measure
    // landing on the same rect -- the common case once the scan settles -- reports nothing at all. The
    // remaining churn (a rect that genuinely moves pixel by pixel while the dialog animates in) is throttled
    // by the notifier, which knows about wire cost; this class only knows about state.
    using ReportFunction = std::function<void(const Rect<int> &default_rect, const Rect<int> &corrected, bool latched)>;

    DetailCropTracker()
        : DetailCropTracker(std::make_shared<PaneModeLatch>()) {}

    explicit DetailCropTracker(std::shared_ptr<PaneModeLatch> pane_mode_latch)
        : DetailCropTracker(
              [](const cv::Mat &image, const Rect<int> &estimate) { return calibrateDetailCrop(image, estimate); },
              std::move(pane_mode_latch)) {}

    explicit DetailCropTracker(
        ScanFunction scan,
        std::shared_ptr<PaneModeLatch> pane_mode_latch = std::make_shared<PaneModeLatch>(),
        CandidateFunction candidates = [](const Size<int> &size) { return pane::paneCandidates(size); },
        PostReleaseExchangeHook post_release_exchange_hook = {})
        : scan(std::move(scan))
        , pane_mode_latch(std::move(pane_mode_latch))
        , candidates(std::move(candidates))
        , post_release_exchange_hook(std::move(post_release_exchange_hook)) {}

    // Installs the settings-UI report sink. Call once, before frames flow (see THREADING); a null function
    // leaves reporting off, which is what every offline path (CLI, unit tests) uses.
    void setReportCallback(ReportFunction report) { report_ = std::move(report); }

    // --- Release requests (any thread) ----------------------------------------------------------------

    // Arms a release. One-way: the flag is only ever set here and cleared by the next per-frame step, so a
    // request raised while no frames are flowing simply waits for the first frame of the next session.
    // Raised at the start of a capture session, and by the settings "restore defaults" action -- which is
    // why this stays callable mid-session: releasing the latch while a session runs is exactly when a user
    // reaches for that button.
    void requestRelease() {
        // Generation change and request publication are one transition with respect to beginFrame. Without
        // this small mutex, either store order leaves a gap: the consumer can see a new empty latch with stale
        // latched_ state, or consume the request while the old shaped snapshot is still current.
        const std::lock_guard<std::mutex> lock(release_transition_mutex);
        pane_mode_latch->release();
        release_requested.store(true, std::memory_order_relaxed);
    }

    // Releases when the input geometry changes. The caller's `size` need not be the frame's own size -- it
    // only has to CHANGE when the input changes (see NativeApi::updateFrame, whose reported original size
    // means something different per producer). The first size seen is not a change.
    void noteFrameSize(const Size<int> &size) {
        const uint64_t packed = packSize(size);
        const uint64_t previous = last_frame_size.exchange(packed, std::memory_order_relaxed);
        if (previous != kUnknownSize && previous != packed) {
            requestRelease();
        }
    }

    // --- Per-frame step (distributor thread only) -----------------------------------------------------

    // Steps 1-2: consume pending releases and return the frame the condition tree should run on. Once
    // latched, the producer owns both shaping and anchoring, so its frame passes through unchanged.
    [[nodiscard]] std::optional<Frame> beginFrame(const Frame &input) {
        PaneModeLatch::Generation latch_generation;
        {
            const std::lock_guard<std::mutex> lock(release_transition_mutex);
            latch_generation = pane_mode_latch->generation();
            const bool release_consumed = release_requested.exchange(false, std::memory_order_relaxed);
            if (release_consumed) {
                if (latched_ || correction_.has_value()) {
                    log_debug("detail crop released (was latched={})", latched_);
                }
                latched_ = false;
                correction_.reset();
                correction_frame_size_.reset();
                ambiguity_warned_ = false;
                // Forget what was last reported too, so the post-release state is announced even when it
                // happens to equal the pre-release one. Without this the settings "restore defaults" action
                // could clear the Dart display and have an identical relatch deduped forever.
                last_report_.reset();
            }
            frame_latch_generation_ = latch_generation;
        }
        if (post_release_exchange_hook) {
            post_release_exchange_hook();
        }
        // Freeze the pane-latch generation captured before the pending-release exchange. requestRelease()
        // publishes its generation/flag transition under release_transition_mutex, so an earlier completed
        // request is consumed above and this full frame may recalibrate. Any later request increments beyond
        // the stored token and invalidates the completed scan; beginFrame never increments the generation.
        // The two live producers, web and Windows, resolve pane geometry and then cross a queue before their
        // frame is consumed, so the decision their pixels were shaped under can be superseded in transit.
        // Validate that exact decision HERE, after the pending-release exchange and on the distributor thread.
        // This drops null->latch, release/relatch ABA, and post-enqueue changes before a mismatched anchor
        // reaches the condition tree. Frames from producers without a selector carry no snapshot and behave as
        // before: nothing was resolved for them, so nothing about them can go stale, and their full-capture
        // pixels stay re-interpretable against whatever the latch says at this moment.
        {
            const std::lock_guard<std::mutex> lock(release_transition_mutex);
            const auto &producer_snapshot = input.paneModeSnapshot();
            if (producer_snapshot.has_value() && !pane_mode_latch->isCurrent(producer_snapshot.value())) {
                frame_latch_generation_.reset();
                return std::nullopt;
            }
        }
        // Once the producer is shaping frames, its explicit anchor is authoritative. correction_ is expressed
        // in the pre-shaping capture coordinates, so applying it to a smaller shaped frame would place the crop
        // against the wrong origin. That combination is unreachable, and by construction rather than by care:
        // a frame leaves cv/frame_shaper.h smaller than the capture only through CropPixels or CopiedRegion
        // with a pane rect, and that rect can only have come from a snapshot, which shapeCapturedFrame then
        // attaches to the frame it returns. The one hole -- CopiedRegion with a non-zero copy_origin and no
        // snapshot -- is refused there as IncompleteCapture. So "cropped" and "carries a snapshot" are the same
        // condition, and the guard below tests the snapshot rather than `latched_` alone because the snapshot
        // is the half that is actually observable on the frame.
        //
        // A producer that resolves no pane decision sends no snapshot, and both offline CLI paths are of that
        // kind on purpose (see cv/video_loader.h for the determinism constraint that forces it). Their frames
        // are always the full capture, so the latched pane has to be applied HERE, by the same re-anchor the
        // correction branch below performs, or it would never reach the pipeline on those paths at all.
        if (latched_ && input.paneModeSnapshot().has_value()) {
            return std::optional<Frame>{input};
        }
        if (!correction_.has_value() || input.empty() || !isCropInsideFrame(correction_.value(), input.size())) {
            return std::optional<Frame>{input};
        }
        return std::optional<Frame>{input.reanchored(correction_.value())};
    }

    // Steps 5-8: `frame` must be what beginFrame returned. An adopted value takes effect at the producer from
    // the next frame; this frame has already passed the producer boundary.
    //
    // Split from the state transition so every accepted frame funnels through one report. A stale producer
    // snapshot is the sole beginFrame exit without endFrame; the next accepted frame publishes any release
    // state that was consumed while rejecting it.
    void endFrame(const Frame &frame) {
        updateState(frame);
        publish(frame);
    }

    // --- Inspection (distributor thread only) ---------------------------------------------------------

    [[nodiscard]] bool latched() const { return latched_; }

    [[nodiscard]] const std::optional<Rect<int>> &correction() const { return correction_; }

private:
    void updateState(const Frame &frame) {
        const auto latch_generation = std::exchange(frame_latch_generation_, std::nullopt);
        if (!latch_generation.has_value()) {
            return;
        }
        if (latched_) {
            return;
        }
        if (frame.empty()) {
            return;
        }

        std::optional<Rect<int>> accepted;
        size_t accepted_count = 0;
        Rect<int> accepted_estimate;
        for (const auto &candidate : candidates(frame.size())) {
            const auto result = scan(frame.data(), candidate.intersection);
            if (!result.ok()) {
                continue;
            }
            // Fit-aware: toRect(frame.size()) absorbs the one row its own independent rounding can invent,
            // and nothing else, so the gate below still refuses everything it refuses today.
            const auto rect = result.calibration.toRect(frame.size());
            if (!isCropInsideFrame(rect, frame.size())) {
                continue;
            }
            accepted = rect;
            accepted_estimate = candidate.intersection;
            ++accepted_count;
        }

        if (accepted_count == 0) {
            ambiguity_warned_ = false;
            return;
        }
        if (accepted_count > 1) {
            if (!ambiguity_warned_) {
                log_warning("detail crop calibration matched both pane candidates; keeping the previous state");
                ambiguity_warned_ = true;
            }
            return;
        }
        ambiguity_warned_ = false;

        const auto &rect = accepted.value();
        if (!pane_mode_latch->latch(rect, frame.size(), latch_generation.value())) {
            return;
        }
        if (!correction_.has_value() || !(correction_.value() == rect)) {
            log_debug(
                "detail crop measured: {} (the accepted pane candidate was {})",
                describeCrop(rect),
                describeCrop(accepted_estimate));
        }
        correction_ = rect;
        correction_frame_size_ = frame.size();
        latched_ = true;
        log_debug(
            "detail crop latched: {} (the uncorrected default would be {})",
            describeCrop(rect),
            describeCrop(FrameAnchor::intersect(frame.size()).intersection()));
    }

    // Hands the current triple to the report sink, if it differs from the last one handed over. An empty
    // frame is skipped rather than reported as a degenerate 0x0 default: it carries no geometry to describe.
    void publish(const Frame &frame) {
        if (!report_ || frame.empty()) {
            return;
        }
        // correction_ is measured in the pre-shaping capture coordinates. Once the producer sends a smaller
        // shaped frame, keep both report rectangles in that original coordinate system.
        const auto report_frame_size = correction_frame_size_.value_or(frame.size());
        const auto default_rect = FrameAnchor::intersect(report_frame_size).intersection();
        const auto corrected = correction_.value_or(default_rect);
        const Report current{default_rect, corrected, latched_};
        if (last_report_.has_value() && last_report_.value() == current) {
            return;
        }
        last_report_ = current;
        report_(default_rect, corrected, latched_);
    }

    // The last triple handed to the report sink, so an unchanged one is not re-sent.
    struct Report {
        Rect<int> default_rect;
        Rect<int> corrected;
        bool latched;

        bool operator==(const Report &other) const {
            return default_rect == other.default_rect && corrected == other.corrected && latched == other.latched;
        }
    };

    // Sentinel for "no size seen yet", made unreachable by construction rather than by argument: packSize
    // always sets kObservedFlag, so no size -- including 0x0 -- can ever encode to it.
    static constexpr uint64_t kUnknownSize = 0;
    static constexpr uint64_t kObservedFlag = uint64_t{1} << 62;

    // Two extents in one 64-bit word, so the last-seen size is a single lock-free atomic instead of a pair
    // that could tear. Each extent comes from a decoded image, so it is a non-negative `int` and fits in 31
    // bits; bits 0-30 hold the height, 31-61 the width, and bit 62 is the observed flag.
    [[nodiscard]] static uint64_t packSize(const Size<int> &size) {
        const auto width = static_cast<uint64_t>(std::max(0, size.width()));
        const auto height = static_cast<uint64_t>(std::max(0, size.height()));
        return kObservedFlag | ((width & 0x7FFFFFFFu) << 31) | (height & 0x7FFFFFFFu);
    }

    const ScanFunction scan;
    const std::shared_ptr<PaneModeLatch> pane_mode_latch;
    const CandidateFunction candidates;
    const PostReleaseExchangeHook post_release_exchange_hook;
    ReportFunction report_;

    std::atomic<bool> release_requested{false};
    std::mutex release_transition_mutex;
    std::atomic<uint64_t> last_frame_size{kUnknownSize};

    std::optional<PaneModeLatch::Generation> frame_latch_generation_;
    std::optional<Rect<int>> correction_;
    std::optional<Size<int>> correction_frame_size_;
    bool latched_ = false;
    bool ambiguity_warned_ = false;
    std::optional<Report> last_report_;
};

}  // namespace uma
