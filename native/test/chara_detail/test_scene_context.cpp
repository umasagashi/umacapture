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
#include "cv/detail_crop_calibrator.h"
#include "cv/detail_crop_tracker.h"
#include "cv/frame.h"
#include "cv/pane_mode_latch.h"
#include "types/shape.h"
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
ConditionBase buildTree(const Flags &f, const std::vector<ConditionBase> &additional = {}) {
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

    std::vector<ConditionBase> children{tab_page, record_type};
    children.insert(children.end(), additional.begin(), additional.end());
    return std::make_shared<condition::ParallelCondition<Frame, rule::LogicalAnd>>(rule::LogicalAnd{}, children);
}

// A close-button branch with the same Stable timer shape as the production scene.
ConditionBase closeButtonBranch(const std::shared_ptr<bool> &flag, int threshold) {
    auto inner = std::make_shared<condition::ParallelCondition<Frame, rule::LogicalAnd>>(
        rule::LogicalAnd{},
        std::vector<ConditionBase>{std::make_shared<condition::NullaryCondition<Frame, Toggle>>(Toggle{flag})});
    return std::make_shared<condition::NestedCondition<Frame, rule::Stable>>(rule::Stable(threshold), inner);
}

// buildTree plus that close-button branch.
ConditionBase buildTreeWithCloseButton(const Flags &f, const std::shared_ptr<bool> &close_flag, int threshold) {
    return buildTree(f, {closeButtonBranch(close_flag, threshold)});
}

// A dummy frame carrying a specific video timestamp; the scene-context debounces key off this value.
Frame frameAt(std::uint64_t timestamp) {
    static const cv::Mat pixels(2, 2, CV_8UC3, cv::Scalar(0, 0, 0));
    return Frame(pixels, timestamp);
}

// A frame big enough to carry a distinguishable calibrated crop (a 2x2 frame's aspect-ratio intersection is
// already the whole frame, which would make the re-anchor checks vacuous).
Frame largeFrameAt(std::uint64_t timestamp) {
    static const cv::Mat pixels(480, 640, CV_8UC3, cv::Scalar(0, 0, 0));
    return Frame(pixels, timestamp);
}

// Captures the three lifecycle event streams via synchronous direct connections.
struct Captured {
    event_util::Connection<SceneInfo> begin = event_util::makeDirectConnection<SceneInfo>();
    event_util::Connection<Frame, SceneState> updated = event_util::makeDirectConnection<Frame, SceneState>();
    event_util::Connection<> end = event_util::makeDirectConnection<>();
    event_util::Connection<std::optional<Size<int>>, std::optional<Size<int>>> resized =
        event_util::makeDirectConnection<std::optional<Size<int>>, std::optional<Size<int>>>();

    std::vector<record::RecordType> begins;
    std::vector<SceneState> updates;
    std::vector<Rect<int>> update_intersections;
    std::vector<Size<int>> update_sizes;
    std::vector<std::optional<ForwardedFrameResize>> update_resizes;
    int ends = 0;
    std::vector<std::pair<std::optional<Size<int>>, std::optional<Size<int>>>> resizes;

    Captured() {
        begin->listen([this](const SceneInfo &info) { begins.push_back(info.record_type); });
        updated->listen([this](const Frame &frame, const SceneState &state) {
            updates.push_back(state);
            update_intersections.push_back(frame.anchor().intersection());
            update_sizes.push_back(frame.size());
            update_resizes.push_back(frame.forwardedResize());
        });
        end->listen([this]() { ends++; });
        resized->listen([this](const std::optional<Size<int>> &from, const std::optional<Size<int>> &to) {
            resizes.emplace_back(from, to);
        });
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
        CharaDetailSceneContext(bad, cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero), std::runtime_error);
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
        CharaDetailSceneContext(root, cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero), std::runtime_error);
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
        CharaDetailSceneContext(root, cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero), std::runtime_error);
}

