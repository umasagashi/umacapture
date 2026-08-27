#pragma once

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <functional>
#include <iomanip>
#include <optional>
#include <sstream>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/decoded_frame_to_bgr.h"
#include "cv/frame.h"
#include "cv/frame_shaper.h"
#include "cv/media_timestamp.h"
#include "types/shape.h"
#include "util/event_util.h"
#include "util/logger_util.h"

// UMACAPTURE_WITH_PLANAR_DECODER selects the diagnostic planar backend, whose header includes the libav
// headers directly. Only umacapture_cli links libav (native/CMakeLists.txt states why the Flutter Windows
// app target deliberately does not), and this header is no longer CLI-only: the Windows runner constructs a
// VideoLoader for video import, and the wasm build compiles the same tree. So the include and every line
// that names a libav type sit behind the switch, and native/CMakeLists.txt defines it on the CLI target
// alone -- the one target where `video --color_matrix` and test/integration/run_dual_decode.py run.
#ifdef UMACAPTURE_WITH_PLANAR_DECODER
#include "cv/planar_video_decoder.h"
#endif

namespace uma::video {

// The narrow path string to hand cv::VideoCapture::open, which takes no wide overload.
//
// WINDOWS-ONLY HAZARD, MEASURED, and the reason this is a function rather than a call to path::string():
// MSVC's std::filesystem::path narrow accessors convert through the system ANSI code page, and they do not
// substitute -- they THROW std::filesystem::filesystem_error ("No mapping for the Unicode character exists in
// the target multi-byte code page") for any name the ACP cannot represent. Under ACP 932 that is a Hangul or
// emoji directory, i.e. an ordinary folder name; the file exists, opens fine through every wide API, and
// std::filesystem::exists says so. The throw landed on VideoImportSession's own thread, whose entry did not
// then wrap probeVideoTrack at all, so it reached std::terminate and took the process down -- measured, not
// reasoned: testdata/evidence/video-import-windows-parity/acp-probe/. (The entry is an exception boundary now, so
// the same throw would end as a reported `failed` rather than a crash; see windows/runner/video_import_session.h.)
//
// ACP FIRST, UTF-8 ONLY AS THE FALLBACK, so that no path which works today changes backend. Measured on this
// machine with OpenCV 4.13 (same directory):
//   * FFmpeg opens either encoding -- its win32_open tries UTF-8 first and falls back to the ACP string --
//     so a real clip decodes identically whichever one is passed.
//   * MSMF widens the narrow bytes naively and therefore only ever accepts ASCII or ACP. It is the backend
//     that opens an audio-only MP4 (FFmpeg refuses it) and reports 0 x 0, which is the single signal
//     VideoImportSession::probeVideoTrack turns into `no_video_track`. Passing UTF-8 unconditionally would
//     lose that verdict for Japanese folder names -- the commonest non-ASCII case here -- and degrade it to
//     the weaker `not_a_video`.
// So the fallback is reached exactly when the alternative was a crash, and never otherwise.
//
// On POSIX and Emscripten there is no conversion: the native narrow encoding IS UTF-8, generic_string() cannot
// throw, and the catch is dead code -- which is why this can be one shared function rather than a divergence
// (.claude/rules/platform-parity.md).
[[nodiscard]] inline std::string capturePathString(const std::filesystem::path &path) {
    try {
        return path.generic_string();
    } catch (const std::exception &) {
        // The exception type of the narrow conversion is implementation-defined (MSVC throws
        // filesystem_error; libstdc++ and libc++ do not throw here at all), so it is caught by base class.
        return path.u8string();
    }
}

// Hooks an EMBEDDING front end (the Windows runner's video import) needs and the CLI does not: a way to stop
// a minutes-long decode from another thread, and the two numbers a progress bar is made of. Every member is
// optional; an absent host is exactly the CLI's behaviour, which is why the whole struct is passed as
// std::optional and defaults to nullopt.
//
// `is_cancelled` is named after web's `host.isCancelled()` (web/video_import.mjs) on purpose: the browser
// import already had this concept, and .claude/rules/platform-parity.md asks the two front ends to spell the
// same concept the same way.
struct OfflineRunHost {
    // Consulted before decoding each frame. Returning true breaks the loop; the loader reports nothing else
    // about it, because "was this run cancelled" is a fact the caller already owns (it set the flag).
    std::function<bool()> is_cancelled;
    // Called once per opened file, before the first frame. `duration_ms` is 0 when the container does not
    // say -- the same "indeterminate" convention the browser import uses.
    std::function<void(int64 duration_ms)> on_opened;
    // Called for each frame that decoded to a usable media time and was passed to emit(). `decoded` is
    // 1-based and counts across the loader's lifetime, so a runBatch reports one continuous progression
    // rather than restarting per file. `media_ts_ms` is the stamp the frame was emitted with (head_ts
    // included). This is the DECODE-side count and nothing else: how many frames the pipeline accepted is
    // the sender listener's answer (NativeApi::updateFrame's return value), which this class never sees.
    std::function<void(int64 decoded, int64 media_ts_ms)> on_decoded;
};

// Decodes a clip frame by frame and feeds every decoded frame into the recognition pipeline.
//
// DELIBERATE DIVERGENCE FROM THE LIVE PRODUCERS (.claude/rules/platform-parity.md)
//   Windows live capture and the web worker resolve the pane latch per frame and crop the pixels they send.
//   This producer resolves nothing: it hands over the full decoded frame with no pane snapshot and leaves the
//   pane decision to the distributor thread, where DetailCropTracker re-anchors the frame to the latched pane.
//
//   The constraint that forces it: an offline producer runs CONCURRENTLY with the thread that owns the latch
//   (loader thread -> Block queue -> recorder thread -> Block queue -> distributor thread), so "had frame n
//   already been shaped when the latch committed" is decided by thread scheduling rather than by the clip.
//   Frames shaped under the superseded decision are then refused at the consumer boundary, and how many of
//   them there are varies from run to run. The golden suite (native/test/integration/run.py) consumes this
//   path as a pure function of the input clip and the model set, so that nondeterminism is not acceptable
//   here. Live capture carries no such contract and keeps cropping, which is what saves it the copy bandwidth
//   in the first place.
//
//   Recognition geometry is NOT part of the divergence: the latched pane reaches the pipeline as the Frame
//   anchor either way, and every downstream coordinate is anchor-relative. What differs is only which thread
//   applies it, and the offline one is the single-threaded, in-order consumer.
//
//   TWO DECODE BACKENDS, ONE PRODUCER. By default the clip is read through cv::VideoCapture, whose FFmpeg
//   backend converts YUV to BGR with swscale -- BT.601 limited range, regardless of the stream's colour
//   tags, with no way to ask it for another interpretation. `diagnostic_matrix` swaps only the step that
//   produces those bytes: cv/planar_video_decoder.h hands over the decoder's own 4:2:0 planes and
//   cv/decoded_frame_to_bgr.h converts them under the named matrix. Everything after that -- the clock, the
//   shaping call, the anchor, the absent pane snapshot, the send -- is the SAME code, on purpose, so that a
//   difference between two runs of the same clip can only have come from the pixels.
//
//   This is a test affordance and nothing selects it in production (the CLI exposes it as
//   `video --color_matrix`, and test/integration/run_dual_decode.py is its only caller). It does not add a
//   producer to the four .claude/rules/platform-parity.md lists: the shipping web offline producer converts
//   its planes with the SAME BT.601 the CLI does, precisely so the two agree, and BT.709 exists here only to
//   measure how much colour shift the recognition thresholds tolerate. Being a test affordance is also why
//   it is compiled in only where it is used -- see UMACAPTURE_WITH_PLANAR_DECODER above; asking for it in a
//   build without it throws rather than falling back.
class VideoLoader {
public:
    explicit VideoLoader(
        const event_util::Sender<Frame, Size<int>> &on_frame_captured,
        const std::optional<color::ColorMatrix> &diagnostic_matrix = std::nullopt,
        std::optional<OfflineRunHost> host = std::nullopt)
        : on_frame_captured(on_frame_captured)
        , diagnostic_matrix(diagnostic_matrix)
        , host(std::move(host)) {}

