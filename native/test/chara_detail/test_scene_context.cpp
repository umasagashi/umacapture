// Behavioral tests for the CharaDetailSceneContext state machine.
//
// This is the scene-detection state machine: it watches a condition tree, resolves which tab page and
// record type are active, and drives the begin / update / end lifecycle with debounces keyed off frame
// timestamps (video time), not the wall clock. These tests build a minimal, tagged condition tree whose
// leaves are toggled through injected flags, feed frames carrying explicit timestamps, and capture the
// emitted begin/update/end events through direct (synchronous) connections. Frame content is irrelevant
// here -- only the timestamp is consumed by the debounces -- so the frames are 2x2 dummies.

#include <doctest/doctest.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "chara_detail/chara_detail_record.h"
#include "chara_detail/chara_detail_scene_context.h"
#include "condition/basic_condition.h"
#include "condition/condition.h"
#include "condition/rule.h"
#include "cv/frame.h"
#include "util/event_util.h"
#include "util/json_util.h"
#include "util/misc.h"

namespace uma::chara_detail {
namespace {

using ConditionBase = std::shared_ptr<condition::Condition<Frame>>;

// A leaf rule whose met() reads an external flag, so a test can flip a branch on and off between frames.
// NullaryCondition instantiates the class's (virtual) toJson, which needs a to_json for the rule; the
// NO_ARGS serializer supplies an empty one (the flag is never serialized).
class Toggle : public rule::Rule<input::None, state::Empty> {
public:
    explicit Toggle(std::shared_ptr<bool> flag)
        : flag(std::move(flag)) {}

    [[nodiscard]] bool met(const input::None &, state::Empty &) const override { return *flag; }

    EXTENDED_JSON_TYPE_NO_ARGS_DC(Toggle);

private:
    std::shared_ptr<bool> flag;
};

ConditionBase toggleBranch(const std::string &tag, const std::shared_ptr<bool> &flag) {
    return std::make_shared<condition::NullaryCondition<Frame, Toggle>>(Toggle{flag}, std::optional<std::string>{tag});
}

// The set of branch flags for a full tree. All start false (nothing met).
struct Flags {
    std::shared_ptr<bool> skill = std::make_shared<bool>(false);
    std::shared_ptr<bool> factor = std::make_shared<bool>(false);
    std::shared_ptr<bool> campaign = std::make_shared<bool>(false);
    std::shared_ptr<bool> standard = std::make_shared<bool>(false);
    std::shared_ptr<bool> inheritance_only = std::make_shared<bool>(false);
    std::shared_ptr<bool> friend_standard = std::make_shared<bool>(false);
    std::shared_ptr<bool> friend_inheritance = std::make_shared<bool>(false);
};

// Builds the tab_page + record_type tagged tree the scene context expects: two LogicalOr branch sets
// (named "tab_page" / "record_type") joined under a LogicalAnd root, mirroring the builder's structure.
ConditionBase buildTree(const Flags &f) {
    std::vector<ConditionBase> tabs{
        toggleBranch(tabPageTag(SkillPage), f.skill),
        toggleBranch(tabPageTag(FactorPage), f.factor),
        toggleBranch(tabPageTag(CampaignPage), f.campaign),
    };
    auto tab_page = std::make_shared<TabCondition>(rule::LogicalOr{}, tabs, std::optional<std::string>{"tab_page"});

    std::vector<ConditionBase> records{
        toggleBranch(record::recordTypeTag(record::Standard), f.standard),
        toggleBranch(record::recordTypeTag(record::InheritanceOnly), f.inheritance_only),
        toggleBranch(record::recordTypeTag(record::FriendStandard), f.friend_standard),
        toggleBranch(record::recordTypeTag(record::FriendInheritance), f.friend_inheritance),
    };
    auto record_type =
        std::make_shared<TabCondition>(rule::LogicalOr{}, records, std::optional<std::string>{"record_type"});

    return std::make_shared<condition::ParallelCondition<Frame, rule::LogicalAnd>>(
        rule::LogicalAnd{}, std::vector<ConditionBase>{tab_page, record_type});
}

// A dummy frame carrying a specific video timestamp; the scene-context debounces key off this value.
Frame frameAt(std::uint64_t timestamp) {
    static const cv::Mat pixels(2, 2, CV_8UC3, cv::Scalar(0, 0, 0));
    return Frame(pixels, timestamp);
}

// Captures the three lifecycle event streams via synchronous direct connections.
struct Captured {
    event_util::Connection<SceneInfo> begin = event_util::makeDirectConnection<SceneInfo>();
    event_util::Connection<Frame, SceneState> updated = event_util::makeDirectConnection<Frame, SceneState>();
    event_util::Connection<> end = event_util::makeDirectConnection<>();