TEST_CASE("zero begin timeout begins immediately and resolves tab/record by firstMet order") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.campaign = true;  // two tabs met -> Factor wins (lower enum value)
    *f.standard = true;
    *f.inheritance_only = true;  // two record types met -> Standard wins
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero);

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
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(100), kZero);

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
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(100), kZero);

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
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(100), kZero);

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
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(100), kZero);

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
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, ms(100));

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

TEST_CASE("a zero end timeout closes the scene on the first non-matching frame") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero);

    ctx.update(frameAt(0));  // begins immediately
    REQUIRE(cap.begins.size() == 1);
    *f.factor = false;
    ctx.update(frameAt(10));  // zero timeout -> ends on this very frame
    CHECK(cap.ends == 1);
}

TEST_CASE("a reappearance within the end timeout keeps the same scene open") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, ms(100));

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

TEST_CASE("onIdle closes an already-committed scene exactly once") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, ms(100));

    ctx.update(frameAt(0));  // begin
    REQUIRE(cap.begins.size() == 1);
    ctx.onIdle();  // closes the scene; met() still reflects the last frame's condition, not scene state
    CHECK(cap.ends == 1);

    // EXACTLY once: a producer may report the end of its input more than once (a cancel racing the natural end
    // of a clip), and a second close would emit a second closed_before_completed for one lost session.
    ctx.onIdle();
    CHECK(cap.ends == 1);
}

TEST_CASE("onIdle on a context with no scene open reports nothing") {
    Captured cap;
    Flags f;  // nothing met: the scene never opens
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, ms(100));

    ctx.update(frameAt(0));
    REQUIRE(cap.begins.empty());
    ctx.onIdle();
    // The end of the input is not by itself a failure. A clip that never showed a detail screen must not be
    // reported as one that lost a session, or every unrelated clip would end in a failure tile.
    CHECK(cap.ends == 0);
}

TEST_CASE("onIdle discards a begin still in its debounce window") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(100), kZero);

    ctx.update(frameAt(0));  // pending, not committed
    ctx.onIdle();
    CHECK(cap.begins.empty());
    CHECK(cap.ends == 0);
    // The window was dropped, not paused: a later run must restart from scratch.
    ctx.update(frameAt(50));  // pending @50
    ctx.update(frameAt(120));  // elapsed 70 -> still no commit
    CHECK(cap.begins.empty());
}

// --- Detail-crop calibration wiring -------------------------------------------------------------------
//
// The state machine itself is covered by test/cv/test_detail_crop_tracker.cpp. What is checked here is the
// seam this class owns: calibration runs after the tree evaluation, and a latched tracker preserves the
// producer-provided anchor forwarded downstream.

// Counts scans and replays a fixed answer, standing in for calibrateDetailCrop.
struct StubScan {
    DetailCropResult answer;
    int calls = 0;
    Size<int> last_scanned_size{0, 0};

    DetailCropTracker::ScanFunction fn() {
        return [this](const cv::Mat &image, const Rect<int> &estimate) {
            calls++;
            last_scanned_size = image.size();
            if (estimate == pane::onePaneCandidate(image.size())) {
                return answer;
            }
            DetailCropResult no_match;
            no_match.status = DetailCropStatus::HeaderStart;
            return no_match;
        };
    }
};

// A crop that fits inside largeFrameAt's 640x480 and differs from its aspect-ratio intersection.
const Rect<int> kCalibrated{{10, 20}, Point<int>{210, 375}};

DetailCropResult calibratedOk() {
    DetailCropResult result;
    result.status = DetailCropStatus::Ok;
    result.calibration = {10.0, 20.0, 200.0, 355.0};
    return result;
}

TEST_CASE("an unambiguous calibration latches without waiting for the scene timer") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    auto close = std::make_shared<bool>(true);
    StubScan scan;
    scan.answer = calibratedOk();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn());
    CharaDetailSceneContext ctx(
        buildTreeWithCloseButton(f, close, 50), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, tracker);

    // The timer has not elapsed, so the scene is not met. Calibration is independent of that verdict and
    // evaluates both pane candidates immediately.
    ctx.update(largeFrameAt(0));
    CHECK_FALSE(ctx.met());
    CHECK(scan.calls == 2);
    CHECK(tracker->latched());

    ctx.update(largeFrameAt(100));  // elapsed 100 > 50 -> the timer fires
    CHECK(ctx.met());
    CHECK(scan.calls == 2);
    CHECK(tracker->latched());
}

