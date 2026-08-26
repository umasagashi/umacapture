#pragma once

// The token paneCopyPlan hands to JavaScript and pushFrameRgba demands back (native/wasm/wasm_api.cpp).
//
// WHY IT IS NOT JUST THE GENERATION. A producer must carry the pane decision it was planned against across its
// asynchronous pixel copy, and PaneModeLatch admits TWO kinds of change to that decision: release() bumps the
// generation (cv/pane_mode_latch.h), but latch() installs a rectangle WITHOUT bumping it. The null -> latched
// transition therefore keeps the generation, and it is attempted exactly once per capture session (every
// session resets the calibration first). A generation-only token cannot see it, so that entirely benign
// transition used to reach the "the caller copied something other than its plan" branch and be reported to the
// user as a capture failure -- while its sibling, a release/relatch, was silently dropped as the expected
// outcome of a copy that takes time. Encoding the rectangle as well as the generation makes the token identify
// the whole latch decision, which is what the frame was planned against, so both changes drop silently and the
// remaining loud branch really does mean a caller that disobeyed its plan.
//
// The token deliberately does NOT encode Snapshot::captured_size: that field is the caller's own argument
// echoed back, not latch state, so it cannot change under the copy. Everything the caller itself chose (the
// copied origin and the buffer's dimensions) is validated against the re-derived plan instead, where a
// disagreement is a real defect and stays loud.
//
// Kept as a pure, header-only codec with no Emscripten dependency -- for the same reason
// core/frame_shaping.h keeps encodeGeneration/decodeGeneration pure: nothing under native/wasm/ is compiled by
// any test suite, so the wire contract is only testable if it can be included from a desktop TU
// (native/test/wasm/test_pane_snapshot_token.cpp).

#include <array>
#include <cstddef>
#include <exception>
#include <optional>
#include <string>

#include "core/frame_shaping.h"
#include "cv/pane_mode_latch.h"
#include "types/shape.h"

namespace uma::wasm {

namespace pane_snapshot_token_impl {

// Canonical decimal int, with the same round-trip strictness frame_shaping::decodeGeneration applies to the
// generation: parse, re-encode, and demand the exact original spelling. That rejects every alias std::stoi
// would otherwise accept ("+1", " 1", "01") without enumerating them.
[[nodiscard]] inline std::optional<int> decodeInt(const std::string &encoded) {
    if (encoded.empty()) {
        return std::nullopt;
    }
    int value = 0;
    std::size_t consumed = 0;
    try {
        value = std::stoi(encoded, &consumed);
    } catch (const std::exception &) {
        return std::nullopt;
    }
    if (consumed != encoded.size() || std::to_string(value) != encoded) {
        return std::nullopt;
    }
    return value;
}

}  // namespace pane_snapshot_token_impl

// The decoded token: the two parts of a PaneModeLatch::Snapshot the latch itself can change.
struct PaneSnapshotToken {
    PaneModeLatch::Generation generation = 0;
    std::optional<Rect<int>> rect;

    [[nodiscard]] bool operator==(const PaneSnapshotToken &other) const {
        return generation == other.generation && rect == other.rect;
    }
};

// "<generation>" when nothing is latched, "<generation>:<x>,<y>,<width>,<height>" when something is.
// A decimal string preserves all 64 generation bits across JS; a Number would alias generations above 2^53.
[[nodiscard]] inline std::string encodePaneSnapshotToken(const PaneModeLatch::Snapshot &snapshot) {
    const std::string generation = app::frame_shaping::encodeGeneration(snapshot.generation);
    if (!snapshot.rect.has_value()) {
        return generation;
    }
    const auto &rect = snapshot.rect.value();
    return generation + ":" + std::to_string(rect.left()) + "," + std::to_string(rect.top()) + ","
           + std::to_string(rect.width()) + "," + std::to_string(rect.height());
}

// nullopt means the string is not a token this module ever issued -- a caller defect, not a stale frame, and
// the one thing on this path that deserves to be reported.
[[nodiscard]] inline std::optional<PaneSnapshotToken> decodePaneSnapshotToken(const std::string &encoded) {
    const std::size_t separator = encoded.find(':');
    const auto generation = app::frame_shaping::decodeGeneration(encoded.substr(0, separator));
    if (!generation.has_value()) {
        return std::nullopt;
    }
    if (separator == std::string::npos) {
        return PaneSnapshotToken{generation.value(), std::nullopt};
    }
    std::array<int, 4> fields{};
    std::size_t begin = separator + 1;
    for (std::size_t i = 0; i < fields.size(); ++i) {
        const bool last = i + 1 == fields.size();
        const std::size_t end = last ? std::string::npos : encoded.find(',', begin);
        if (!last && end == std::string::npos) {
            return std::nullopt;
        }
        // The last field takes the whole remainder, so a fifth field ("1:0,0,2,2,9") leaves a comma inside it
        // and decodeInt rejects it: exactly four fields, never more.
        const auto value = pane_snapshot_token_impl::decodeInt(
            last ? encoded.substr(begin) : encoded.substr(begin, end - begin));
        if (!value.has_value()) {
            return std::nullopt;
        }
        fields[i] = value.value();
        begin = last ? begin : end + 1;
    }
    return PaneSnapshotToken{
        generation.value(), Rect<int>{Point<int>{fields[0], fields[1]}, Size<int>{fields[2], fields[3]}}};
}

// Whether the frame planned against `token` still belongs to the latch decision `snapshot` reports. A false
// here is a STALE frame (release, relatch, or the once-per-session null -> latch), which is an expected
// outcome of a copy that takes time and must be dropped in silence.
[[nodiscard]] inline bool paneSnapshotTokenMatches(
    const PaneSnapshotToken &token, const PaneModeLatch::Snapshot &snapshot) {
    return token == PaneSnapshotToken{snapshot.generation, snapshot.rect};
}

}  // namespace uma::wasm
