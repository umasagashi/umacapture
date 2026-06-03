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
            scene_end_pending_since = std::nullopt;  // A reappearance within the timeout keeps the same scene.
            if (!scene_active) {
                on_scene_begin->send({record_type.value()});
                scene_active = true;
            }
            on_scene_updated->send(input, {tab_page.value()});
        } else if (scene_active) {
            // Debounce the scene end by video time (frame timestamps), not wall-clock. A wall-clock timer
            // running on its own thread made scene closing depend on how fast frames were fed during
            // offline video replay; keying off the frame timestamp keeps this deterministic. Frame
            // timestamps track real time in live capture, so live behavior is unchanged.
            if (scene_end_timeout == chrono_util::time_unit::zero()) {
                endScene();
            } else if (!scene_end_pending_since) {
                scene_end_pending_since = input.timestamp();
            } else if (input.timestamp() - scene_end_pending_since.value() >= sceneEndTimeoutMs()) {
                endScene();
            }
        }
    }

    [[nodiscard]] bool met() const override { return met_; }

private:
    void endScene() {
        on_scene_end->send();
        scene_active = false;
        scene_end_pending_since = std::nullopt;
    }

    [[nodiscard]] uint64 sceneEndTimeoutMs() const { return static_cast<uint64>(scene_end_timeout.count()); }

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

    const chrono_util::time_unit scene_end_timeout;

    std::optional<uint64> scene_end_pending_since;
    bool scene_active = false;
    bool met_ = false;
};

}  // namespace uma::chara_detail
