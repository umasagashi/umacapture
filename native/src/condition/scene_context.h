#ifndef NATIVE_SCENE_CONTEXT_H
#define NATIVE_SCENE_CONTEXT_H

#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/rule.h"
#include "cv/frame.h"
#include "util/eventpp_util.h"
#include "util/json_utils.h"
#include "util/stds.h"

enum TabPage {
    SkillPage,
    FactorPage,
    CampaignPage,
};

struct SceneInfo {
    TabPage tab_page;

    SceneInfo(int tab_page)  // NOLINT(google-explicit-constructor)
        : tab_page(static_cast<TabPage>(tab_page)) {}
};

namespace {

using TabCondition = condition::ParallelCondition<Frame, rule::LogicalOr>;

}

class SceneContext : public condition::Condition<Frame> {
public:
    SceneContext(
        std::shared_ptr<condition::Condition<Frame>> child,
        connection::Sender<Frame, SceneInfo> on_scene_begin,
        connection::Sender<Frame, SceneInfo> on_scene_updated,
        connection::Sender<> on_scene_end,
        const std::chrono::milliseconds &scene_end_timeout = std::chrono::milliseconds::zero())
        : child(std::move(child))
        , tab_condition(dynamic_cast<const TabCondition *>(child->getByName("tab_condition")))
        , on_scene_begin(std::move(on_scene_begin))
        , on_scene_updated(std::move(on_scene_updated))
        , on_scene_end(std::move(on_scene_end))
        , scene_end_timeout(scene_end_timeout) {
        if (tab_condition == nullptr) {
            throw std::runtime_error("tab_condition not found");
        }
    }

    void update(const Frame &input) override {
        child->update(input);
        const auto tab_index = getActiveTabIndex();
        met_ = child->met() && tab_index.has_value();

        if (current_timer) {
            current_timer->cancel();
            current_timer = nullptr;
        }

        if (met_ && !previous_condition) {
            on_scene_begin->send(input, {tab_index.value()});
        } else if (met_ && previous_condition) {
            on_scene_updated->send(input, {tab_index.value()});
        } else if (!met_ && previous_condition) {
            if (scene_end_timeout == std::chrono::milliseconds::zero()) {
                on_scene_end->send();
            } else {
                current_timer =
                    std::make_unique<threading::Timer>(scene_end_timeout, [this]() { this->on_scene_end->send(); });
            }
        }

        previous_condition = met_;
    }

    [[nodiscard]] bool met() const override { return met_; }

private:
    [[nodiscard]] std::optional<int> getActiveTabIndex() const {
        const auto tab_states = tab_condition->metDetail();
        const auto active = stds::find(tab_states, true);
        if (active == tab_states.end()) {
            return std::nullopt;
        } else {
            return static_cast<int>(std::distance(tab_states.begin(), active));
        }
    }

    const std::shared_ptr<condition::Condition<Frame>> child;
    const condition::ParallelCondition<Frame, rule::LogicalOr> *tab_condition;
    const connection::Sender<Frame, SceneInfo> on_scene_begin;
    const connection::Sender<Frame, SceneInfo> on_scene_updated;
    const connection::Sender<> on_scene_end;

    std::unique_ptr<threading::Timer> current_timer;
    const std::chrono::milliseconds scene_end_timeout;

    bool previous_condition = false;
    bool met_ = false;
};

#endif  //NATIVE_SCENE_CONTEXT_H
