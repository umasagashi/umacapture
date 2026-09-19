#pragma once

#include <array>
#include <cstddef>

namespace uma::chara_detail::scraper_impl {

// What the factor tab's character-switch rule concludes once it has read both frames of a candidate switch
// (CharaDetailSceneScraper::maybeResetOnFactorChange; the comparison itself is factorSwitchVerdict, next to the
// reading it takes). Only Same keeps the session; the other three discard it.
//
// Empty and Unreadable are kept APART although they act alike, because they are different facts about the run --
// "the reader found no rows" (a list still loading, a frame the scan cannot anchor on) versus "the reader failed"
// -- and a count of either must not absorb the other.
//
// IN ITS OWN HEADER because two sides name it: the scraper, which reaches a verdict, and the core, which counts
// the verdicts a run reached (app::FactorSwitchVerdictTally). native_api.h deliberately knows the scraper by a
// forward declaration only, so the vocabulary the count is keyed by cannot live in the scraper's header.
enum class FactorSwitchVerdict {
    Same,        // both readings are non-empty and equal, element for element (id and star)
    Different,   // both readings are non-empty and they are not equal, in length or in any element
    Empty,       // at least one reading found no rows, so there is nothing to call the same
    Unreadable,  // the reader threw; there is no reading at all
};

// EVERY VERDICT, ONCE, IN DECLARATION ORDER. What anything that reports verdicts per kind iterates, so a kind
// that never happened is reported as a zero rather than left out: "this run reached no Empty verdict" and "this
// report does not know about Empty" must not read alike. The static_assert below pins that each entry is its own
// index, which is what lets a count be an array indexed by the verdict.
inline constexpr std::array<FactorSwitchVerdict, 4> kFactorSwitchVerdicts{
    FactorSwitchVerdict::Same,
    FactorSwitchVerdict::Different,
    FactorSwitchVerdict::Empty,
    FactorSwitchVerdict::Unreadable,
};

[[nodiscard]] constexpr bool factorSwitchVerdictsAreTheirOwnIndices() {
    for (std::size_t i = 0; i < kFactorSwitchVerdicts.size(); i++) {
        if (static_cast<std::size_t>(kFactorSwitchVerdicts[i]) != i) {
            return false;
        }
    }
    return true;
}
static_assert(factorSwitchVerdictsAreTheirOwnIndices(), "kFactorSwitchVerdicts must list every verdict at its index");

// The word for a verdict, in the same idiom as topOfContentTag. It is the log word of the rule's
// `factor switch verdict=` line AND the key the CLI's run summary counts the verdict under
// (core/cli_run_report.h), so the two cannot name one verdict differently.
[[nodiscard]] inline const char *factorSwitchVerdictTag(const FactorSwitchVerdict verdict) {
    switch (verdict) {
        case FactorSwitchVerdict::Same: return "same";
        case FactorSwitchVerdict::Different: return "different";
        case FactorSwitchVerdict::Empty: return "empty";
        case FactorSwitchVerdict::Unreadable: return "unreadable";
    }
    return "";  // out-of-range fallback; also silences C4715 (not all paths return a value)
}

}  // namespace uma::chara_detail::scraper_impl
