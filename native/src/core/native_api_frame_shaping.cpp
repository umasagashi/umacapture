#include "core/native_api.h"

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

}  // namespace uma::app
