#pragma once

#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/rule.h"
#include "cv/frame.h"
#include "util/eventpp_util.h"
#include "util/json_utils.h"
#include "util/stds.h"

namespace {

using TabCondition = condition::ParallelCondition<Frame, rule::LogicalOr>;

}

namespace chara_detail {

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

class CharaDetailSceneContext {
public:
    CharaDetailSceneContext(
        const std::shared_ptr<condition::Condition<Frame>> &child,
        const connection::Sender<> &on_scene_begin,
        const connection::Sender<Frame, SceneInfo> &on_scene_updated,
        const connection::Sender<> &on_scene_end,
        const std::chrono::milliseconds &scene_end_timeout = std::chrono::milliseconds::zero())
        : child(child)
        , tab_condition(dynamic_cast<const TabCondition *>(child->findByTag("tab_condition")))
        , on_scene_begin(on_scene_begin)
        , on_scene_updated(on_scene_updated)
        , on_scene_end(on_scene_end)
        , scene_end_timeout(scene_end_timeout) {
        if (tab_condition == nullptr) {
            throw std::runtime_error("tab_condition not found");
        }
    }

    void update(const Frame &input) {
        child->update(input);
        const auto tab_index = getActiveTabIndex();
        met_ = child->met() && tab_index.has_value();

        if (met_) {
            const auto canceled = cancelSceneEndTimer();
            if (!previous_condition && !canceled) {  // When end is canceled, no need to call begin either.
                on_scene_begin->send();
            }
            on_scene_updated->send(input, {tab_index.value()});
        } else if (previous_condition) {
            if (scene_end_timeout == std::chrono::milliseconds::zero()) {
                on_scene_end->send();
            } else {
                startSceneEndTimer();
            }
        }

        previous_condition = met_;
    }

    [[nodiscard]] bool met() const { return met_; }

private:
    bool cancelSceneEndTimer() {
        if (scene_end_timer) {
            scene_end_timer->cancel();
            const auto expired = scene_end_timer->hasExpired();
            scene_end_timer = nullptr;
            return expired.has_value() && !expired.value();
        }
        return false;
    }

    void startSceneEndTimer() {
        cancelSceneEndTimer();
        scene_end_timer = std::make_unique<threading::Timer>(scene_end_timeout, [this]() { on_scene_end->send(); });
    }

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
    const connection::Sender<> on_scene_begin;
    const connection::Sender<Frame, SceneInfo> on_scene_updated;
    const connection::Sender<> on_scene_end;

    std::unique_ptr<threading::Timer> scene_end_timer;
    const std::chrono::milliseconds scene_end_timeout;

    bool previous_condition = false;
    bool met_ = false;
};

}  // namespace chara_detail