    std::vector<record::RecordType> begins;
    std::vector<SceneState> updates;
    int ends = 0;

    Captured() {
        begin->listen([this](const SceneInfo &info) { begins.push_back(info.record_type); });
        updated->listen([this](const Frame &, const SceneState &state) { updates.push_back(state); });
        end->listen([this]() { ends++; });
    }
};

constexpr auto kZero = chrono_util::time_unit::zero();

chrono_util::time_unit ms(int value) {
    return chrono_util::time_unit(value);
}

TEST_CASE("ctor throws when the tab_page condition is missing") {
    Captured cap;
    const ConditionBase bad = std::make_shared<condition::NullaryCondition<Frame, rule::AlwaysTrue>>(rule::AlwaysTrue{});
    CHECK_THROWS_AS(
        CharaDetailSceneContext(bad, cap.begin, cap.updated, cap.end, kZero, kZero), std::runtime_error);
}

TEST_CASE("ctor throws when a branch count does not match the enum") {
    Captured cap;
    Flags f;
    std::vector<ConditionBase> tabs{
        toggleBranch(tabPageTag(SkillPage), f.skill),
        toggleBranch(tabPageTag(FactorPage), f.factor),
        toggleBranch(tabPageTag(CampaignPage), f.campaign),
    };
    auto tab_page = std::make_shared<TabCondition>(rule::LogicalOr{}, tabs, std::optional<std::string>{"tab_page"});

    // Only three record-type branches (should be four).
    std::vector<ConditionBase> records{
        toggleBranch(record::recordTypeTag(record::Standard), f.standard),
        toggleBranch(record::recordTypeTag(record::InheritanceOnly), f.inheritance_only),
        toggleBranch(record::recordTypeTag(record::FriendStandard), f.friend_standard),
    };
    auto record_type =
        std::make_shared<TabCondition>(rule::LogicalOr{}, records, std::optional<std::string>{"record_type"});
    const ConditionBase root = std::make_shared<condition::ParallelCondition<Frame, rule::LogicalAnd>>(
        rule::LogicalAnd{}, std::vector<ConditionBase>{tab_page, record_type});

    CHECK_THROWS_AS(
        CharaDetailSceneContext(root, cap.begin, cap.updated, cap.end, kZero, kZero), std::runtime_error);
}

TEST_CASE("ctor throws when a branch tag does not match its enum value") {
    Captured cap;
    Flags f;
    std::vector<ConditionBase> tabs{
        toggleBranch(tabPageTag(SkillPage), f.skill),
        toggleBranch("tab_page.Misnamed", f.factor),  // wrong tag: count is right but lookup fails
        toggleBranch(tabPageTag(CampaignPage), f.campaign),
    };
    auto tab_page = std::make_shared<TabCondition>(rule::LogicalOr{}, tabs, std::optional<std::string>{"tab_page"});
    std::vector<ConditionBase> records{
        toggleBranch(record::recordTypeTag(record::Standard), f.standard),
        toggleBranch(record::recordTypeTag(record::InheritanceOnly), f.inheritance_only),
        toggleBranch(record::recordTypeTag(record::FriendStandard), f.friend_standard),
        toggleBranch(record::recordTypeTag(record::FriendInheritance), f.friend_inheritance),
    };
    auto record_type =
        std::make_shared<TabCondition>(rule::LogicalOr{}, records, std::optional<std::string>{"record_type"});
    const ConditionBase root = std::make_shared<condition::ParallelCondition<Frame, rule::LogicalAnd>>(
        rule::LogicalAnd{}, std::vector<ConditionBase>{tab_page, record_type});

    CHECK_THROWS_AS(
        CharaDetailSceneContext(root, cap.begin, cap.updated, cap.end, kZero, kZero), std::runtime_error);
}

TEST_CASE("zero begin timeout begins immediately and resolves tab/record by firstMet order") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.campaign = true;  // two tabs met -> Factor wins (lower enum value)
    *f.standard = true;
    *f.inheritance_only = true;  // two record types met -> Standard wins
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, kZero, kZero);

    ctx.update(frameAt(1));

