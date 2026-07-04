// Behavioral tests for the STL-algorithm wrappers.
//
// These thin helpers underpin the condition/frame logic (any_of/all_of drive the line sampling,
// find_transformed_if the builder lookups). The tests pin the vacuous-truth edges (empty AND is
// true, empty OR is false), the empty-prefix rule of starts_with, and the map-then-find contract.

#include <doctest/doctest.h>

#include <array>
#include <optional>
#include <string>
#include <vector>

#include "util/stds.h"

namespace uma::stds {
namespace {

TEST_CASE("starts_with checks a prefix without allocating") {
    CHECK(starts_with("hello", "he"));
    CHECK(starts_with("hello", "hello"));  // a full match is a prefix
    CHECK(starts_with("hello", ""));  // the empty prefix matches anything
    CHECK_FALSE(starts_with("hello", "world"));
    CHECK_FALSE(starts_with("", "hello"));  // a longer query cannot be a prefix
}

TEST_CASE("all_of / any_of fold to their logical identity on an empty range") {
    const std::array<bool, 0> none{};
    CHECK(all_of(none));  // AND over nothing is vacuously true
    CHECK_FALSE(any_of(none));  // OR over nothing is false

    const std::array<bool, 3> mixed{true, false, true};
    CHECK_FALSE(all_of(mixed));
    CHECK(any_of(mixed));

    const std::array<bool, 3> all_true{true, true, true};
    CHECK(all_of(all_true));

    const std::array<bool, 3> all_false{false, false, false};
    CHECK_FALSE(any_of(all_false));
}

TEST_CASE("find_transformed_if returns the first mapped value matching the predicate") {
    const std::vector<int> values{1, 2, 3, 4, 5, 6};
    const auto doubled = [](int v) { return v * 2; };

    const std::optional<int> found = find_transformed_if(values, doubled, [](int v) { return v > 10; });
    CHECK(found.has_value());
    CHECK(*found == 12);  // 6 * 2, the first mapped value above 10

    CHECK_FALSE(find_transformed_if(values, doubled, [](int v) { return v > 100; }).has_value());

    const std::vector<int> empty;
    CHECK_FALSE(find_transformed_if(empty, doubled, [](int v) { return v > 0; }).has_value());
}

TEST_CASE("slice copies a compile-time sub-range") {
    const std::array<int, 5> source{10, 20, 30, 40, 50};

    const auto head = slice<0, 3>(source);
    CHECK(head.size() == 3);
    CHECK(head[0] == 10);
    CHECK(head[2] == 30);

    const auto empty = slice<2, 2>(source);  // a zero-width slice is valid
    CHECK(empty.size() == 0);
    // slice<0, 6>(source) would be a static_assert failure (end must be <= the array size).
}

}  // namespace
}  // namespace uma::stds
