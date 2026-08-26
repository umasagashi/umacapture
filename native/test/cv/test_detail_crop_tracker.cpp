// Behavioral tests for the candidate-based detail-crop state machine and its pane-mode latch handoff.

#include <doctest/doctest.h>

#include <algorithm>
#include <array>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "cv/detail_crop_calibrator.h"
#include "cv/detail_crop_tracker.h"
#include "cv/frame.h"
#include "cv/frame_shaper.h"
#include "cv/pane_mode.h"
#include "cv/pane_mode_latch.h"
#include "types/shape.h"

namespace uma {
namespace {

constexpr int kWidth = 640;
constexpr int kHeight = 480;
const Size<int> kFrameSize{kWidth, kHeight};
const Rect<int> kOneMeasured{{10, 20}, Point<int>{210, 375}};
const Rect<int> kTwoMeasured{{300, 40}, Point<int>{500, 395}};

Frame frameOfSize(int width = kWidth, int height = kHeight, uint64 timestamp = 1) {
    return {cv::Mat::zeros(height, width, CV_8UC3), timestamp};
}

DetailCropResult okFor(const Rect<int> &rect) {
    DetailCropResult result;
    result.status = DetailCropStatus::Ok;
    result.calibration = {
        static_cast<double>(rect.left()),
        static_cast<double>(rect.top()),
        static_cast<double>(rect.width()),
        static_cast<double>(rect.height()),
    };
    return result;
}

DetailCropResult failed() {
    DetailCropResult result;
    result.status = DetailCropStatus::HeaderStart;
    return result;
}

struct FakeScan {
    std::vector<std::pair<Rect<int>, DetailCropResult>> answers;
    std::vector<Rect<int>> estimates;

    void answer(const Rect<int> &estimate, const DetailCropResult &result) { answers.emplace_back(estimate, result); }

    DetailCropTracker::ScanFunction fn() {
        return [this](const cv::Mat &, const Rect<int> &estimate) {
            estimates.push_back(estimate);
            for (const auto &[key, result] : answers) {
                if (key == estimate) {
                    return result;
                }
            }
            return failed();
        };
    }

    [[nodiscard]] size_t calls() const { return estimates.size(); }
};

// One tracker step, without asserting anything: an empty result means beginFrame dropped the frame.
//
// THE CONCURRENCY CASES BELOW MUST USE THIS ONE, NOT step(). A regression that makes beginFrame drop a frame
// these cases feed it turns `.value()` into a std::bad_optional_access, and an exception that leaves a
// std::thread's entry function calls std::terminate: doctest never sees a failed case, it loses the whole
// binary, and the log says only "umacapture_tests crashed" -- which invariant broke is then a bisect rather
// than a test name. Handing the optional back to the joining thread keeps the failure a named red case.
std::optional<Frame> tryStep(DetailCropTracker &tracker, const Frame &input) {
    std::optional<Frame> frame = tracker.beginFrame(input);
    if (frame.has_value()) {
        tracker.endFrame(*frame);
    }
    return frame;
}

// The single-threaded form: the drop is reported by doctest, on the thread doctest is running the case on.
Frame step(DetailCropTracker &tracker, const Frame &input) {
    std::optional<Frame> frame = tryStep(tracker, input);
    REQUIRE(frame.has_value());
    return *frame;
}

TEST_CASE("the one-pane candidate alone is adopted and immediately latched") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);

    step(tracker, frameOfSize());

    CHECK(scan.estimates == std::vector<Rect<int>>{
                                pane::onePaneCandidate(kFrameSize),
                                pane::twoPaneCandidate(kFrameSize),
                            });
    REQUIRE(tracker.correction().has_value());
    CHECK(tracker.correction().value() == kOneMeasured);
    CHECK(tracker.latched());
    CHECK(latch->rectFor(kFrameSize) == std::optional<Rect<int>>{kOneMeasured});
}

