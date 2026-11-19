#include "chara_detail/chara_detail_scene_context.h"

#include <string>

#include "core/frame_flow_counters.h"

namespace uma::chara_detail {

CharaDetailSceneContext::CharaDetailSceneContext(
    const std::shared_ptr<condition::Condition<Frame>> &child,
    const event_util::Sender<SceneInfo> &on_scene_begin,
    const event_util::Sender<Frame, SceneState> &on_scene_updated,
    const event_util::Sender<> &on_scene_end,
    const event_util::Sender<std::optional<Size<int>>, std::optional<Size<int>>> &on_scene_resized,
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
    , on_scene_resized(on_scene_resized)
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

namespace {

[[nodiscard]] std::string describeCapturedSize(const std::optional<Size<int>> &size) {
    if (!size.has_value()) {
        return "unknown";
    }
    return std::to_string(size->width()) + "x" + std::to_string(size->height());
}

}  // namespace

void CharaDetailSceneContext::update(const Frame &raw_input) {
    // Let the detail-crop tracker consume pending releases before the tree runs. Before latching this is the
    // full producer frame; after latching the producer is authoritative for both shaping and frame.anchor(),
    // which then reaches the scraper, stitcher and recognizer without further plumbing.
    // The size the producer captured, before any shaping: the one geometry fact that changes when -- and only
    // when -- the game's window (or shared surface) changes size. Read off raw_input, because the tracker's
    // re-anchored copy does not carry it.
    const auto &captured_size = raw_input.capturedSize();

    // Checked BEFORE the tracker may refuse the frame and before the condition tree's verdict. The first frame
    // of a new size is the one whose size change released the pane latch, so its snapshot is stale and the
    // tracker refuses its pixels; and a frame of the new size is frequently not recognized as the detail screen
    // at all. Either way it is the first such frame that has to be reported, whatever happens to its pixels.
    if (active_scene.has_value() && !(active_scene->captured_size == captured_size)) {
        log_info(
            "capture size changed during a detail scene: {} -> {}",
            describeCapturedSize(active_scene->captured_size),
            describeCapturedSize(captured_size));
        on_scene_resized->send(active_scene->captured_size, captured_size);
        active_scene->captured_size = captured_size;
    }

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

    // Calibration is driven only by the two pane candidates; the scene verdict is not a guard for it. What the
    // scene decides is WHEN an adopted value may take effect: never while a scene runs, end debounce included,
    // so every frame of one scene keeps the anchor that scene began with as far as calibration is concerned.
    const bool latched_now = detail_crop != nullptr && detail_crop->endFrame(input, active_scene.has_value());

    if (met_) {
        scene_end_pending_since = std::nullopt;  // A reappearance within the timeout keeps the same scene.
        if (!active_scene.has_value()) {
            if (latched_now) {
                // This frame was evaluated under the uncalibrated anchor and its successors carry the latched
                // one, so it must not begin a scene, nor count towards beginning one. Start the begin window
                // over from the next frame. The tree's Stable rules are not keyed on the anchor, so they would
                // not restart on their own.
                scene_begin_pending = std::nullopt;
            } else {
                beginSceneWhenStable(input, record_type.value(), captured_size);
            }
        }
        // Scrape only after the scene has actually begun. Holding back until the begin debounce commits
        // also makes the scraper's reference frame a settled, post-animation still instead of one captured
        // mid-animation.
        if (active_scene.has_value()) {
            // Hold the forwarded frame's anchor unit inside the configured band when the setting asks for it.
            // Deliberately HERE and not at the pipeline entry: the crop calibration above scans the raw
            // pixels, so an earlier resize would hand it a blurred image -- calibrate first, then resize.
            // Everything downstream (scraper, stitcher, recognizer) maps through frame.anchor(), so recognition
            // needs no further plumbing for the rescaled frame. A no-op when the setting is off, and also
            // whenever THIS frame's unit is already inside the band -- which is the majority of frames, and is
            // why the band is evaluated per frame here instead of being resolved to one unit at construction.
            // What the band did is attached to the forwarded frame (Frame::forwardedThroughBand) together with
            // the producer's captured size, read off raw_input: `input` may be the tracker's re-anchored copy,
            // which does not carry it. The scraper writes these facts next to the record.
            const bool forwarded = on_scene_updated->send(
                input.forwardedThroughBand(forwarded_frame_band, captured_size),
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
        scene_begin_pending = std::nullopt;
        if (active_scene.has_value()) {
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
    if (active_scene.has_value()) {
        endScene();
    }
    scene_begin_pending = std::nullopt;
}

void CharaDetailSceneContext::beginSceneWhenStable(
    const Frame &input, record::RecordType record_type, const std::optional<Size<int>> &captured_size) {
    if (scene_begin_timeout == chrono_util::time_unit::zero()) {
        beginScene(record_type, captured_size);
    } else if (!scene_begin_pending.has_value() || scene_begin_pending->record_type != record_type
               || !(scene_begin_pending->captured_size == captured_size)) {
        scene_begin_pending = PendingBegin{input.timestamp(), record_type, captured_size};
    } else if (chrono_util::monotonicElapsed(input.timestamp(), scene_begin_pending->since) >= sceneBeginTimeoutMs()) {
        beginScene(record_type, captured_size);
    }
}

void CharaDetailSceneContext::beginScene(
    record::RecordType record_type, const std::optional<Size<int>> &captured_size) {
    on_scene_begin->send({record_type});
    active_scene = ActiveScene{captured_size};
    scene_begin_pending = std::nullopt;
}

void CharaDetailSceneContext::endScene() {
    on_scene_end->send();
    active_scene = std::nullopt;
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
