#pragma once

#include <filesystem>
#include <string>
#include <system_error>

namespace uma::tool {

// The startup clearing of a `--stop-file`, shared by `capture` (src/core/cli.cpp) and by the mimic
// player (tool/mimic_player/mimic_player.cpp) so the two options that carry the same name cannot
// behave differently.
//
// WHAT A STOP-FILE IS. It is a sentinel: a path that does not exist yet, whose later APPEARANCE
// means "stop cleanly". Both callers clear it at startup so that a leftover from an earlier run
// cannot end the new run immediately. Both used to do that with an unconditional
// `std::filesystem::remove(path, ec)` -- deleting whatever the path named, without inspecting it and
// without reporting either outcome, because `ec` was discarded. The paths these two harnesses are
// handed every day sit in the same directory as the capture recordings, which are recordings of live
// game sessions and mostly cannot be produced again at all. One mistyped argument was therefore one
// unrecoverable deletion, and a silent one.
//
// HOW IT IS DECIDED. By a property this code can evaluate on the file itself, not by a table of
// names or extensions that the next kind of precious file would fall outside of: a sentinel carries
// no bytes. Only an EMPTY REGULAR FILE is removed, because removing it cannot destroy content that
// is not there. Everything else -- a file with bytes in it, a directory, a symlink, a device, or a
// path this process cannot even inspect -- is REFUSED: left exactly as it was, with the caller told
// to stop before it starts.
//
// WHY REFUSING IS THE SAFE SIDE. Refusing costs a run that has to be started again after the
// operator picks another path, and says so on the way out. Clearing wrongly costs a recording that
// cannot be re-recorded. The two errors are not exchangeable, so the guard always errs towards
// refusing -- including when it cannot tell what is there.
enum class StopFileClearance {
    Absent,  // nothing at the path: the ordinary case, and nothing to do
    Cleared,  // an empty regular file, i.e. a stale sentinel: removed
    Refused,  // anything else, or an inspection/removal that failed: untouched, do not start
};

struct StopFileClearResult {
    StopFileClearance clearance = StopFileClearance::Absent;
    // Empty for Absent. Otherwise a sentence naming the path and what was found there, so neither
    // caller has to invent its own wording and neither outcome can be silent.
    std::string reason;
};

[[nodiscard]] inline StopFileClearResult clearStaleStopFile(const std::filesystem::path &path) {
    const std::string quoted = "'" + path.string() + "'";

    std::error_code ec;
    // symlink_status, not status: a symlink must be judged as a symlink. Following it would let the
    // link's own harmlessness stand in for the target's, and `remove` deletes the link, not the target.
    const auto status = std::filesystem::symlink_status(path, ec);
    if (status.type() == std::filesystem::file_type::not_found) {
        return {StopFileClearance::Absent, {}};
    }
    if (ec || status.type() == std::filesystem::file_type::none) {
        return {
            StopFileClearance::Refused,
            "cannot inspect the stop-file path " + quoted + " (" + ec.message()
                + "); nothing was deleted. Pass a path this process can read."};
    }
    if (!std::filesystem::is_regular_file(status)) {
        return {
            StopFileClearance::Refused,
            "the stop-file path " + quoted
                + " already exists and is not a regular file; a stale stop-file sentinel would be an empty one. "
                  "Nothing was deleted. Pass a path you own, or remove it yourself."};
    }
    const auto size = std::filesystem::file_size(path, ec);
    if (ec) {
        return {
            StopFileClearance::Refused,
            "cannot read the size of the existing stop-file path " + quoted + " (" + ec.message()
                + "); nothing was deleted."};
    }
    if (size != 0) {
        return {
            StopFileClearance::Refused,
            "the stop-file path " + quoted + " already exists and holds " + std::to_string(size)
                + " bytes, so it is not a stale stop-file sentinel. Nothing was deleted. Pass a path you own, "
                  "or remove it yourself."};
    }
    std::filesystem::remove(path, ec);
    if (ec) {
        // The removal itself failed (a lock, a permission). Reported rather than dropped: if the file
        // is still there when the run starts, the run would stop on its very first poll.
        return {
            StopFileClearance::Refused,
            "failed to remove the stale stop-file " + quoted + " (" + ec.message() + ")."};
    }
    return {StopFileClearance::Cleared, "cleared a stale (empty) stop-file at " + quoted + "."};
}

}  // namespace uma::tool
