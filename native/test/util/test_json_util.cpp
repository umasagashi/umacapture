// Behavioral tests for json_util::trim.
//
// trim strips the leading/trailing underscores the EXTENDED_JSON macros wrap around member names
// (e.g. `min_` -> `min`), which is what maps a private field to its stable JSON key. A regression
// here would silently rename every serialized key, so the underscore-stripping edges are pinned.

#include <doctest/doctest.h>

#include <string>

#include "util/json_util.h"

namespace uma::json_util {
namespace {

TEST_CASE("trim removes surrounding underscores only") {
    CHECK(trim("___value___") == "value");
    CHECK(trim("_a_b_c_") == "a_b_c");  // interior underscores are kept
    CHECK(trim("value") == "value");  // nothing to strip
}

TEST_CASE("trim collapses an all-underscore or empty key to empty") {
    CHECK(trim("___").empty());
    CHECK(trim("").empty());
}

}  // namespace
}  // namespace uma::json_util
