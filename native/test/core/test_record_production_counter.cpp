// Contract test for the core's per-run record count (app::RecordProductionCounter).
//
// The count is what makes "the import finished" and "records were produced" two different facts: a run that
// ends with zero is reported as a failure rather than as a completion (messages::videoImportVerdictOf), so the
// value the counter holds at the end of a run is user-visible, not diagnostic. What it must get right is the
// UNIT -- one run, not one process and not one pipeline build -- because the two ways to be wrong are the two
// ways to lie: a count that survives into the next run reports another run's records, and a count cleared by a
// teardown reads as zero for every reader, all of which read after their drain barrier has joined the loop.
//
// Driven directly rather than through NativeApi, which umacapture_tests deliberately does not compile (see the
// target's comment in native/CMakeLists.txt); the counter is header-only for exactly that reason, like
// CaptureSessionPolicy and RunningPipelineIdentity next to it.

#include <doctest/doctest.h>

#include <thread>
#include <vector>

#include "core/native_api.h"

namespace uma::app {
namespace {

TEST_CASE("a fresh counter reports no records") {
    const RecordProductionCounter counter;
    CHECK(counter.count() == 0);
}

TEST_CASE("each produced record is counted once") {
    RecordProductionCounter counter;
    counter.noteProduced();
    counter.noteProduced();
    counter.noteProduced();
    CHECK(counter.count() == 3);
}

TEST_CASE("a new run starts from zero however the previous one ended") {
    // The failure this pins: an import that recognized nobody, run right after one that produced two records,
    // must report 0 and be classified as a refusal. Reading a stale 2 would present it as a clean success --
    // the exact silence the count exists to break, restored by the counter instead of by the message.
    RecordProductionCounter counter;
    counter.noteProduced();
    counter.noteProduced();
    REQUIRE(counter.count() == 2);

    counter.beginRun();
    CHECK(counter.count() == 0);
}

TEST_CASE("the count survives until the next run begins") {
    // NOT cleared by anything else, and this is load-bearing rather than incidental. Every reader reads it
    // AFTER its drain barrier has joined the event loop -- windows/runner/video_import_session.h publishes its
    // terminal message as the last statement of the run, past runUntilDrainedThenJoin and past
    // endCaptureSession -- so a counter that reset on teardown or on a session release would be read as zero
    // by every one of them, turning every import into a reported failure.
    RecordProductionCounter counter;
    counter.beginRun();
    counter.noteProduced();
    // Nothing between here and the next beginRun() may touch it: no teardown hook, no release hook.
    CHECK(counter.count() == 1);
    CHECK(counter.count() == 1);  // reading it does not consume it either
}

TEST_CASE("counting is safe across the threads that actually use it") {
    // The increment runs on the recognizer runner's thread and the read on the front end's, so the count is
    // atomic. Not a race detector -- it is a smoke test that concurrent increments do not lose one.
    RecordProductionCounter counter;
    counter.beginRun();
    std::vector<std::thread> threads;
    threads.reserve(4);
    for (int t = 0; t < 4; t++) {
        threads.emplace_back([&counter]() {
            for (int i = 0; i < 250; i++) {
                counter.noteProduced();
            }
        });
    }
    for (auto &thread : threads) {
        thread.join();
    }
    CHECK(counter.count() == 1000);
}

}  // namespace
}  // namespace uma::app