TEST_CASE("the two-pane candidate alone is adopted and immediately latched") {
    FakeScan scan;
    scan.answer(pane::twoPaneCandidate(kFrameSize), okFor(kTwoMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);

    step(tracker, frameOfSize());

    REQUIRE(tracker.correction().has_value());
    CHECK(tracker.correction().value() == kTwoMeasured);
    CHECK(tracker.latched());
    CHECK(latch->rectFor(kFrameSize) == std::optional<Rect<int>>{kTwoMeasured});
}

TEST_CASE("two successful candidates are ambiguous and leave state unchanged") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    scan.answer(pane::twoPaneCandidate(kFrameSize), okFor(kTwoMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);

    step(tracker, frameOfSize());

    CHECK(scan.calls() == 2);
    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
}

TEST_CASE("zero successful candidates leave state unchanged") {
    FakeScan scan;
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);

    step(tracker, frameOfSize());

    CHECK(scan.calls() == 2);
    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
}

TEST_CASE("the immediate latch stops every later scan") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    DetailCropTracker tracker(scan.fn());

    step(tracker, frameOfSize());
    scan.answers.clear();
    step(tracker, frameOfSize(kWidth, kHeight, 2));
    step(tracker, frameOfSize(kWidth, kHeight, 3));

    CHECK(scan.calls() == 2);
    CHECK(tracker.correction().value() == kOneMeasured);
    CHECK(tracker.latched());
}

TEST_CASE("a latched tracker preserves the producer-provided anchor") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    step(tracker, frameOfSize());

    const Rect<int> producer_anchor{{5, 6}, Point<int>{125, 219}};
    // A shaping producer carries the pane snapshot it resolved; that token is what makes its anchor
    // authoritative here (reanchored() drops the snapshot, so it is attached afterwards).
    const Frame shaped =
        frameOfSize(240, 400, 2).reanchored(producer_anchor).withPaneModeSnapshot(latch->snapshotFor(kFrameSize));
    const Frame passed = tracker.beginFrame(shaped).value();

    CHECK(passed.size() == shaped.size());
    CHECK(passed.anchor().intersection() == producer_anchor);
    CHECK(passed.timestamp() == shaped.timestamp());
}

// The consumer half of the offline determinism contract (see cv/video_loader.h). The two CLI producers send
// no pane snapshot at all, so a latched pane can only reach the pipeline from here -- and their frames, being
// the full capture every time, can never go stale and are never dropped.
TEST_CASE("a producer that sends no pane snapshot gets the latched pane applied on this side") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);

    // The frame that latches is still uncorrected: the decision only takes effect from the next one.
    const Frame first = step(tracker, frameOfSize());
    REQUIRE(tracker.latched());
    CHECK(first.anchor().intersection() == FrameAnchor::intersect(kFrameSize).intersection());

    for (uint64 timestamp = 2; timestamp <= 4; ++timestamp) {
        const auto prepared = tracker.beginFrame(frameOfSize(kWidth, kHeight, timestamp));
        REQUIRE(prepared.has_value());
        CHECK(prepared->size() == kFrameSize);  // Anchored, never cropped: the pixels stay the full capture.
        CHECK(prepared->anchor().intersection() == kOneMeasured);
        tracker.endFrame(prepared.value());
    }
    CHECK(scan.calls() == 2);  // Two candidates on the first frame; a latched tracker never re-scans.
}

TEST_CASE("requestRelease drops the pane latch immediately and tracker state on the next frame") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    step(tracker, frameOfSize());

    tracker.requestRelease();
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
    CHECK(tracker.latched());

    (void) tracker.beginFrame(frameOfSize(kWidth, kHeight, 2));
    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(tracker.correction().has_value());
}

TEST_CASE("a reported frame-size change releases both latches") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    tracker.noteFrameSize(kFrameSize);
    step(tracker, frameOfSize());

    tracker.noteFrameSize({800, 600});
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
    (void) tracker.beginFrame(frameOfSize(kWidth, kHeight, 2));

    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(tracker.correction().has_value());
}

