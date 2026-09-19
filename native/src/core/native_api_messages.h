#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "chara_detail/chara_detail_record.h"
#include "types/shape.h"
#include "util/json_util.h"

// Pure builders for the notification payloads NativeApi pushes across the FFI boundary to Dart.
//
// Each function returns the already-dumped JSON string that NativeApi::notify() forwards. They are kept
// free of any NativeApi/pipeline state on purpose: the wire contract these produce (the "type" tag plus the
// per-message keys, which the Dart side reads by string) is the load-bearing part, and pulling it out here
// lets it be asserted as data, without standing a pipeline up to reach the string. NativeApi's notify*
// methods are thin wrappers that call these and hand the result to notify().
namespace uma::app::messages {

inline std::string screenshotTaken(const std::string &path, const std::string &result) {
    return json_util::Json{{"type", "onScreenshotTaken"}, {"path", path}, {"result", result}}.dump();
}

inline std::string error(const std::string &message) {
    // [message] often embeds an exception's what(), which is not guaranteed to be UTF-8 (e.g. a
    // CP932-localized system message on a Japanese Windows). dump() is strict by default and would
    // throw on such bytes, killing the very error notification the caller is trying to deliver;
    // replace invalid sequences with U+FFFD instead so onError always reaches the Dart side.
    return json_util::Json{{"type", "onError"}, {"message", message}}.dump(
        -1, ' ', false, json_util::Json::error_handler_t::replace);
}

// A TERMINAL ERROR THAT BELONGS TO ONE CAPTURE ATTEMPT, named by the `record_id` that attempt was announced
// under (charaDetailStarted / charaDetailRestarted). Used by the three errors that end a session's record --
// `stitch_failed`, `scrape_failed` and `closed_before_completed` -- because the first is reported from the
// stitcher's thread and can therefore reach the front end after the NEXT attempt has been announced. A front
// end applies such an error to its card only when the id is the attempt it is showing; without the id it could
// only apply it to whatever attempt happened to be current when the message arrived.
//
// Every other error carries no `record_id`, and its absence is the meaning: "not scoped to an attempt".
inline std::string error(const std::string &message, const std::string &record_id) {
    return json_util::Json{{"type", "onError"}, {"message", message}, {"record_id", record_id}}.dump(
        -1, ' ', false, json_util::Json::error_handler_t::replace);
}

inline std::string captureStarted() { return json_util::Json{{"type", "onCaptureStarted"}}.dump(); }

inline std::string captureStopped() { return json_util::Json{{"type", "onCaptureStopped"}}.dump(); }

inline std::string scrollReady(int index) {
    return json_util::Json{{"type", "onScrollReady"}, {"index", index}}.dump();
}

inline std::string scrollUpdated(int index, double progress) {
    return json_util::Json{{"type", "onScrollUpdated"}, {"index", index}, {"progress", progress}}.dump();
}

// WHETHER A TAB IS FLUSH WITH THE HEAD OF ITS CONTENT, stated THREE-VALUED and deliberately UNRESOLVED.
//
// `top_of_content` is the same stable machine word `onTabRefused`'s `reason` carries
// (scraper_impl::topOfContentTag): "at_top", "scrolled", or "unknown" when no sensor could read this frame --
// a tab not built yet, or a scroll bar unmeasurable for a moment on a page that has one. A page with NO scroll
// bar at all reads "at_top" from the frame after its tab is built, on every tab and whatever its frames show:
// it cannot be anywhere but the head of its content, and the core takes that from the structure the tab was
// built with, before any sensor (CharaDetailSceneScraper::topOfContent). A scrollable factor page reads its
// scroll thumb first, like every other tab, so it reads "unknown" exactly when the thumb cannot be read (the
// first frame of a tab not built yet included). The green header is asked only behind a thumb at the head,
// and it can only turn that "at_top" into "scrolled".
//
// NOT A BOOL, and that is the contract rather than a richer payload for its own sake. The core cannot answer
// "unknown" for the front end because the front end has two consumers whose costs for a wrong answer are
// OPPOSITE: the capture card's phase wants fail-open (a tab nobody could read is not "capturing"), while the
// duplicate-probe hint gate wants fail-closed (standing the hint on an unreadable frame would claim a
// certainty that the core's own reset rule -- which resolves fail-closed -- refuses to claim for a switch).
// One bool picks one of them for both. Each consumer resolves this word for itself, which is the same rule
// the core already applies internally (TopOfContentPolicy::unknown_verdict), applied one layer further out.
// The green character-switch arrows are not a consumer of this word at all: they read whether the factor tab
// is shown (this message's `index`) and whether the switch rule holds its witness (onFactorSwitchArmed below),
// never the scroll position (see switchSafety in lib/src/core/platform_controller.dart).
//
// A READER MUST TREAT AN ABSENT OR UNRECOGNISED WORD AS "unknown", not as "at_top": that keeps a payload this
// build does not understand on the side each consumer already chose for missing evidence, instead of handing
// every consumer the optimistic answer. Fail-open consumers lose nothing by it -- "unknown" is what they
// resolve to at_top anyway -- and fail-closed ones stay closed.
//
// Edge-triggered on the VERDICT, so a tab going from readable-at-top to unreadable is a message: the two
// resolve the same way for one consumer and differently for the other, so they cannot be collapsed here.
inline std::string scrollPosition(int index, const std::string &top_of_content) {
    return json_util::Json{{"type", "onScrollPosition"}, {"index", index}, {"top_of_content", top_of_content}}
        .dump();
}

// A TAB'S CAPTURE WAS REFUSED, or that refusal was withdrawn. `refused` is the level, not an occurrence: the
// scraper re-states it whenever it changes, so a front end holds the last value per `index` rather than
// counting events, and a tab switch (which rebuilds the tab) arrives here as `refused: false` on the same
// message type. There is deliberately no separate "cleared" type to fall out of step with this one.
//
// NOT onError. That channel is session-scoped and terminal: it would mark the whole capture failed while the
// other two tabs are still fine and while this one is about to be retried. What happened is that this tab's
// first captured fragment was not the head of its list -- the user began scrolling before the ready cue -- so
// the rows above it were never seen and only this tab is unusable.
//
// `reason` is a stable machine word (scraper_impl::topOfContentTag): "scrolled" when the scroll bar was
// measured away from the top, "unknown" when the tab has a scroll bar but this frame yielded no reading and
// the shipped policy refuses rather than risk capturing a truncated list. It is not a user-facing string; the
// front end maps it to its own wording, and must have a fallback for a word it does not recognise.
inline std::string tabRefused(int index, bool refused, const std::string &reason) {
    return json_util::Json{{"type", "onTabRefused"}, {"index", index}, {"refused", refused}, {"reason", reason}}
        .dump();
}

// A TAB STILL NEEDS THE USER TO LEAVE IT ALONE (or no longer does), and WHETHER ITS PAGE HAS A SCROLL BAR.
// `awaiting` is the level, not an occurrence, in exactly the idiom of onTabRefused above: the scraper re-states
// it whenever it changes and there is no paired "cleared" type. What ends the wait depends on the page, and the
// core decides it (scraper_impl::SceneScraper::awaitingHead): on a page with a scroll bar the wait ends when the
// frame that becomes fragment #0 is latched, because from then on scrolling IS the capture; on a page with no
// scroll bar it ends when the tab is complete, because every remaining step there needs the same thing -- a
// picture that holds still. A tab not built yet is awaiting.
//
// NOT onScrollReady, and the difference is the whole point of this message existing. onScrollReady is an
// ANNOUNCEMENT -- the chime the user listens for -- and there are exits from this wait that have nothing to
// announce: the offset exit in ScrollableScrapingInterpreter::updateBefore begins capture without ever
// latching a stationary frame, and a page with no scroll bar is handed no cue sender at all. A front end that
// reads "no onScrollReady yet" as "still waiting" would tell the user to hold off, in a caution colour, for
// the rest of a capture that is running normally. The chime and the permission are two facts; this is
// the second one.
//
// `scroll_bar` is the page's structure (scraper_impl::SceneScraper::scrollable), fixed from the tab's first frame
// until the tab is rebuilt. It rides HERE, and not on a message of its own, because it and `awaiting` describe
// one wait on one tab and change on the same events: on a tab's first frame the pair goes from
// {awaiting, not built} to {awaiting, no scroll bar}, and one message carries that step whole. The one consumer is
// the front end's wording of the wait (a page with no scroll bar must not be told about scrolling). The key is
// OMITTED while the tab is not built -- nothing has established either answer -- and a reader must treat an
// absent key as "unknown", not as either answer.
inline std::string tabAwaitingHead(int index, bool awaiting, const std::optional<bool> &scroll_bar) {
    json_util::Json json{{"type", "onTabAwaitingHead"}, {"index", index}, {"awaiting", awaiting}};
    if (scroll_bar.has_value()) {
        json["scroll_bar"] = scroll_bar.value();
    }
    return json.dump();
}

// WHETHER THE CHARACTER-SWITCH RULE CAN SEE A SWITCH RIGHT NOW: the core holds a reference to compare the factor
// tab against (CharaDetailSceneScraper::factorSwitchArmed). Not per tab, because the reference is not: it is
// installed by the factor tab's head latch, kept through that tab's capture and the session's completion, and
// dropped only when the factor tab is rebuilt or the session is discarded. The rule watches only the factor tab,
// and that half is already on the wire (onScrollPosition's `index`), so a front end offers a switch exactly when
// the factor tab is shown AND this level is true -- which is the rule's own condition, read from the rule.
//
// A level, edge-triggered, restated on the first frame of every session, like onTabAwaitingHead. It is sent
// BEFORE onTabAwaitingHead within a frame, so a front end never holds "the factor tab has stopped waiting" while
// still holding "not armed" from the frame before. A reader must treat an absent or malformed `armed` as false.
inline std::string factorSwitchArmed(bool armed) {
    return json_util::Json{{"type", "onFactorSwitchArmed"}, {"armed", armed}}.dump();
}

inline std::string pageReady(int index) {
    return json_util::Json{{"type", "onPageReady"}, {"index", index}}.dump();
}

// THE FACTOR TAB'S FRAGMENT #0, recognized down to the trainee's own visible factor rows, for the early
// duplicate check -- plus the two facts the front end cannot work out for itself: `below_threshold` and
// `cue_owed` -- and the attempt it belongs to, `record_id`. Four data fields and nothing else: no record type
// (no consumer decided anything by it) and no threshold (the front end is not asked to apply one).
//
// `record_id` is the id the session was announced under (charaDetailStarted / charaDetailRestarted). The probe is
// recognized on the recognizer's thread, so this message can arrive after the NEXT session has been announced;
// the id is what lets the front end drop a result that no longer describes the character on screen, instead of
// guessing from arrival order.
//
// `factors` is the single-frame read (FactorRowReader::visibleSelfPrefix), which never holds more than
// `factor_limit` -- the self_factor_prefix_length of the layout this session's scraper chose
// (scene_scraper.json's common or friend_common). The front end compares every factor in it with the head of
// each stored record.
//
// `below_threshold` is `factors.size() < factor_limit`, computed HERE from the same limit the read stopped at,
// so the flag and the list it describes cannot disagree. When it is true the list ended on the frame (the
// layout's scroll area shows the threshold's rows, see recognizer_impl::SelfFactorWindow), so the front end
// additionally requires a stored record to hold exactly that many self factors. An empty list is sent too (the
// read found no header, say) and is below any limit; `cue_owed` still has to reach the front end.
//
// This tab's chime is not sounded by the core (see CharaDetailSceneScraper::constructSession's factor_scroll_ready
// sink): the front end withholds it until this message says the character is not already stored, and sounds it
// there. That leaves the front end holding only half the condition. `cue_owed` is the other half -- true when
// the latch came from the exit that waited for a settled frame, false when the user was already scrolling and
// an announcement would arrive after the thing it announces. Both halves travel on this one message rather
// than on two the front end would have to correlate by arrival order; the probe is recognized on a worker
// thread, so that order is not something either side may lean on.
inline std::string factorProbe(
    const std::vector<chara_detail::record::Factor> &factors,
    std::size_t factor_limit,
    bool cue_owed,
    const std::string &record_id) {
    return json_util::Json{
        {"type", "onFactorProbe"},
        {"factors", factors},
        {"below_threshold", factors.size() < factor_limit},
        {"cue_owed", cue_owed},
        {"record_id", record_id},
    }
        .dump();
}

// A CAPTURE ATTEMPT BEGAN, and `record_id` is the id it will finish under: the `id` of the onCharaDetailFinished
// that ends it, and the `record_id` of every other message scoped to it (onFactorProbe, and onError for
// stitch_failed / scrape_failed / closed_before_completed). Those outcomes are produced on other threads and can
// arrive after the next attempt has begun, so a front end compares ids rather than trusting arrival order. Sent by
// the scraper (CharaDetailSceneScraper::build) after the session's id is minted and before the session is
// constructed, so the id is the session's own and not a second mint, and a construction that throws ends this
// attempt under the id already announced (scrape_failed).
inline std::string charaDetailStarted(const std::string &record_id) {
    return json_util::Json{{"type", "onCharaDetailStarted"}, {"record_id", record_id}}.dump();
}

// A SESSION WAS THROWN AWAY MID-SCENE, and this says whether that cost anything.
//
// The type tag has always differed from `onCharaDetailStarted`, but the message carried nothing, so the only
// thing a front end could do with the distinction was ignore it -- and both front ends did, dispatching the two
// tags into one branch. Saying whether the discarded session had already produced its record is what makes
// telling them apart worth anything: a discard that lost nothing and one that lost a half-captured character
// are now different messages, and an import can report "3 registered, 1 lost" instead of reporting the 3 as an
// unqualified success.
//
// NOT AN ERROR, and deliberately not routed like one. Each of the scraper's two reset rules fires
// legitimately when the player switches character, so reporting a discard as a failure would be wrong more
// often than right (it would fire on every switch in an ordinary two-character clip). What the wire states is
// the FACT and its contents; which of them deserves a sentence is the front end's call, and it differs by front
// end for a real reason -- for live capture a switch IS the feature, for an import it is a character the user
// meant to import and did not get.
//
// ONE BIT, AND ONLY ONE. `completed` is chara_detail::DiscardedSession::completed: the session had already
// produced its record, so nothing was lost. A reader must treat the field's ABSENCE as false (not completed),
// which errs towards announcing a loss rather than towards the silence this change exists to remove -- the
// opposite direction from `origin` above, because here the harmless default is the loud one.
//
// A RESET ALSO BEGINS AN ATTEMPT, so `record_id` is the id of the session the reset BEGAN -- exactly what
// charaDetailStarted carries for a fresh open, and for the same reason: the outcomes of the discarded session
// (its onCharaDetailFinished, a late onFactorProbe) are still on their way, and the front end tells them apart
// from the new attempt's by this id.
//
// The DISCARDED session's id and its captured-tab count are DELIBERATELY not here. Neither is read to decide
// anything: the discarded id names a scraping directory no receiver can open, and the tab count only ever
// narrowed one class of false positive in a number nothing displayed. A field on the wire has to be parsed,
// defaulted and kept in step on three front ends, and a field nobody decides from buys none of that back. The
// discarded id still goes to the log at the discard site (chara_detail_scene_scraper.cpp), which is where a
// discard is actually traced. Putting it here under `record_id` would be the worse mistake: the front end would
// then match the NEW attempt's outcomes against the OLD attempt's id.
//
// snake_case keys, like every other `on`-prefixed message in this file; the camelCase block further down is
// web's protocol and says why it differs.
inline std::string charaDetailRestarted(bool completed, const std::string &record_id) {
    return json_util::Json{{"type", "onCharaDetailRestarted"}, {"completed", completed}, {"record_id", record_id}}
        .dump();
}

inline std::string charaDetailClosed() { return json_util::Json{{"type", "onCharaDetailClosed"}}.dump(); }

// The value of `onCharaDetailFinished`'s optional `origin` field when the record was produced by a VIDEO IMPORT
// rather than by a live capture. Deliberately the same string web already puts on `onLiveRecordsHarvested.origin`
// (lib/src/core/video_import_ops.dart -- harvestOriginVideoImport), because the two transports differ for a
// platform reason (web harvests batches out of MEMFS, Windows relays per record) but the MARKER does not: one
// value, one meaning, both front ends (.claude/rules/platform-parity.md -- share, don't port).
inline constexpr const char *originVideoImport = "video_import";

// `origin` is OMITTED for a live capture, and that asymmetry is the contract, not an optimization: the Dart side
// reads `data['origin'] == harvestOriginVideoImport`, so a message that loses the field -- an older relay, a
// serializer that drops unknown keys -- degrades to "live", i.e. towards an extra chime for an import and never
// towards a missing one for a live capture. Marking the import (the exceptional, silent case) rather than the
// live path is what makes absence the safe default.
inline std::string charaDetailFinished(const std::string &record_id, bool success, bool from_video_import = false) {
    json_util::Json json{{"type", "onCharaDetailFinished"}, {"id", record_id}, {"success", success}};
    if (from_video_import) {
        json["origin"] = originVideoImport;
    }
    return json.dump();
}

inline std::string charaDetailUpdated(const std::string &record_id) {
    return json_util::Json{{"type", "onCharaDetailUpdated"}, {"id", record_id}}.dump();
}

inline std::string frameRateReported(double fps) {
    return json_util::Json{{"type", "onFrameRateReported"}, {"fps", fps}}.dump();
}

inline std::string frameSizeReported(const Size<int> &size) {
    return json_util::Json{{"type", "onFrameSizeReported"}, {"size", size}}.dump();
}

// NOTE: the capture page's live preview has NO message here. Its frames are raw BGRA pixels, which travel on
// their own binary transport (NativeApi::PreviewFrameCallback -> the "previewFrame" method on the Windows
// platform channel; a transferable ImageBitmap on web) rather than as base64 inside this JSON.

// A crop as four flat integers. Deliberately NOT Rect<int>'s own serialization, which nests two Points and
// carries their layout anchors -- meaningless on the wire and awkward to read back in Dart. left/top plus
// width/height is what the settings UI renders and what a difference is computed from.
inline json_util::Json cropToJson(const Rect<int> &rect) {
    return json_util::Json{
        {"left", rect.left()}, {"top", rect.top()}, {"width", rect.width()}, {"height", rect.height()}};
}

// The detail-crop auto-calibration's current value, for the settings UI: the intersection the frame would
// have had without the correction, the one it has with it, and whether the value is latched (frozen until
// an explicit release). `default` and `corrected` are equal while no correction has been adopted.
inline std::string detailCropReported(const Rect<int> &default_rect, const Rect<int> &corrected, bool latched) {
    return json_util::Json{
        {"type", "onDetailCropReported"},
        {"default", cropToJson(default_rect)},
        {"corrected", cropToJson(corrected)},
        {"latched", latched}}
        .dump();
}

// ---------------------------------------------------------------------------------------------------------
// Video import progress reporting.
//
// These three carry NO "on" prefix on their type tag, unlike every message above. That is deliberate and is the
// contract: web already emits exactly these three tags from the worker (web/worker.js, the `videoImportDone`
// protocol comment), the Dart side dispatches on the string, and a Windows-only rename would fork one protocol
// into two for no platform reason at all. The payload keys are camelCase for the same reason -- they are web's,
// copied verbatim rather than restyled to this file's snake_case habit.
//
// Ordering matters and belongs to the caller, not here: these ride the SAME notify queue as
// onCharaDetailFinished, so `videoImportDone` lands after the last record of the import it ends. Putting them
// on a queue of their own would break that (windows/runner/platform_channel.h -- the only cross-queue guarantee
// is "notify first").

// An import session's event loop is running and the clip is being read. Exactly one per import that starts.
inline std::string videoImportStarted() { return json_util::Json{{"type", "videoImportStarted"}}.dump(); }

// Throttled progress. `media_time_ms / duration_ms` is the fraction the bar renders -- both come from the
// container rather than from a frame count -- and `duration_ms == 0` means the clip declares no duration, in
// which case the counts are all the UI has. `supplied` below `decoded` means the pipeline refused frames.
inline std::string videoImportProgress(int64_t decoded, int64_t supplied, int64_t media_time_ms, int64_t duration_ms) {
    return json_util::Json{
        {"type", "videoImportProgress"},
        {"decoded", decoded},
        {"supplied", supplied},
        {"mediaTimeMs", media_time_ms},
        {"durationMs", duration_ms}}
        .dump();
}

// HOW AN IMPORT ENDED, after the core has had its say about what came out of it.
//
// `reason` is completed / cancelled / unbraked / refused / failed and `reason_kind` narrows a refusal or a
// failure to one named cause the UI can translate.
struct VideoImportVerdict {
    std::string reason;
    std::string reason_kind;
};

// The one `reason` value the rule below reacts to, named because the rule is otherwise tied to a producer's
// string literal: rename "completed" at a driver and an unnamed rule here would simply stop firing, silently,
// which is the failure class this whole change removes. Windows's driver takes its value from here for that
// reason (windows/runner/video_import_session.h); web's own IMPORT_COMPLETED is the same string on the wire
// (web/video_import.mjs) and is checked against this by the verdict export in native/wasm/wasm_api.cpp.
inline constexpr const char *reasonCompleted = "completed";
// The outcome an import that ran to the end and recognized nothing is reported as, with its named cause.
inline constexpr const char *reasonRefused = "refused";
inline constexpr const char *reasonKindNoRecords = "no_records";

// AN IMPORT THAT PRODUCED NO RECORD IS NOT A COMPLETION, and this is the one place that is decided.
//
// `reason: "completed"` used to mean "the decode loop returned", which a front end could only present as a
// success -- so a clip of the wrong screen, or one whose detail pane never opened, ended with the capture card
// falling silent and the user told nothing at all. It now means "the import ran to the end AND something came
// out of it"; the widened meaning is the deliberate cost, and it is paid HERE so that no front end can pay it
// differently. `records` is the core's own count (NativeApi::recordsProduced), so all three front ends classify
// the same run identically instead of each reconstructing the rule.
//
// `refused` rather than `failed`, matching what Windows already does with a clip that decoded no frame
// (windows/runner/video_import_session.h): nothing malfunctioned, the clip simply does not contain what an
// import needs. That is the outcome kind whose channel is an ordinary app state rather than a crash report, and
// it is already one of the kinds the capture card puts on screen (lib/src/core/platform_controller.dart --
// _eventfulImportOutcomeKinds), so an empty import becomes visible without a new event slot.
//
// A PRODUCER'S OWN CLASSIFICATION WINS, which is why only `completed` is rewritten. A driver that already
// named the ending -- cancelled, unbraked, failed, or a refusal narrowed to no_video_track /
// codec_unsupported -- did so from evidence this rule does not have (the container's declared frame count, the
// decoder's own error, the user's cancel), and `records == 0` follows from every one of those anyway. Rewriting
// them would replace a specific answer with a vaguer one.
[[nodiscard]] inline VideoImportVerdict videoImportVerdictOf(
    const std::string &reason, const std::string &reason_kind, const int64_t records) {
    if (reason == reasonCompleted && records <= 0) {
        return {reasonRefused, reasonKindNoRecords};
    }
    return {reason, reason_kind};
}

// EXACTLY ONE per import, whatever ended it. `reason` is completed / cancelled / unbraked / refused / failed;
// `reason_kind` narrows a refusal or a failure to one named cause the UI can translate ("" when there is nothing
// to narrow); `message` stays English prose for the log and is never rendered.
//
// `records` is how many records the recognition pipeline actually produced during the run, counted by the core
// (NativeApi::recordsProduced) rather than by whoever composes this message: it is a fact about a recognition
// run and differs on no platform, so two front-end reconstructions of it would be two chances to disagree. It
// is also what decides the verdict above -- the reason and kind this message carries are the CLASSIFIED ones,
// so a payload stating `completed` alongside `records: 0` cannot be built.
//
// `matrix_converted` is ALWAYS "" on Windows -- the core decodes and converts the clip itself, so there is no
// third party to have converted it behind the app's back the way a browser's decoder can (web/video_import.mjs
// coreFormatOf). The field is kept anyway: dropping it on one platform would leave Dart unable to tell "this
// build does not report conversions" from "nothing was converted", and that distinction is the only trace an
// accepted browser conversion leaves at all.
//
// Dumped with the same U+FFFD replacement handler `error()` uses, and for the same reason: `message` carries an
// exception's what(), which on a Japanese Windows can be CP932 rather than UTF-8, and a strict dump() would
// throw here -- killing the one terminal message the UI is waiting for and leaving the import hung until the
// Dart-side watchdog fires.
inline std::string videoImportDone(
    const std::string &reason,
    const std::string &reason_kind,
    int64_t decoded,
    int64_t supplied,
    int64_t rejected,
    int64_t records,
    int64_t duration_ms,
    const std::string &matrix_converted,
    const std::string &message) {
    const auto verdict = videoImportVerdictOf(reason, reason_kind, records);
    return json_util::Json{
        {"type", "videoImportDone"},
        {"reason", verdict.reason},
        {"reasonKind", verdict.reason_kind},
        {"decoded", decoded},
        {"supplied", supplied},
        {"rejected", rejected},
        {"records", records},
        {"durationMs", duration_ms},
        {"matrixConverted", matrix_converted},
        {"message", message}}
        .dump(-1, ' ', false, json_util::Json::error_handler_t::replace);
}

}  // namespace uma::app::messages
