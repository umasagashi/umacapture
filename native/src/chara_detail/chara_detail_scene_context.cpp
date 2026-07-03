#include "chara_detail/chara_detail_scene_context.h"

namespace uma::chara_detail {

CharaDetailSceneContext::CharaDetailSceneContext(
    const std::shared_ptr<condition::Condition<Frame>> &child,
    const event_util::Sender<SceneInfo> &on_scene_begin,
    const event_util::Sender<Frame, SceneState> &on_scene_updated,
    const event_util::Sender<> &on_scene_end,
    const chrono_util::time_unit &scene_begin_timeout,
    const chrono_util::time_unit &scene_end_timeout)
    : child(child)
    , tab_page_condition(dynamic_cast<const TabCondition *>(child->findByTag("tab_page")))
    , record_type_condition(dynamic_cast<const TabCondition *>(child->findByTag("record_type")))
    , on_scene_begin(on_scene_begin)
    , on_scene_updated(on_scene_updated)
    , on_scene_end(on_scene_end)
    , scene_begin_timeout(scene_begin_timeout)
    , scene_end_timeout(scene_end_timeout) {
    if (tab_page_condition == nullptr) {
        throw std::runtime_error("tab_page condition not found");
    }
    if (record_type_condition == nullptr) {
        throw std::runtime_error("record_type condition not found");
    }
    record_type_branches = resolveBranches(record_type_condition, record::kAllRecordTypes, record::recordTypeTag);
    tab_page_branches = resolveBranches(tab_page_condition, kAllTabPages, tabPageTag);
}

void CharaDetailSceneContext::update(const Frame &input) {
    child->update(input);
    const auto tab_page = getActiveTabIndex();
    const auto record_type = getRecordType();
    met_ = child->met() && tab_page.has_value() && record_type.has_value();

    if (met_) {
        scene_end_pending_since = std::nullopt;  // A reappearance within the timeout keeps the same scene.
        if (!scene_active) {
            beginSceneWhenStable(input, record_type.value());
        }
        // Scrape only after the scene has actually begun. Holding back until the begin debounce commits
        // also makes the scraper's reference frame a settled, post-animation still instead of one captured
        // mid-animation.
        if (scene_active) {
            on_scene_updated->send(input, {tab_page.value(), record_type.value()});
        }
    } else {
        // Any drop before commit resets the begin window; the same record_type must persist uninterrupted.
        scene_begin_pending_since = std::nullopt;
        scene_begin_pending_type = std::nullopt;
        if (scene_active) {
            // Debounce the scene end by video time (frame timestamps), not wall-clock. A wall-clock timer
            // running on its own thread made scene closing depend on how fast frames were fed during
            // offline video replay; keying off the frame timestamp keeps this deterministic. Frame
            // timestamps track real time in live capture, so live behavior is unchanged.
            if (scene_end_timeout == chrono_util::time_unit::zero()) {
                endScene();
            } else if (!scene_end_pending_since) {
                scene_end_pending_since = input.timestamp();
            } else if (chrono_util::monotonicElapsed(input.timestamp(), scene_end_pending_since.value())
                       >= sceneEndTimeoutMs()) {
                endScene();
            }
        }
    }
}

bool CharaDetailSceneContext::met() const {
    return met_;
}

void CharaDetailSceneContext::onIdle() {
    if (scene_active) {
        endScene();
    }
    scene_begin_pending_since = std::nullopt;
    scene_begin_pending_type = std::nullopt;
}

void CharaDetailSceneContext::beginSceneWhenStable(const Frame &input, record::RecordType record_type) {
    if (scene_begin_timeout == chrono_util::time_unit::zero()) {
        beginScene(record_type);
    } else if (!scene_begin_pending_since || scene_begin_pending_type != record_type) {
        scene_begin_pending_since = input.timestamp();
        scene_begin_pending_type = record_type;
    } else if (chrono_util::monotonicElapsed(input.timestamp(), scene_begin_pending_since.value())
               >= sceneBeginTimeoutMs()) {
        beginScene(record_type);
    }
}

void CharaDetailSceneContext::beginScene(record::RecordType record_type) {
    on_scene_begin->send({record_type});
    scene_active = true;
    scene_begin_pending_since = std::nullopt;
    scene_begin_pending_type = std::nullopt;
}

void CharaDetailSceneContext::endScene() {
    on_scene_end->send();
    scene_active = false;
    scene_end_pending_since = std::nullopt;
}

uint64 CharaDetailSceneContext::sceneBeginTimeoutMs() const {
    return static_cast<uint64>(scene_begin_timeout.count());
}

uint64 CharaDetailSceneContext::sceneEndTimeoutMs() const {
    return static_cast<uint64>(scene_end_timeout.count());
}

std::optional<TabPage> CharaDetailSceneContext::getActiveTabIndex() const {
    return firstMet(tab_page_branches, kAllTabPages);
}

std::optional<record::RecordType> CharaDetailSceneContext::getRecordType() const {
    return firstMet(record_type_branches, record::kAllRecordTypes);
}

}  // namespace uma::chara_detail
