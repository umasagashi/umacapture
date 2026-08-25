// Unit tests for the thread-safe pane rectangle handoff shared by the tracker and frame producers.

#include <doctest/doctest.h>

#include <atomic>
#include <thread>

#include "cv/pane_mode_latch.h"

namespace uma {
namespace {

const Size<int> kCaptured{640, 480};
const Rect<int> kRect{{10, 20}, Point<int>{210, 375}};
const Rect<int> kReplacement{{300, 40}, Point<int>{500, 395}};

TEST_CASE("an empty latch has no rectangle") {
    const PaneModeLatch latch;
    CHECK_FALSE(latch.rectFor(kCaptured).has_value());
}

TEST_CASE("a latched rectangle is returned only for its captured size") {
    PaneModeLatch latch;
    REQUIRE(latch.latch(kRect, kCaptured, latch.generation()));

    CHECK(latch.rectFor(kCaptured) == std::optional<Rect<int>>{kRect});
    CHECK_FALSE(latch.rectFor({641, 480}).has_value());
    CHECK_FALSE(latch.rectFor({640, 481}).has_value());
}

TEST_CASE("a null snapshot becomes stale when a pane is latched in the same generation") {
    PaneModeLatch latch;
    const auto empty = latch.snapshotFor(kCaptured);
    CHECK(empty.captured_size == kCaptured);
    CHECK(empty.generation == latch.generation());
    CHECK_FALSE(empty.rect.has_value());
    CHECK(latch.isCurrent(empty));

    REQUIRE(latch.latch(kRect, kCaptured, empty.generation));

    CHECK_FALSE(latch.isCurrent(empty));
    const auto current = latch.snapshotFor(kCaptured);
    CHECK(current.rect == std::optional<Rect<int>>{kRect});
    CHECK(latch.isCurrent(current));
}

TEST_CASE("a snapshot detects a same-generation pane replacement") {
    PaneModeLatch latch;
    REQUIRE(latch.latch(kRect, kCaptured, latch.generation()));
    const auto first = latch.snapshotFor(kCaptured);

    REQUIRE(latch.latch(kReplacement, kCaptured, first.generation));

    CHECK_FALSE(latch.isCurrent(first));
    const auto replacement = latch.snapshotFor(kCaptured);
    CHECK(replacement.generation == first.generation);
    CHECK(replacement.rect == std::optional<Rect<int>>{kReplacement});
    CHECK(latch.isCurrent(replacement));
}

TEST_CASE("a release and identical relatch cannot revive an old snapshot token") {
    PaneModeLatch latch;
    REQUIRE(latch.latch(kRect, kCaptured, latch.generation()));
    const auto before_release = latch.snapshotFor(kCaptured);

    latch.release();
    REQUIRE(latch.latch(kRect, kCaptured, latch.generation()));

    CHECK_FALSE(latch.isCurrent(before_release));
    const auto after_relatch = latch.snapshotFor(kCaptured);
    CHECK(after_relatch.generation != before_release.generation);
    CHECK(after_relatch.rect == before_release.rect);
    CHECK(latch.isCurrent(after_relatch));
}

TEST_CASE("a later latch atomically replaces both rectangle and captured size") {
    PaneModeLatch latch;
    REQUIRE(latch.latch(kRect, kCaptured, latch.generation()));
    REQUIRE(latch.latch(kReplacement, {800, 600}, latch.generation()));

    CHECK_FALSE(latch.rectFor(kCaptured).has_value());
    CHECK(latch.rectFor({800, 600}) == std::optional<Rect<int>>{kReplacement});
}

TEST_CASE("release is immediate and idempotent") {
    PaneModeLatch latch;
    REQUIRE(latch.latch(kRect, kCaptured, latch.generation()));

    latch.release();
    latch.release();

    CHECK_FALSE(latch.rectFor(kCaptured).has_value());
}

TEST_CASE("a generation captured before release cannot relatch") {
    PaneModeLatch latch;
    const auto stale_generation = latch.generation();

    latch.release();

    CHECK_FALSE(latch.latch(kRect, kCaptured, stale_generation));
    CHECK_FALSE(latch.rectFor(kCaptured).has_value());
}

TEST_CASE("concurrent producer reads and distributor updates remain coherent") {
    PaneModeLatch latch;
    std::atomic<bool> start{false};
    std::atomic<bool> invalid{false};

    std::thread writer([&] {
        while (!start.load(std::memory_order_acquire)) {
        }
        for (int i = 0; i < 2000; ++i) {
            (void) latch.latch(kRect, kCaptured, latch.generation());
            latch.release();
        }
    });
    std::thread reader([&] {
        start.store(true, std::memory_order_release);
        for (int i = 0; i < 2000; ++i) {
            const auto rect = latch.rectFor(kCaptured);
            if (rect.has_value() && !(rect.value() == kRect)) {
                invalid.store(true, std::memory_order_relaxed);
            }
        }
    });

    writer.join();
    reader.join();
    CHECK_FALSE(invalid.load(std::memory_order_relaxed));
}

}  // namespace
}  // namespace uma
