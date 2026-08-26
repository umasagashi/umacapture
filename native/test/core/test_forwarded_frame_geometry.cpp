// Contract test for the geometry the core reports about a run (app::ForwardedFrameGeometryObserver).
//
// WHAT IT IS FOR. The anchor unit of the frames that reach the scraper is the only externally visible evidence
// that the `frame_resize` band (core/pipeline_config.h) was armed and applied. It cannot be read off the
// records, and that held in both of the band's regimes: while the band still clamped this material the
// ~736 -> 720 step changed no golden at all (measured by re-deriving every golden with the band armed and with
// it absent and diffing the two sets), and now that Frame::kShrinkDeadband holds the shrink arm off until
// 1080 px the same clips reach recognition at their own 735-737 and every committed baseline is byte-identical
// again (measured 2026-08-19). So a build in which the band never armed reproduces every baseline either way,
// and no arrangement of the band is visible in the records. The integration
// manifest states the unit each case must reach recognition at, and this is the reporting mechanism that
// answer travels through, so what the observer itself must get right is asserted here rather than only end to
// end.
//
// Driven directly rather than through NativeApi, which umacapture_tests deliberately does not compile (see the
// target's comment in native/CMakeLists.txt); the observer is header-only for exactly that reason, like
// RecordProductionCounter next to it.

#include <doctest/doctest.h>

#include <thread>
#include <vector>

#include "core/native_api.h"

namespace uma::app {
namespace {

TEST_CASE("a run that forwarded nothing reports no frames, and no geometry") {
    // The distinction the `frames` field exists for: "no chara-detail scene ever committed" must not be
    // readable as "every frame measured 0 px". A consumer that only compared the bounds would take the second
    // for the first, and a case asserting a unit would pass against a run that recognized nothing at all.
    const ForwardedFrameGeometryObserver observer;
    const auto geometry = observer.snapshot();
    CHECK(geometry.frames == 0);
    CHECK(geometry.min_unit == 0);
    CHECK(geometry.max_unit == 0);
}

TEST_CASE("one forwarded frame reports its unit as both bounds") {
    ForwardedFrameGeometryObserver observer;
    observer.note(720);
    const auto geometry = observer.snapshot();
    CHECK(geometry.frames == 1);
    CHECK(geometry.min_unit == 720);
    CHECK(geometry.max_unit == 720);
}

TEST_CASE("a run held at one unit reports that unit as a degenerate range") {
    // What the shipped band produces on all of this project's material: every frame is above the band, so every
    // frame is scaled to the upper bound and min == max. That equality is what makes "the band applied" a
    // statement a manifest can pin with a single number.
    ForwardedFrameGeometryObserver observer;
    for (int i = 0; i < 100; i++) {
        observer.note(720);
    }
    const auto geometry = observer.snapshot();
    CHECK(geometry.frames == 100);
    CHECK(geometry.min_unit == 720);
    CHECK(geometry.max_unit == 720);
}

TEST_CASE("a unit that moves during the run widens the range instead of replacing it") {
    // The reason this is a range and not one number: the detail-crop calibration re-anchors the stream mid-run,
    // so the unit legitimately changes. Reporting the first or the last would be a claim about scheduling; both
    // bounds together state what happened without ordering it.
    ForwardedFrameGeometryObserver observer;
    observer.note(736);
    observer.note(720);
    observer.note(724);
    const auto geometry = observer.snapshot();
    CHECK(geometry.frames == 3);
    CHECK(geometry.min_unit == 720);
    CHECK(geometry.max_unit == 736);
}

TEST_CASE("a new run starts from nothing however the previous one ended") {
    // Hooked at the same two sites as RecordProductionCounter::beginRun. A range carried over would report a
    // geometry the run being measured never forwarded -- and would do it in the direction that hides a
    // regression, since the previous run's correct unit would still be in the range.
    ForwardedFrameGeometryObserver observer;
    observer.note(736);
    observer.note(736);
    REQUIRE(observer.snapshot().frames == 2);

    observer.beginRun();
    const auto geometry = observer.snapshot();
    CHECK(geometry.frames == 0);
    CHECK(geometry.min_unit == 0);
    CHECK(geometry.max_unit == 0);

    // And the next run's first frame establishes both bounds afresh, rather than being merged with a bound the
    // reset only appeared to clear.
    observer.note(540);
    CHECK(observer.snapshot().min_unit == 540);
    CHECK(observer.snapshot().max_unit == 540);
}

TEST_CASE("the geometry survives until the next run begins") {
    // Read AFTER the drain barrier, like the record count beside it (NativeApi::forwardedFrameGeometry says
    // so), which means nothing between the last forwarded frame and the next beginRun may clear it. A teardown
    // hook here would make every CLI run report a geometry of nothing.
    ForwardedFrameGeometryObserver observer;
    observer.beginRun();
    observer.note(720);
    CHECK(observer.snapshot().frames == 1);
    CHECK(observer.snapshot().frames == 1);  // reading it does not consume it either
}

TEST_CASE("observing is safe across the threads that actually use it") {
    // The note runs on the scraper runner's thread and the snapshot on the front end's. Not a race detector --
    // a smoke test that concurrent notes lose no frame and that the bounds still cover every value seen.
    ForwardedFrameGeometryObserver observer;
    observer.beginRun();
    std::vector<std::thread> threads;
    threads.reserve(4);
    for (int t = 0; t < 4; t++) {
        threads.emplace_back([&observer, t]() {
            for (int i = 0; i < 250; i++) {
                observer.note(700 + t);
            }
        });
    }
    for (auto &thread : threads) {
        thread.join();
    }
    const auto geometry = observer.snapshot();
    CHECK(geometry.frames == 1000);
    CHECK(geometry.min_unit == 700);
    CHECK(geometry.max_unit == 703);
}

}  // namespace
}  // namespace uma::app