TEST_CASE("candidate evaluation order does not affect the accepted result") {
    FakeScan normal_scan;
    FakeScan reversed_scan;
    const auto one = pane::onePaneCandidate(kFrameSize);
    normal_scan.answer(one, okFor(kOneMeasured));
    reversed_scan.answer(one, okFor(kOneMeasured));

    DetailCropTracker normal(normal_scan.fn());
    DetailCropTracker reversed(
        reversed_scan.fn(),
        std::make_shared<PaneModeLatch>(),
        [](const Size<int> &size) {
            auto result = pane::paneCandidates(size);
            std::reverse(result.begin(), result.end());
            return result;
        });

    step(normal, frameOfSize());
    step(reversed, frameOfSize());

    CHECK(normal.correction() == reversed.correction());
    CHECK(normal.latched() == reversed.latched());
    CHECK(normal_scan.estimates.front() == reversed_scan.estimates.back());
    CHECK(normal_scan.estimates.back() == reversed_scan.estimates.front());
}

TEST_CASE("an out-of-frame calibration is rejected") {
    FakeScan scan;
    const Rect<int> outside{{500, 20}, Point<int>{700, 375}};
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(outside));
    DetailCropTracker tracker(scan.fn());

    step(tracker, frameOfSize());

    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(tracker.latched());
}

// --- the one row independent rounding can invent ------------------------------------------------------
//
// The three cases below pin the whole of the fit-aware rounding, at the level that matters: what the state
// machine ADOPTS. The frame is the recorded incident's, 2326x1340 (see the note above calibrateDetailCrop
// in cv/detail_crop_calibrator.h): a header boundary one row early solved top 28.778 / height 1312, which
// rounds to top 29 + 1312 = bottom 1341, one row past the last row of the frame -- and the import produced
// no records and no error at all.

const Size<int> kIncidentFrame{2326, 1340};

DetailCropResult okForCalibration(double left, double top, double width, double height) {
    DetailCropResult result;
    result.status = DetailCropStatus::Ok;
    result.calibration = {left, top, width, height};
    return result;
}

TEST_CASE("a calibration one row past the bottom edge is pulled in and adopted") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kIncidentFrame), okForCalibration(794.0, 28.778, 737.752, 1312.0));
    DetailCropTracker tracker(scan.fn());

    step(tracker, frameOfSize(kIncidentFrame.width(), kIncidentFrame.height()));

    REQUIRE(tracker.correction().has_value());
    CHECK(tracker.latched());
    const Rect<int> adopted = tracker.correction().value();
    CHECK(adopted.bottom() == 1340);  // pulled in from 1341
    // The unit, and the origin it is measured from, are exactly what toRect() alone would have produced.
    CHECK(adopted.left() == 794);
    CHECK(adopted.top() == 29);
    CHECK(adopted.width() == 738);
}

TEST_CASE("a calibration two rows past the bottom edge is still rejected") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kIncidentFrame), okForCalibration(794.0, 29.0, 737.752, 1313.0));
    DetailCropTracker tracker(scan.fn());

    step(tracker, frameOfSize(kIncidentFrame.width(), kIncidentFrame.height()));

    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(tracker.latched());
}

TEST_CASE("a calibration above the top edge is still rejected") {
    // The rejections the shipped path actually performs are negative tops (-10 / -6 / -8 measured); one row
    // of bottom-edge absorption must not rescue any of them.
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kIncidentFrame), okForCalibration(794.0, -1.0, 737.752, 1312.0));
    DetailCropTracker tracker(scan.fn());

    step(tracker, frameOfSize(kIncidentFrame.width(), kIncidentFrame.height()));

    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(tracker.latched());
}

TEST_CASE("an empty frame passes through without scanning or reporting") {
    FakeScan scan;
    size_t reports = 0;
    DetailCropTracker tracker(scan.fn());
    tracker.setReportCallback([&](const Rect<int> &, const Rect<int> &, bool) { ++reports; });

    const Frame passed = step(tracker, Frame());

    CHECK(passed.empty());
    CHECK(scan.calls() == 0);
    CHECK(reports == 0);
}

