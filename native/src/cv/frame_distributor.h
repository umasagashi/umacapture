#pragma once

#include <utility>

#include "chara_detail/chara_detail_scene_context.h"
#include "condition/condition.h"
#include "core/frame_flow_counters.h"
#include "cv/frame.h"
#include "util/event_util.h"

namespace uma::distributor {

class FrameDistributor {
public:
    FrameDistributor(
        const std::vector<std::shared_ptr<SceneContext>> &scene_contexts,
        const event_util::Listener<Frame> &frame_supplier)
        : scene_contexts(scene_contexts)
        , frame_supplier(frame_supplier) {
        this->frame_supplier->listen([this](const auto &image) { this->update(image); });
    }

    // Forward a frame-stall signal to every scene context. Must be invoked on the same runner thread as
    // update() (e.g. via a queued connection) so the contexts' state is touched from a single thread.
    void onIdle() {
        for (auto &context : scene_contexts) {
            context->onIdle();
        }
    }

private:
    void update(const Frame &image) {
        // HOP 1 OUT of the offline producer's brake (core/frame_flow_counters.h): this runs as the frame_captured
        // connection is dequeued on the distributor runner, so it is the exact point at which the producer's
        // queue gives a frame up. Its paired enqueue is NativeApi::updateFrame's accepted send.
        //
        // Counted HERE, and unconditionally, rather than at the far end of the fan-out. Whether any scene context
        // goes on to forward the frame to the scraper is hop 2's business and is counted separately; this hop
        // must balance for EVERY frame or the lead-in -- where nothing is ever forwarded -- would leave a residue
        // the gate could never settle. onIdle deliberately does not count: it is a signal, not a frame.
        app::frameFlowCounters().noteDequeued();
        for (auto &context : scene_contexts) {
            context->update(image);
        }
    }

    std::vector<std::shared_ptr<SceneContext>> scene_contexts;
    const event_util::Listener<Frame> frame_supplier;
};

}  // namespace uma::distributor
