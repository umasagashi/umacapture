#pragma once

#include <atomic>
#include <cstdint>

#ifdef __EMSCRIPTEN__
#include <climits>

#include <emscripten/threading.h>
#endif

namespace uma::app {

// THE PRODUCER-SIDE BRAKE for an offline frame source, in the one form a browser can read.
//
// Why it exists at all. On Emscripten the video-mode frame queue is QueueLimitMode::NoLimit -- it never blocks
// and never drops -- because Block deadlocks against the MEMFS proxy queue on the module's host thread (the
// rationale is written out at native_api.cpp's startPipeline). NoLimit is only safe while SOMETHING ELSE stops
// the producer from outrunning the pipeline, and on web that something has to be the JS side: it is the only
// party that can pause a decode loop. These two counters are what it reads. The queue mode and this brake are
// one decision, not two, and neither may exist without the other.
//
// WHAT THE DIFFERENCE MEANS: the number of frames RESIDENT IN THE FRAME PATH -- the depth of the distributor's
// queue PLUS the depth of the scraper's. Not "the scraper's backlog". A pushed frame crosses two queued hops
// before anything can free its pixels:
//
//   producer --[frame_captured, distributor runner]--> FrameDistributor --[chara_detail_updated, scraper
//   runner]--> the scraper
//
// and BOTH hold whole decoded frames alive. An earlier draft of this pair counted the second hop alone, which
// left the first one unmeasured: through the entire lead-in -- menus, loading, every frame before a chara-detail
// scene commits -- nothing is ever forwarded to the scraper, so the figure sat at exactly 0 while a hardware
// decoder piled multi-megabyte frames onto the distributor's queue against a 4 GB wasm32 heap. The same hole
// reopens mid-scene whenever the distributor, not the scraper, is the slower stage.
//
// HOW ONE PAIR HONESTLY COVERS TWO HOPS. Each hop is counted at BOTH of its own ends -- enqueue and dequeue --
// into the same pair, so what accumulates is the sum of the two depths rather than a hop-to-hop difference:
//
//   noteEnqueued   NativeApi::updateFrame, when on_frame_captured accepted the send      (hop 1 in)
//   noteDequeued   FrameDistributor::update, i.e. the distributor runner dequeued it     (hop 1 out)
//   noteEnqueued   CharaDetailSceneContext, when the scraper connection accepted it      (hop 2 in)
//   noteDequeued   the chara_detail_updated listener, on the scraper thread              (hop 2 out)
//
// A frame that the distributor decides NOT to forward -- the lead-in case -- is counted in and out on hop 1 and
// never enters hop 2, so it leaves no residue. That is precisely what a naive "count the producer, discount the
// scraper" pair could not do, and why counting the producer alone was rejected: it would have inflated the
// figure permanently and parked the gate on a backlog that does not exist. Sum-of-depths OVER-states relative to
// "the deepest single queue", and over-stating is the safe direction: it parks a frame early rather than late.
//
// TWO INVARIANTS make each hop's pair balance:
//   1. Only an ACCEPTED enqueue is counted. Live capture runs both frame-path connections in Discard mode, so a
//      full queue drops the send -- and the paired dequeue can never fire for a frame that was never enqueued.
//      Counting it would ratchet the depth up by one per drop, permanently, until the gate refused every frame.
//   2. The pair is RESET at every teardown (NativeApi::teardownLocked, after the runners are joined). A
//      session's connections are destroyed with whatever is still queued on them, and those frames' dequeue
//      never runs, so the residue would otherwise accumulate across sessions until the gate parked forever.
//      Doing it in teardownLocked rather than in the web stop() export is the fix generalized: every path that
//      destroys a pipeline resets, on every platform, instead of only the one export that remembered to.
//
// NOT #ifdef'd to Emscripten, unlike the hooks this replaces. A hook only web compiles is a hook no native test
// can ever cover, and that is exactly how the previous pair ended up deleted for having "no reader anywhere".
// The cost on desktop is two relaxed-ish atomic increments per hop per frame at ~30 fps, which is nothing.
//
// int32 and 4-byte alignment are not decoration: the JS side builds an Int32Array view over the module's heap at
// these addresses and runs Atomics.load / Atomics.waitAsync against them, and neither is legal on any other
// width or alignment.
class FrameFlowCounters {
public:
    // A frame entered one of the two frame-path queues. Call ONLY when that queue accepted the send.
    void noteEnqueued() { enqueued_.fetch_add(1, std::memory_order_release); }