TEST_CASE("the immediate latch and its release are both reported") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    struct Report {
        Rect<int> corrected;
        bool latched;
    };
    std::vector<Report> reports;
    DetailCropTracker tracker(scan.fn());
    tracker.setReportCallback(
        [&](const Rect<int> &, const Rect<int> &corrected, bool latched) { reports.push_back({corrected, latched}); });

    step(tracker, frameOfSize());
    REQUIRE(reports.size() == 1);
    CHECK(reports[0].corrected == kOneMeasured);
    CHECK(reports[0].latched);

    scan.answers.clear();
    tracker.requestRelease();
    step(tracker, frameOfSize(kWidth, kHeight, 2));

    REQUIRE(reports.size() == 2);
    CHECK(reports[1].corrected == FrameAnchor::intersect(kFrameSize).intersection());
    CHECK_FALSE(reports[1].latched);
}

TEST_CASE("a shaped producer frame keeps both report rectangles in capture coordinates") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    struct Report {
        Rect<int> default_rect;
        Rect<int> corrected;
    };
    std::vector<Report> reports;
    DetailCropTracker tracker(scan.fn());
    tracker.setReportCallback([&](const Rect<int> &default_rect, const Rect<int> &corrected, bool) {
        reports.push_back({default_rect, corrected});
    });
    step(tracker, frameOfSize());

    // READ `shaped` AS "HAND-BUILT", NOT AS "WHAT A PRODUCER SENDS". It is pane-sized with a fixed anchor and
    // NO pane snapshot, and no shaping mode can emit that combination -- "no shaping mode can emit cropped
    // pixels without a pane snapshot naming that crop" below proves it directly. What this case is actually
    // about is the REPORT: whichever frame arrives, both rectangles handed to the report callback stay in
    // capture coordinates. The producer-shaped forms, snapshot and all, are covered by "a cropping producer's
    // shaped frame never receives the pre-crop correction" and the two cases after it.
    const Frame shaped = Frame::fixed(cv::Mat::zeros(kOneMeasured.height(), kOneMeasured.width(), CV_8UC3), 2);
    const Frame passed = tracker.beginFrame(shaped).value();
    tracker.endFrame(passed);

    REQUIRE(reports.size() == 1);
    CHECK(reports[0].default_rect == FrameAnchor::intersect(kFrameSize).intersection());
    CHECK(reports[0].corrected == kOneMeasured);
    CHECK(passed.anchor().intersection() == shaped.anchor().intersection());
}

TEST_CASE("a release while a scan is blocked prevents that scan from relatching") {
    std::mutex mutex;
    std::condition_variable condition;
    bool scan_entered = false;
    bool resume_scan = false;
    const auto one = pane::onePaneCandidate(kFrameSize);
    DetailCropTracker::ScanFunction scan = [&](const cv::Mat &, const Rect<int> &estimate) {
        if (!(estimate == one)) {
            return failed();
        }
        std::unique_lock<std::mutex> lock(mutex);
        scan_entered = true;
        condition.notify_all();
        condition.wait(lock, [&] { return resume_scan; });
        return okFor(kOneMeasured);
    };
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan, latch);

    std::optional<Frame> shaped;
    std::thread distributor([&] { shaped = tryStep(tracker, frameOfSize()); });
    {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&] { return scan_entered; });
    }
    tracker.requestRelease();
    {
        const std::lock_guard<std::mutex> lock(mutex);
        resume_scan = true;
    }
    condition.notify_all();
    distributor.join();
    // Asserted here, not inside the thread: a dropped frame has to be a red case, not a terminate().
    CHECK(shaped.has_value());

    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
}

TEST_CASE("a release between beginFrame and endFrame prevents that frame from relatching") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);

    const Frame frame = tracker.beginFrame(frameOfSize()).value();
    tracker.requestRelease();
    tracker.endFrame(frame);

    CHECK(scan.calls() == 2);
    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
}

