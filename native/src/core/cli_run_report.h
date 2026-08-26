#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "util/json_util.h"

// WHAT ONE CLI INVOCATION DID, as data instead of prose.
//
// The CLI is a front end (.claude/rules/platform-parity.md puts it alongside Windows and web on every path that
// is not a display surface), and until now its only channel was a spdlog line. That made two very different
// endings indistinguishable to anything driving it: a run that recognized nothing and announced so, and a run
// that produced records cleanly, both printed a wall of DEBUG and returned 0. A harness could only tell them
// apart by grepping English.
//
// So this collects the terminal facts off the notify stream -- the same stream Dart and the web worker read --
// and turns them into ONE line a machine can parse, plus a classified exit code. It observes; it never decides
// what the pipeline does.
//
// WHY IT IS A HEADER, and not a lambda inside cli.cpp: cli.cpp is not compiled into umacapture_tests (that
// target deliberately links pure-logic sources only -- see native/CMakeLists.txt), so anything living there is
// asserted by nothing. The wire tags this classifies are load-bearing strings that no C++ type checks, which is
// the same reason the rest of the wire vocabulary lives in native_api_messages.h rather than at its emitters.
namespace uma::cli {

// PROCESS EXIT CODES. Three outcomes, three values, because collapsing the last two into one non-zero would
// leave "the clip contained nothing and the run said so" and "the build is broken" reading identically -- and a
// harness asserting the first would then pass on the second (a pass-by-vacuum, which
// test/integration/run_dual_decode.py already refuses by name).
//
// 77 IS DELIBERATELY NOT USED and must stay unused: ctest reads 77 as Skipped (SKIP_RETURN_CODE in
// native/CMakeLists.txt), and tool/live_capture_test/run_capture.cmd already passes this process's code
// straight through to its caller. A CLI exit of 77 would be read as "this test did not run".
//
// CLI11's own parse failures are outside this scale: it returns its own codes (and 0 for --help) from
// CLI11_PARSE before anything starts. That is still "could not run", just reported by the parser.
inline constexpr int kExitOk = 0;
// The subcommand threw: bad arguments, an unopenable clip, a pipeline that did not drain within its deadline.
// Nothing can be concluded about the run, because it did not finish. Kept at 1 -- the value main() has always
// returned for this -- so no existing caller changes meaning.
inline constexpr int kExitDidNotRun = 1;
// The subcommand ran to the end AND the pipeline reported at least one terminal error (an `onError`, which is
// what the front ends translate into a failure tile). The run's verdict is in the summary line.
inline constexpr int kExitReportedError = 2;

// The line's first token, so a consumer can find it in a stream that also carries spdlog output without
// matching on JSON shape. Fixed and greppable on purpose.
inline constexpr const char *kRunSummaryMarker = "UMACAPTURE_RUN_SUMMARY";

// Bumped when a key changes meaning or disappears, so a harness pinned to an older CLI fails loudly instead of
// reading a field that moved.
inline constexpr int kRunSummarySchema = 1;

// The parts of the summary the report cannot observe for itself: what the process was asked to do, and what it
// is about to return.
struct RunInvocation {
    // Which subcommand ran -- "video", "replay", "stitch", "recognize", "capture". Only the subcommands that
    // start the pipeline produce a summary at all; `build` and `screenshot` never touch NativeApi.
    std::string subcommand;
    // How many inputs the command line named: clips for `video`, record ids for `recognize`, 1 for `replay`,
    // 0 for live `capture`. This is what makes the run/clip distinction visible -- see the `unit` key.
    int64_t inputs = 0;
    // The core's own count for this run (app::NativeApi::recordsProduced), READ AFTER THE DRAIN BARRIER. Passed
    // in rather than recounted from the notify stream: the count is a fact the core states, and a second
    // reconstruction here would be a second chance to disagree with it (.claude/rules/design-priorities.md).
    int64_t records = 0;
    // The code main() is about to return, so the line and the process can never tell different stories -- in
    // particular for a run that threw, where the report itself saw no error.
    int exit_code = kExitOk;
    // WHAT GEOMETRY THE RUN RECOGNIZED AT (app::NativeApi::forwardedFrameGeometry), READ AFTER THE DRAIN
    // BARRIER, exactly like `records` and for the same reason.
    //
    // This is the only channel through which the `frame_resize` band is observable from outside the core at
    // all. The records are not one, and that was true in both of the band's regimes: while the band still
    // clamped this material (~736 -> 720) the step changed no record, and now that Frame::kShrinkDeadband
    // holds the shrink arm off until 1080 px the same clips are forwarded unresized -- and the records are
    // byte-identical across that change too (measured, 2026-08-19). A build that never armed the band
    // reproduces every golden byte for byte either way. Without these three numbers a harness can only pin
    // the band by measuring the pixel width of
    // a scrape artefact -- a property of the scraper config and of temp-file retention rather than of the
    // pipeline -- or not pin it at all, which is what left a regression costing the shipping path a factor of
    // two in speed with no test signal.
    //
    // Passed in rather than observed off the notify stream, because the notify stream does not carry it: the
    // frame path is not notified per frame, and adding a per-frame notification to make it observable here
    // would put a wire message on the hot path of all three front ends to serve one harness.
    //
    // DELIBERATELY LAST in the struct, after exit_code: every construction site -- cli.cpp and the contract
    // test -- uses positional aggregate initialisation, so a field inserted above would silently re-bind those
    // arguments to different members. The declaration order is a load-bearing part of this struct's interface.
    int64_t forwarded_frames = 0;
    int anchor_unit_min = 0;
    int anchor_unit_max = 0;
};

// Accumulates the notify stream of one invocation.
//
// Thread-safe because the notify callback is invoked from whichever pipeline thread produced the event (the
// distributor's, the recognizer's, the stitcher's), while the summary is composed on the main thread after the
// event loop has been joined.
class RunReport {
public:
    // One notification payload, exactly as NativeApi handed it to the callback.
    //
    // NEVER THROWS. It runs inside the notify callback, on a pipeline thread, and a throw there would escape
    // into a runner -- so a payload this cannot parse is COUNTED (`unparsed`) rather than dropped. Silently
    // ignoring it would rebuild, inside the very mechanism meant to end silent failures, the defect that
    // something happened and nobody was told.
    void observe(const std::string &notification) {
        const auto json = json_util::Json::parse(notification, nullptr, false);
        std::lock_guard<std::mutex> lock(mutex);
        if (json.is_discarded() || !json.is_object() || !json.contains("type") || !json["type"].is_string()) {
            unparsed_count += 1;
            return;
        }
        const auto type = json["type"].get<std::string>();
        if (type == "onError") {
            noteErrorLocked(json.contains("message") && json["message"].is_string()
                                ? json["message"].get<std::string>()
                                : std::string());
        } else if (type == "onCharaDetailRestarted") {
            discarded_count += 1;
            // ABSENT MEANS NOT COMPLETED, matching what native_api_messages.h states about this field: the
            // default has to err towards announcing a loss, never towards the silence this change removes.
            if (!(json.contains("completed") && json["completed"].is_boolean() && json["completed"].get<bool>())) {
                discarded_incomplete_count += 1;
            }
        } else if (type == "onCharaDetailFinished") {
            // Only the failures are counted here. The successes are the core's count (RunInvocation::records),
            // and counting them twice is how the two would come to disagree.
            if (!(json.contains("success") && json["success"].is_boolean() && json["success"].get<bool>())) {
                failed_record_count += 1;
            }
        }
    }