    [[maybe_unused]] void runBatch(const std::vector<std::filesystem::path> &files) const {
        int64 ts = 0;
        for (const auto &path : files) {
            ts += run(path, ts);
        }
    }

    [[nodiscard]] int64 run(const std::filesystem::path &path, int64 head_ts = 0) const {
        if (diagnostic_matrix.has_value()) {
            return runPlanar(path, head_ts, diagnostic_matrix.value());
        }
        return runCapture(path, head_ts);
    }

    // CAP_PROP_FRAME_COUNT / CAP_PROP_FPS: container metadata, not a decode result. A container that omits
    // either (or reports a nonsense value) yields 0, which the front ends read as "indeterminate" and render
    // as an unbounded progress bar rather than a wrong one.
    //
    // PUBLIC because cv/video_frame_grabber.h states a clip's duration to a time selector and must state the
    // SAME number the import reports through OfflineRunHost::on_opened -- a second, independently written
    // formula could disagree with the progress bar for the very same file.
    [[nodiscard]] static int64 durationMsOf(cv::VideoCapture &cap) {
        const double frame_count = cap.get(cv::CAP_PROP_FRAME_COUNT);
        const double fps = cap.get(cv::CAP_PROP_FPS);
        if (!std::isfinite(frame_count) || !std::isfinite(fps) || frame_count <= 0.0 || fps <= 0.0) {
            return 0;
        }
        return static_cast<int64>(std::llround(frame_count / fps * 1000.0));
    }

private:
    [[nodiscard]] int64 runCapture(const std::filesystem::path &path, int64 head_ts) const {
        const std::string narrow_path = capturePathString(path);
        vlog_info(narrow_path);
        cv::VideoCapture cap;
        if (!cap.open(narrow_path)) {
            throw std::runtime_error((std::ostringstream() << "Failed to open: " << narrow_path << "\n"
                                                           << "You might need to copy opencv_videoio_ffmpeg455_64.dll.")
                                         .str());
        }
        vlog_debug("VideoCapture successfully opened.");
        notifyOpened(durationMsOf(cap));

        // Some containers/codecs report POS_MSEC == 0 (or a lower value) mid-stream. Do not treat that as
        // end-of-stream -- the read failure above is the only terminal condition -- and do not let it rewind the
        // downstream debounce either. The rounding, the monotonic clamp and the validation all live in
        // MonotonicMediaClock (cv/media_timestamp.h), shared with the browser's video import so the two offline
        // producers that read arbitrary containers stamp a given clip identically; that class also records what
        // a clip whose every frame reports 0 does, and why it is unsupported rather than worked around.
        media::MonotonicMediaClock clock;
        int64 last_ts = 0;
        for (int i = 0;; i++) {
            // Checked BEFORE the read, so a cancel costs at most the frame already in flight and never a
            // whole decode of the remaining clip. Nothing is reported here: the caller set the flag, so it
            // already knows, and the loop is only one of several places the run can end.
            if (isCancelled()) {
                log_info("VideoLoader stopped decoding: the host cancelled the run");
                break;
            }
            cv::Mat mat;
            if (!cap.read(mat) || mat.empty()) {
                break;
            }
            const auto pos_ms = cap.get(cv::CAP_PROP_POS_MSEC);
            if (i != 0 && pos_ms <= 0.0) {
                vlog_debug(i, pos_ms);
            }
            const auto stamped = clock.advance(pos_ms);
            if (!stamped.has_value()) {
                // NaN/infinity from the container. Skipped rather than stamped, for the reason the clock states:
                // the value cannot be made into a media time without inventing one.
                log_debug("VideoLoader dropped a frame: CAP_PROP_POS_MSEC is not a finite value");
                continue;
            }

            last_ts = stamped.value();
            emit(mat, static_cast<uint64>(last_ts + head_ts));
            notifyDecoded(last_ts + head_ts);
        }
        return last_ts;
    }

#ifndef UMACAPTURE_WITH_PLANAR_DECODER
    // Built without libav (every target except umacapture_cli). Refusing loudly rather than silently falling
    // back to cv::VideoCapture is the point: a `--color_matrix` run that quietly decoded through swscale
    // would report a colour comparison it never made. Nothing in production selects this path -- the Windows
    // runner and the wasm build always pass an absent `diagnostic_matrix` -- so this is unreachable there.
    [[nodiscard]] int64 runPlanar(const std::filesystem::path &, int64, color::ColorMatrix) const {
        throw std::runtime_error("planar decode backend is not compiled into this build");
    }
#else
    // The `--color_matrix` backend. Identical in every respect except where the BGR bytes come from: libav
    // hands over the decoder's own planes and cv/decoded_frame_to_bgr.h converts them under `matrix`. The
    // timestamp goes through the same MonotonicMediaClock, from a value computed the way OpenCV computes
    // CAP_PROP_POS_MSEC (see cv/planar_video_decoder.h), and the frame goes out through the same emit().
    [[nodiscard]] int64 runPlanar(const std::filesystem::path &path, int64 head_ts,
                                  color::ColorMatrix matrix) const {
        // Same reason capturePathString exists: path::string() throws on Windows for an ACP-unrepresentable
        // name, and a log line must not be what takes the process down. decodePlanarFrames below already
        // passes libav the u8string() for its own half of this.
        vlog_info(capturePathString(path));
        // libav is asked for planes, not for container metadata, so this backend cannot state a duration.
        // 0 is the same "indeterminate" value a container that omits it produces on the capture backend.
        notifyOpened(0);
        media::MonotonicMediaClock clock;
        int64 last_ts = 0;
        planar::decodePlanarFrames(path, [&](const planar::PlanarFrame &decoded) {
            // decodePlanarFrames' sink returns void, so a cancel cannot break libav's read loop the way it
            // breaks runCapture's: the remaining packets are still decoded, but nothing more is emitted.
            // Left as-is because this backend is a CLI-only test affordance that no host is ever attached
            // to -- the cancellable path is the one the front ends actually run.
            if (isCancelled()) {
                return;
            }
            const auto stamped = clock.advance(decoded.pos_ms);
            if (!stamped.has_value()) {
                log_debug("VideoLoader dropped a frame: the decoded presentation time is not a finite value");
                return;
            }
            const cv::Mat mat = color::decodedFrameToBgr(decoded.data, decoded.size,
                                                         color::DecodedFrameFormat::I420, decoded.width,
                                                         decoded.height, matrix);
            if (mat.empty()) {
                // Only reachable if the decoder's plane sizes and the packed buffer disagree, which would be
                // a defect in planar_video_decoder.h rather than a property of the clip. Loud, not silent.
                throw std::runtime_error("VideoLoader: planar frame did not convert to BGR");
            }
            last_ts = stamped.value();
            emit(mat, static_cast<uint64>(last_ts + head_ts));
            notifyDecoded(last_ts + head_ts);
        });
        return last_ts;
    }
#endif