TEST_CASE("a release after the begin-frame exchange invalidates its pre-exchange generation") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    std::mutex mutex;
    std::condition_variable condition;
    bool exchange_completed = false;
    bool resume_begin = false;
    DetailCropTracker tracker(
        scan.fn(),
        latch,
        [](const Size<int> &size) { return pane::paneCandidates(size); },
        [&] {
            std::unique_lock<std::mutex> lock(mutex);
            exchange_completed = true;
            condition.notify_all();
            condition.wait(lock, [&] { return resume_begin; });
        });

    std::optional<Frame> shaped;
    std::thread distributor([&] { shaped = tryStep(tracker, frameOfSize()); });
    {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&] { return exchange_completed; });
    }
    tracker.requestRelease();
    {
        const std::lock_guard<std::mutex> lock(mutex);
        resume_begin = true;
    }
    condition.notify_all();
    distributor.join();
    // Asserted here, not inside the thread: a dropped frame has to be a red case, not a terminate().
    CHECK(shaped.has_value());

    CHECK(scan.calls() == 2);
    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
}

TEST_CASE("a queued null snapshot is dropped when an earlier frame latches before consumption") {
    FakeScan scan;
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    const auto producer_snapshot = latch->snapshotFor(kFrameSize);
    const auto queued = frameOfSize().withPaneModeSnapshot(producer_snapshot);

    CHECK(latch->isCurrent(producer_snapshot));  // The producer-side pre-submit check passed.
    REQUIRE(latch->latch(kOneMeasured, kFrameSize, producer_snapshot.generation));

    CHECK_FALSE(tracker.beginFrame(queued).has_value());
    CHECK(scan.calls() == 0);
}

TEST_CASE("release and identical relatch cannot revive a queued shaped frame") {
    FakeScan scan;
    const auto latch = std::make_shared<PaneModeLatch>();
    REQUIRE(latch->latch(kOneMeasured, kFrameSize, latch->generation()));
    DetailCropTracker tracker(scan.fn(), latch);
    const auto producer_snapshot = latch->snapshotFor(kFrameSize);
    const auto queued = Frame::fixed(
                            cv::Mat::zeros(kOneMeasured.height(), kOneMeasured.width(), CV_8UC3),
                            1)
                            .withPaneModeSnapshot(producer_snapshot);

    latch->release();
    REQUIRE(latch->latch(kOneMeasured, kFrameSize, latch->generation()));

    CHECK_FALSE(tracker.beginFrame(queued).has_value());
    CHECK(scan.calls() == 0);
}

TEST_CASE("a pane change after consumer entry but before snapshot validation drops the frame") {
    FakeScan scan;
    const auto latch = std::make_shared<PaneModeLatch>();
    std::mutex mutex;
    std::condition_variable condition;
    bool exchange_completed = false;
    bool resume_begin = false;
    DetailCropTracker tracker(
        scan.fn(),
        latch,
        [](const Size<int> &size) { return pane::paneCandidates(size); },
        [&] {
            std::unique_lock<std::mutex> lock(mutex);
            exchange_completed = true;
            condition.notify_all();
            condition.wait(lock, [&] { return resume_begin; });
        });
    const auto producer_snapshot = latch->snapshotFor(kFrameSize);
    const auto queued = frameOfSize().withPaneModeSnapshot(producer_snapshot);
    std::optional<Frame> prepared;

    std::thread distributor([&] { prepared = tracker.beginFrame(queued); });
    {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&] { return exchange_completed; });
    }
    const bool installed = latch->latch(kOneMeasured, kFrameSize, producer_snapshot.generation);
    {
        const std::lock_guard<std::mutex> lock(mutex);
        resume_begin = true;
    }
    condition.notify_all();
    distributor.join();

    CHECK(installed);
    CHECK_FALSE(prepared.has_value());
    CHECK(scan.calls() == 0);
}

