#pragma once

#include <charconv>
#include <cmath>
#include <optional>
#include <string>

namespace uma::mimic {

// Strict numeric parsing for the control channel's arguments.
//
// WHY NOT atoi/atof. Both report failure by returning 0, which is indistinguishable from a real 0 --
// and 0 is a legal frame index and a legal timestamp, so a mistyped argument does not fail, it names
// a DIFFERENT FRAME and the reply says `ok`. `pause-at sec=2,44` (a comma where the decimal point
// belongs), a shell variable that collapsed to nothing, `step abc`: each of them used to arm or
// perform something the caller did not ask for, and the harness, which blocks on the reply, saw
// success. A breakpoint exists precisely so that the frame it stops on is exact by construction, so
// a spec that does not parse has to be an error and never a different frame.
//
// The integer branch did carry a guard (`frame == 0 && spec[0] != '0'`), but it inspected the first
// character instead of the parse, so it covered only that one branch and only that one shape of
// failure; the seconds branch had none at all. These two functions replace both by asking the parser
// itself whether it consumed the WHOLE token.
//
// std::from_chars is used for exactly that: it reports the first unconsumed character, it is
// locale-independent (so a decimal comma is rejected wherever the process runs), and it accepts
// neither leading whitespace nor a leading '+' nor a 0x prefix. Tokens reach here already split on
// whitespace, so nothing legitimate is lost.

// A base-10 integer, and nothing else in the token. Returns nullopt on any trailing character, on an
// empty token, and on a value that does not fit an int.
[[nodiscard]] inline std::optional<int> parseWholeInt(const std::string &text) {
    int value = 0;
    const char *const begin = text.data();
    const char *const end = begin + text.size();
    const auto result = std::from_chars(begin, end, value, 10);
    if (result.ec != std::errc{} || result.ptr != end) {
        return std::nullopt;
    }
    return value;
}

// A decimal number, and nothing else in the token. Non-finite spellings ("inf", "nan") parse under
// from_chars' general format but are not times, and would make every downstream comparison false, so
// they are rejected here rather than turned into a frame index.
[[nodiscard]] inline std::optional<double> parseWholeDouble(const std::string &text) {
    double value = 0.0;
    const char *const begin = text.data();
    const char *const end = begin + text.size();
    const auto result = std::from_chars(begin, end, value);
    if (result.ec != std::errc{} || result.ptr != end || !std::isfinite(value)) {
        return std::nullopt;
    }
    return value;
}

}  // namespace uma::mimic