    // How many `onError` notifications arrived, all causes together. This is the predicate the exit code turns
    // on: "the pipeline reported a terminal error", not "the run produced no records". The two are different
    // questions and the summary answers both separately.
    [[nodiscard]] int64_t errorTotal() const {
        std::lock_guard<std::mutex> lock(mutex);
        return error_total;
    }

    // The distinct error messages, in the order they were first seen. For a session that ended early this is
    // exactly the tag the front ends translate (`closed_before_completed`); for anything else they are the
    // English prose that was reported. Deduped so that a run reporting one cause a hundred times still names
    // one cause -- `error_total` keeps the hundred.
    [[nodiscard]] std::vector<std::string> errorTags() const {
        std::lock_guard<std::mutex> lock(mutex);
        return error_tags;
    }

    [[nodiscard]] int64_t discardedSessions() const {
        std::lock_guard<std::mutex> lock(mutex);
        return discarded_count;
    }

    [[nodiscard]] int64_t discardedIncomplete() const {
        std::lock_guard<std::mutex> lock(mutex);
        return discarded_incomplete_count;
    }

    [[nodiscard]] int64_t failedRecords() const {
        std::lock_guard<std::mutex> lock(mutex);
        return failed_record_count;
    }

    [[nodiscard]] int64_t unparsed() const {
        std::lock_guard<std::mutex> lock(mutex);
        return unparsed_count;
    }