TEST_CASE("a second release after consuming a pending request invalidates the captured generation") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    std::mutex mutex;
    std::condition_variable condition;
    bool exchange_completed = false;
    bool resume_begin = false;
    DetailCropTracker tracker(
        scan.fn(),
        latch,
        [](const Size<int> &size) { return pane::paneCandidates(size); },
        [&] {
            std::unique_lock<std::mutex> lock(mutex);
            exchange_completed = true;
            condition.notify_all();
            condition.wait(lock, [&] { return resume_begin; });
        });
    tracker.requestRelease();

    std::optional<Frame> shaped;
    std::thread distributor([&] { shaped = tryStep(tracker, frameOfSize()); });
    {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [&] { return exchange_completed; });
    }
    tracker.requestRelease();
    {
        const std::lock_guard<std::mutex> lock(mutex);
        resume_begin = true;
    }
    condition.notify_all();
    distributor.join();
    // Asserted here, not inside the thread: a dropped frame has to be a red case, not a terminate().
    CHECK(shaped.has_value());

    CHECK(scan.calls() == 2);
    CHECK_FALSE(tracker.latched());
    CHECK_FALSE(tracker.correction().has_value());
    CHECK_FALSE(latch->rectFor(kFrameSize).has_value());
}

TEST_CASE("a lone pending release permits clean recalibration on the current frame") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    step(tracker, frameOfSize());
    REQUIRE(tracker.latched());

    tracker.requestRelease();
    step(tracker, frameOfSize(kWidth, kHeight, 2));

    CHECK(scan.calls() == 4);
    CHECK(tracker.latched());
    CHECK(tracker.correction() == std::optional<Rect<int>>{kOneMeasured});
    CHECK(latch->rectFor(kFrameSize) == std::optional<Rect<int>>{kOneMeasured});
}

TEST_CASE("repeating the same reported frame size does not release either latch") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    tracker.noteFrameSize(kFrameSize);
    step(tracker, frameOfSize());

    tracker.noteFrameSize(kFrameSize);
    (void) tracker.beginFrame(frameOfSize(kWidth, kHeight, 2));

    CHECK(tracker.latched());
    CHECK(latch->rectFor(kFrameSize) == std::optional<Rect<int>>{kOneMeasured});
}

// --- "silent anchor destruction": the enumeration -----------------------------------------------------
//
// The claim under test was that correction_ -- which is measured in PRE-SHAPING capture coordinates -- can be
// applied to a frame whose pixels a producer already cropped. Reaching the correction branch of beginFrame
// needs the conjunction of THREE facts, and the tests below hold each of them against a producer frame built
// through the real shaping seam (cv/frame_shaper.h) rather than by hand:
//
//   (i)   the frame carries no pane snapshot        -- beginFrame:224 routes a snapshot-bearing frame away
//   (ii)  correction_ is present                    -- which implies latched_ (updateState:305-307)
//   (iii) correction_ fits inside the shaped frame  -- isCropInsideFrame, beginFrame:227
//
// (i) and "the pixels are cropped" are mutually exclusive at the producer: shapeCapturedFrame crops only when
// the snapshot names a pane, and then attaches that same snapshot (frame_shaper.h:164-212). That is the
// binding constraint -- not anything inside this class.

constexpr int kWideWidth = 2326;
constexpr int kWideHeight = 1080;
const Size<int> kWideSize{kWideWidth, kWideHeight};
// The landscape shape this dispatch measured: the game surface occupies x=301..1037 of a 2326-px wide capture.
const Rect<int> kWideMeasured{{301, 0}, Size<int>{736, kWideHeight}};