    // A frame left one of the two frame-path queues, on that queue's runner thread.
    //
    // The wake is part of the decrementing half rather than a separate call a site could forget: the JS gate
    // parks on this address with Atomics.waitAsync, so a dequeue that did not wake it is a stall the gate cannot
    // distinguish from a genuinely full pipeline. (The gate also passes a timeout, so a missing wake would
    // degrade to polling rather than hang -- which is precisely why it would go unnoticed.)
    void noteDequeued() {
        dequeued_.fetch_add(1, std::memory_order_release);
        wakeWaiters();
    }

    // Frames resident in the frame path: the distributor queue's depth plus the scraper queue's.
    //
    // `dequeued` is read FIRST on purpose. Between the two loads the other threads only ever increase both, so
    // reading dequeued first can only OVER-state the figure, and over-stating makes the brake park a frame too
    // early. Reading enqueued first would under-state it and let a frame through that should have waited, which
    // is the direction that grows memory.
    [[nodiscard]] int32_t inFlight() const {
        const auto dequeued = dequeued_.load(std::memory_order_acquire);
        const auto enqueued = enqueued_.load(std::memory_order_acquire);
        return enqueued - dequeued;
    }

    // Both counters back to zero. Only safe once every pipeline thread that can touch them is joined; see
    // invariant 2 above for the call site and why it is there rather than in a front end.
    //
    // WAKES THE WAITERS, exactly as noteDequeued does, and for a reason the timeout must not be asked to cover:
    // a teardown is the one event that empties the pipeline WITHOUT a dequeue, so a gate parked at the limit
    // when a session ends has nothing else coming. Leaving it to the gate's 30 ms waitAsync timeout would make
    // that timeout the mechanism rather than the safety net the worker comment calls it. The store is not
    // enough on its own: waitAsync parks on a notify, not on the cell's value changing.
    void reset() {
        enqueued_.store(0, std::memory_order_release);
        dequeued_.store(0, std::memory_order_release);
        wakeWaiters();
    }

    // Byte offsets into the module's linear memory, for a JS caller to build its Int32Array views from. Distinct
    // and 4-aligned by construction; a test asserts both, because a shared layout that silently overlapped would
    // make the difference read as a constant zero and the brake as a no-op.
    [[nodiscard]] uintptr_t enqueuedAddress() const { return reinterpret_cast<uintptr_t>(&enqueued_); }
    [[nodiscard]] uintptr_t dequeuedAddress() const { return reinterpret_cast<uintptr_t>(&dequeued_); }

private:
    // The one place that names the address JS parks on, so the two sites that must wake it cannot name different
    // ones. A no-op off Emscripten, where nobody waits on these cells.
    void wakeWaiters() {
#ifdef __EMSCRIPTEN__
        emscripten_futex_wake(&dequeued_, INT_MAX);
#else
        // Nothing waits on a native build; the counters are read directly by tests and by nothing else.
#endif
    }

    alignas(4) std::atomic<int32_t> enqueued_{0};
    alignas(4) std::atomic<int32_t> dequeued_{0};
};

// The process-lifetime pair the pipeline writes and the front end reads.
//
// A free singleton rather than a NativeApi member, for one structural reason: two of the four call sites are
// inside the recognition pipeline -- CharaDetailSceneContext and FrameDistributor -- which are constructed with
// the connections they send on and deliberately know nothing about NativeApi. The pair this replaces solved that
// by declaring a function from `uma::wasm` inside chara_detail_scene_context.cpp -- i.e. the recognition core
// reaching up into the web front end -- which is both a layering inversion and the reason the hook could not be
// tested. Its lifetime matches what it describes: the counters outlive any single pipeline, exactly as the
// addresses handed to JS must.
inline FrameFlowCounters &frameFlowCounters() {
    static FrameFlowCounters counters;
    return counters;
}

}  // namespace uma::app
