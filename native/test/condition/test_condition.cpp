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

// rule::Stable is the load-bearing debounce behind scene detection. It is exercised here at the rule level
// (driving state.now directly, exactly as NestedCondition::update does via state::setFrameTimestamp) so the
// threshold / reset / backward-clock semantics are pinned independently of any frame plumbing.

TEST_CASE("stable fires only after the threshold elapses in video time") {
    const rule::Stable stable{100};
    state::TimestampState st{};

    // First true starts the debounce window; nothing fires yet.
    st.now = 1000;
    CHECK_FALSE(stable.met(true, st));

    // Exactly at the threshold is not enough (the compare is strictly greater-than).
    st.now = 1100;
    CHECK_FALSE(stable.met(true, st));

    // One tick past the threshold fires.
    st.now = 1101;
    CHECK(stable.met(true, st));
}

TEST_CASE("stable restarts its window when the parent goes false") {
    const rule::Stable stable{100};
    state::TimestampState st{};

    st.now = 1000;
    CHECK_FALSE(stable.met(true, st));
    st.now = 1200;
    CHECK(stable.met(true, st));  // elapsed 200 > 100

    // Parent drops: the window resets.
    st.now = 1300;
    CHECK_FALSE(stable.met(false, st));

    // Parent true again: the debounce starts over from this frame (1350), so an immediate check must not fire.
    st.now = 1350;
    CHECK_FALSE(stable.met(true, st));  // elapsed 0 at restart
    st.now = 1400;
    CHECK_FALSE(stable.met(true, st));  // elapsed 50 from the restart
    st.now = 1500;
    CHECK(stable.met(true, st));  // elapsed 150 from the restart
}

TEST_CASE("stable does not fire instantly when the clock steps backward") {
    const rule::Stable stable{100};
    state::TimestampState st{};

    st.now = 5000;
    CHECK_FALSE(stable.met(true, st));  // window starts at 5000

    // Clock steps backward below `since`: monotonicElapsed restarts the window rather than wrapping the
    // unsigned subtraction to a huge elapsed, so this must not fire.
    st.now = 1000;
    CHECK_FALSE(stable.met(true, st));

    // From the restarted window at 1000, the threshold must elapse again before firing.
    st.now = 1050;
    CHECK_FALSE(stable.met(true, st));
    st.now = 1200;
    CHECK(stable.met(true, st));
}

}  // namespace
}  // namespace uma::condition
