#pragma once

#include "chara_detail/chara_detail_record.h"
#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/rule.h"
#include "cv/frame.h"
#include "cv/scene_context.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/stds.h"

namespace uma::chara_detail {

using TabCondition = condition::ParallelCondition<Frame, rule::LogicalOr>;

enum TabPage {
    SkillPage = 0,
    FactorPage,
    CampaignPage,
};

struct SceneInfo {
    record::RecordType record_type;
};

struct SceneState {
    TabPage tab_page;
};

class CharaDetailSceneContext : public distributor::SceneContext {
public:
    CharaDetailSceneContext(
        const std::shared_ptr<condition::Condition<Frame>> &child,
        const event_util::Sender<SceneInfo> &on_scene_begin,
        const event_util::Sender<Frame, SceneState> &on_scene_updated,
        const event_util::Sender<> &on_scene_end,
        const chrono_util::time_unit &scene_end_timeout)
        : child(child)
        , tab_page_condition(dynamic_cast<const TabCondition *>(child->findByTag("tab_page")))
        , record_type_condition(dynamic_cast<const TabCondition *>(child->findByTag("record_type")))
        , on_scene_begin(on_scene_begin)
        , on_scene_updated(on_scene_updated)
        , on_scene_end(on_scene_end)
        , scene_end_timeout(scene_end_timeout) {
        if (tab_page_condition == nullptr) {
            throw std::runtime_error("tab_page condition not found");
        }
        if (record_type_condition == nullptr) {
            throw std::runtime_error("record_type condition not found");
        }
    }

    void update(const Frame &input) override {
        child->update(input);
        const auto tab_page = getActiveTabIndex();
        const auto record_type = getRecordType();
        met_ = child->met() && tab_page.has_value() && record_type.has_value();

        if (met_) {
            const auto canceled = cancelSceneEndTimer();
            if (!previous_condition && !canceled) {  // When end is canceled, no need to call begin either.
                on_scene_begin->send({record_type.value()});
            }
            on_scene_updated->send(input, { tab_page.value()});
        } else if (previous_condition) {
            if (scene_end_timeout == chrono_util::time_unit::zero()) {
                on_scene_end->send();
            } else {
                startSceneEndTimer();
            }
        }

        previous_condition = met_;
    }

    [[nodiscard]] bool met() const override { return met_; }

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
        scene_end_timer = std::make_unique<thread_util::Timer>(scene_end_timeout, [this]() { on_scene_end->send(); });
    }

    template<typename T>
    [[nodiscard]] std::optional<T> getActiveIndexAs(const TabCondition *cond) const {
        const auto states = cond->metDetail();
        const auto active = stds::find(states, true);
        if (active == states.end()) {
            return std::nullopt;
        }
        return static_cast<T>(std::distance(states.begin(), active));
    }

    [[nodiscard]] std::optional<TabPage> getActiveTabIndex() const {
        return getActiveIndexAs<TabPage>(tab_page_condition);
    }

    [[nodiscard]] std::optional<record::RecordType> getRecordType() const {
        return getActiveIndexAs<record::RecordType>(record_type_condition);
    }

    const std::shared_ptr<condition::Condition<Frame>> child;
    const condition::ParallelCondition<Frame, rule::LogicalOr> *tab_page_condition;
    const condition::ParallelCondition<Frame, rule::LogicalOr> *record_type_condition;
    const event_util::Sender<SceneInfo> on_scene_begin;
    const event_util::Sender<Frame, SceneState> on_scene_updated;
    const event_util::Sender<> on_scene_end;

    std::unique_ptr<thread_util::Timer> scene_end_timer;
    const chrono_util::time_unit scene_end_timeout;

    bool previous_condition = false;
    bool met_ = false;
};

}  // namespace uma::chara_detail
