#pragma once

// Lenient readers for the optional, platform-neutral keys of the pipeline start config.
//
// Every reader here degrades to a documented default instead of throwing: these keys are optional
// refinements, and Json::value() would raise a type_error on a malformed value, which would abort
// startPipeline and refuse the whole capture session over one bad number.

#include <chrono>
#include <cstdint>
#include <limits>
#include <optional>

#include "types/range.h"
#include "util/json_util.h"
#include "util/logger_util.h"

namespace uma::app {

// Default stall timeout for the live-capture FrameStallWatchdog: how long the frame stream may go silent
// before an open scene is force-closed. 2000 ms is the value the watchdog shipped with before the timeout
// became configurable.
//
// DO NOT DIVERGE THIS PER PLATFORM. The key exists purely as an escape hatch for the case where false
// stall detections are actually MEASURED in the field; it is not a knob for making the browser behave
// differently from the Windows desktop build. Web and Windows must keep writing the same value from the
// single Dart-side definition (`_frameStallTimeoutMs` in lib/src/core/platform_controller.dart). A
// web-only longer timeout would widen the very web/Windows behaviour gap the watchdog was enabled on web
// to close, and would do it invisibly.
constexpr std::chrono::milliseconds kDefaultFrameStallTimeout{2000};

// Reads the neutral, platform-independent top-level key:
//
//   "frame_stall_timeout_ms": <int > 0>
//
// Tolerant in the same shape as `readFrameResizeBand` below: an absent key means the default (so an older
// config keeps today's behaviour), and a present-but-malformed value -- wrong type, or a zero/negative
// millisecond count, which is not a lesser kind of wrong than a string -- is warned about and also falls
// back to the default.
[[nodiscard]] inline std::chrono::milliseconds readFrameStallTimeout(const json_util::Json &config_json) {
    const auto entry = config_json.find("frame_stall_timeout_ms");
    if (entry == config_json.end()) {
        return kDefaultFrameStallTimeout;
    }
    if (!entry->is_number_integer() || entry->get<int64_t>() <= 0) {
        log_warning("frame_stall_timeout_ms is not a positive integer; keeping the default timeout");
        return kDefaultFrameStallTimeout;
    }
    return std::chrono::milliseconds(entry->get<int64_t>());
}

// The shipped frame-resize BAND: the closed interval, in pixels, the forwarded frame's anchor UNIT (its
// intersection width -- see cv/frame.h) is allowed to sit in. A frame below the lower bound is scaled UP to
// it, a frame above the upper bound is scaled DOWN to it, and a frame anywhere in between is forwarded
// untouched. These are the values used when the resize is enabled but the config names no bounds.
//
// This is the shipped operating point, not a derived quantity: nothing else in the code computes it, so a
// change here changes what every platform ships. It is pinned by name in test/core/test_pipeline_config.cpp
// ("the shipped frame-resize band is 540-720 px"), and mirrored -- by derivation, not by repetition -- into
// the CLI's `--frame-resize` block (`kFrameResizeMinUnit` / `kFrameResizeMaxUnit`, core/cli.cpp), which is
// the one caller in this repository that writes the two keys explicitly.
//
// 540 is the recognizer's reference width (FrameAnchor::base_size in cv/frame.h). A band rather than a
// single target because the resample is only worth paying for at the ends: the target this replaced
// resampled EVERY capture whose unit was not already exactly that number, including the many that recognize
// perfectly well at the width they arrive in.
//
// THE UPPER BOUND IS NOT THE WIDTH AT WHICH SHRINKING STARTS. The shrink arm carries a dead band expressed as
// a MULTIPLE of this bound (Frame::kShrinkDeadband, cv/frame.h), so a frame is only resampled down once its
// unit reaches `kDefaultFrameResizeMaxUnit * kShrinkDeadband` -- 1080 px as shipped. Moving the bound moves
// that fire point with it, by construction; it is not a second number to keep in step.
constexpr int kDefaultFrameResizeMinUnit = 540;
constexpr int kDefaultFrameResizeMaxUnit = 720;

// Reads one bound of the band. Returns false -- after warning -- when the key is present but malformed, and
// leaves `value` untouched when the key is absent, so an absent bound keeps its default while a malformed
// one disables the whole resize (the caller's job).
[[nodiscard]] inline bool readFrameResizeBound(const json_util::Json &block, const char *key, int &value) {
    const auto entry = block.find(key);
    if (entry == block.end()) {
        return true;
    }
    // Read as int64 and range-check before narrowing, like readFrameStallTimeout above: nlohmann's
    // is_number_integer() is equally true for a 64-bit value, and get<int>() would then narrow it silently
    // -- nlohmann performs the conversion without a check, so an out-of-range bound would arrive as an
    // arbitrary (possibly negative) pixel width instead of being caught here.
    const auto raw = entry->is_number_integer() ? entry->get<int64_t>() : 0;
    if (raw <= 0 || raw > std::numeric_limits<int>::max()) {
        // Malformed, so fall back to the DEFAULT -- which is "disabled" -- rather than silently substituting
        // a shipped bound for one the config asked for and got wrong. A zero, negative, or out-of-range
        // bound is not a lesser kind of wrong than a string: all mean the caller does not know what it wants.
        log_warning("frame_resize.{} is not a positive int-range integer; keeping the frame resize disabled", key);
        return false;
    }
    value = static_cast<int>(raw);
    return true;
}

// Reads the neutral, platform-independent `frame_resize` block:
//
//   "frame_resize": { "enabled": <bool>, "min_unit": <int > 0>, "max_unit": <int > 0, >= min_unit> }
//
// and returns the band the forwarded frame's unit is held inside, or nullopt for "forward the frames
// untouched". Deliberately NOT read out of a platform-specific path (it is applied by shared pipeline code,
// on every platform), and deliberately tolerant, exactly like `detail_crop_calibration` in native_api.cpp:
// an absent key means the default (disabled, so an older config keeps today's behaviour), and a
// present-but-malformed value is warned about and then also falls back to the default. Json::value() would
// instead throw a type_error, which would abort startPipeline and refuse the whole capture session over an
// optional refinement.
//
// THE KEYS WERE RENAMED WITH THE MEANING. This block used to carry a single `unit`, "the width every
// forwarded frame is resized to"; `min_unit`/`max_unit` are bounds, which is a different question, so a
// writer that still says `unit` is not merely terse -- it is asking for something this reader no longer
// does. A same-named field whose meaning moved underneath it is a defect this repository has already paid
// for once (an unsigned field silently fed a float, in both directions, with no message anywhere), which is
// why the legacy key is not just ignored but reported below.
[[nodiscard]] inline std::optional<Range<int>> readFrameResizeBand(const json_util::Json &config_json) {
    const auto entry = config_json.find("frame_resize");
    if (entry == config_json.end()) {
        return std::nullopt;
    }
    if (!entry->is_object()) {
        log_warning("frame_resize is not an object; keeping the frame resize disabled");
        return std::nullopt;
    }
    // Warned about wherever it appears, including under `enabled: false`, because what it reports is not a
    // bad value but a writer still speaking the old schema -- which the `enabled` flag says nothing about.
    // The band still comes out of the keys this reader does understand; the warning exists so that a stale
    // writer is visible in the log instead of being silently normalized to the defaults.
    //
    // THIS WARNING IS AN ASSERTED OBSERVABLE, not only a diagnostic. A stale writer that names no bounds gets
    // the shipped defaults, so its RESULT is indistinguishable from a correct writer's and no record, count or
    // exit code can see the regression -- this line is the only thing that can. test/integration/run.py fails
    // any case whose run logs the `frame_resize` token (check_run step 5), which is what covers the key names
    // of the one writer no unit test links: core/cli.cpp. Keep the key spelled out in every warning below.
    if (entry->find("unit") != entry->end()) {
        log_warning(
            "frame_resize.unit is the pre-band key and is ignored; the resize target is now the "
            "frame_resize.min_unit / frame_resize.max_unit band");
    }
    bool enabled = false;
    const auto enabled_entry = entry->find("enabled");
    if (enabled_entry != entry->end()) {
        if (enabled_entry->is_boolean()) {
            enabled = enabled_entry->get<bool>();
        } else {
            log_warning("frame_resize.enabled is not a boolean; keeping the frame resize disabled");
        }
    }
    if (!enabled) {
        return std::nullopt;
    }
    int min_unit = kDefaultFrameResizeMinUnit;
    int max_unit = kDefaultFrameResizeMaxUnit;
    if (!readFrameResizeBound(*entry, "min_unit", min_unit) || !readFrameResizeBound(*entry, "max_unit", max_unit)) {
        return std::nullopt;
    }
    if (min_unit > max_unit) {
        // Range<int> would throw on this, which is exactly what this reader exists not to do: an inverted
        // band is a config typo, not a reason to refuse the capture session.
        log_warning("frame_resize.min_unit exceeds frame_resize.max_unit; keeping the frame resize disabled");
        return std::nullopt;
    }
    vlog_debug(min_unit, max_unit);
    return Range<int>{min_unit, max_unit};
}

}  // namespace uma::app
