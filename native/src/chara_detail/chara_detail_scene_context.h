#pragma once

#include <array>

#include "chara_detail/chara_detail_record.h"
#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/rule.h"
#include "cv/frame.h"
#include "cv/scene_context.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/misc.h"
#include "util/stds.h"

namespace uma::chara_detail {

using TabCondition = condition::ParallelCondition<Frame, rule::LogicalOr>;

enum TabPage {
    SkillPage = 0,
    FactorPage,
    CampaignPage,
};

// Stable tag for each tab-page branch, mirroring record::recordTypeTag. The builder names each branch
// with this tag and the scene context resolves the active tab by tag, not by position. The default-less
// switch plus /we4062 (see native/CMakeLists.txt) makes a new TabPage that forgets a case here a
// compile error.
[[nodiscard]] inline std::string tabPageTag(TabPage page) {
    switch (page) {
        case SkillPage: return "tab_page.SkillPage";
        case FactorPage: return "tab_page.FactorPage";
        case CampaignPage: return "tab_page.CampaignPage";
    }
    return "";  // out-of-range fallback; also silences C4715 (not all paths return a value)
}

inline constexpr std::array<TabPage, 3> kAllTabPages{
    SkillPage,
    FactorPage,
    CampaignPage,
};

struct SceneInfo {
    record::RecordType record_type;
};

struct SceneState {
    TabPage tab_page;
    record::RecordType record_type;
};

class CharaDetailSceneContext : public distributor::SceneContext {
public:
    CharaDetailSceneContext(
        const std::shared_ptr<condition::Condition<Frame>> &child,
        const event_util::Sender<SceneInfo> &on_scene_begin,
        const event_util::Sender<Frame, SceneState> &on_scene_updated,
        const event_util::Sender<> &on_scene_end,
        const chrono_util::time_unit &scene_begin_timeout,
        const chrono_util::time_unit &scene_end_timeout);

    void update(const Frame &input) override;

    [[nodiscard]] bool met() const override;

    // The live frame stream stalled. The frame-timestamp scene-end debounce cannot advance without frames, so
    // close an already-committed scene here; a scene still in the begin debounce never committed, so just drop
    // its pending window. Invoked on the distributor runner thread, the same thread as update().
    void onIdle() override;

private:
    // Commit the scene only once the same record_type has stayed met for the begin timeout. The record_type is
    // locked here for the whole scene, so a transient first-match during the opening animation must not win — it
    // has to persist. Keyed off frame timestamps for replay-deterministic timing, mirroring the scene-end
    // debounce. A zero timeout commits on the first met frame (legacy behavior).
    void beginSceneWhenStable(const Frame &input, record::RecordType record_type);

    void beginScene(record::RecordType record_type);

    void endScene();

    [[nodiscard]] uint64 sceneBeginTimeoutMs() const;

    [[nodiscard]] uint64 sceneEndTimeoutMs() const;

    // Bind each enum value to its named branch in `cond` once, at construction. Resolving by tag (not by
    // child position) means reordering the branch list cannot silently remap a value, and a missing or
    // misnamed branch throws here instead of misclassifying at runtime. The branch count is checked too,
    // so a stray extra branch is caught as well.
    template<typename Enum, size_t N, typename TagFn>
    [[nodiscard]] std::array<const condition::Condition<Frame> *, N>
    resolveBranches(const TabCondition *cond, const std::array<Enum, N> &values, TagFn tag) const {
        if (cond->metDetail().size() != N) {
            throw std::runtime_error("condition branch count does not match the enum");
        }
        std::array<const condition::Condition<Frame> *, N> branches{};
        for (size_t i = 0; i < N; ++i) {
            branches[i] = cond->findByTag(tag(values[i]));
            if (branches[i] == nullptr) {
                throw std::runtime_error("condition branch not found: " + tag(values[i]));
            }
        }
        return branches;
    }

    // Resolve the active enum by testing each named branch's met() in enum-value order. That order IS the
    // documented tie-breaker: when overlapping branches could both match (e.g. InheritanceOnly vs
    // FriendInheritance, which share the (not friendLayout) and (inheritanceSignal) prefix and are told
    // apart by mutually exclusive owner markers), the earlier enum value wins. A simultaneous match beyond
    // that overlap means a discrimination assumption broke; surface it in Debug, keep first-match in Release.
    template<typename Enum, size_t N>
    [[nodiscard]] std::optional<Enum> firstMet(
        const std::array<const condition::Condition<Frame> *, N> &branches,
        const std::array<Enum, N> &values) const {
        std::optional<Enum> found;
        for (size_t i = 0; i < N; ++i) {
            if (branches[i]->met()) {
                if (!found.has_value()) {
                    found = values[i];
                } else {
                    // A simultaneous match beyond the documented enum-order overlap means a discrimination
                    // assumption broke. Keep first-match, but surface it once in release logs (not only in a
                    // Debug assert) so the breakage is observable in the field.
                    if (!simultaneous_match_warned_) {
                        simultaneous_match_warned_ = true;
                        log_warning(
                            "firstMet: multiple branches matched simultaneously ({} and {})",
                            static_cast<int>(found.value()),
                            static_cast<int>(values[i]));
                    }
                }
            }
        }
        return found;
    }

    [[nodiscard]] std::optional<TabPage> getActiveTabIndex() const;

    [[nodiscard]] std::optional<record::RecordType> getRecordType() const;

    const std::shared_ptr<condition::Condition<Frame>> child;
    const condition::ParallelCondition<Frame, rule::LogicalOr> *tab_page_condition;
    const condition::ParallelCondition<Frame, rule::LogicalOr> *record_type_condition;
    std::array<const condition::Condition<Frame> *, kAllTabPages.size()> tab_page_branches{};
    std::array<const condition::Condition<Frame> *, record::kAllRecordTypes.size()> record_type_branches{};
    const event_util::Sender<SceneInfo> on_scene_begin;
    const event_util::Sender<Frame, SceneState> on_scene_updated;
    const event_util::Sender<> on_scene_end;

    const chrono_util::time_unit scene_begin_timeout;
    const chrono_util::time_unit scene_end_timeout;

    std::optional<uint64> scene_begin_pending_since;
    std::optional<record::RecordType> scene_begin_pending_type;
    std::optional<uint64> scene_end_pending_since;
    bool scene_active = false;
    bool met_ = false;
    mutable bool simultaneous_match_warned_ = false;
};

}  // namespace uma::chara_detail
