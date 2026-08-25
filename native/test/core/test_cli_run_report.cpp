// Contract test for the CLI's machine-readable account of a run (cli::RunReport).
//
// This is the CLI front end's only channel. Everything a driver can learn about a run -- did the pipeline
// report a terminal error, did it produce anything, did it throw away a half-captured character -- has to come
// off this one line and this one exit code, because the alternative is grepping spdlog prose. So what is pinned
// here is the CONTRACT rather than the formatting: the exit code's three-way classification, the counts and
// their unit, and the fact that a payload this cannot read is counted instead of vanishing.
//
// Driven directly rather than through the CLI, whose translation unit umacapture_tests deliberately does not
// compile (see the target's comment in native/CMakeLists.txt); the report is header-only for exactly that
// reason, like RecordProductionCounter next to it.

#include <doctest/doctest.h>

#include <string>
#include <thread>
#include <vector>

#include "core/cli_run_report.h"
#include "core/native_api_messages.h"
#include "util/json_util.h"

namespace uma::cli {
namespace {

// The `onError` tag a session that ended before it completed is reported with (NativeApi's
// closed_before_completed listener). Spelled out here rather than shared with the emitter because that
// translation unit is not compiled into this target; a rename there is caught by the golden cases in
// native/test/integration/cases.json, which assert the same string end to end.
constexpr const char *kIncompleteSessionTag = "closed_before_completed";

// The summary line, parsed back the way a harness would: strip the marker, parse the remainder.
json_util::Json summaryJsonOf(const RunReport &report, const RunInvocation &run) {
    const auto line = report.summaryLine(run);
    const std::string marker = std::string(kRunSummaryMarker) + " ";
    REQUIRE(line.rfind(marker, 0) == 0);
    // One line, always: a consumer scanning a mixed stream splits on newlines before it parses.
    REQUIRE(line.find('\n') == std::string::npos);
    return json_util::Json::parse(line.substr(marker.size()));
}

TEST_CASE("a run that reported nothing is a clean run") {
    RunReport report;
    CHECK(report.errorTotal() == 0);
    CHECK(report.exitCode(false) == kExitOk);

    const auto json = summaryJsonOf(report, RunInvocation{"video", 1, 3, kExitOk});
    CHECK(json["records"].get<int64_t>() == 3);
    CHECK(json["errors"].empty());
    CHECK(json["error_total"].get<int64_t>() == 0);
    CHECK(json["discarded"].get<int64_t>() == 0);
    CHECK(json["exit"].get<int>() == kExitOk);
}

TEST_CASE("a reported terminal error is named and turns the exit code non-zero") {
    // The empty-clip case this whole change exists for: zero records AND an announcement, which a driver must
    // be able to tell apart from a build that could not start (kExitDidNotRun).
    RunReport report;
    report.observe(app::messages::error(kIncompleteSessionTag));

    CHECK(report.errorTotal() == 1);
    CHECK(report.exitCode(false) == kExitReportedError);
    CHECK(report.exitCode(false) != kExitDidNotRun);

    const auto json = summaryJsonOf(report, RunInvocation{"video", 1, 0, kExitReportedError});
    REQUIRE(json["errors"].size() == 1);
    CHECK(json["errors"][0].get<std::string>() == std::string(kIncompleteSessionTag));
    CHECK(json["records"].get<int64_t>() == 0);
}

TEST_CASE("two different causes stay distinguishable on the line") {
    // The line carries a SET of causes, not a count of them: a run that only lost a session and one that also
    // failed to stitch must not read alike, or a harness asserting the first would pass on the second.
    RunReport incomplete;
    incomplete.observe(app::messages::error(kIncompleteSessionTag));
    RunReport stitch;
    stitch.observe(app::messages::error("stitch_failed"));

    CHECK(incomplete.errorTags() != stitch.errorTags());
    CHECK(incomplete.errorTags().at(0) == std::string(kIncompleteSessionTag));
    CHECK(stitch.errorTags().at(0) == "stitch_failed");
}

TEST_CASE("one cause reported many times is one tag and many occurrences") {
    RunReport report;
    for (int i = 0; i < 5; i++) {
        report.observe(app::messages::error(kIncompleteSessionTag));
    }
    report.observe(app::messages::error("stitch_failed"));

    CHECK(report.errorTotal() == 6);
    const auto tags = report.errorTags();
    REQUIRE(tags.size() == 2);
    // First-seen order, so the line reads as a history rather than as a set.
    CHECK(tags[0] == std::string(kIncompleteSessionTag));
    CHECK(tags[1] == "stitch_failed");
}

TEST_CASE("a discard that had already produced its record is not counted as a loss") {
    // An ordinary two-character clip switches once and loses nothing; only the incomplete discard is a lost
    // character. Reporting the two alike would make the loud path fire on every legitimate switch, which is the
    // design the user already rejected.
    RunReport report;
    report.observe(app::messages::charaDetailRestarted(true));
    report.observe(app::messages::charaDetailRestarted(false));

    CHECK(report.discardedSessions() == 2);
    CHECK(report.discardedIncomplete() == 1);

    const auto json = summaryJsonOf(report, RunInvocation{"video", 1, 1, kExitOk});
    CHECK(json["discarded"].get<int64_t>() == 2);
    CHECK(json["discarded_incomplete"].get<int64_t>() == 1);
}

TEST_CASE("a discard whose completed flag is missing counts as a loss") {
    // Absence must err towards announcing a loss, matching what native_api_messages.h states about the field.
    // The opposite default would let an older core's message read as "nothing was lost".
    RunReport report;
    report.observe(R"({"type":"onCharaDetailRestarted"})");
    CHECK(report.discardedSessions() == 1);
    CHECK(report.discardedIncomplete() == 1);
}

TEST_CASE("a failed record is counted, and does not inflate the produced count") {
    // The produced count is the core's (RunInvocation::records) and is never recomputed from this stream; what
    // the stream adds is the failures, which the count deliberately excludes.
    RunReport report;
    report.observe(app::messages::charaDetailFinished("ok-id", true, false));
    report.observe(app::messages::charaDetailFinished("bad-id", false, false));

    CHECK(report.failedRecords() == 1);
    const auto json = summaryJsonOf(report, RunInvocation{"video", 1, 1, kExitOk});
    CHECK(json["failed"].get<int64_t>() == 1);
    CHECK(json["records"].get<int64_t>() == 1);
}

TEST_CASE("the line states its unit and how many inputs that unit covered") {
    // `video --video_path_list a b c` is ONE run over three clips: the loader concatenates their media times
    // and the pipeline is never drained at a boundary, so no per-clip count exists to report. The line has to
    // say that rather than let a reader assume its counts are per clip.
    RunReport report;
    const auto json = summaryJsonOf(report, RunInvocation{"video", 3, 2, kExitOk});
    CHECK(json["unit"].get<std::string>() == "run");
    CHECK(json["inputs"].get<int64_t>() == 3);
    CHECK(json["subcommand"].get<std::string>() == "video");
    CHECK(json["schema"].get<int>() == kRunSummarySchema);
}

TEST_CASE("the line states the geometry the run recognized at") {
    // The band's ONLY observable from outside the core. A run's records cannot carry it, in either of the
    // band's regimes: the shipped 540-720 band's clamp changed no golden on any clip this project holds while
    // it still fired on them, and it no longer fires on them at all now that Frame::kShrinkDeadband holds the
    // shrink arm off until 1080 px -- the clips reach recognition at their own 735-737 and the goldens are
    // byte-identical across that change too -- so a harness that wants to know
    // whether the frames actually reached recognition at the configured geometry has this line and nothing
    // else. native/test/integration/run.py asserts these three keys per case.
    RunReport report;
    RunInvocation run{"video", 1, 1, kExitOk};
    run.forwarded_frames = 412;
    run.anchor_unit_min = 720;
    run.anchor_unit_max = 720;
    const auto json = summaryJsonOf(report, run);
    CHECK(json["forwarded_frames"].get<int64_t>() == 412);
    CHECK(json["anchor_unit_min"].get<int>() == 720);
    CHECK(json["anchor_unit_max"].get<int>() == 720);
}

TEST_CASE("a run that forwarded no frame reports the count, not a geometry of zero") {
    // `forwarded_frames` is what makes the two bounds readable. A run in which no chara-detail scene ever
    // committed reports 0 frames and 0..0, and a consumer that read only the bounds would take that for a
    // measured geometry -- so the count is on the line beside them, not left to be inferred.
    RunReport report;
    const auto json = summaryJsonOf(report, RunInvocation{"video", 1, 0, kExitOk});
    CHECK(json["forwarded_frames"].get<int64_t>() == 0);
    CHECK(json["anchor_unit_min"].get<int>() == 0);
    CHECK(json["anchor_unit_max"].get<int>() == 0);
}

TEST_CASE("a notification that cannot be read is counted, never dropped") {
    // The mechanism that exists to end silent failures must not have a silent failure of its own.
    RunReport report;
    report.observe("not json at all");
    report.observe("[1,2,3]");            // valid JSON, wrong shape
    report.observe(R"({"no":"type"})");   // object without the tag every message carries
    CHECK(report.unparsed() == 3);
    CHECK(report.errorTotal() == 0);

    const auto json = summaryJsonOf(report, RunInvocation{"video", 1, 0, kExitOk});
    CHECK(json["unparsed"].get<int64_t>() == 3);
}

TEST_CASE("a notification this report does not classify is not an anomaly") {
    // Most of the stream is progress and lifecycle chatter. It is read successfully and contributes nothing --
    // which is different from being unreadable, and must not show up as `unparsed`.
    RunReport report;
    report.observe(app::messages::charaDetailStarted());
    report.observe(app::messages::scrollReady(1));
    report.observe(app::messages::captureStopped());
    CHECK(report.unparsed() == 0);
    CHECK(report.errorTotal() == 0);
    CHECK(report.discardedSessions() == 0);
}

TEST_CASE("a run that threw exits as did-not-run whatever it managed to announce") {
    // "It threw" and "it ran and reported a failure" are different facts about the run, and the throw wins: a
    // run that stopped early cannot have its verdict believed. Collapsing them would let a broken build pass a
    // harness case that expects an announced emptiness.
    RunReport report;
    report.observe(app::messages::error(kIncompleteSessionTag));
    CHECK(report.exitCode(true) == kExitDidNotRun);

    RunReport quiet;
    CHECK(quiet.exitCode(true) == kExitDidNotRun);
    CHECK(quiet.exitCode(false) == kExitOk);
}

TEST_CASE("no exit code collides with ctest's Skipped") {
    // 77 is ctest's SKIP_RETURN_CODE (native/CMakeLists.txt) and tool/live_capture_test/run_capture.cmd passes
    // this process's code straight through, so a CLI value of 77 would read as "this never ran".
    CHECK(kExitOk != 77);
    CHECK(kExitDidNotRun != 77);
    CHECK(kExitReportedError != 77);
    // And the three have to stay three: two of them sharing a value is the one-bit collapse this design refused.
    CHECK(kExitOk != kExitDidNotRun);
    CHECK(kExitOk != kExitReportedError);
    CHECK(kExitDidNotRun != kExitReportedError);
}

TEST_CASE("observing is safe from the threads that actually notify") {
    // The notify callback runs on whichever pipeline thread produced the event (distributor, recognizer,
    // stitcher) while the summary is composed on the main thread. Not a race detector -- a smoke test that
    // concurrent observations lose nothing.
    RunReport report;
    std::vector<std::thread> threads;
    threads.reserve(4);
    for (int t = 0; t < 4; t++) {
        threads.emplace_back([&report]() {
            for (int i = 0; i < 100; i++) {
                report.observe(app::messages::error(kIncompleteSessionTag));
            }
        });
    }
    for (auto &thread : threads) {
        thread.join();
    }
    CHECK(report.errorTotal() == 400);
    CHECK(report.errorTags().size() == 1);
}

}  // namespace
}  // namespace uma::cli