TEST_CASE("a frame the tree does not match is scanned") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    auto close = std::make_shared<bool>(false);  // the close button is not on screen
    StubScan scan;
    scan.answer = calibratedOk();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn());
    CharaDetailSceneContext ctx(
        buildTreeWithCloseButton(f, close, 50), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, tracker);

    ctx.update(largeFrameAt(0));

    CHECK_FALSE(ctx.met());
    CHECK(scan.calls == 2);
    REQUIRE(tracker->correction().has_value());
    CHECK(tracker->correction().value() == kCalibrated);
}

TEST_CASE("the producer anchor reaches the frame forwarded downstream after latching") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    auto close = std::make_shared<bool>(false);
    StubScan scan;
    scan.answer = calibratedOk();
    const auto latch = std::make_shared<PaneModeLatch>();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn(), latch);
    CharaDetailSceneContext ctx(
        buildTreeWithCloseButton(f, close, 50), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, tracker);

    // A shaping producer resolves the pane latch and carries that token on the frame; carrying it is what
    // makes its own anchor authoritative here. (A producer that resolves nothing gets the pane applied FOR
    // it instead -- see the resize case below.)
    const auto fromShapingProducer = [&latch](std::uint64_t timestamp) {
        return largeFrameAt(timestamp).withPaneModeSnapshot(latch->snapshotFor(Size<int>{640, 480}));
    };

    ctx.update(largeFrameAt(0));  // scans and adopts the crop
    *close = true;
    ctx.update(fromShapingProducer(10));  // producer anchor is preserved; the timer starts
    ctx.update(fromShapingProducer(100));  // the timer fires -> scene begins and the frame is forwarded

    REQUIRE(cap.update_intersections.size() == 1);
    CHECK(cap.update_intersections[0] == FrameAnchor::intersect(Size<int>{640, 480}).intersection());
}

TEST_CASE("calibration does not depend on a close-button instant node") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    StubScan scan;
    scan.answer = calibratedOk();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn());
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, tracker);

    ctx.update(largeFrameAt(0));
    ctx.update(largeFrameAt(100));

    CHECK(scan.calls == 2);
    CHECK(tracker->correction().has_value());
    CHECK(tracker->latched());
    CHECK(ctx.met());
}

DetailCropResult calibrationNotFound() {
    DetailCropResult result;
    result.status = DetailCropStatus::HeaderStart;
    return result;
}

TEST_CASE("a running scene adopts no calibration, its end debounce included, and the next frame after it does") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    StubScan scan;
    scan.answer = calibrationNotFound();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn());
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, ms(1000), tracker);

    ctx.update(largeFrameAt(0));  // nothing to calibrate yet; the scene begins
    REQUIRE(cap.begins.size() == 1);

    // The dialog becomes measurable only now, with the scene running.
    scan.answer = calibratedOk();
    ctx.update(largeFrameAt(10));
    ctx.update(largeFrameAt(15));
    CHECK_FALSE(tracker->latched());

    // The scene stops being met; its end debounce runs, and the scene is still the one that began.
    *f.factor = false;
    ctx.update(largeFrameAt(20));
    ctx.update(largeFrameAt(500));
    CHECK(cap.ends == 0);
    CHECK_FALSE(tracker->latched());

    ctx.update(largeFrameAt(1100));  // the debounce elapses: the scene ends after this frame was evaluated
    CHECK(cap.ends == 1);
    CHECK_FALSE(tracker->latched());

    ctx.update(largeFrameAt(1200));  // the first frame outside the scene adopts
    CHECK(tracker->latched());

    // Every frame the scene forwarded kept the anchor it began with.
    const auto uncalibrated = FrameAnchor::intersect(Size<int>{640, 480}).intersection();
    REQUIRE(cap.update_intersections.size() == 3);
    for (const auto &intersection : cap.update_intersections) {
        CHECK(intersection == uncalibrated);
    }
}