    // The code the process has earned. `threw` is the caller's own fact (the subcommand raised), and it WINS
    // over a reported error: a run that did not finish cannot have its verdict believed, whatever it managed to
    // announce before it stopped.
    [[nodiscard]] int exitCode(bool threw) const {
        if (threw) {
            return kExitDidNotRun;
        }
        return errorTotal() > 0 ? kExitReportedError : kExitOk;
    }

    // The one machine-readable line: the marker, a space, then one JSON object on one line.
    //
    // ON `unit`. The counts cover the WHOLE INVOCATION and not one clip, and the key says so rather than
    // leaving a reader to assume. It cannot be per clip: `video --video_path_list a b c` decodes the files as
    // one continuous media stream (VideoLoader::runBatch accumulates the timestamp across them), so a session
    // opened in `a` may well complete during `b`, and the pipeline is never drained at the boundary. There is
    // no instant at which a per-clip count would be a fact rather than a guess about scheduling. `inputs` is
    // therefore reported beside it: a consumer that needs per-clip attribution can see from `inputs > 1` that
    // this run cannot give it, and split the invocation instead.
    [[nodiscard]] std::string summaryLine(const RunInvocation &run) const {
        std::lock_guard<std::mutex> lock(mutex);
        const json_util::Json json{
            {"schema", kRunSummarySchema},
            {"subcommand", run.subcommand},
            {"unit", "run"},
            {"inputs", run.inputs},
            {"records", run.records},
            {"failed", failed_record_count},
            {"discarded", discarded_count},
            {"discarded_incomplete", discarded_incomplete_count},
            {"errors", error_tags},
            {"error_total", error_total},
            {"unparsed", unparsed_count},
            // THE GEOMETRY THAT REACHED RECOGNITION. `anchor_unit_*` is the intersection width of the frames
            // the scraper actually scraped -- min and max, because the unit may legitimately move within a run
            // (see ForwardedFrameGeometryObserver). `forwarded_frames` is what says whether the two bounds
            // describe anything at all; a consumer that skipped it would read 0..0 for a run in which no
            // chara-detail scene ever committed and take it for a measured geometry.
            //
            // NOT A SCHEMA BUMP. These keys are ADDED; none of the existing ones changed meaning or went away,
            // which is what kRunSummarySchema says it is bumped for. A harness that requires the geometry and
            // meets an older CLI does not misread anything -- the keys are simply absent, and it fails on that.
            {"forwarded_frames", run.forwarded_frames},
            {"anchor_unit_min", run.anchor_unit_min},
            {"anchor_unit_max", run.anchor_unit_max},
            {"exit", run.exit_code}};
        // Same `replace` error handler messages::error uses, and for the same measured reason: a reported
        // what() can carry CP932 bytes on a Japanese Windows, and a strict dump() would throw here -- inside the
        // one line whose whole job is to make the failure visible.
        return std::string(kRunSummaryMarker) + " "
               + json.dump(-1, ' ', false, json_util::Json::error_handler_t::replace);
    }

private:
    void noteErrorLocked(std::string message) {
        error_total += 1;
        for (const auto &seen : error_tags) {
            if (seen == message) {
                return;
            }
        }
        error_tags.push_back(std::move(message));
    }

    mutable std::mutex mutex;
    int64_t error_total = 0;
    std::vector<std::string> error_tags;
    int64_t discarded_count = 0;
    int64_t discarded_incomplete_count = 0;
    int64_t failed_record_count = 0;
    int64_t unparsed_count = 0;
};

}  // namespace uma::cli
