#pragma once

#include <functional>
#include <optional>
#include <stdexcept>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/frame.h"
#include "cv/pane_mode_latch.h"
#include "types/shape.h"

namespace uma::frame_shaper {

// THE producer shaping contract, in one place.
//
// Windows live capture, the web worker, the CLI VideoLoader and the CLI FFV1 replay reader are four front ends
// over one recognition pipeline (see .claude/rules/platform-parity.md). Each of them has to obey the same rule:
//
//   A producer that crops must also construct or reanchor its Frame so the anchor identifies the latched pane
//   intersection IN THE PIXELS IT ACTUALLY SENDS. Cropping and claiming the corresponding anchor are one
//   operation.
//
// That rule used to be open-coded four times, in three different Frame factories (Frame::fixed,
// Frame::reanchored, Frame::viewPixels().clone()), and was enforced by review discipline alone. It is now this
// one function: a producer hands over the pixels it has, the pane snapshot it resolved BEFORE those pixels were
// copied, and which of the three shaping shapes applies. The anchor, the bounds check and the post-copy
// re-validation of the snapshot come back as one decision.
//
// What stays with the producer, deliberately:
//   * Acquiring the pixels, including any platform-specific copy rectangle. Only web adjusts that rectangle
//     (Gecko rejects odd-numbered crop rects); the adjustment must not change recognition geometry, which is
//     why the copy origin is an INPUT here rather than something this function may choose.
//   * Passing the PRE-CROP captured size to NativeApi::updateFrame. Passing the shaped size can release the
//     latch and make crop state oscillate, so it is never derived from the shaped frame.

// Resolves the pane rectangle and its generation for one exact captured size, atomically. Holding one of these
// (NativeApi::frameShapingSnapshot, normally) is what makes a producer a SHAPING producer: it is the only way
// to read the latch, and the snapshot it returns is what the shaped frame then carries. The two live producers
// hold one; the two offline ones deliberately hold none, because reading the latch from a thread that runs
// concurrently with the one owning it would make their output depend on scheduling (see cv/video_loader.h).
// For a producer that does hold one, the same callable is reused as `revalidate` below to re-check the
// decision after the pixel copy.
using ShapingSelector = std::function<PaneModeLatch::Snapshot(const Size<int> &)>;

enum class ShapingMode {
    // The caller holds the FULL captured frame and wants the latched pane's pixels only. This function performs
    // the copy, so the result owns its buffer independently of the caller's and is the one mode exempt from the
    // sole-ownership precondition below.
    CropPixels,
    // The caller holds the FULL captured frame and wants to keep every pixel, naming the latched pane as
    // metadata only. Used where the pixels themselves are the artifact -- FFV1 replay must re-run detection and
    // calibration over the recorded full frame -- and by `capture --record`, which tees full pixels to disk.
    AnchorOnly,
    // The caller already copied a sub-rectangle of the captured surface, starting at `copy_origin`. The pane
    // rectangle is in captured coordinates, so the local intersection is derived here rather than by the
    // producer. Windows' GPU copy and the browser's VideoFrame.copyTo both land here.
    CopiedRegion,
};

enum class ShapingStatus {
    Ok,
    // The pane decision changed between the producer resolving it and this call, i.e. across the pixel copy.
    // The pixels no longer belong to the anchor they would be given, so the frame is dropped here. The
    // consumer-side check in DetailCropTracker still covers a change that lands after this one.
    StaleSnapshot,
    // The latched pane does not lie inside the pixels the producer actually holds.
    PaneOutsideCopy,
    // A frame with no latched pane must be the whole captured surface; this one is a partial copy.
    IncompleteCapture,
};

struct ShapedFrame {
    ShapingStatus status = ShapingStatus::Ok;
    Frame frame;

