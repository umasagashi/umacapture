// Contract tests for the notification payloads NativeApi pushes to Dart.
//
// The Dart side dispatches on the "type" string and reads each message's keys by name, so a renamed key or
// tag is a silent break that the C++ type system cannot catch. These lock the exact JSON each builder emits.
// Both sides are parsed into json_util::Json and compared by value, so the checks are independent of the key
// ordering .dump() happens to produce. The expected side is written as a raw JSON literal (the actual wire
// format) rather than a nested brace-init to avoid nlohmann's object/array initializer-list ambiguity.

#include <doctest/doctest.h>

#include <optional>
#include <string>
#include <vector>

#include "chara_detail/chara_detail_record.h"
#include "core/native_api_messages.h"
#include "util/json_util.h"

namespace uma::app::messages {
namespace {

using json_util::Json;

// Parses both the builder output and the expected raw JSON and checks value equality (order-independent).
void checkMessage(const std::string &built, const std::string &expected) {
    CHECK(Json::parse(built) == Json::parse(expected));
}

TEST_CASE("no-argument messages carry only their type tag") {
    checkMessage(captureStarted(), R"({"type":"onCaptureStarted"})");
    checkMessage(captureStopped(), R"({"type":"onCaptureStopped"})");
    checkMessage(charaDetailClosed(), R"({"type":"onCharaDetailClosed"})");
}

TEST_CASE("a session start names the id its record will finish under, and nothing else") {
    // The id is what a front end matches every later outcome of this attempt against (onCharaDetailFinished's
    // `id`, and the `record_id` of a probe or a scoped error), so the key and its value are the contract.
    checkMessage(charaDetailStarted("rec-1"), R"({"type":"onCharaDetailStarted","record_id":"rec-1"})");
}

TEST_CASE("a mid-scene reset reports whether the session it discarded had completed, and the id it built") {
    checkMessage(
        charaDetailRestarted(false, "rec-2"),
        R"({"type":"onCharaDetailRestarted","completed":false,"record_id":"rec-2"})");
    checkMessage(
        charaDetailRestarted(true, "rec-3"),
        R"({"type":"onCharaDetailRestarted","completed":true,"record_id":"rec-3"})");
}

TEST_CASE("a discard is distinguishable from a start by more than its tag") {
    // A tag difference alone is not enough: with an empty restart message, the only thing a receiver can do
    // with the difference is ignore it and dispatch the pair into one branch. Both begin an attempt and name
    // it; only the discard carries the one bit that says whether anything was lost with it.
    const Json started = Json::parse(charaDetailStarted("rec-1"));
    const Json restarted = Json::parse(charaDetailRestarted(false, "rec-1"));
    CHECK(started.at("type") != restarted.at("type"));
    CHECK(started.size() == 2);
    CHECK_FALSE(started.contains("completed"));
    CHECK(restarted.at("completed") == false);
    CHECK(started.at("record_id") == restarted.at("record_id"));
}

TEST_CASE("a discarded session that had already produced its record says so") {
    // The field that keeps an ordinary two-character clip quiet. A reset fires on every legitimate switch, and
    // the switch that follows a FINISHED capture threw nothing away -- the record went to the stitcher before
    // it. A front end counting discards without reading this would report a loss for every character the user
    // captured successfully, which is worse than the silence it replaces.
    const Json kept = Json::parse(charaDetailRestarted(true, "rec-built"));
    CHECK(kept.at("completed") == true);
    const Json lost = Json::parse(charaDetailRestarted(false, "rec-built"));
    CHECK(lost.at("completed") == false);
}

TEST_CASE("a discard carries the completion bit and the built session's id, and nothing about the discarded one") {
    // THE WIRE IS DELIBERATELY THIS NARROW. The discarded session's id and its captured-tab count were both
    // carried at first and neither was ever read to decide anything, so they were taken back off: a field that
    // has to be parsed, defaulted and kept in step on three front ends has to buy something. The discarded id
    // still goes to the log at the discard site, which is where a discard is actually traced. The one id on the
    // wire is the BUILT session's, under the same key a start uses: which session's id it is cannot be told from
    // here (the builder is handed one string), so that half is pinned by the scraper test that drives a reset.
    const Json parsed = Json::parse(charaDetailRestarted(false, "rec-built"));
    CHECK(parsed.size() == 3);
    CHECK(parsed.at("record_id") == "rec-built");
    CHECK_FALSE(parsed.contains("id"));
    CHECK_FALSE(parsed.contains("captured_tabs"));
}

TEST_CASE("string-payload messages") {
    checkMessage(
        screenshotTaken("C:/tmp/shot.png", "ok"),
        R"({"type":"onScreenshotTaken","path":"C:/tmp/shot.png","result":"ok"})");
    checkMessage(error("boom"), R"({"type":"onError","message":"boom"})");
}

TEST_CASE("an error that ends one attempt names it, and any other error names none") {
    // Absence is the meaning of the unscoped form: "not about any one attempt". A front end fails the card for a
    // scoped error only when the id is the attempt it is showing.
    checkMessage(
        error("stitch_failed", "rec-1"), R"({"type":"onError","message":"stitch_failed","record_id":"rec-1"})");
    CHECK_FALSE(Json::parse(error("stitch_failed")).contains("record_id"));
    // The scoped form keeps the unscoped one's tolerance for a non-UTF-8 message.
    std::string built;
    CHECK_NOTHROW(built = error("boom: \x8e\xc0\x8d\x73", "rec-1"));
    CHECK(Json::parse(built).at("record_id") == "rec-1");
}

TEST_CASE("a tab's wait states the level and the page's structure, and omits the structure until it is known") {
    checkMessage(
        tabAwaitingHead(0, true, true), R"({"type":"onTabAwaitingHead","index":0,"awaiting":true,"scroll_bar":true})");
    checkMessage(
        tabAwaitingHead(1, false, false),
        R"({"type":"onTabAwaitingHead","index":1,"awaiting":false,"scroll_bar":false})");
    // ABSENT, not false and not null: a reader treats the missing key as "not established", and a `false` here would
    // tell it the tab has no scroll bar before anything has looked at it.
    checkMessage(tabAwaitingHead(2, true, std::nullopt), R"({"type":"onTabAwaitingHead","index":2,"awaiting":true})");
    CHECK_FALSE(Json::parse(tabAwaitingHead(2, true, std::nullopt)).contains("scroll_bar"));
}

TEST_CASE("the switch witness is a level with one key, in both directions") {
    checkMessage(factorSwitchArmed(true), R"({"type":"onFactorSwitchArmed","armed":true})");
    checkMessage(factorSwitchArmed(false), R"({"type":"onFactorSwitchArmed","armed":false})");
}

TEST_CASE("error survives a non-UTF-8 message instead of throwing") {
    // The message often embeds an exception's what(), which can carry non-UTF-8 bytes (e.g. a
    // CP932-localized system message). A strict dump() would throw here and the onError notification
    // would never reach Dart; error() must degrade the bytes (U+FFFD) and still produce valid JSON.
    const std::string cp932_like = "boom: \x8e\xc0\x8d\x73";
    std::string built;
    CHECK_NOTHROW(built = error(cp932_like));
    const Json parsed = Json::parse(built);
    CHECK(parsed.at("type") == "onError");
    const auto message = parsed.at("message").get<std::string>();
    CHECK(message.rfind("boom: ", 0) == 0);
}

TEST_CASE("scroll messages") {
    checkMessage(scrollReady(3), R"({"type":"onScrollReady","index":3})");
    checkMessage(pageReady(2), R"({"type":"onPageReady","index":2})");
    checkMessage(scrollUpdated(1, 0.25), R"({"type":"onScrollUpdated","index":1,"progress":0.25})");
    // Three-valued, not a bool: "unknown" is on the wire because the front end's two consumers of this fact
    // resolve a missing reading in opposite directions (see messages::scrollPosition). Pinning all three words
    // here is what keeps a later "simplification" back to a yes/no from being silent.
    checkMessage(scrollPosition(0, "at_top"), R"({"type":"onScrollPosition","index":0,"top_of_content":"at_top"})");
    checkMessage(
        scrollPosition(4, "scrolled"), R"({"type":"onScrollPosition","index":4,"top_of_content":"scrolled"})");
    checkMessage(
        scrollPosition(1, "unknown"), R"({"type":"onScrollPosition","index":1,"top_of_content":"unknown"})");
}

TEST_CASE("a tab refusal states the tab, the level and the machine reason") {
    // The withdrawal travels on the SAME type with refused=false, so a front end holding one value per index
    // needs no second message type; pinning both directions here is what keeps that contract from drifting
    // into a paired "cleared" message later.
    checkMessage(
        tabRefused(1, true, "scrolled"), R"({"type":"onTabRefused","index":1,"refused":true,"reason":"scrolled"})");
    checkMessage(
        tabRefused(1, false, ""), R"({"type":"onTabRefused","index":1,"refused":false,"reason":""})");
    checkMessage(
        tabRefused(0, true, "unknown"), R"({"type":"onTabRefused","index":0,"refused":true,"reason":"unknown"})");
}

TEST_CASE("chara-detail record messages use the id/success keys") {
    checkMessage(charaDetailFinished("rec-1", true), R"({"type":"onCharaDetailFinished","id":"rec-1","success":true})");
    checkMessage(charaDetailFinished("rec-2", false), R"({"type":"onCharaDetailFinished","id":"rec-2","success":false})");
    checkMessage(charaDetailUpdated("rec-3"), R"({"type":"onCharaDetailUpdated","id":"rec-3"})");
}

TEST_CASE("chara-detail finish omits origin for a live capture and names it for a video import") {
    // ABSENT MEANS LIVE, and that direction is the contract rather than an accident of the default argument.
    // The Dart side asks `data['origin'] == harvestOriginVideoImport` (lib/src/core/video_import_ops.dart), so a
    // message that grew an origin for live capture -- or lost it for an import -- would flip which session has
    // its duplicate cue silenced. Both directions are locked, because only the pair pins the default.
    CHECK(Json::parse(charaDetailFinished("rec-live", true)).contains("origin") == false);
    CHECK(Json::parse(charaDetailFinished("rec-live", false)).contains("origin") == false);
    CHECK(Json::parse(charaDetailFinished("rec-live", true, false)).contains("origin") == false);
    checkMessage(
        charaDetailFinished("rec-live", true, false),
        R"({"type":"onCharaDetailFinished","id":"rec-live","success":true})");

    checkMessage(
        charaDetailFinished("rec-import", true, true),
        R"({"type":"onCharaDetailFinished","id":"rec-import","success":true,"origin":"video_import"})");
    // A FAILED finish is marked too: it is still the import's record, and the receiver decides what to do with
    // that. Marking only successes would make the origin mean "a record was produced" instead of "who produced".
    checkMessage(
        charaDetailFinished("rec-import", false, true),
        R"({"type":"onCharaDetailFinished","id":"rec-import","success":false,"origin":"video_import"})");

    // The exact literal, not merely "some marker": it is web's own value, and the two must not drift apart.
    CHECK(std::string(originVideoImport) == "video_import");
}

TEST_CASE("video import messages carry web's un-prefixed tags and camelCase keys") {
    // These three tags deliberately lack the "on" prefix every other message here has, and their keys are
    // camelCase rather than this file's snake_case: they are web's payloads verbatim (web/worker.js, the
    // videoImportDone protocol comment), and one protocol is the point.
    checkMessage(videoImportStarted(), R"({"type":"videoImportStarted"})");
    checkMessage(
        videoImportProgress(120, 118, 4000, 61000),
        R"({"type":"videoImportProgress","decoded":120,"supplied":118,"mediaTimeMs":4000,"durationMs":61000})");
    checkMessage(
        videoImportDone("completed", "", 900, 890, 10, 2, 61000, "", ""),
        R"({"type":"videoImportDone","reason":"completed","reasonKind":"",)"
        R"("decoded":900,"supplied":890,"rejected":10,"records":2,"durationMs":61000,)"
        R"("matrixConverted":"","message":""})");
}

TEST_CASE("video import done carries the record count beside the frame counts") {
    // The count is the core's (NativeApi::recordsProduced) and it is on the wire because it is a fact about the
    // recognition run, not about the decode: `decoded`/`supplied`/`rejected` all describe frames going IN, and
    // an import can be perfect on all three and still have recognized nobody.
    const Json parsed = Json::parse(videoImportDone("completed", "", 900, 890, 10, 3, 61000, "", ""));
    CHECK(parsed.at("records") == 3);
    CHECK(parsed.at("decoded") == 900);
    CHECK(parsed.at("reason") == "completed");
}

TEST_CASE("an import that produced no record is not reported as completed") {
    // THE POINT OF THE WHOLE MESSAGE. "The decode loop returned" and "records were produced" used to be one
    // fact, so a clip of the wrong screen ended as a success and the user was told nothing at all. The payload
    // must not be able to state it: a zero count arrives as a refusal with a named cause the UI can translate.
    const Json parsed = Json::parse(videoImportDone("completed", "", 900, 890, 10, 0, 61000, "", ""));
    CHECK(parsed.at("reason") == "refused");
    CHECK(parsed.at("reasonKind") == "no_records");
    // The counts still describe what actually happened -- the reclassification restates the ENDING, never the
    // measurements, which is what keeps the diagnostic line honest.
    CHECK(parsed.at("records") == 0);
    CHECK(parsed.at("decoded") == 900);
    CHECK(parsed.at("supplied") == 890);
    CHECK(std::string(reasonKindNoRecords) == "no_records");
}

TEST_CASE("videoImportVerdictOf rewrites only a completion, and only an empty one") {
    // One record is enough: the count answers "did this run produce anything", and partial loss is a different
    // question with a different answer (Rank 3's discard event), not a smaller version of this one.
    CHECK(videoImportVerdictOf("completed", "", 1).reason == "completed");
    CHECK(videoImportVerdictOf("completed", "", 1).reason_kind.empty());
    CHECK(videoImportVerdictOf("completed", "", 0).reason == "refused");
    CHECK(videoImportVerdictOf("completed", "", 0).reason_kind == "no_records");

    // A PRODUCER'S OWN CLASSIFICATION WINS. Windows reclassifies a clip that decoded no frame at all before it
    // publishes (windows/runner/video_import_session.h), from the container's declared frame count -- evidence
    // this rule does not have. Such an ending implies records == 0, so an unconditional rewrite here would
    // replace "the decoder produced no pixels" with the vaguer "nothing was recognized" on every one of them.
    CHECK(videoImportVerdictOf("refused", "codec_unsupported", 0).reason_kind == "codec_unsupported");
    CHECK(videoImportVerdictOf("refused", "no_video_track", 0).reason_kind == "no_video_track");
    CHECK(videoImportVerdictOf("failed", "", 0).reason == "failed");
    CHECK(videoImportVerdictOf("failed", "", 0).reason_kind.empty());
    // A cancel is the user's own doing and is neither a failure of the clip nor of the app; an import stopped
    // after two seconds has produced nothing BY DEFINITION, so rewriting it would make every cancel a refusal.
    CHECK(videoImportVerdictOf("cancelled", "", 0).reason == "cancelled");
    CHECK(videoImportVerdictOf("unbraked", "unbraked", 0).reason == "unbraked");
}

TEST_CASE("a negative record count is treated as none rather than as some") {
    // Not reachable from the counter (it only ever increments from zero), but the field is a signed int64 that
    // crosses two front ends, and "fewer than none" must not read as a success.
    CHECK(videoImportVerdictOf("completed", "", -1).reason == "refused");
}

TEST_CASE("video import progress reports an unknown duration as zero rather than omitting it") {
    // 0 is web's "indeterminate" convention: the container declared no duration, so the UI falls back to the
    // counts. The key still has to be there for the receiver to read that.
    const Json parsed = Json::parse(videoImportProgress(7, 7, 0, 0));
    CHECK(parsed.at("durationMs") == 0);
    CHECK(parsed.at("mediaTimeMs") == 0);
    CHECK(parsed.at("decoded") == 7);
    CHECK(parsed.at("supplied") == 7);
}

TEST_CASE("video import done keeps matrixConverted even though Windows never fills it") {
    // Windows decodes and converts inside the core, so nothing else can have converted the clip behind the
    // app's back -- the field is always "". It is emitted anyway so Dart can still tell "nothing was converted"
    // from "this build does not report conversions"; dropping it would collapse the two.
    const Json parsed =
        Json::parse(videoImportDone("failed", "not_a_video", 0, 0, 0, 0, 0, "", "cap.open failed"));
    CHECK(parsed.contains("matrixConverted"));
    CHECK(parsed.at("matrixConverted") == "");
    CHECK(parsed.at("reason") == "failed");
    CHECK(parsed.at("reasonKind") == "not_a_video");
    CHECK(parsed.at("message") == "cap.open failed");
}

TEST_CASE("video import done survives a non-UTF-8 message instead of throwing") {
    // `message` carries an exception's what(), which on a Japanese Windows can be CP932. A strict dump() would
    // throw here and the ONE terminal message of the import would never reach Dart, hanging the UI until its
    // watchdog fires -- so the bytes degrade (U+FFFD) and the message still ships.
    const std::string cp932_like = "open failed: \x8e\xc0\x8d\x73";
    std::string built;
    CHECK_NOTHROW(built = videoImportDone("failed", "", 3, 3, 0, 1, 0, "", cp932_like));
    const Json parsed = Json::parse(built);
    CHECK(parsed.at("type") == "videoImportDone");
    CHECK(parsed.at("message").get<std::string>().rfind("open failed: ", 0) == 0);
}

TEST_CASE("frame report messages") {
    checkMessage(frameRateReported(59.94), R"({"type":"onFrameRateReported","fps":59.94})");
    checkMessage(
        frameSizeReported(Size<int>{1920, 1080}),
        R"({"type":"onFrameSizeReported","size":{"width":1920,"height":1080}})");
}

TEST_CASE("detail crop report carries two flat rects and the latch flag") {
    // Flat left/top/width/height, NOT Rect<int>'s own nested top_left/bottom_right (which would also drag
    // the layout anchors onto the wire). The Dart side reads these four names, and computes the difference
    // the settings UI shows from them, so a rename here is a silent break there.
    checkMessage(
        detailCropReported(Rect<int>{{0, 0}, Point<int>{1280, 720}}, Rect<int>{{2, 1}, Point<int>{1278, 719}}, true),
        R"({"type":"onDetailCropReported",)"
        R"("default":{"left":0,"top":0,"width":1280,"height":720},)"
        R"("corrected":{"left":2,"top":1,"width":1276,"height":718},"latched":true})");
}

TEST_CASE("detail crop report before anything is measured repeats the default as the corrected value") {
    const auto rect = Rect<int>{{4, 8}, Point<int>{644, 368}};
    const Json parsed = Json::parse(detailCropReported(rect, rect, false));
    CHECK(parsed.at("default") == parsed.at("corrected"));
    CHECK(parsed.at("latched") == false);
}

TEST_CASE("factor probe serializes each factor as id/star, beside exactly three more data fields") {
    // The whole message, so a field that came back -- record_type, match_threshold -- or went missing fails here.
    // `record_id` names the attempt the probe frame was latched in, so a result arriving after the next attempt
    // began can be told apart from that attempt's own.
    const std::vector<chara_detail::record::Factor> factors{{101, 3}, {202, 1}};
    checkMessage(
        factorProbe(factors, 10, true, "rec-1"),
        R"({"type":"onFactorProbe","factors":[{"id":101,"star":3},{"id":202,"star":1}],)"
        R"("below_threshold":true,"cue_owed":true,"record_id":"rec-1"})");
}

TEST_CASE("factor probe with no factors emits an empty array, below any limit") {
    // An empty read (no header found, say) is still sent: cue_owed has to reach the front end. It is below the
    // limit by the same comparison as any other list; telling "read nothing" apart is the front end's rule.
    const Json parsed = Json::parse(factorProbe({}, 14, true, "rec-1"));
    CHECK(parsed.at("factors").is_array());
    CHECK(parsed.at("factors").empty());
    CHECK(parsed.at("below_threshold") == true);
}

TEST_CASE("factor probe states below_threshold as the list's length against the limit, and never the limit") {
    // below_threshold is `factors.size() < factor_limit`, on both sides of the boundary: one short of the limit is
    // below, the limit itself is not. A flag hard-wired to either value, or compared with <=, fails one of these.
    // The limit is not on the wire: the front end compares every factor it is sent and applies no number.
    const std::vector<chara_detail::record::Factor> nine(9, chara_detail::record::Factor{101, 3});
    const std::vector<chara_detail::record::Factor> ten(10, chara_detail::record::Factor{101, 3});
    CHECK(Json::parse(factorProbe(nine, 10, true, "rec-1")).at("below_threshold") == true);
    CHECK(Json::parse(factorProbe(ten, 10, true, "rec-1")).at("below_threshold") == false);
    // The same nine under Standard's larger limit: the flag follows the limit, not a constant.
    CHECK(Json::parse(factorProbe(nine, 14, true, "rec-1")).at("below_threshold") == true);
    CHECK(Json::parse(factorProbe(std::vector<chara_detail::record::Factor>(14, {101, 3}), 14, true, "rec-1"))
              .at("below_threshold")
          == false);
    const Json parsed = Json::parse(factorProbe(ten, 10, true, "rec-1"));
    CHECK(parsed.at("below_threshold").is_boolean());
    CHECK_FALSE(parsed.contains("match_threshold"));
    CHECK_FALSE(parsed.contains("record_type"));
}

TEST_CASE("factor probe states whether the latch owed a cue, in both directions") {
    // The factor tab's chime is synthesized by the front end off this message, so this field is the whole of
    // what tells it whether the latch that took fragment #0 owed the user a cue: of a scrollable page's two exits
    // only the one that waited does, and a page with no scroll bar (which also arms the probe) owes none. Both
    // directions are pinned: a field
    // that were hard-wired to either value would leave the front end either always silent (the capture never
    // starts, because the user is never told to scroll) or always chiming (the defect this replaces).
    CHECK(Json::parse(factorProbe({}, 14, true, "rec-1")).at("cue_owed") == true);
    CHECK(Json::parse(factorProbe({}, 14, false, "rec-1")).at("cue_owed") == false);
}

}  // namespace
}  // namespace uma::app::messages