TEST_CASE("a cropping producer's shaped frame never receives the pre-crop correction") {
    for (const auto mode : {frame_shaper::ShapingMode::CropPixels, frame_shaper::ShapingMode::CopiedRegion}) {
        FakeScan scan;
        scan.answer(pane::twoPaneCandidate(kWideSize), okFor(kWideMeasured));
        const auto latch = std::make_shared<PaneModeLatch>();
        DetailCropTracker tracker(scan.fn(), latch);
        step(tracker, frameOfSize(kWideWidth, kWideHeight));
        REQUIRE(tracker.correction() == std::optional<Rect<int>>{kWideMeasured});

        const auto snapshot = latch->snapshotFor(kWideSize);
        // CropPixels is handed the whole capture and copies the pane out; CopiedRegion is handed the pane's
        // pixels, already copied by the GPU/browser, starting at the pane's own origin.
        const bool whole = mode == frame_shaper::ShapingMode::CropPixels;
        const cv::Mat pixels = cv::Mat::zeros(
            whole ? kWideHeight : kWideMeasured.height(), whole ? kWideWidth : kWideMeasured.width(), CV_8UC3);
        const auto shaped = frame_shaper::shapeCapturedFrame(
            pixels,
            2,
            snapshot,
            mode,
            whole ? Point<int>{0, 0} : frame_shaper::paneCopyOrigin(snapshot),
            [&](const Size<int> &size) { return latch->snapshotFor(size); });
        REQUIRE(shaped.ok());
        REQUIRE(shaped.frame.size() == kWideMeasured.size());  // the pixels really are cropped

        const auto prepared = tracker.beginFrame(shaped.frame);
        REQUIRE(prepared.has_value());
        // The producer's own local anchor, NOT correction_ (which names x=301 in a frame only 736 px wide).
        CHECK(prepared->anchor().intersection() == Rect<int>{{0, 0}, kWideMeasured.size()});
        CHECK_FALSE(prepared->anchor().intersection() == kWideMeasured);
    }
}

TEST_CASE("a partial copy larger than the pane keeps the producer's local anchor, not the correction") {
    FakeScan scan;
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    scan.answer(pane::twoPaneCandidate(kWideSize), okFor(kWideMeasured));
    step(tracker, frameOfSize(kWideWidth, kWideHeight));
    REQUIRE(tracker.correction() == std::optional<Rect<int>>{kWideMeasured});

    // The worst shape for the claim: a copy origin small enough that correction_ still FITS inside the copied
    // pixels, so the containment gate would not refuse it. Web's even-alignment adjustment produces exactly
    // this family (a rectangle that merely contains the pane).
    const Point<int> copy_origin{2, 0};
    const cv::Mat pixels = cv::Mat::zeros(kWideHeight, kWideWidth - copy_origin.x(), CV_8UC3);
    const auto snapshot = latch->snapshotFor(kWideSize);
    const auto shaped = frame_shaper::shapeCapturedFrame(
        pixels, 2, snapshot, frame_shaper::ShapingMode::CopiedRegion, copy_origin, [&](const Size<int> &size) {
            return latch->snapshotFor(size);
        });
    REQUIRE(shaped.ok());
    REQUIRE(isCropInsideFrame(kWideMeasured, shaped.frame.size()));  // the gate alone would NOT have refused it

    const auto prepared = tracker.beginFrame(shaped.frame);
    REQUIRE(prepared.has_value());
    CHECK(prepared->anchor().intersection() == Rect<int>{kWideMeasured.topLeft() - copy_origin, kWideMeasured.size()});
    CHECK_FALSE(prepared->anchor().intersection() == kWideMeasured);
}

// The residual, stated as a fact rather than left implied: the correction branch DOES mis-anchor cropped
// pixels -- it is simply unreachable, because the only thing that produces cropped pixels also attaches the
// snapshot that routes them away from it. This test builds the frame by hand, bypassing shapeCapturedFrame,
// and is therefore evidence about the guard's necessity, NOT about a reachable defect. The test below it
// pins that no shaping mode can emit such a frame.
TEST_CASE("only a producer bypassing the shaping seam can reach the correction with cropped pixels") {
    FakeScan scan;
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    scan.answer(pane::twoPaneCandidate(kWideSize), okFor(kWideMeasured));
    step(tracker, frameOfSize(kWideWidth, kWideHeight));

    const Point<int> copy_origin{2, 0};
    const Frame hand_built = frameOfSize(kWideWidth - copy_origin.x(), kWideHeight, 2)
                                 .reanchored({kWideMeasured.topLeft() - copy_origin, kWideMeasured.size()});
    REQUIRE_FALSE(hand_built.paneModeSnapshot().has_value());

    const auto prepared = tracker.beginFrame(hand_built);
    REQUIRE(prepared.has_value());
    // Off by the copy origin: the pre-crop rectangle applied to post-crop pixels.
    CHECK(prepared->anchor().intersection() == kWideMeasured);
    CHECK_FALSE(prepared->anchor().intersection() == hand_built.anchor().intersection());
}

