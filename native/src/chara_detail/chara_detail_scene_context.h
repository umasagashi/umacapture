#pragma once

#include <array>
#include <optional>

#include "chara_detail/chara_detail_record.h"
#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/rule.h"
#include "cv/detail_crop_tracker.h"
#include "cv/frame.h"
#include "cv/scene_context.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/misc.h"

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
        const event_util::Sender<std::optional<Size<int>>, std::optional<Size<int>>> &on_scene_resized,
        const chrono_util::time_unit &scene_begin_timeout,
        const chrono_util::time_unit &scene_end_timeout,
        const std::shared_ptr<DetailCropTracker> &detail_crop = nullptr,
        const std::optional<Range<int>> &forwarded_frame_band = std::nullopt);

    void update(const Frame &raw_input) override;

    [[nodiscard]] bool met() const override;

    // The frame stream ended -- an offline producer's input ran out, or a live stream stalled. The
    // frame-timestamp scene-end debounce cannot advance without frames, so close an already-committed scene
    // here; a scene still in the begin debounce never committed, so just drop its pending window. Invoked on
    // the distributor runner thread, the same thread as update().
    void onIdle() override;

private:
    // Commit the scene only once the same record_type has stayed met for the begin timeout. The record_type is
    // locked here for the whole scene, so a transient first-match during the opening animation must not win — it
    // has to persist. Keyed off frame timestamps for replay-deterministic timing, mirroring the scene-end
    // debounce. A zero timeout commits on the first met frame (legacy behavior).
    // The begin window also restarts when the producer's captured size changes, so a scene only begins once the
    // size has held for the whole window (a window being dragged does not begin one).
    void beginSceneWhenStable(
        const Frame &input, record::RecordType record_type, const std::optional<Size<int>> &captured_size);

    void beginScene(record::RecordType record_type, const std::optional<Size<int>> &captured_size);

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
    // THE PRODUCER'S CAPTURED SIZE CHANGED WHILE A SCENE WAS RUNNING, carrying the scene's size and the new one.
    // Sent once per change, on the first frame of the new size that reaches this context, whether or not the
    // condition tree still recognizes that frame: a resized frame often does not, and it is exactly the frame
    // that must not go unnoticed. The scene itself goes on -- the detail screen is still open -- and its owner
    // decides what the change means for the attempt in flight (the scraper fails it).
    const event_util::Sender<std::optional<Size<int>>, std::optional<Size<int>>> on_scene_resized;

    const chrono_util::time_unit scene_begin_timeout;
    const chrono_util::time_unit scene_end_timeout;

    // Null when calibration is switched off in the config. Owned by NativeApi so it outlives this pipeline.
    std::shared_ptr<DetailCropTracker> detail_crop;

    // Band (in pixels) the anchor unit -- the intersection width -- of the frames forwarded downstream is
    // held inside, or nullopt to forward them untouched. A BAND and not a resolved unit because which bound
    // applies, and whether either does, depends on each frame's own intersection width: the crop calibration
    // can change that mid-session, so resolving it once here would resolve it against a frame that has not
    // arrived yet. Applied at the forward site only -- AFTER the condition tree and the crop calibration have
    // run on the full-resolution image -- so the calibration never scans a rescaled frame.
    const std::optional<Range<int>> forwarded_frame_band;

    // A begin window in progress: since when the same record type has been met, at which captured size.
    struct PendingBegin {
        uint64 since;
        record::RecordType record_type;
        std::optional<Size<int>> captured_size;
    };
    std::optional<PendingBegin> scene_begin_pending;
    std::optional<uint64> scene_end_pending_since;
    // The scene begun and not yet ended (its end debounce included), with the producer's captured size it is
    // running at. Present exactly while a scene is active, so the size cannot outlive or predate its scene.
    struct ActiveScene {
        std::optional<Size<int>> captured_size;
    };
    std::optional<ActiveScene> active_scene;
    bool met_ = false;
    mutable bool simultaneous_match_warned_ = false;
};

}  // namespace uma::chara_detail