    [[nodiscard]] bool isCancelled() const { return host && host->is_cancelled && host->is_cancelled(); }

    void notifyOpened(int64 duration_ms) const {
        if (host && host->on_opened) {
            host->on_opened(duration_ms);
        }
    }

    void notifyDecoded(int64 media_ts_ms) const {
        decoded_count += 1;
        if (host && host->on_decoded) {
            host->on_decoded(decoded_count, media_ts_ms);
        }
    }

    // Shared by both backends: shape, then send. No pane snapshot, deliberately -- see the class comment. With
    // an absent snapshot `AnchorOnly` is "keep every pixel and give it the default anchor", which is what this
    // producer owes the pipeline; with nothing resolved beforehand there is also nothing to re-validate.
    //
    // NO FULL-FRAME COPY, and that is a measured claim rather than an assumed one. This used to pass
    // `CropPixels`, whose only effect under an absent snapshot is a clone of the whole decoded image, justified
    // by a comment saying cv::VideoCapture reuses `mat` for the next frame. It does not: read() returns a
    // solely-owned, refcounted buffer per frame (FFMPEG backend, measured 2026-08-19 -- see
    // testdata/evidence/import-perf-remeasure-2026-08-18/I1-clone-settlement.md), and runPlanar's Mat is freshly
    // allocated by decodedFrameToBgr. The pixels the pipeline receives are byte-identical either way; only the
    // copy is gone. What keeps this honest for a backend nobody here has measured -- cv::VideoCapture picks its
    // backend from the file, and MSMF is reachable on Windows -- is frame_shaper::ownsPixelsSolely, which every
    // non-CropPixels call is checked against and which throws instead of silently forwarding a buffer somebody
    // else may overwrite.
    void emit(const cv::Mat &mat, uint64 timestamp) const {
        const Size<int> captured_size = mat.size();
        const auto shaped =
            frame_shaper::shapeCapturedFrame(mat, timestamp, std::nullopt, frame_shaper::ShapingMode::AnchorOnly);
        if (!shaped.ok()) {
            log_debug("VideoLoader dropped a frame: {}", frame_shaper::describe(shaped.status));
            return;
        }
        // original_size is the decoded size, which is also this frame's own size. NativeApi uses it for
        // size-change release/reporting, so it must change when (and only when) the input geometry does.
        on_frame_captured->send(shaped.frame, captured_size);
    }

    const event_util::Sender<Frame, Size<int>> on_frame_captured{};
    const std::optional<color::ColorMatrix> diagnostic_matrix{};
    const std::optional<OfflineRunHost> host{};
    // Mutable because run()/runBatch() are const and the progress counter is reporting state, not decode
    // state. Single-threaded by construction: one loader runs on one thread.
    mutable int64 decoded_count = 0;
};

}  // namespace uma::video
