#include "chara_detail/chara_detail_scene_context.h"

#include "core/frame_flow_counters.h"

namespace uma::chara_detail {

CharaDetailSceneContext::CharaDetailSceneContext(
    const std::shared_ptr<condition::Condition<Frame>> &child,
    const event_util::Sender<SceneInfo> &on_scene_begin,
    const event_util::Sender<Frame, SceneState> &on_scene_updated,
    const event_util::Sender<> &on_scene_end,
    const chrono_util::time_unit &scene_begin_timeout,
    const chrono_util::time_unit &scene_end_timeout,
    const std::shared_ptr<DetailCropTracker> &detail_crop,
    const std::optional<Range<int>> &forwarded_frame_band)
    : child(child)
    , tab_page_condition(dynamic_cast<const TabCondition *>(child->findByTag("tab_page")))
    , record_type_condition(dynamic_cast<const TabCondition *>(child->findByTag("record_type")))
    , on_scene_begin(on_scene_begin)
    , on_scene_updated(on_scene_updated)
    , on_scene_end(on_scene_end)
    , scene_begin_timeout(scene_begin_timeout)
    , scene_end_timeout(scene_end_timeout)
    , detail_crop(detail_crop)
    , forwarded_frame_band(forwarded_frame_band) {
    if (tab_page_condition == nullptr) {
        throw std::runtime_error("tab_page condition not found");
    }
    if (record_type_condition == nullptr) {
        throw std::runtime_error("record_type condition not found");
    }
    record_type_branches = resolveBranches(record_type_condition, record::kAllRecordTypes, record::recordTypeTag);
    tab_page_branches = resolveBranches(tab_page_condition, kAllTabPages, tabPageTag);
}

void CharaDetailSceneContext::update(const Frame &raw_input) {
    // Let the detail-crop tracker consume pending releases before the tree runs. Before latching this is the
    // full producer frame; after latching the producer is authoritative for both shaping and frame.anchor(),
    // which then reaches the scraper, stitcher and recognizer without further plumbing.
    const auto prepared =
        detail_crop != nullptr ? detail_crop->beginFrame(raw_input) : std::optional<Frame>{raw_input};
    if (!prepared.has_value()) {
        return;
    }
    const Frame &input = prepared.value();

    child->update(input);
    const auto tab_page = getActiveTabIndex();
    const auto record_type = getRecordType();
    const bool resolved = tab_page.has_value() && record_type.has_value();
    met_ = child->met() && resolved;

    if (detail_crop != nullptr) {
        // Calibration is driven only by the two pane candidates. The scene verdict is not an independent
        // guard for it, so no close-button timer bypass or extra tree resolution is involved.
        detail_crop->endFrame(input);
    }

    if (met_) {
        scene_end_pending_since = std::nullopt;  // A reappearance within the timeout keeps the same scene.
        if (!scene_active) {
            beginSceneWhenStable(input, record_type.value());
        }
        // Scrape only after the scene has actually begun. Holding back until the begin debounce commits
        // also makes the scraper's reference frame a settled, post-animation still instead of one captured
        // mid-animation.
        if (scene_active) {
            // Hold the forwarded frame's anchor unit inside the configured band when the setting asks for it.
            // Deliberately HERE and not at the pipeline entry: the crop calibration above scans the raw
            // pixels, so an earlier resize would hand it a blurred image -- calibrate first, then resize.
            // Everything downstream (scraper, stitcher, recognizer) maps through frame.anchor(), so the
            // rescaled frame needs no further plumbing. A no-op when the setting is off, and also whenever
            // THIS frame's unit is already inside the band -- which is the majority of frames, and is why the
            // band is evaluated per frame here instead of being resolved to one unit at construction.
            const bool forwarded = on_scene_updated->send(
                forwarded_frame_band.has_value() ? input.resizedIntoBand(forwarded_frame_band.value()) : input,
                {tab_page.value(), record_type.value()});
            // HOP 2 IN of the offline producer's brake (core/frame_flow_counters.h): the frame just entered the
            // scraper's queue. Its paired dequeue is the chara_detail_updated listener in native_api.cpp, on the
            // scraper thread. Counted only when the queue ACCEPTED the frame: live capture runs this connection
            // in Discard mode, so a full queue drops the send and the paired dequeue can never fire for it --
            // counting a dropped send would ratchet the reported depth up by one per drop, permanently.
            if (forwarded) {
                app::frameFlowCounters().noteEnqueued();
            }
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
