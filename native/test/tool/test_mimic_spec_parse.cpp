// Tests for the mimic player's strict argument parsing (tool/mimic_player/spec_parse.h).
//
// WHAT THIS PINS. The control channel's whole selling point is that the frame a `pause-at` stops on
// is exact by construction: the harness blocks on the reply and takes `ok` as the answer. With
// std::atof / std::atoi, a token that is not a number came back as 0.0 / 0 -- a legal timestamp and a
// legal frame index -- so `pause-at sec=2,44` (a decimal comma), a shell variable that collapsed to
// nothing, or `step abc` armed or performed something the caller never asked for AND reported
// success. The bug is not that garbage was accepted; it is that garbage was accepted AS FRAME ZERO.
//
// So each negative case below asserts nullopt specifically, and the two "was zero" cases below say
// so in their names: they are exactly the inputs the old failure value made indistinguishable from a
// deliberate 0.

#include <doctest/doctest.h>

#include <string>

#include "tool/mimic_player/spec_parse.h"

namespace uma::mimic {
namespace {

TEST_CASE("parseWholeInt accepts a whole base-10 integer") {
    CHECK(parseWholeInt("0") == 0);
    CHECK(parseWholeInt("62") == 62);
    CHECK(parseWholeInt("-3") == -3);
}

TEST_CASE("parseWholeInt rejects what atoi used to turn into zero") {
    CHECK_FALSE(parseWholeInt("abc").has_value());  // atoi: 0
    CHECK_FALSE(parseWholeInt("").has_value());  // an argument that collapsed to nothing; atoi: 0
    CHECK_FALSE(parseWholeInt("2,44").has_value());  // atoi: 2, silently truncated at the comma
    CHECK_FALSE(parseWholeInt("12x").has_value());  // atoi: 12, trailing junk ignored
    CHECK_FALSE(parseWholeInt("1.5").has_value());  // atoi: 1, a seconds spec written without sec=
    CHECK_FALSE(parseWholeInt(" 5").has_value());  // leading whitespace is not part of a token here
    CHECK_FALSE(parseWholeInt("+5").has_value());
}

TEST_CASE("parseWholeInt rejects a value too large for an int instead of wrapping") {
    CHECK_FALSE(parseWholeInt("99999999999999999999").has_value());
}

TEST_CASE("parseWholeDouble accepts a whole decimal number") {
    REQUIRE(parseWholeDouble("2.44").has_value());
    CHECK(parseWholeDouble("2.44").value() == doctest::Approx(2.44));
    REQUIRE(parseWholeDouble("0").has_value());
    CHECK(parseWholeDouble("0").value() == doctest::Approx(0.0));
    REQUIRE(parseWholeDouble("62").has_value());
    CHECK(parseWholeDouble("62").value() == doctest::Approx(62.0));
    REQUIRE(parseWholeDouble("-0.5").has_value());
    CHECK(parseWholeDouble("-0.5").value() == doctest::Approx(-0.5));
}

// The named reachable input from the finding: a decimal comma. atof stops at the comma and returns
// 2.0 -- a perfectly ordinary timestamp, two frames' worth away from what was meant.
TEST_CASE("parseWholeDouble rejects a decimal comma rather than truncating at it") {
    CHECK_FALSE(parseWholeDouble("2,44").has_value());
}

TEST_CASE("parseWholeDouble rejects what atof used to turn into zero") {
    CHECK_FALSE(parseWholeDouble("abc").has_value());  // atof: 0.0, i.e. frame 0
    CHECK_FALSE(parseWholeDouble("").has_value());  // `sec=` with nothing after it; atof: 0.0
    CHECK_FALSE(parseWholeDouble(" 2.44").has_value());
}

TEST_CASE("parseWholeDouble rejects trailing junk") {
    CHECK_FALSE(parseWholeDouble("1.5s").has_value());
    CHECK_FALSE(parseWholeDouble("2.44.5").has_value());
}

// from_chars' general format does parse these; they are not times, and every comparison against a
// NaN is false, so a nearest-frame search over one has no defined answer at all.
TEST_CASE("parseWholeDouble rejects the non-finite spellings") {
    CHECK_FALSE(parseWholeDouble("nan").has_value());
    CHECK_FALSE(parseWholeDouble("inf").has_value());
    CHECK_FALSE(parseWholeDouble("-inf").has_value());
}

}  // namespace
}  // namespace uma::mimic
