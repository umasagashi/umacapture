#pragma once

#include <utility>

#include "chara_detail/chara_detail_scene_context.h"
#include "condition/condition.h"
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
        for (auto &context : scene_contexts) {
            context->update(image);
        }
    }

    std::vector<std::shared_ptr<SceneContext>> scene_contexts;
    const event_util::Listener<Frame> frame_supplier;
};

}  // namespace uma::distributor