TEST_CASE("no shaping mode can emit cropped pixels without a pane snapshot naming that crop") {
    const cv::Mat captured = cv::Mat::zeros(kWideHeight, kWideWidth, CV_8UC3);
    for (const auto mode :
         {frame_shaper::ShapingMode::CropPixels,
          frame_shaper::ShapingMode::AnchorOnly,
          frame_shaper::ShapingMode::CopiedRegion}) {
        // No pane decision at all, and a decision that resolved to "nothing latched": the only two ways a
        // shaped frame can come out without a rect-bearing snapshot.
        for (const auto &snapshot :
             std::vector<std::optional<PaneModeLatch::Snapshot>>{
                 std::nullopt, PaneModeLatch::Snapshot{kWideSize, 0, std::nullopt}}) {
            const auto shaped = frame_shaper::shapeCapturedFrame(captured, 1, snapshot, mode);
            REQUIRE(shaped.ok());
            // Full capture every time -- so a frame that reaches the correction branch is never a cropped one.
            CHECK(shaped.frame.size() == kWideSize);
        }
    }
}

TEST_CASE("the correction is never present while the tracker is unlatched") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);

    CHECK((!tracker.correction().has_value() || tracker.latched()));  // before anything
    step(tracker, frameOfSize());
    CHECK((!tracker.correction().has_value() || tracker.latched()));  // latched
    tracker.requestRelease();
    (void) tracker.beginFrame(frameOfSize(kWidth, kHeight, 2));
    CHECK_FALSE(tracker.latched());
    CHECK((!tracker.correction().has_value() || tracker.latched()));  // released: both gone together
    CHECK_FALSE(tracker.correction().has_value());
}

// The other half of the claim: that a portrait capture "silently falls back to the default anchor". Through
// the real seam it does not fall back -- the geometry change releases the latch, which makes the in-flight
// shaped frame's snapshot stale, and beginFrame drops the frame instead of anchoring it wrongly.
TEST_CASE("a shaped frame whose capture geometry changed is dropped, not silently default-anchored") {
    FakeScan scan;
    scan.answer(pane::onePaneCandidate(kFrameSize), okFor(kOneMeasured));
    const auto latch = std::make_shared<PaneModeLatch>();
    DetailCropTracker tracker(scan.fn(), latch);
    tracker.noteFrameSize(kFrameSize);
    step(tracker, frameOfSize());
    REQUIRE(tracker.latched());

    // The producer resolves its decision for the OLD size, then the reported geometry changes (updateFrame
    // calls noteFrameSize before the send, so the release is armed no later than the new frame).
    const auto snapshot = latch->snapshotFor(kFrameSize);
    REQUIRE(snapshot.rect.has_value());
    const cv::Mat pixels = cv::Mat::zeros(kOneMeasured.height(), kOneMeasured.width(), CV_8UC3);
    const auto shaped = frame_shaper::shapeCapturedFrame(
        // No revalidate: this test drives the geometry change AFTER the copy, so the producer-side
        // re-check has nothing to see and the consumer-side check is the one under test.
        pixels, 2, snapshot, frame_shaper::ShapingMode::CopiedRegion, frame_shaper::paneCopyOrigin(snapshot));
    REQUIRE(shaped.ok());
    tracker.noteFrameSize({kWidth + 8, kHeight});

    CHECK_FALSE(tracker.beginFrame(shaped.frame).has_value());
}

}  // namespace
}  // namespace uma
