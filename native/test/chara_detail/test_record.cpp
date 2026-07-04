// Behavioral tests for the RecordType axis predicates in chara_detail_record.h.
//
// isInheritanceOnly / isFriend split the four RecordType values into the two independent axes
// (content: full vs inheritance-only; owner: own vs friend) that downstream recognizer/scraper code
// branches on. They are pure enum logic -- no Frame, OpenCV, ONNX, or config -- so they are pinned
// here directly, without any of the recognizer stack.

#include <doctest/doctest.h>

#include "chara_detail/chara_detail_record.h"

namespace uma::chara_detail::record {
namespace {

TEST_CASE("isInheritanceOnly is true only for the inheritance-only content axis") {
    CHECK_FALSE(isInheritanceOnly(Standard));
    CHECK(isInheritanceOnly(InheritanceOnly));
    CHECK_FALSE(isInheritanceOnly(FriendStandard));
    CHECK(isInheritanceOnly(FriendInheritance));
}

TEST_CASE("isFriend is true only for the friend owner axis") {
    CHECK_FALSE(isFriend(Standard));
    CHECK_FALSE(isFriend(InheritanceOnly));
    CHECK(isFriend(FriendStandard));
    CHECK(isFriend(FriendInheritance));
}

TEST_CASE("the two axes are independent across all four record types") {
    // Every (content, owner) combination is represented exactly once, so the two predicates together
    // uniquely identify each RecordType. This is the invariant downstream code relies on when it tests
    // one axis without enumerating every combination.
    CHECK((!isInheritanceOnly(Standard) && !isFriend(Standard)));
    CHECK((isInheritanceOnly(InheritanceOnly) && !isFriend(InheritanceOnly)));
    CHECK((!isInheritanceOnly(FriendStandard) && isFriend(FriendStandard)));
    CHECK((isInheritanceOnly(FriendInheritance) && isFriend(FriendInheritance)));
}

}  // namespace
}  // namespace uma::chara_detail::record
