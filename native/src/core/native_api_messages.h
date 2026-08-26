#pragma once

#include <cstdint>
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
// lets it be unit-tested without linking the ONNX/WinRT-heavy NativeApi translation unit. NativeApi's notify*
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

inline std::string captureStarted() { return json_util::Json{{"type", "onCaptureStarted"}}.dump(); }

inline std::string captureStopped() { return json_util::Json{{"type", "onCaptureStopped"}}.dump(); }

inline std::string scrollReady(int index) {
    return json_util::Json{{"type", "onScrollReady"}, {"index", index}}.dump();
}

inline std::string scrollUpdated(int index, double progress) {
    return json_util::Json{{"type", "onScrollUpdated"}, {"index", index}, {"progress", progress}}.dump();
}

inline std::string scrollPosition(int index, bool at_top) {
    return json_util::Json{{"type", "onScrollPosition"}, {"index", index}, {"at_top", at_top}}.dump();
}

inline std::string pageReady(int index) {
    return json_util::Json{{"type", "onPageReady"}, {"index", index}}.dump();
}

inline std::string factorProbe(const std::vector<chara_detail::record::Factor> &factors, int record_type) {
    return json_util::Json{{"type", "onFactorProbe"}, {"factors", factors}, {"record_type", record_type}}.dump();
}

inline std::string charaDetailStarted() { return json_util::Json{{"type", "onCharaDetailStarted"}}.dump(); }

// A SESSION WAS THROWN AWAY MID-SCENE, and this says whether that cost anything.
//
// The type tag has always differed from `onCharaDetailStarted`, but the message carried nothing, so the only
// thing a front end could do with the distinction was ignore it -- and both front ends did, dispatching the two
// tags into one branch. Saying whether the discarded session had already produced its record is what makes
// telling them apart worth anything: a discard that lost nothing and one that lost a half-captured character
// are now different messages, and an import can report "3 registered, 1 lost" instead of reporting the 3 as an
// unqualified success.
//
// NOT AN ERROR, and deliberately not routed like one. Every one of the scraper's three reset rules fires
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
// The discarded session's id and its captured-tab count are DELIBERATELY not here. Both were carried at first
// and neither was ever read to decide anything: the id names a scraping directory no receiver can open, and the
// tab count only ever narrowed one class of false positive in a number nothing displayed. A field on the wire
// has to be parsed, defaulted and kept in step on three front ends, and a field nobody decides from buys none
// of that back. The id still goes to the log at the discard site (chara_detail_scene_scraper.cpp), which is
// where a discard is actually traced.
//
// snake_case keys, like every other `on`-prefixed message in this file; the camelCase block further down is
// web's protocol and says why it differs.
inline std::string charaDetailRestarted(bool completed) {
    return json_util::Json{{"type", "onCharaDetailRestarted"}, {"completed", completed}}.dump();
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