    CHECK(ctx.met());
    REQUIRE(cap.begins.size() == 1);
    CHECK(cap.begins[0] == record::Standard);
    REQUIRE(cap.updates.size() == 1);
    CHECK(cap.updates[0].tab_page == FactorPage);
    CHECK(cap.updates[0].record_type == record::Standard);
    CHECK(cap.ends == 0);
}

TEST_CASE("begin debounce commits only after the record_type persists past the timeout") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, ms(100), kZero);

    ctx.update(frameAt(0));  // window starts
    CHECK(cap.begins.empty());
    ctx.update(frameAt(50));  // 50 <= 100
    CHECK(cap.begins.empty());
    ctx.update(frameAt(150));  // 150 > 100 -> commit
    REQUIRE(cap.begins.size() == 1);
    CHECK(cap.begins[0] == record::Standard);
}

TEST_CASE("begin debounce restarts when the record_type changes mid-window") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, ms(100), kZero);

    ctx.update(frameAt(0));  // pending Standard @0
    *f.standard = false;
    *f.inheritance_only = true;  // switch record type
    ctx.update(frameAt(50));  // window restarts @50 for InheritanceOnly
    ctx.update(frameAt(120));  // elapsed 70 from restart -> no commit (would be >100 from the original @0)
    CHECK(cap.begins.empty());
    ctx.update(frameAt(160));  // elapsed 110 from restart -> commit
    REQUIRE(cap.begins.size() == 1);
    CHECK(cap.begins[0] == record::InheritanceOnly);
}

TEST_CASE("begin debounce resets when the scene stops being met") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, ms(100), kZero);

    ctx.update(frameAt(0));  // pending @0
    *f.factor = false;  // scene no longer met
    ctx.update(frameAt(50));  // drop clears the pending window
    *f.factor = true;
    ctx.update(frameAt(80));  // pending restarts @80
    ctx.update(frameAt(150));  // elapsed 70 from restart -> no commit
    CHECK(cap.begins.empty());
}

TEST_CASE("scene updates are withheld until the begin debounce commits") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, ms(100), kZero);

    ctx.update(frameAt(0));  // pending
    ctx.update(frameAt(50));  // pending
    CHECK(cap.updates.empty());
    ctx.update(frameAt(150));  // commit + first update
    CHECK(cap.begins.size() == 1);
    CHECK(cap.updates.size() == 1);
}

TEST_CASE("end debounce closes the scene only after the timeout of missing frames") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, kZero, ms(100));

    ctx.update(frameAt(0));  // begins immediately
    REQUIRE(cap.begins.size() == 1);
    *f.factor = false;  // scene drops
    ctx.update(frameAt(50));  // end window starts @50
    CHECK(cap.ends == 0);
    ctx.update(frameAt(120));  // elapsed 70 -> no end
    CHECK(cap.ends == 0);
    ctx.update(frameAt(200));  // elapsed 150 -> end
    CHECK(cap.ends == 1);
    CHECK_FALSE(ctx.met());
}

TEST_CASE("a reappearance within the end timeout keeps the same scene open") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, kZero, ms(100));

    ctx.update(frameAt(0));  // begin
    *f.factor = false;
    ctx.update(frameAt(50));  // end window @50
    *f.factor = true;
    ctx.update(frameAt(80));  // re-met within the window cancels the pending end
    *f.factor = false;
    ctx.update(frameAt(120));  // a fresh end window starts @120
    CHECK(cap.ends == 0);
    ctx.update(frameAt(300));  // elapsed 180 from @120 -> end
    CHECK(cap.ends == 1);
    CHECK(cap.begins.size() == 1);  // never re-begun: it stayed a single scene throughout
}

TEST_CASE("onIdle closes an already-committed scene") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, kZero, ms(100));

    ctx.update(frameAt(0));  // begin
    REQUIRE(cap.begins.size() == 1);
    ctx.onIdle();  // closes the scene; met() still reflects the last frame's condition, not scene state
    CHECK(cap.ends == 1);
}

TEST_CASE("onIdle discards a begin still in its debounce window") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, ms(100), kZero);

    ctx.update(frameAt(0));  // pending, not committed
    ctx.onIdle();
    CHECK(cap.begins.empty());
    CHECK(cap.ends == 0);
    // The window was dropped, not paused: a later run must restart from scratch.
    ctx.update(frameAt(50));  // pending @50
    ctx.update(frameAt(120));  // elapsed 70 -> still no commit
    CHECK(cap.begins.empty());
}

}  // namespace
}  // namespace uma::chara_detail
