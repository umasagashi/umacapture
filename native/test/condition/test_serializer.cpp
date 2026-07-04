// Characterization tests for the condition serializer.
//
// These lock the JSON serialization contract before the planned header/.cpp
// split: for every registered condition/rule pair, a condition tree must survive
// a toJson -> conditionFromJson -> toJson round-trip unchanged. This is the same
// invariant the CLI `build` subcommand asserts at runtime, captured here as a
// standalone regression test that does not require the game assets.

#include <doctest/doctest.h>

#include <memory>
#include <optional>
#include <vector>

#include "condition/basic_condition.h"
#include "condition/rule.h"
#include "condition/serializer.h"
#include "cv/frame.h"

namespace uma::condition {
namespace {

using json_util::Json;
using serializer::ConditionBase;

// Serializes the condition, rebuilds it from that JSON, and re-serializes. A
// stable serializer produces identical JSON on both passes.
void checkRoundTrip(const ConditionBase &condition) {
    const Json first = condition->toJson();
    const ConditionBase restored = serializer::conditionFromJson(first);
    const Json second = restored->toJson();
    CHECK(first == second);
}

ConditionBase alwaysTrue() {
    return std::make_shared<NullaryCondition<Frame, rule::AlwaysTrue>>(rule::AlwaysTrue{});
}

ConditionBase alwaysFalse() {
    return std::make_shared<NullaryCondition<Frame, rule::AlwaysFalse>>(rule::AlwaysFalse{});
}

TEST_CASE("nullary conditions round-trip") {
    checkRoundTrip(alwaysTrue());
    checkRoundTrip(alwaysFalse());
}

TEST_CASE("nested conditions round-trip") {
    SUBCASE("logical not") {
        checkRoundTrip(std::make_shared<NestedCondition<Frame, rule::LogicalNot>>(rule::LogicalNot{}, alwaysTrue()));
    }
    SUBCASE("stable preserves its threshold") {
        checkRoundTrip(std::make_shared<NestedCondition<Frame, rule::Stable>>(rule::Stable{500}, alwaysTrue()));
    }
}

TEST_CASE("parallel conditions round-trip") {
    const std::vector<ConditionBase> children{alwaysTrue(), alwaysFalse()};
    SUBCASE("logical and") {
        checkRoundTrip(std::make_shared<ParallelCondition<Frame, rule::LogicalAnd>>(rule::LogicalAnd{}, children));
    }
    SUBCASE("logical or") {
        checkRoundTrip(std::make_shared<ParallelCondition<Frame, rule::LogicalOr>>(rule::LogicalOr{}, children));
    }
}

TEST_CASE("nested trees round-trip") {
    const std::vector<ConditionBase> children{
        std::make_shared<NestedCondition<Frame, rule::Stable>>(rule::Stable{200}, alwaysTrue()),
        std::make_shared<NestedCondition<Frame, rule::LogicalNot>>(rule::LogicalNot{}, alwaysFalse()),
    };
    checkRoundTrip(std::make_shared<ParallelCondition<Frame, rule::LogicalAnd>>(rule::LogicalAnd{}, children));
}

TEST_CASE("named conditions preserve their tag") {
    const auto named = std::make_shared<NullaryCondition<Frame, rule::AlwaysTrue>>(
        rule::AlwaysTrue{}, std::optional<std::string>{"my_tag"});
    const Json json = named->toJson();
    CHECK(json.at("name").get<std::string>() == "my_tag");
    checkRoundTrip(named);
}

TEST_CASE("conditionFromJson rejects an unknown type") {
    const Json unknown = {{"type", "NoSuchCondition"}};
    CHECK_THROWS_AS(serializer::conditionFromJson(unknown), std::invalid_argument);
}

}  // namespace
}  // namespace uma::condition
