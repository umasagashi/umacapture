#pragma once

// The test seam into NativeApi (declared as a friend by core/native_api.h under UMACAPTURE_TESTING).
//
// Everything here reaches the PRODUCTION object: `create` runs the same constructor body NativeApi() runs, with
// the pane latch supplied so a case can drive the latch it reads, and `sendStitchReady` sends on the very
// connection the production stitcher subscribes to inside startPipeline. Nothing here reimplements wiring; a
// case that uses it observes what the app does.

#include <memory>
#include <utility>

#include "chara_detail/record_info.h"
#include "core/native_api.h"
#include "cv/pane_mode_latch.h"

namespace uma::app {

struct NativeApiTestAccess {
    static std::unique_ptr<NativeApi> create(const std::shared_ptr<PaneModeLatch> &pane_mode_latch) {
        return std::unique_ptr<NativeApi>(new NativeApi(pane_mode_latch));
    }

    static std::unique_ptr<NativeApi> create() { return create(std::make_shared<PaneModeLatch>()); }

    // Hands a record to the stitcher stage of a running pipeline, the way the scraper does when a record's
    // fragments are complete. Null until startPipeline has built the stage.
    static bool sendStitchReady(NativeApi &api, const chara_detail::RecordInfo &info) {
        if (api.on_stitch_ready == nullptr) {
            return false;
        }
        api.on_stitch_ready->send(info);
        return true;
    }
};

}  // namespace uma::app
