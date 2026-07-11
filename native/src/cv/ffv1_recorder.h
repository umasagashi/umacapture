#pragma once

#include <filesystem>
#include <memory>

#include "cv/frame.h"
#include "types/shape.h"

namespace uma::video {

// Records every pushed Frame into a single lossless FFV1 matroska (`.mkv`) file, preserving each frame's
// millisecond timestamp as a variable-frame-rate PTS. Built for reproducing a failed live capture: the
// exact frame stream (and its inter-frame timing, which drives the recognition debounce) can be replayed
// later via Ffv1Reader. Pixels round-trip bit-exact (GBRP planar RGB; see ffv1_pixfmt.h).
//
// Encoding runs on its own thread (an event_util Block-mode runner), so it never stalls the capture
// thread beyond brief backpressure. Push is safe to call from the capture listener; the Frame is cloned
// internally, so the caller keeps ownership of its buffer. libav is hidden behind a PIMPL so translation
// units that only *drive* the recorder (e.g. cli.cpp) never include the ffmpeg headers.
class Ffv1Recorder {
public:
    // Opens `path` for a stream of `size`-sized frames. `fps_hint` is only a nominal AVStream metadata
    // value; real timing comes from per-frame PTS. Throws std::runtime_error if the file/codec cannot be
    // opened. The parent directory is created if missing.
    Ffv1Recorder(const std::filesystem::path &path, const Size<int> &size, int fps_hint = 30);

    // Finalizes the file (flush + trailer) if close() was not called explicitly.
    ~Ffv1Recorder();

    Ffv1Recorder(const Ffv1Recorder &) = delete;
    Ffv1Recorder &operator=(const Ffv1Recorder &) = delete;

    // Enqueues a copy of `frame` for encoding. Frames whose size differs from the stream size are dropped
    // with a warning (FFV1 streams are fixed-size). No-op after close().
    void push(const Frame &frame);

    // Drains the encode queue, flushes the encoder, and writes the matroska trailer. Idempotent.
    void close();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace uma::video
