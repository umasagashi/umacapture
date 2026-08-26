// Contract test for the pane snapshot token the Wasm producer carries across its asynchronous pixel copy
// (native/wasm/pane_snapshot_token.h). Nothing else under native/wasm/ is compiled by any suite; the codec is
// deliberately Emscripten-free so this desktop TU can pin the wire contract, and in particular the ONE
// distinction the token exists to make: a benign latch change is stale (silent), a malformed token is not.

#include <doctest/doctest.h>

#include <optional>
#include <string>

#include "cv/pane_mode_latch.h"
#include "types/shape.h"
#include "wasm/pane_snapshot_token.h"

namespace uma::wasm {

namespace {

PaneModeLatch::Snapshot snapshotOf(
    const PaneModeLatch::Generation generation, const std::optional<Rect<int>> &rect) {
    return {Size<int>{640, 480}, generation, rect};
}

const Rect<int> kPane{Point<int>{10, 20}, Size<int>{200, 100}};

TEST_CASE("the token spells the generation alone when nothing is latched") {
    CHECK(encodePaneSnapshotToken(snapshotOf(0, std::nullopt)) == "0");
    CHECK(encodePaneSnapshotToken(snapshotOf(7, std::nullopt)) == "7");
}

TEST_CASE("the token spells the latched rectangle as well as the generation") {
    CHECK(encodePaneSnapshotToken(snapshotOf(7, kPane)) == "7:10,20,200,100");
}

TEST_CASE("the token round trips") {
    for (const auto &snapshot : {snapshotOf(0, std::nullopt), snapshotOf(18446744073709551615ULL, kPane)}) {
        const auto decoded = decodePaneSnapshotToken(encodePaneSnapshotToken(snapshot));
        REQUIRE(decoded.has_value());
        CHECK(paneSnapshotTokenMatches(decoded.value(), snapshot));
    }
}

// THE DEFECT THIS FILE EXISTS FOR. PaneModeLatch::latch() installs a rectangle WITHOUT bumping the generation,
// so the once-per-session null -> latch transition keeps it. A generation-only token cannot see that change,
// and pushFrameRgba then reported the frame as a capture failure (error chime + failure banner) instead of
// dropping it as stale.
TEST_CASE("a same-generation null -> latch is a token mismatch, exactly like a release") {
    const auto issued = decodePaneSnapshotToken(encodePaneSnapshotToken(snapshotOf(3, std::nullopt)));
    REQUIRE(issued.has_value());
    CHECK(paneSnapshotTokenMatches(issued.value(), snapshotOf(3, std::nullopt)));
    // Latched during the copy, at the same generation.
    CHECK_FALSE(paneSnapshotTokenMatches(issued.value(), snapshotOf(3, kPane)));
    // Released during the copy: the generation moved, and this was already detected before.
    CHECK_FALSE(paneSnapshotTokenMatches(issued.value(), snapshotOf(4, std::nullopt)));
}

TEST_CASE("a same-generation relatch of a moved rectangle is a token mismatch") {
    const auto issued = decodePaneSnapshotToken(encodePaneSnapshotToken(snapshotOf(3, kPane)));
    REQUIRE(issued.has_value());
    CHECK(paneSnapshotTokenMatches(issued.value(), snapshotOf(3, kPane)));
    const Rect<int> moved{Point<int>{12, 20}, kPane.size()};
    const Rect<int> resized{kPane.topLeft(), Size<int>{200, 101}};
    CHECK_FALSE(paneSnapshotTokenMatches(issued.value(), snapshotOf(3, moved)));
    CHECK_FALSE(paneSnapshotTokenMatches(issued.value(), snapshotOf(3, resized)));
    CHECK_FALSE(paneSnapshotTokenMatches(issued.value(), snapshotOf(3, std::nullopt)));
}

// A token the module never issued must stay distinguishable from a stale one: pushFrameRgba reports it, and
// silently dropping it instead would make a broken transport look like a session that simply sees no frames.
TEST_CASE("a malformed token is rejected rather than treated as stale") {
    for (const auto &encoded : {
             "",         "  7",      "+7",     "07",       "7abc",    "7:",       ":10,20,200,100",
             "7:10,20",  "7:10,20,200",        "7:10,20,200,100,9",   "7:10,20,200,10a",
             "7:10,20,200,+100",     "7:,20,200,100",      "7,10",    "-1:10,20,200,100",
         }) {
        CHECK_FALSE(decodePaneSnapshotToken(encoded).has_value());
    }
}

TEST_CASE("a negative rectangle field is legal syntax, so it decodes and simply does not match") {
    const auto decoded = decodePaneSnapshotToken("7:-10,20,200,100");
    REQUIRE(decoded.has_value());
    CHECK_FALSE(paneSnapshotTokenMatches(decoded.value(), snapshotOf(7, kPane)));
    CHECK(paneSnapshotTokenMatches(
        decoded.value(), snapshotOf(7, Rect<int>{Point<int>{-10, 20}, Size<int>{200, 100}})));
}

}  // namespace

}  // namespace uma::wasm