TEST_CASE("a frame that latches does not begin a scene, and the begin window starts over after it") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    StubScan scan;
    scan.answer = calibrationNotFound();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn());
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(200), kZero, tracker);

    ctx.update(largeFrameAt(0));  // the begin window opens
    scan.answer = calibratedOk();
    ctx.update(largeFrameAt(200));  // the window would close here, but this frame latches
    CHECK(tracker->latched());
    CHECK(cap.begins.empty());

    ctx.update(largeFrameAt(201));  // a new window opens: 201 is only 1 ms after the latch
    CHECK(cap.begins.empty());
    ctx.update(largeFrameAt(400));
    CHECK(cap.begins.empty());

    ctx.update(largeFrameAt(401));  // 200 ms after the first frame of the new window
    REQUIRE(cap.begins.size() == 1);
    // The scene's very first forwarded frame already carries the calibrated anchor (this producer sends no
    // snapshot, so the latched pane is applied on this side).
    REQUIRE(cap.update_intersections.size() == 1);
    CHECK(cap.update_intersections[0] == kCalibrated);
}

// --- Capture size changes ------------------------------------------------------------------------------

TEST_CASE("a capture size change during a scene is reported once, even from a frame the scene does not match") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    const Size<int> before{640, 480};
    const Size<int> after{800, 600};
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, ms(1000));

    ctx.update(largeFrameAt(0).withCapturedSize(before));  // the scene begins at `before`
    ctx.update(largeFrameAt(10).withCapturedSize(before));
    REQUIRE(cap.begins.size() == 1);

    // The resized frames are not recognized as the detail screen: the scene is in its end debounce when the
    // first frame of the new size arrives, and that frame is where the change must be reported.
    *f.factor = false;
    ctx.update(largeFrameAt(20).withCapturedSize(before));
    CHECK(cap.resizes.empty());
    ctx.update(largeFrameAt(30).withCapturedSize(after));
    REQUIRE(cap.resizes.size() == 1);
    CHECK(cap.resizes[0].first == std::optional<Size<int>>{before});
    CHECK(cap.resizes[0].second == std::optional<Size<int>>{after});
    CHECK(cap.ends == 0);  // the detail screen did not close; only the attempt in flight is affected

    // More frames of the new size, matched or not, are the same change.
    ctx.update(largeFrameAt(40).withCapturedSize(after));
    *f.factor = true;
    ctx.update(largeFrameAt(50).withCapturedSize(after));
    CHECK(cap.resizes.size() == 1);
    CHECK(cap.ends == 0);

    // Outside a scene a size change is not reported.
    *f.factor = false;
    ctx.update(largeFrameAt(60).withCapturedSize(after));
    ctx.update(largeFrameAt(1100).withCapturedSize(after));
    REQUIRE(cap.ends == 1);
    ctx.update(largeFrameAt(1200).withCapturedSize(before));
    CHECK(cap.resizes.size() == 1);
}

TEST_CASE("a capture size change restarts the begin window") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(100), kZero);

    ctx.update(largeFrameAt(0).withCapturedSize({640, 480}));  // the window opens
    ctx.update(largeFrameAt(100).withCapturedSize({800, 600}));  // would close it, but the size changed
    CHECK(cap.begins.empty());
    ctx.update(largeFrameAt(150).withCapturedSize({800, 600}));
    CHECK(cap.begins.empty());
    ctx.update(largeFrameAt(200).withCapturedSize({800, 600}));  // 100 ms at the new size
    CHECK(cap.begins.size() == 1);
    CHECK(cap.resizes.empty());
}

