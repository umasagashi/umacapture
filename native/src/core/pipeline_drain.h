#pragma once

#include <chrono>
#include <functional>
#include <thread>
#include <utility>
#include <vector>

#include "util/event_util.h"
#include "util/logger_util.h"

namespace uma::cli {

// How a wait for the pipeline to drain ended.
enum class DrainOutcome {
    // Every stage reported empty. The run produced everything it was going to.
    Drained,
    // The deadline expired first. A STAGE IS WEDGED and whatever it still held has been discarded by the join,
    // so this must reach the caller as a failure -- see runUntilDrainedThenJoin's comment on the watchdog.
    TimedOut,
};

// The end of a run, as a list of stages plus the operations that observe and stop them.
//
// The stage list is the whole point. NativeApi::isPipelineDrained answers for the runners NativeApi itself
// owns -- distributor, scraper, stitcher, recognizer -- and for nothing else. The CLI puts a runner of its OWN
// between the offline producer and NativeApi (cli.cpp's "recorder"), and a barrier that asked only the core
// would be blind to it: VideoLoader::runBatch / Ffv1Reader::run return after their last ENQUEUE onto that
// runner's queue, not after delivery, so at the moment the producer returns the core can legitimately hold
// nothing while whole frames sit one stage upstream. Joining there discards them, silently, on exactly the
// path the golden suite drives.
//
// So the stages are named in ONE place (offlineDrainBarrier) rather than assembled at each call site, and
// every operation is injected -- the same shape as CaptureSessionPolicy::start and ensureCaptureLoop in
// native_api.h -- so this barrier is unit-tested against a real event_util runner without building a
// recognition pipeline (native/test/core/test_pipeline_drain.cpp).
struct DrainBarrier {
    // Stops everything that could still ADD work to the pipeline, run ONCE before the first poll.
    //
    // A drain condition is only an answer while nothing upstream can refill it, and each path has a different
    // set of things that can. It is a required member, and required to be explicit even when it does nothing
    // (offlineDrainBarrier passes a documented no-op), for the same reason `producer_side` below is required:
    // an optional "and also stop this" is the shape of the defect this whole header exists to close.
    std::function<void()> quiesce;
    // "Does this stage hold no accepted-but-unfinished work", in PIPELINE ORDER, upstream first. Order is not
    // what makes each individual answer trustworthy (the hand-off overlap inside
    // SingleThreadMultiEventRunnerImpl is); it only rules out the reverse-scan hole, where a stage read early
    // is refilled from behind by a stage read later. See EventRunnerControllerImpl::pendingEvents.
    std::vector<std::function<bool()>> stages;
    // Whether the core event loop is still up. A loop that has already stopped can produce nothing, so the
    // wait ends immediately.
    std::function<bool()> is_running;
    // Stops everything, from the producer end down.
    std::function<void()> join;
};

// The barrier the CLI's one-shot subcommands (video/replay/stitch/recognize) end on.
//
// `producer_side` is the CLI-owned runner that carries frames from the offline producer's thread into
// NativeApi::updateFrame. It is REQUIRED rather than optional: the subcommands that send it nothing
// (stitch/recognize) pass a runner that always reads zero, which costs nothing, whereas an optional argument
// is exactly the thing the defect above was -- a stage that one call site remembered and another forgot.
//
// `Api` is a template parameter only so this header does not have to include native_api.h (and with it the
// recognition stack) to be testable; the sole production instantiation is app::NativeApi.
template<typename Api>
[[nodiscard]] inline DrainBarrier offlineDrainBarrier(Api &api, const event_util::EventRunner &producer_side) {
    return DrainBarrier{
        // Nothing to quiesce, and that is a property of these paths rather than an omission: the producer has
        // already returned before the barrier is built, and every offline path builds with video_mode = true,
        // which leaves the frame-stall watchdog unbuilt (native_api.cpp). So no wall-clock source can inject.
        []() {},
        {[producer_side]() { return producer_side->pendingEvents() == 0; },
         [&api]() { return api.isPipelineDrained(); }},
        [&api]() { return api.isRunning(); },
        // Producer end first, for the same reason the stages are read in that order: once the recorder runner
        // is joined nothing can enter the core pipeline while the core is being torn down.
        [&api, producer_side]() {
            producer_side->join();
            api.joinEventLoop();
        },
    };
}

// The barrier a LIVE capture stop ends on.
//
// Same defect, ordinary path: a user who stops capture shortly after the detail screen closes leaves a record on
// the stitcher or in the recognizer -- roughly a second of ONNX work -- and the pre-barrier stop tore the loop
// down under it. The record was refused by an already-stopping pipeline while the UI reported a clean stop, the
// same silent-success shape the video import lost its last record to.
//
// THE SEQUENCE IS THE DIFFERENCE FROM THE OFFLINE BARRIER, and it lives in `quiesce`:
//   1. `stop_producer` -- the platform frame source (the WinRT window recorder), so no new frame is captured.
//   2. join `producer_side` -- the runner carrying captured frames into NativeApi::updateFrame.
//   3. Api::stopFrameStallWatchdog -- the wall-clock injector, which is why polling is stable afterwards.
// Only then is api.isPipelineDrained() an answer rather than a momentary reading.
//
// `producer_side` is JOINED here rather than waited on, unlike the offline barrier which waits for it to reach
// zero first. That is deliberate and it is the pre-existing behaviour: its queue holds raw CAPTURED FRAMES, in
// Discard mode, from after the user pressed stop. Delivering them would keep feeding a session the user has
// ended (and could reopen a scene), and the frames a join discards keep their `pending` increment forever
// (event_util.h says so at join()), so this runner must not be a polled stage either -- it would never read
// zero again. What must survive the stop is the RECORD already handed downstream, and that is the core's count.
//
// NOT COVERED, deliberately: a stop while a chara-detail scene is still OPEN. The scene-end debounce advances on
// frame timestamps, so with the producer stopped that scene never closes and produces no record to wait for.
// Making the stop fire the stall callback instead would manufacture a record out of a half-seen screen, which is
// a different decision from "do not discard what the pipeline already has".
template<typename Api>
[[nodiscard]] inline DrainBarrier liveDrainBarrier(
    Api &api,
    const event_util::EventRunner &producer_side,
    const std::function<void()> &stop_producer) {
    return DrainBarrier{
        [&api, producer_side, stop_producer]() {
            stop_producer();
            producer_side->join();
            api.stopFrameStallWatchdog();
        },
        {[&api]() { return api.isPipelineDrained(); }},
        [&api]() { return api.isRunning(); },
        [&api]() { api.joinEventLoop(); },
    };
}

// Wait for every stage to DRAIN, then join, and report which of the two ways it ended.
//
// This is where the one-shot subcommands end, and (with liveDrainBarrier) where a live capture stop ends. In
// the offline case the producer has already returned by the time this runs --
// VideoLoader::runBatch / Ffv1Reader::run have pushed every frame, api.stitch()/api.recognize() have handed
// over every record -- so what is left is only what the chain is still carrying, and the stages answer exactly
// that (see NativeApi::isPipelineDrained for why it is the caller who owns "the producer has stopped").
//
// IT REPLACES A QUIET WINDOW, and the replacement is the point. The predecessor waited for ten seconds without
// a notify message, which is a guess in both directions: it cost every run ten seconds it did not need, and it
// was only ever *probably* long enough -- a recognize pass that went quiet for longer would have been joined
// mid-record, silently, with the record lost. The browser front end reached for the same shape of answer and
// lost the last record of every import to it. There is now one condition, in the core, that both ask.
//
// Nothing time-based can restart a drained pipeline once `quiesce` has run, and that is what makes Drained mean
// finished rather than momentarily quiet: the offline paths build with video_mode = true, which leaves the
// frame-stall watchdog unbuilt (native_api.cpp), and the live path ends the watchdog in its quiesce step.
//
// The deadline is a WATCHDOG, not the completion condition: it exists so a wedged stage ends as a loud failure
// instead of a hung process (the predecessor always terminated, and the golden harness depends on that).
// Reaching it means work was discarded, which is why it is REPORTED rather than merely logged -- the caller
// turns it into a non-zero exit, so a wedged run is distinguishable from a successful one instead of surfacing
// to the golden harness as a content diff or a missing record.json.
[[nodiscard]] inline DrainOutcome runUntilDrainedThenJoin(
    const DrainBarrier &barrier,
    const std::chrono::steady_clock::duration deadline = std::chrono::minutes(5),
    const std::chrono::milliseconds poll_interval = std::chrono::milliseconds(10)) {
    const auto drained = [&barrier]() {
        for (const auto &stage : barrier.stages) {
            if (!stage()) {
                return false;
            }
        }
        return true;
    };

    // Before the first poll, never between polls: a stage silenced halfway through the wait would make every
    // reading taken before it meaningless.
    barrier.quiesce();

    auto outcome = DrainOutcome::Drained;
    const auto started = std::chrono::steady_clock::now();
    while (barrier.is_running()) {
        if (drained()) {
            break;
        }
        if (std::chrono::steady_clock::now() - started > deadline) {
            log_error("the pipeline did not drain within the deadline; joining anyway (work may be lost)");
            outcome = DrainOutcome::TimedOut;
            break;
        }
        std::this_thread::sleep_for(poll_interval);
    }
    barrier.join();
    return outcome;
}

}  // namespace uma::cli
