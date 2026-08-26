#pragma once

#include "chara_detail/chara_detail_record.h"

namespace uma::chara_detail {

struct RecordInfo {
    std::string record_id;
    std::optional<record::RecordType> record_type;
};

// WHAT A MID-SCENE RESET THREW AWAY.
//
// The scraper discards a session whenever it infers a character switch (three rules, all in
// CharaDetailSceneScraper). The reset itself is not a failure -- a clip or a live session containing two
// characters produces one per switch, legitimately -- so this is deliberately NOT reported as an error. But the
// event announcing it used to carry nothing at all, which left every front end unable to tell "a session was
// thrown away" from "a session started", and therefore unable to say that an import lost a character mid-way:
// a clip whose first character was discarded and whose second succeeded read as an unqualified success.
//
// So the event carries WHAT WAS LOST, and each front end decides what that means (live capture ignores it -- a
// switch is the feature working; an import counts it). Both fields are read at the instant of the discard,
// before the state that holds them is cleared:
//
//  * `info` -- the session's own identity, for the log line the discard writes. Its record_id names the
//    scraping directory the discarded fragments were being written into, which is what makes a discard
//    traceable in a log at all. It is deliberately NOT put on the wire: no front end decides anything from it,
//    and a record id that names nothing a receiver can open is a field to be kept in step for nothing.
//  * `completed` -- whether the session had ALREADY produced its record (CharaDetailSceneScraper::ready()). A
//    discard of a completed session loses nothing: the record was handed to the stitcher before the switch.
//    This is the field that keeps an ordinary two-character clip from reporting a loss, and it states the core's
//    fact rather than the front end's conclusion. A reader that cannot find the field must treat the session as
//    NOT completed: erring towards announcing a loss, never towards the silence this change exists to remove.
struct DiscardedSession {
    RecordInfo info;
    bool completed = false;
};

}  // namespace uma::chara_detail
