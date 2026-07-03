// Behavioral tests for the condition evaluation logic.
//
// Conditions are the state machine that drives scene detection. These tests pin
// the boolean semantics of the composable rules (nullary / nested / parallel)
// independently of any on-screen pixels, using the input-agnostic AlwaysTrue and
// AlwaysFalse leaves as fixtures.

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

using serializer::ConditionBase;

ConditionBase alwaysTrue() {
    return std::make_shared<NullaryCondition<Frame, rule::AlwaysTrue>>(rule::AlwaysTrue{});
}

ConditionBase alwaysFalse() {
    return std::make_shared<NullaryCondition<Frame, rule::AlwaysFalse>>(rule::AlwaysFalse{});
}

// Feeds one frame through the tree and reports whether the root condition is met.
bool evaluate(const ConditionBase &condition) {
    condition->update(Frame{});
    return condition->met();
}

TEST_CASE("nullary conditions ignore the input") {
    CHECK(evaluate(alwaysTrue()));
    CHECK_FALSE(evaluate(alwaysFalse()));
}

TEST_CASE("logical not inverts its child") {
    CHECK_FALSE(evaluate(std::make_shared<NestedCondition<Frame, rule::LogicalNot>>(rule::LogicalNot{}, alwaysTrue())));
    CHECK(evaluate(std::make_shared<NestedCondition<Frame, rule::LogicalNot>>(rule::LogicalNot{}, alwaysFalse())));
}

TEST_CASE("logical and is true only when every child is met") {
    CHECK(evaluate(std::make_shared<ParallelCondition<Frame, rule::LogicalAnd>>(
        rule::LogicalAnd{}, std::vector<ConditionBase>{alwaysTrue(), alwaysTrue()})));
    CHECK_FALSE(evaluate(std::make_shared<ParallelCondition<Frame, rule::LogicalAnd>>(
        rule::LogicalAnd{}, std::vector<ConditionBase>{alwaysTrue(), alwaysFalse()})));
}

TEST_CASE("logical or is true when any child is met") {
    CHECK(evaluate(std::make_shared<ParallelCondition<Frame, rule::LogicalOr>>(
        rule::LogicalOr{}, std::vector<ConditionBase>{alwaysTrue(), alwaysFalse()})));
    CHECK_FALSE(evaluate(std::make_shared<ParallelCondition<Frame, rule::LogicalOr>>(
        rule::LogicalOr{}, std::vector<ConditionBase>{alwaysFalse(), alwaysFalse()})));
}

TEST_CASE("empty parallel folds to its logical identity") {
    // AND over no operands is vacuously true; OR over no operands is false.
    CHECK(evaluate(
        std::make_shared<ParallelCondition<Frame, rule::LogicalAnd>>(rule::LogicalAnd{}, std::vector<ConditionBase>{})));
    CHECK_FALSE(evaluate(
        std::make_shared<ParallelCondition<Frame, rule::LogicalOr>>(rule::LogicalOr{}, std::vector<ConditionBase>{})));
}

TEST_CASE("findByTag locates a nested condition by name") {
    const auto leaf = std::make_shared<NullaryCondition<Frame, rule::AlwaysTrue>>(
        rule::AlwaysTrue{}, std::optional<std::string>{"leaf"});
    const auto root = std::make_shared<NestedCondition<Frame, rule::LogicalNot>>(rule::LogicalNot{}, leaf);
    CHECK(root->findByTag("leaf") == leaf.get());
    CHECK(root->findByTag("missing") == nullptr);
}

}  // namespace
}  // namespace uma::condition
