// Contract test for NativeApi's producer-facing pane-shaping lookup.

#include <doctest/doctest.h>

#include <limits>
#include <memory>
#include <optional>
#include <utility>

#include "core/frame_shaping.h"
#include "core/native_api.h"
#include "cv/pane_mode_latch.h"
#include "types/shape.h"

namespace uma::app {

struct NativeApiFrameShapingTestAccess {
    static std::unique_ptr<NativeApi> create(const std::shared_ptr<PaneModeLatch> &pane_mode_latch) {
        return std::unique_ptr<NativeApi>(new NativeApi(pane_mode_latch));
    }
};

namespace {

TEST_CASE("the NativeApi frame-shaping lookup is captured-size scoped") {
    const auto latch = std::make_shared<PaneModeLatch>();
    const auto api = NativeApiFrameShapingTestAccess::create(latch);
    const NativeApi &const_api = *api;
    const Size<int> captured_size{640, 480};
    const Rect<int> pane_rect{{10, 20}, Point<int>{210, 375}};

    CHECK_FALSE(const_api.frameShapingRect(captured_size).has_value());
    REQUIRE(latch->latch(pane_rect, captured_size, latch->generation()));
    CHECK(const_api.frameShapingRect(captured_size) == std::optional<Rect<int>>{pane_rect});
    CHECK_FALSE(const_api.frameShapingRect({641, 480}).has_value());
}

TEST_CASE("the NativeApi frame-shaping snapshot detects changes across producer work") {
    const auto latch = std::make_shared<PaneModeLatch>();
    const auto api = NativeApiFrameShapingTestAccess::create(latch);
    const NativeApi &const_api = *api;
    const Size<int> captured_size{640, 480};
    const Rect<int> pane_rect{{10, 20}, Point<int>{210, 375}};

    const auto empty = const_api.frameShapingSnapshot(captured_size);
    CHECK(const_api.isFrameShapingSnapshotCurrent(empty));

    REQUIRE(latch->latch(pane_rect, captured_size, empty.generation));
    CHECK_FALSE(const_api.isFrameShapingSnapshotCurrent(empty));

    const auto latched = const_api.frameShapingSnapshot(captured_size);
    CHECK(latched.rect == std::optional<Rect<int>>{pane_rect});
    CHECK(const_api.isFrameShapingSnapshotCurrent(latched));

    latch->release();
    CHECK_FALSE(const_api.isFrameShapingSnapshotCurrent(latched));
}

TEST_CASE("pane generations round-trip losslessly through the canonical JavaScript string wire format") {
    constexpr PaneModeLatch::Generation above_js_safe_integer = 9007199254740993ULL;
    const auto encoded = frame_shaping::encodeGeneration(above_js_safe_integer);
    CHECK(encoded == "9007199254740993");
    CHECK(frame_shaping::decodeGeneration(encoded) == std::optional<PaneModeLatch::Generation>{above_js_safe_integer});

    const auto maximum = std::numeric_limits<PaneModeLatch::Generation>::max();
    CHECK(frame_shaping::decodeGeneration(frame_shaping::encodeGeneration(maximum))
          == std::optional<PaneModeLatch::Generation>{maximum});
    CHECK_FALSE(frame_shaping::decodeGeneration("+1").has_value());
    CHECK_FALSE(frame_shaping::decodeGeneration("01").has_value());
    CHECK_FALSE(frame_shaping::decodeGeneration(" 1").has_value());
    CHECK_FALSE(frame_shaping::decodeGeneration("-1").has_value());
}

// The aliases std::stoull accepts but the wire format must not, split by which guard rejects them.
TEST_CASE("decodeGeneration rejects every non-canonical form std::stoull would otherwise accept") {
    SUBCASE("leading whitespace: consumed reaches the end, only the round trip rejects it") {
        CHECK_FALSE(frame_shaping::decodeGeneration(" 12").has_value());
        CHECK_FALSE(frame_shaping::decodeGeneration("\t12").has_value());
    }
    SUBCASE("sign: stoull wraps -1 to ULLONG_MAX and consumes the whole string") {
        CHECK_FALSE(frame_shaping::decodeGeneration("-1").has_value());
        CHECK_FALSE(frame_shaping::decodeGeneration("-0").has_value());
    }
    SUBCASE("trailing garbage: stoull stops early, so consumed already rejects it") {
        CHECK_FALSE(frame_shaping::decodeGeneration("12abc").has_value());
        CHECK_FALSE(frame_shaping::decodeGeneration("12 ").has_value());
    }
    SUBCASE("not a number at all") {
        CHECK_FALSE(frame_shaping::decodeGeneration("").has_value());
        CHECK_FALSE(frame_shaping::decodeGeneration("abc").has_value());
    }
}

// The even-alignment geometry below used to live in web/frame_shaping.mjs with its own Node harness
// (tool/test_web_frame_shaping.mjs). These cases are that harness's exhaustive sweep, re-expressed against the
// core implementation the browser now calls through wasm, so one wire contract has one test suite.

TEST_CASE("outward even alignment contains the entire pane target") {
    const auto aligned = frame_shaping::outwardEvenCropRect({{1, 3}, Size<int>{5, 7}}, {20, 20});
    REQUIRE(aligned.has_value());
    CHECK(aligned.value() == Rect<int>{{0, 2}, Size<int>{6, 8}});
}

TEST_CASE("outward even alignment preserves its invariants for every small valid rectangle") {
    for (int captured_width = 1; captured_width <= 8; captured_width++) {
        for (int captured_height = 1; captured_height <= 8; captured_height++) {
            const Size<int> captured{captured_width, captured_height};
            for (int x = 0; x < captured_width; x++) {
                for (int y = 0; y < captured_height; y++) {
                    for (int width = 1; width <= captured_width - x; width++) {
                        for (int height = 1; height <= captured_height - y; height++) {
                            const Rect<int> pane{{x, y}, Size<int>{width, height}};
                            const auto aligned = frame_shaping::outwardEvenCropRect(pane, captured);
                            if (!aligned.has_value()) {
                                // The only admissible reason to refuse: the outward expansion would leave the
                                // captured bounds. Anything else would be a silently dropped pane.
                                const int expanded_right = (x + width + 1) & ~1;
                                const int expanded_bottom = (y + height + 1) & ~1;
                                REQUIRE((expanded_right > captured_width || expanded_bottom > captured_height));
                                continue;
                            }
                            const auto &rect = aligned.value();
                            CHECK(rect.left() % 2 == 0);
                            CHECK(rect.top() % 2 == 0);
                            CHECK(rect.width() % 2 == 0);
                            CHECK(rect.height() % 2 == 0);
                            // Contains the pane...
                            CHECK(rect.left() <= x);
                            CHECK(rect.top() <= y);
                            CHECK(rect.right() >= x + width);
                            CHECK(rect.bottom() >= y + height);
                            // ...and never leaves the captured surface.
                            CHECK(rect.right() <= captured_width);
                            CHECK(rect.bottom() <= captured_height);
                        }
                    }
                }
            }
        }
    }
}

TEST_CASE("outward even alignment rejects malformed and out-of-bounds rectangles") {
    const Size<int> captured{10, 10};
    CHECK_FALSE(frame_shaping::outwardEvenCropRect({{-1, 0}, Size<int>{2, 2}}, captured).has_value());
    CHECK_FALSE(frame_shaping::outwardEvenCropRect({{0, -1}, Size<int>{2, 2}}, captured).has_value());
    CHECK_FALSE(frame_shaping::outwardEvenCropRect({{0, 0}, Size<int>{0, 2}}, captured).has_value());
    CHECK_FALSE(frame_shaping::outwardEvenCropRect({{0, 0}, Size<int>{2, 0}}, captured).has_value());
    CHECK_FALSE(frame_shaping::outwardEvenCropRect({{9, 0}, Size<int>{2, 2}}, captured).has_value());
    CHECK_FALSE(frame_shaping::outwardEvenCropRect({{0, 9}, Size<int>{2, 2}}, captured).has_value());
}

TEST_CASE("an odd unlatched capture stays full-size and asks for no copy rectangle at all") {
    const auto plan = frame_shaping::paneCopyPlan(std::nullopt, {673, 1217});
    CHECK_FALSE(plan.copy_rect.has_value());
    CHECK(plan.out_size == Size<int>{673, 1217});
    CHECK(plan.origin == Point<int>{0, 0});
    CHECK_FALSE(plan.pane_anchor.has_value());
}

TEST_CASE("an uncontainable even expansion falls back to full pixels with the pane anchor unmoved") {
    const Rect<int> pane{{1, 2}, Size<int>{672, 20}};
    const auto plan = frame_shaping::paneCopyPlan(pane, {673, 101});
    CHECK_FALSE(plan.copy_rect.has_value());
    CHECK(plan.out_size == Size<int>{673, 101});
    CHECK(plan.origin == Point<int>{0, 0});
    // Full-frame pixels: the anchor is the pane exactly as captured, because nothing was cropped away.
    REQUIRE(plan.pane_anchor.has_value());
    CHECK(plan.pane_anchor.value() == pane);
}

TEST_CASE("a contained aligned copy translates the pane into copied-frame local coordinates") {
    const auto plan = frame_shaping::paneCopyPlan(Rect<int>{{11, 21}, Size<int>{7, 9}}, {100, 100});
    REQUIRE(plan.copy_rect.has_value());
    CHECK(plan.copy_rect.value() == Rect<int>{{10, 20}, Size<int>{8, 10}});
    CHECK(plan.out_size == Size<int>{8, 10});
    CHECK(plan.origin == Point<int>{10, 20});
    REQUIRE(plan.pane_anchor.has_value());
    CHECK(plan.pane_anchor.value() == Rect<int>{{1, 1}, Size<int>{7, 9}});
}

// The property the browser's copy actually depends on: whatever rectangle the plan asks for, the anchor it
// hands back addresses the same pixels the pane does, and lies inside the copied buffer.
TEST_CASE("the plan's anchor identifies the pane inside the pixels the plan asks for") {
    for (int captured_width = 1; captured_width <= 12; captured_width++) {
        for (int captured_height = 1; captured_height <= 12; captured_height++) {
            const Size<int> captured{captured_width, captured_height};
            for (int x = 0; x < captured_width; x++) {
                for (int y = 0; y < captured_height; y++) {
                    for (int width = 1; width <= captured_width - x; width++) {
                        for (int height = 1; height <= captured_height - y; height++) {
                            const Rect<int> pane{{x, y}, Size<int>{width, height}};
                            const auto plan = frame_shaping::paneCopyPlan(pane, captured);
                            REQUIRE(plan.pane_anchor.has_value());
                            const auto &anchor = plan.pane_anchor.value();
                            // The anchor is the pane, expressed from the copied origin.
                            CHECK(anchor.left() == pane.left() - plan.origin.x());
                            CHECK(anchor.top() == pane.top() - plan.origin.y());
                            CHECK(anchor.size() == pane.size());
                            // ...and it fits inside the buffer the producer is told to allocate.
                            CHECK(anchor.left() >= 0);
                            CHECK(anchor.top() >= 0);
                            CHECK(anchor.right() <= plan.out_size.width());
                            CHECK(anchor.bottom() <= plan.out_size.height());
                            if (plan.copy_rect.has_value()) {
                                CHECK(plan.copy_rect->size() == plan.out_size);
                                CHECK(plan.copy_rect->topLeft() == plan.origin);
                            } else {
                                // The fallback copies everything, so nothing may be offset.
                                CHECK(plan.out_size == captured);
                                CHECK(plan.origin == Point<int>{0, 0});
                            }
                        }
                    }
                }
            }
        }
    }
}

TEST_CASE("the snapshot overload plans for the size the snapshot was taken with") {
    const auto latch = std::make_shared<PaneModeLatch>();
    const Size<int> captured_size{640, 480};
    const Rect<int> pane_rect{{11, 21}, Size<int>{7, 9}};
    REQUIRE(latch->latch(pane_rect, captured_size, latch->generation()));

    const auto plan = frame_shaping::paneCopyPlan(latch->snapshotFor(captured_size));
    REQUIRE(plan.copy_rect.has_value());
    CHECK(plan.copy_rect.value() == Rect<int>{{10, 20}, Size<int>{8, 10}});

    // A different captured size sees no pane at all, so the plan is the full-frame one.
    const auto other = frame_shaping::paneCopyPlan(latch->snapshotFor({641, 480}));
    CHECK_FALSE(other.copy_rect.has_value());
    CHECK(other.out_size == Size<int>{641, 480});
    CHECK_FALSE(other.pane_anchor.has_value());
}

}  // namespace
}  // namespace uma::app