    [[nodiscard]] bool ok() const { return status == ShapingStatus::Ok; }
};

inline const char *describe(const ShapingStatus status) {
    switch (status) {
        case ShapingStatus::Ok:
            return "ok";
        case ShapingStatus::StaleSnapshot:
            return "the pane snapshot changed during the pixel copy";
        case ShapingStatus::PaneOutsideCopy:
            return "the pane intersection is outside the copied frame";
        case ShapingStatus::IncompleteCapture:
            return "an unshaped frame must carry the full capture";
    }
    return "unknown frame shaping status";
}

// The origin, in captured-surface coordinates, of the pixels a CopiedRegion producer copies when it crops to
// the latched pane. Feeding the SAME value to the copy and to shapeCapturedFrame is what keeps "crop" and
// "claim the corresponding anchor" one operation instead of two that can drift.
inline Point<int> paneCopyOrigin(const PaneModeLatch::Snapshot &snapshot) {
    return snapshot.rect.has_value() ? snapshot.rect->topLeft() : Point<int>{0, 0};
}

// THE OWNERSHIP PRECONDITION, AS CODE. Two of the three shaping modes forward the caller's pixel buffer by
// shallow cv::Mat copy: the Frame that leaves here shares the caller's allocation, and NativeApi::updateFrame
// then hands that Frame down the pipeline without cloning it. Only CropPixels copies. So every non-CropPixels
// caller is asserting "nothing else will write these pixels", and until this function existed that assertion
// lived in four separate prose comments (video_loader.h, ffv1_reader.cpp, wasm_api.cpp, window_capturer.h) --
// where breaking it would have silently corrupted whichever frames a decoder overwrote, with no failing test
// and no wrong-looking code at the point of breakage.
//
// Both halves are load-bearing, and neither is redundant:
//   * `u == nullptr` is a Mat that WRAPS memory it does not own -- cv::Mat(rows, cols, type, ptr), which is
//     exactly how a decoder hands back its own internal frame buffer (window_capturer.h's `bgra_image` over the
//     D3D mapped resource is one in this repo). Such a buffer is rewritten by the producer's next frame and no
//     shallow copy downstream can stop it, because cv::Mat has no refcount to consult.
//   * `refcount == 1` says the caller's header is the only one, so no live alias exists that could write
//     through the same allocation -- e.g. a ROI view whose parent the producer keeps and reuses.
// Together they also give the SAFETY of buffer reuse, not merely its absence: for a refcounted allocation,
// cv::Mat::create reallocates instead of overwriting whenever the refcount is above one, so once a downstream
// Frame holds a reference, a producer that re-decodes into "the same" Mat gets a fresh buffer.
//
// MEASURED, 2026-08-19, cv::VideoCapture/FFMPEG backend on this machine: every frame comes back with
// u != nullptr and refcount == 1, and 40 held frames stayed byte-identical (FNV-1a over the pixels) across the
// remaining ~257 decodes of the clip. See testdata/evidence/import-perf-remeasure-2026-08-18/I1-clone-settlement.md.
[[nodiscard]] inline bool ownsPixelsSolely(const cv::Mat &image) {
    return image.u != nullptr && image.u->refcount == 1;
}

// True when `rect` is a non-degenerate rectangle wholly inside a `bounds`-sized image.
inline bool isRectInside(const Size<int> &bounds, const Rect<int> &rect) {
    return rect.left() >= 0 && rect.top() >= 0 && rect.width() > 0 && rect.height() > 0
        && rect.right() <= bounds.width() && rect.bottom() <= bounds.height();
}

// Shapes one captured image into the Frame the pipeline should receive.
//
// `image`     the pixels the producer holds. Must be a non-empty CV_8UC3 image (the producers check this while
//             acquiring it, where they can also tell an absent frame from a malformed one).
// `snapshot`  the pane decision the producer resolved BEFORE copying those pixels; nullopt for a producer that
//             does no pane shaping at all, which then gets the default aspect-ratio anchor and no snapshot.
// `mode`      which of the three shaping shapes applies; see ShapingMode.
// `copy_origin` for CopiedRegion, where `image` starts inside the captured surface. Ignored otherwise.
// `revalidate`  re-resolves the pane decision after the copy. Empty means "the producer copied nothing between
//             resolving the snapshot and this call", which must be stated where it is passed empty.
inline ShapedFrame shapeCapturedFrame(
    const cv::Mat &image,
    const uint64 timestamp,
    const std::optional<PaneModeLatch::Snapshot> &snapshot,
    const ShapingMode mode,
    const Point<int> &copy_origin = {0, 0},
    const ShapingSelector &revalidate = {}) {
    // Enforced, not documented. A violation is a producer defect and never a property of the input, so it is a
    // throw rather than a ShapingStatus: a status would be reported as "this frame was dropped", the producers
    // log that at debug level and carry on, and a whole run would come out empty with the reason buried. The
    // throw lands on an exception boundary in every front end that can reach here (the CLI's main, the Windows
    // VideoImportSession thread entry, the capture loop's catch), so it is reported, not fatal.
    if (mode != ShapingMode::CropPixels && !ownsPixelsSolely(image)) {
        throw std::runtime_error(
            "shapeCapturedFrame: this mode forwards the caller's pixel buffer by reference, but the caller does "
            "not solely own it (an unowned cv::Mat wrapper, or a live alias onto the same allocation)");
    }
    const Frame captured{image, timestamp};
    const std::optional<Rect<int>> pane = snapshot.has_value() ? snapshot->rect : std::nullopt;

    Frame shaped = captured;
    switch (mode) {
        case ShapingMode::CropPixels:
            if (pane.has_value()) {
                if (!isRectInside(captured.size(), pane.value())) {
                    return {ShapingStatus::PaneOutsideCopy, {}};
                }
                // viewPixels gives the ROI a fixed, full local anchor; clone then detaches it from the
                // caller's buffer. Downstream normalized coordinates address the shaped pane itself.
                shaped = captured.viewPixels(pane.value()).clone();
            } else {
                shaped = captured.clone();
            }
            break;
        case ShapingMode::AnchorOnly:
            if (pane.has_value()) {
                if (!isRectInside(captured.size(), pane.value())) {
                    return {ShapingStatus::PaneOutsideCopy, {}};
                }
                shaped = captured.reanchored(pane.value());
            }
            break;
        case ShapingMode::CopiedRegion:
            if (pane.has_value()) {
                // The pane is in captured coordinates and the pixels start at copy_origin, so this is the same
                // rectangle expressed locally. Deriving it here (rather than trusting a producer to subtract)
                // makes the bounds check a real invariant instead of a re-check of somebody else's arithmetic.
                const Rect<int> local{pane->topLeft() - copy_origin, pane->size()};
                if (!isRectInside(captured.size(), local)) {
                    return {ShapingStatus::PaneOutsideCopy, {}};
                }
                shaped = captured.reanchored(local);
            } else if (!(copy_origin == Point<int>{0, 0})
                       || (snapshot.has_value() && !(snapshot->captured_size == captured.size()))) {
                return {ShapingStatus::IncompleteCapture, {}};
            }
            break;
    }

    if (snapshot.has_value()) {
        if (revalidate && !(revalidate(snapshot->captured_size) == snapshot.value())) {
            return {ShapingStatus::StaleSnapshot, {}};
        }
        // Binding the token to the Frame is the correctness guard: DetailCropTracker validates it again at the
        // actual distributor-thread consumer boundary, covering a change after the check above.
        shaped = shaped.withPaneModeSnapshot(snapshot.value());
    }
    return {ShapingStatus::Ok, shaped};
}

}  // namespace uma::frame_shaper