TEST_CASE("a capture size change is reported from a frame the tracker refuses as stale, with no frame after it") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    StubScan scan;
    scan.answer = calibratedOk();
    const auto latch = std::make_shared<PaneModeLatch>();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn(), latch);
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, tracker);
    const Size<int> before{640, 480};
    const Size<int> after{800, 600};

    ctx.update(largeFrameAt(0).withCapturedSize(before));  // latches; does not begin a scene
    const auto live = [&latch](std::uint64_t timestamp, const Size<int> &captured) {
        return largeFrameAt(timestamp)
            .withPaneModeSnapshot(latch->snapshotFor(Size<int>{640, 480}))
            .withCapturedSize(captured);
    };
    ctx.update(live(10, before));  // the scene begins at `before`
    REQUIRE(cap.begins.size() == 1);
    const auto forwarded = cap.updates.size();

    // A live producer resolves its snapshot, then the size change releases the latch (NativeApi::updateFrame's
    // noteFrameSize): the first frame of the new size carries a stale snapshot and its pixels are refused.
    // The capture then stops, so no later frame of the new size arrives.
    const auto stale = live(20, after);
    tracker->requestRelease();
    ctx.update(stale);
    CHECK(cap.updates.size() == forwarded);
    REQUIRE(cap.resizes.size() == 1);
    CHECK(cap.resizes[0].first == std::optional<Size<int>>{before});
    CHECK(cap.resizes[0].second == std::optional<Size<int>>{after});
    ctx.onIdle();
    CHECK(cap.resizes.size() == 1);
}

// --- Forwarded-frame resize ---------------------------------------------------------------------------
//
// The transform itself is covered by test/cv/test_frame.cpp (Frame::resizedIntoBand). What is pinned here is
// the seam this class owns: WHERE the resize happens -- at the forward site, only for frames that are
// actually forwarded, and only after the condition tree and the crop calibration have seen the raw pixels --
// and that what reaches that site is the BAND, not a bound resolved once at construction.

TEST_CASE("the forwarded frame is held inside the configured band, and only once the scene is active") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    // largeFrameAt is 640x480, whose aspect-ratio intersection is 270 wide -- below the band, so it is
    // scaled UP to the lower bound, doubling the frame.
    CharaDetailSceneContext ctx(
        buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, ms(100), kZero, nullptr, Range<int>{540, 720});

    ctx.update(largeFrameAt(0).withCapturedSize({800, 600}));  // met, but inside the begin debounce: nothing forwarded
    CHECK(cap.update_sizes.empty());

    ctx.update(largeFrameAt(150).withCapturedSize({800, 600}));  // commit -> the first forwarded frame

    REQUIRE(cap.update_sizes.size() == 1);
    CHECK(cap.update_intersections[0].width() == 540);
    CHECK(cap.update_sizes[0] == Size<int>{1280, 960});
    // The forwarded frame says what happened to it, and carries the size the producer stamped.
    REQUIRE(cap.update_resizes[0].has_value());
    const auto &resize = cap.update_resizes[0].value();
    REQUIRE(resize.band.has_value());
    CHECK(resize.band->min() == 540);
    CHECK(resize.band->max() == 720);
    CHECK(resize.captured_size == std::optional<Size<int>>{Size<int>{800, 600}});
    CHECK(resize.pre_band_unit == 270);
    CHECK(resize.unit == 540);
    CHECK(resize.arm() == ResizeArm::Enlarged);
}

TEST_CASE("a frame already inside the band is forwarded untouched") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    // The same 270-wide intersection, against a band that CONTAINS it. Nothing is resampled, and the frame
    // arrives downstream exactly as the producer sent it. This is what a band buys over a single target, and
    // it is only expressible because the whole band -- not one resolved bound -- reaches the forward site.
    CharaDetailSceneContext ctx(
        buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, nullptr, Range<int>{200, 300});

    ctx.update(largeFrameAt(0));

    REQUIRE(cap.update_sizes.size() == 1);
    CHECK(cap.update_sizes[0] == Size<int>{640, 480});
    CHECK(cap.update_intersections[0].width() == 270);
    REQUIRE(cap.update_resizes[0].has_value());
    CHECK(cap.update_resizes[0]->band.has_value());
    CHECK(cap.update_resizes[0]->pre_band_unit == 270);
    CHECK(cap.update_resizes[0]->unit == 270);
    CHECK(cap.update_resizes[0]->arm() == ResizeArm::Untouched);
}

