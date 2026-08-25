#pragma once

#include <cstddef>
#include <exception>
#include <optional>
#include <string>

#include "cv/pane_mode_latch.h"
#include "types/shape.h"

namespace uma::app::frame_shaping {

// Pane generations cross JavaScript as canonical decimal strings. A JS Number would lose distinctions above
// 2^53; keeping the encoder/decoder pure makes the entire uint64 wire contract testable outside Emscripten.
[[nodiscard]] inline std::string encodeGeneration(const PaneModeLatch::Generation generation) {
    return std::to_string(generation);
}

[[nodiscard]] inline std::optional<PaneModeLatch::Generation> decodeGeneration(const std::string &encoded) {
    if (encoded.empty()) {
        return std::nullopt;
    }
    PaneModeLatch::Generation generation;
    size_t consumed = 0;
    try {
        generation = std::stoull(encoded, &consumed);
    } catch (const std::exception &) {
        return std::nullopt;
    }
    // The round-trip comparison is the load-bearing guard: re-encoding the parsed value and demanding the
    // exact original string admits only the canonical decimal form, so every alias std::stoull would
    // otherwise accept is rejected there -- leading whitespace (" 12"), signs ("+1", and "-1", which stoull
    // wraps to ULLONG_MAX), and leading zeros ("012"). None of those reach the `consumed` check: stoull
    // consumes the whole string in each case, so `consumed == encoded.size()` still holds. `consumed`
    // covers the one remaining shape, trailing garbage ("12abc"), where stoull stops early -- the round
    // trip rejects that too, so this check is a cheap, explicit statement of intent rather than the gate.
    // The wire format accepts no alias: doing so would weaken the claim that JS transports one exact,
    // lossless token.
    if (consumed != encoded.size() || encodeGeneration(generation) != encoded) {
        return std::nullopt;
    }
    return generation;
}

// GECKO-ONLY PIXEL ALIGNMENT. This is the one place the shaping geometry deliberately diverges per producer
// (.claude/rules/platform-parity.md), so the constraint that forces it is written here, at the divergence
// itself. It lives in the shared core -- not in web/frame_shaping.mjs, where it used to -- because the core is
// what the browser compiles to wasm: one implementation, one test suite, and the constraint is visible to
// every reader of the shaping path rather than to JavaScript readers alone.
//
// THE PLATFORM CONSTRAINT: VideoFrame.copyTo verifies the requested rect's offset against the frame's chroma
// sample size BEFORE converting anything to RGBA, so on a chroma-subsampled format -- I420 / NV12, which is what
// a getDisplayMedia surface actually hands out -- an odd `x` or `y` is rejected outright. Gecko is the strict
// engine here and throws from copyTo on an element-derived frame ("VideoFrame's image format is unrecognized"
// was observed once during the design measurements). There is no per-frame recovery from it: the pane rect does
// not move between frames, so an odd rect fails identically on every frame and the session produces nothing.
// The Windows recorder (BitBlt into a BGRA buffer) and the CLI (cv::Mat ROI) copy the pixels themselves and are
// subject to no such rule, which is why the alignment exists on the browser's copy rectangle alone -- it shapes
// what the browser is ASKED to copy, never what the recognizer is told it is looking at.
//
// THE CONTAINMENT + FALLBACK RULE: expand OUTWARD only. The even rectangle must CONTAIN the latched pane rect --
// never shrink it, which would quietly change what the recognizer sees -- and must stay inside the captured
// bounds. When no rectangle satisfies both (a pane rect flush against an odd right/bottom edge), return nullopt;
// paneCopyPlan then asks for the FULL frame with no rect at all, which is the shape web's rgbaCopyOptions
// records Gecko accepting. Browser-only alignment must not change recognition geometry, and it does not: on both
// paths the plan carries the EXACT pane intersection across as the Frame anchor, expressed relative to the
// origin that is actually copied (FrameCopyPlan::pane_anchor).
[[nodiscard]] inline std::optional<Rect<int>> outwardEvenCropRect(const Rect<int> &pane, const Size<int> &captured) {
    if (pane.left() < 0 || pane.top() < 0 || pane.width() <= 0 || pane.height() <= 0 || pane.right() > captured.width()
        || pane.bottom() > captured.height()) {
        return std::nullopt;
    }
    const int left = pane.left() & ~1;
    const int top = pane.top() & ~1;
    const int right = (pane.right() + 1) & ~1;
    const int bottom = (pane.bottom() + 1) & ~1;
    if (right > captured.width() || bottom > captured.height()) {
        return std::nullopt;
    }
    return Rect<int>{Point<int>{left, top}, Point<int>{right, bottom}};
}

// What a producer that copies a sub-rectangle of the captured surface must copy, and the anchor that belongs to
// those exact pixels. Deriving both together is what keeps "crop" and "claim the corresponding anchor" one
// operation (see cv/frame_shaper.h); a producer that follows the plan cannot disagree with the anchor.
struct FrameCopyPlan {
    // nullopt means "copy the whole captured surface, with no rectangle at all". Omitting the rectangle is
    // semantically different from spelling an odd full-frame one: Gecko accepts the former for subsampled
    // inputs and can reject the latter before converting to RGBA.
    std::optional<Rect<int>> copy_rect;
    // Dimensions of the buffer the producer must copy into (== copy_rect's size, or the full captured size).
    Size<int> out_size;
    // Where the copied pixels start inside the captured surface. Feed this to frame_shaper::shapeCapturedFrame.
    Point<int> origin;
    // The latched pane, expressed LOCAL to the copied pixels; nullopt when nothing is latched.
    std::optional<Rect<int>> pane_anchor;
};

[[nodiscard]] inline FrameCopyPlan paneCopyPlan(const std::optional<Rect<int>> &pane, const Size<int> &captured) {
    const std::optional<Rect<int>> copy_rect =
        pane.has_value() ? outwardEvenCropRect(pane.value(), captured) : std::nullopt;
    const Point<int> origin = copy_rect.has_value() ? copy_rect->topLeft() : Point<int>{0, 0};
    const Size<int> out_size = copy_rect.has_value() ? copy_rect->size() : captured;
    std::optional<Rect<int>> pane_anchor;
    if (pane.has_value()) {
        pane_anchor = Rect<int>{pane->topLeft() - origin, pane->size()};
    }
    return {copy_rect, out_size, origin, pane_anchor};
}

[[nodiscard]] inline FrameCopyPlan paneCopyPlan(const PaneModeLatch::Snapshot &snapshot) {
    return paneCopyPlan(snapshot.rect, snapshot.captured_size);
}

}  // namespace uma::app::frame_shaping
