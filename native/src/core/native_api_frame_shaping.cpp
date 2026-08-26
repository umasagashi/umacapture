#include "core/native_api.h"

#ifdef UMACAPTURE_TESTING
#include "chara_detail/chara_detail_recognizer.h"
#include "chara_detail/chara_detail_scene_scraper.h"
#include "chara_detail/chara_detail_scene_stitcher.h"
#endif

namespace uma::app {

const std::optional<Rect<int>> NativeApi::frameShapingRect(const Size<int> &captured_size) const {
    return pane_mode_latch->rectFor(captured_size);
}

PaneModeLatch::Snapshot NativeApi::frameShapingSnapshot(const Size<int> &captured_size) const {
    return pane_mode_latch->snapshotFor(captured_size);
}

bool NativeApi::isFrameShapingSnapshotCurrent(const PaneModeLatch::Snapshot &snapshot) const {
    return pane_mode_latch->isCurrent(snapshot);
}

#ifdef UMACAPTURE_TESTING
NativeApi::NativeApi(std::shared_ptr<PaneModeLatch> test_pane_mode_latch)
    : pane_mode_latch(std::move(test_pane_mode_latch))
    , detail_crop_tracker(nullptr) {}

NativeApi::~NativeApi() = default;
#endif

}  // namespace uma::app
