// Unit tests for the shared producer shaping contract (cv/frame_shaper.h). The FIVE capture producers --
// Windows live capture, the web worker's live path, the CLI VideoLoader, FFV1 replay and the web video import
// (pushOfflineFrame in native/wasm/wasm_api.cpp) -- all funnel through shapeCapturedFrame, so the rules
// verified here are the rules every producer obeys. The count matters: .claude/rules/platform-parity.md
// enumerates the same five, and a header that leaves the web import out invites the reading that it sits
// outside this shared seam and may grow a shaping step of its own -- the one thing that file forbids, and the
// one producer no golden case can catch it in.

#include <doctest/doctest.h>
#include <nameof/nameof.hpp>

#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "cv/frame_shaper.h"

namespace uma::frame_shaper {
namespace {

const Size<int> kCaptured{40, 24};
const Rect<int> kPane{{7, 2}, Size<int>{20, 20}};

cv::Mat makeImage(const Size<int> &size, const uchar seed = 0) {
    cv::Mat image(size.height(), size.width(), CV_8UC3);
    for (int y = 0; y < size.height(); ++y) {
        for (int x = 0; x < size.width(); ++x) {
            image.at<cv::Vec3b>(y, x) = cv::Vec3b(
                static_cast<uchar>((x * 7 + seed) % 256),
                static_cast<uchar>((y * 13 + seed) % 256),
                static_cast<uchar>(((x + y) * 5 + seed) % 256));
        }
    }
    return image;
}

PaneModeLatch::Snapshot snapshotOf(const std::optional<Rect<int>> &rect, const PaneModeLatch::Generation gen = 0) {
    return {kCaptured, gen, rect};
}

// A selector that always agrees with the snapshot it is given -- the "nothing changed during the copy" case.
ShapingSelector stable(const std::optional<Rect<int>> &rect, const PaneModeLatch::Generation gen = 0) {
    return [rect, gen](const Size<int> &size) { return PaneModeLatch::Snapshot{size, gen, rect}; };
}

TEST_CASE("a producer without a pane decision keeps the aspect-ratio anchor and carries no snapshot") {
    for (const auto mode : {ShapingMode::CropPixels, ShapingMode::AnchorOnly, ShapingMode::CopiedRegion}) {
        const auto shaped = shapeCapturedFrame(makeImage(kCaptured), 11, std::nullopt, mode);
        REQUIRE(shaped.ok());
        CHECK(shaped.frame.size() == kCaptured);
        CHECK(shaped.frame.timestamp() == 11);
        CHECK_FALSE(shaped.frame.paneModeSnapshot().has_value());
        CHECK(shaped.frame.anchor().intersection() == FrameAnchor::intersect(kCaptured).intersection());
    }
}

TEST_CASE("an unlatched snapshot keeps the full frame in every mode and still carries the token") {
    for (const auto mode : {ShapingMode::CropPixels, ShapingMode::AnchorOnly, ShapingMode::CopiedRegion}) {
        const auto shaped = shapeCapturedFrame(
            makeImage(kCaptured), 3, snapshotOf(std::nullopt), mode, {0, 0}, stable(std::nullopt));
        REQUIRE(shaped.ok());
        CHECK(shaped.frame.size() == kCaptured);
        REQUIRE(shaped.frame.paneModeSnapshot().has_value());
        CHECK_FALSE(shaped.frame.paneModeSnapshot()->rect.has_value());
    }
}

TEST_CASE("CropPixels copies the latched pane and gives it a full local anchor") {
    const auto image = makeImage(kCaptured, 5);
    const auto shaped =
        shapeCapturedFrame(image, 7, snapshotOf(kPane), ShapingMode::CropPixels, {0, 0}, stable(kPane));
    REQUIRE(shaped.ok());
    CHECK(shaped.frame.size() == kPane.size());
    CHECK(shaped.frame.anchor().intersection() == Rect<int>{{0, 0}, kPane.size()});
    REQUIRE(shaped.frame.paneModeSnapshot().has_value());
    CHECK(shaped.frame.paneModeSnapshot()->rect == std::optional<Rect<int>>{kPane});

    // The pixels are the pane's, and they are an independently owned buffer: overwriting the source (which a
    // decoder does for the next frame) must not reach the shaped frame.
    const auto expected = image(cv::Rect(kPane.left(), kPane.top(), kPane.width(), kPane.height())).clone();
    CHECK(shaped.frame.data().data != image.data);
    cv::Mat diff;
    cv::absdiff(shaped.frame.data(), expected, diff);
    CHECK(cv::countNonZero(diff.reshape(1)) == 0);
}

TEST_CASE("AnchorOnly keeps every pixel and names the pane as metadata") {
    const auto image = makeImage(kCaptured, 9);
    const auto shaped =
        shapeCapturedFrame(image, 13, snapshotOf(kPane), ShapingMode::AnchorOnly, {0, 0}, stable(kPane));
    REQUIRE(shaped.ok());
    CHECK(shaped.frame.size() == kCaptured);
    CHECK(shaped.frame.anchor().intersection() == kPane);
    REQUIRE(shaped.frame.paneModeSnapshot().has_value());
    CHECK(shaped.frame.paneModeSnapshot()->rect == std::optional<Rect<int>>{kPane});
}

TEST_CASE("CopiedRegion re-expresses the captured pane in the copied pixels' coordinates") {
    // The producer copied a 30x22 region starting at (4, 1); the pane sits at (7, 2) in captured coordinates,
    // so its local place is (3, 1).
    const Point<int> origin{4, 1};
    const auto shaped = shapeCapturedFrame(
        makeImage({30, 22}), 17, snapshotOf(kPane), ShapingMode::CopiedRegion, origin, stable(kPane));
    REQUIRE(shaped.ok());
    CHECK(shaped.frame.size() == Size<int>{30, 22});
    CHECK(shaped.frame.anchor().intersection() == Rect<int>{{3, 1}, kPane.size()});
    REQUIRE(shaped.frame.paneModeSnapshot().has_value());
    CHECK(shaped.frame.paneModeSnapshot()->rect == std::optional<Rect<int>>{kPane});
}

TEST_CASE("CopiedRegion with the pane exactly copied yields a full local anchor") {
    // What Windows live capture does: the GPU copy is narrowed to the pane, so the copy origin is the pane's
    // own top-left and the local intersection covers the whole copied image.
    const auto snapshot = snapshotOf(kPane);
    const auto origin = paneCopyOrigin(snapshot);
    CHECK(origin == kPane.topLeft());
    const auto shaped = shapeCapturedFrame(
        makeImage(kPane.size()), 19, snapshot, ShapingMode::CopiedRegion, origin, stable(kPane));
    REQUIRE(shaped.ok());
    CHECK(shaped.frame.size() == kPane.size());
    CHECK(shaped.frame.anchor().intersection() == Rect<int>{{0, 0}, kPane.size()});
}

TEST_CASE("paneCopyOrigin is the frame origin when nothing is latched") {
    CHECK(paneCopyOrigin(snapshotOf(std::nullopt)) == Point<int>{0, 0});
}

TEST_CASE("a pane outside the pixels the producer holds is rejected, not anchored") {
    const Rect<int> outside{{30, 2}, Size<int>{20, 20}};  // right() == 50 > 40
    for (const auto mode : {ShapingMode::CropPixels, ShapingMode::AnchorOnly}) {
        const auto shaped =
            shapeCapturedFrame(makeImage(kCaptured), 1, snapshotOf(outside), mode, {0, 0}, stable(outside));
        CHECK(shaped.status == ShapingStatus::PaneOutsideCopy);
    }
    // CopiedRegion: the pane is inside the captured surface but not inside the smaller copy.
    const auto shaped = shapeCapturedFrame(
        makeImage({10, 10}), 1, snapshotOf(kPane), ShapingMode::CopiedRegion, {0, 0}, stable(kPane));
    CHECK(shaped.status == ShapingStatus::PaneOutsideCopy);
}

TEST_CASE("a degenerate pane is rejected in every mode") {
    const Rect<int> empty{{5, 5}, Size<int>{0, 4}};
    for (const auto mode : {ShapingMode::CropPixels, ShapingMode::AnchorOnly, ShapingMode::CopiedRegion}) {
        const auto shaped =
            shapeCapturedFrame(makeImage(kCaptured), 1, snapshotOf(empty), mode, {0, 0}, stable(empty));
        CHECK(shaped.status == ShapingStatus::PaneOutsideCopy);
    }
}

TEST_CASE("an unshaped CopiedRegion frame must be the whole captured surface") {
    // A partial copy with no latched pane: the pipeline would receive fewer pixels than the size reported to
    // updateFrame, so it is refused rather than silently mis-anchored.
    const auto offset = shapeCapturedFrame(
        makeImage(kCaptured), 1, snapshotOf(std::nullopt), ShapingMode::CopiedRegion, {2, 0}, stable(std::nullopt));
    CHECK(offset.status == ShapingStatus::IncompleteCapture);

    const auto smaller = shapeCapturedFrame(
        makeImage({30, 24}), 1, snapshotOf(std::nullopt), ShapingMode::CopiedRegion, {0, 0}, stable(std::nullopt));
    CHECK(smaller.status == ShapingStatus::IncompleteCapture);
}

TEST_CASE("a pane decision that changed during the copy drops the frame in every mode") {
    for (const auto mode : {ShapingMode::CropPixels, ShapingMode::AnchorOnly, ShapingMode::CopiedRegion}) {
        // Same rectangle, later generation: a release/relatch of an identical pane must still be caught.
        const auto relatched = shapeCapturedFrame(
            makeImage(kCaptured), 1, snapshotOf(kPane, 4), mode, {0, 0}, stable(kPane, 5));
        CHECK(relatched.status == ShapingStatus::StaleSnapshot);

        // Released outright.
        const auto released = shapeCapturedFrame(
            makeImage(kCaptured), 1, snapshotOf(kPane, 4), mode, {0, 0}, stable(std::nullopt, 4));
        CHECK(released.status == ShapingStatus::StaleSnapshot);
    }
}

TEST_CASE("the re-validation is skipped when the producer supplies no selector") {
    const auto shaped = shapeCapturedFrame(makeImage(kCaptured), 1, snapshotOf(kPane), ShapingMode::AnchorOnly);
    REQUIRE(shaped.ok());
    CHECK(shaped.frame.anchor().intersection() == kPane);
}

TEST_CASE("ownsPixelsSolely separates a buffer safe to forward from one that is not") {
    const cv::Mat owned = makeImage(kCaptured);
    CHECK(ownsPixelsSolely(owned));

    // A Mat over memory it does not own -- how a decoder hands back its own internal frame buffer.
    std::vector<uchar> external(static_cast<size_t>(kCaptured.width() * kCaptured.height() * 3), 0);
    const cv::Mat wrapped(kCaptured.height(), kCaptured.width(), CV_8UC3, external.data());
    REQUIRE(wrapped.u == nullptr);
    CHECK_FALSE(ownsPixelsSolely(wrapped));

    // A live alias onto the same allocation.
    const cv::Mat alias = owned;
    CHECK_FALSE(ownsPixelsSolely(owned));

    // A ROI whose parent is still alive.
    const cv::Mat parent = makeImage(kCaptured);
    const cv::Mat roi = parent(cv::Rect(2, 2, 8, 8));
    CHECK_FALSE(ownsPixelsSolely(roi));
}

TEST_CASE("a mode that forwards the caller's buffer refuses one the caller does not solely own") {
    std::vector<uchar> external(static_cast<size_t>(kCaptured.width() * kCaptured.height() * 3), 0);
    const cv::Mat wrapped(kCaptured.height(), kCaptured.width(), CV_8UC3, external.data());
    const cv::Mat owned = makeImage(kCaptured);
    const cv::Mat alias = owned;

    for (const auto mode : {ShapingMode::AnchorOnly, ShapingMode::CopiedRegion}) {
        CHECK_THROWS_AS(shapeCapturedFrame(wrapped, 1, std::nullopt, mode), std::runtime_error);
        CHECK_THROWS_AS(shapeCapturedFrame(owned, 1, std::nullopt, mode), std::runtime_error);
    }
    // CropPixels copies, so aliasing cannot reach the pipeline through it and it stays exempt.
    CHECK_NOTHROW(shapeCapturedFrame(wrapped, 1, std::nullopt, ShapingMode::CropPixels));
    CHECK_NOTHROW(shapeCapturedFrame(owned, 1, std::nullopt, ShapingMode::CropPixels));
}

TEST_CASE("AnchorOnly forwards the caller's pixels while CropPixels detaches from them") {
    const cv::Mat image = makeImage(kCaptured);
    const auto forwarded = shapeCapturedFrame(image, 1, std::nullopt, ShapingMode::AnchorOnly);
    REQUIRE(forwarded.ok());
    // The point of the mode: no full-frame copy. VideoLoader relies on this (cv/video_loader.h).
    CHECK(forwarded.frame.data().data == image.data);

    const auto copied = shapeCapturedFrame(image, 1, std::nullopt, ShapingMode::CropPixels);
    REQUIRE(copied.ok());
    CHECK(copied.frame.data().data != image.data);
    // ... and the two carry the same pixels, which is why swapping one for the other cannot move a record.
    CHECK(cv::countNonZero(cv::Mat(forwarded.frame.data().reshape(1) != copied.frame.data().reshape(1))) == 0);
}

TEST_CASE("every status has a distinct description") {
    // THE STATUS SET IS DISCOVERED, NOT LISTED. This case used to compare two hand-picked pairs out of the six
    // a four-value enum has, so `Ok` and `PaneOutsideCopy` could have carried the same sentence and it stayed
    // green -- and, worse, a FIFTH status added without a `case` in describe() changed nothing here at all.
    // That last one is the failure describe()'s own comment says it exists to prevent, and the compiler does
    // not cover it either: MSVC's missing-enumerator warnings (C4061/C4062) are off by default and this build
    // enables neither them nor /W4, so a switch that has grown a hole compiles clean (measured, not assumed).
    //
    // nameof scans the enum's value range and returns an empty name for anything that is not an enumerator, so
    // the loop below walks exactly the statuses that exist at compile time. Adding one is enough to put it in
    // this test; forgetting its sentence is what turns the test red.
    std::vector<ShapingStatus> statuses;
    for (int value = 0; value <= 64; ++value) {
        const auto status = static_cast<ShapingStatus>(value);
        if (!nameof::nameof_enum(status).empty()) {
            statuses.push_back(status);
        }
    }
    REQUIRE(statuses.size() >= 4);  // the four the file documents; more is fine, fewer means the scan broke

    const std::string fallback = describe(static_cast<ShapingStatus>(1000));
    CHECK(fallback == "unknown frame shaping status");  // the sentence a caller shows when a case is missing

    for (size_t a = 0; a < statuses.size(); ++a) {
        CAPTURE(nameof::nameof_enum(statuses[a]));
        // A status without its own `case` falls through to the fallback -- which is the "reason-less refusal"
        // the Windows video import would then put in front of the user.
        CHECK(std::string(describe(statuses[a])) != fallback);
        for (size_t b = a + 1; b < statuses.size(); ++b) {
            CAPTURE(nameof::nameof_enum(statuses[b]));
            CHECK(std::string(describe(statuses[a])) != describe(statuses[b]));
        }
    }
}

}  // namespace
}  // namespace uma::frame_shaper
