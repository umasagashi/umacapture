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
        const event_util::Listener<Frame> &frame_supplier,
        const event_util::Sender<Frame> &on_no_target)
        : scene_contexts(scene_contexts)
        , on_no_target(on_no_target)
        , frame_supplier(frame_supplier) {
        this->frame_supplier->listen([this](const auto &image) { this->update(image); });
    }

private:
    void update(const Frame &image) {
        bool has_active = false;
        for (auto &context : scene_contexts) {
            context->update(image);
            if (context->met()) {
                has_active = true;
            }
        }
        if (!has_active && on_no_target) {
            on_no_target->send(image);
        }
    }

    std::vector<std::shared_ptr<SceneContext>> scene_contexts;
    const event_util::Listener<Frame> frame_supplier;
    const event_util::Sender<Frame> on_no_target;
};

}  // namespace uma::distributor