TEST_CASE("a frame above the band is scaled down to the upper bound") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    // The same frame, against a band it sits ABOVE: 270 -> 135, the other end of the same decision. Pinning
    // both directions here is what stops the forward site from being wired to one bound only.
    CharaDetailSceneContext ctx(
        buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, nullptr, Range<int>{100, 135});

    ctx.update(largeFrameAt(0));

    REQUIRE(cap.update_sizes.size() == 1);
    CHECK(cap.update_intersections[0].width() == 135);
    CHECK(cap.update_sizes[0] == Size<int>{320, 240});
    REQUIRE(cap.update_resizes[0].has_value());
    CHECK(cap.update_resizes[0]->pre_band_unit == 270);
    CHECK(cap.update_resizes[0]->unit == 135);
    CHECK(cap.update_resizes[0]->arm() == ResizeArm::Shrunk);
}

TEST_CASE("no resize is applied when the setting is off") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    CharaDetailSceneContext ctx(buildTree(f), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero);

    ctx.update(largeFrameAt(0));

    REQUIRE(cap.update_sizes.size() == 1);
    CHECK(cap.update_sizes[0] == Size<int>{640, 480});
    CHECK(cap.update_intersections[0].width() == 270);
    // The facts are attached with the setting off too: no band, nothing done, and no captured size, because this
    // frame was not stamped by NativeApi::updateFrame.
    REQUIRE(cap.update_resizes[0].has_value());
    CHECK_FALSE(cap.update_resizes[0]->band.has_value());
    CHECK_FALSE(cap.update_resizes[0]->captured_size.has_value());
    CHECK(cap.update_resizes[0]->arm() == ResizeArm::Untouched);
}

TEST_CASE("the crop calibration scans the raw frame, and the forwarded resize follows the resulting anchor") {
    Captured cap;
    Flags f;
    *f.factor = true;
    *f.standard = true;
    auto close = std::make_shared<bool>(false);
    StubScan scan;
    scan.answer = calibratedOk();
    auto tracker = std::make_shared<DetailCropTracker>(scan.fn());
    CharaDetailSceneContext ctx(
        buildTreeWithCloseButton(f, close, 50), cap.begin, cap.updated, cap.end, cap.resized, kZero, kZero, tracker,
        Range<int>{540, 720});

    ctx.update(largeFrameAt(0).withCapturedSize({1000, 750}));  // scans and adopts the crop
    *close = true;
    ctx.update(largeFrameAt(10).withCapturedSize({1000, 750}));  // producer anchor is preserved; the timer starts
    ctx.update(largeFrameAt(100).withCapturedSize({1000, 750}));  // the timer fires -> the frame is forwarded

    // The scan must have seen the full-resolution image: resizing before the calibration would hand it a
    // blurred frame, which is exactly what forwarding-site placement exists to prevent.
    CHECK(scan.last_scanned_size == Size<int>{640, 480});

    // This producer resolves no pane decision of its own -- it sends no snapshot, which is how both offline
    // CLI paths work -- so the latched pane is applied on this side, and the resize normalizes THAT
    // intersection to 540 (kCalibrated is 200 wide, so the whole frame scales by 2.7).
    REQUIRE(cap.update_intersections.size() == 1);
    const Rect<int> forwarded = cap.update_intersections[0];
    CHECK(forwarded.width() == 540);
    CHECK(forwarded.left() == 27);
    CHECK(forwarded.top() == 54);
    CHECK(forwarded.height() == 959);
    CHECK(cap.update_sizes[0] == Size<int>{1728, 1296});
    // The band decided on the calibrated unit, and the captured size survives the tracker's re-anchored copy.
    REQUIRE(cap.update_resizes[0].has_value());
    CHECK(cap.update_resizes[0]->pre_band_unit == 200);
    CHECK(cap.update_resizes[0]->unit == 540);
    CHECK(cap.update_resizes[0]->captured_size == std::optional<Size<int>>{Size<int>{1000, 750}});
}

}  // namespace
}  // namespace uma::chara_detail
