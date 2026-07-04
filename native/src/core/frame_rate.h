#pragma once

#include <chrono>
#include <cstddef>

#include "util/misc.h"

// Pure frame-rate arithmetic split out of NativeApi's lap-time listener so it can be unit-tested without
// linking the ONNX/WinRT-heavy NativeApi translation unit (same rationale as native_api_messages.h).
//
// NativeApi accumulates frame timestamps into a buffer and, once the buffer spans more than the reporting
// window, reports the observed rate and clears the buffer. The rate is the sample count scaled by the
// reporting window over the actual span the samples cover; keeping it here isolates that ratio from the
// event wiring.
namespace uma::app {

// Frames per second implied by `sample_count` timestamps covering `span`, expressed on the `report_interval`
// window (i.e. count * report_interval / span, so the result is samples-per-report-window normalized to a
// per-interval rate). Returns 0.0 when `span` is non-positive, guarding the division; NativeApi only reports
// once span exceeds report_interval, but the pure function stays defined at the degenerate edge.
[[nodiscard]] inline double frameRate(
    std::chrono::milliseconds report_interval, std::size_t sample_count, std::chrono::steady_clock::duration span) {
    const auto span_ms = chrono_util::ms(span);
    if (span_ms <= 0) {
        return 0.0;
    }
    return static_cast<double>(chrono_util::ms(report_interval) * sample_count) / static_cast<double>(span_ms);
}

}  // namespace uma::app
