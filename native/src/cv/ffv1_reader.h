#pragma once

#include <filesystem>
#include <memory>

#include "cv/frame.h"
#include "types/shape.h"
#include "util/event_util.h"

namespace uma::video {

// Replays an FFV1 `.mkv` produced by Ffv1Recorder back into the recognition pipeline. Each decoded full frame
// is emitted through the same event_util::Sender the live capture and VideoLoader use, carrying its original
// millisecond timestamp (recovered from the container PTS) so the scene begin/end debounce fires on exactly
// the frames it did during capture. Pixels round-trip bit-exact (BGR0 -> BGR).
//
// This producer resolves NO pane decision of its own: it emits the full recorded frame with the default
// anchor and no pane snapshot, and the distributor thread applies the latched pane as the Frame anchor. See
// cv/video_loader.h for the constraint that forces both offline producers to work that way -- in short, an
// offline producer races the thread that owns the latch, while the golden suite consumes these paths as a
// deterministic function of their input. Ingestion is paced by the downstream Block-mode queue, not by
// wall-clock, matching VideoLoader.
class Ffv1Reader {
public:
    Ffv1Reader(const std::filesystem::path &path, const event_util::Sender<Frame, Size<int>> &on_frame_captured);
    ~Ffv1Reader();

    Ffv1Reader(const Ffv1Reader &) = delete;
    Ffv1Reader &operator=(const Ffv1Reader &) = delete;

    // Decodes every frame and sends it downstream, returning at end-of-stream. Throws std::runtime_error if
    // the file cannot be opened or is not an FFV1 stream.
    void run() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace uma::video
