// Contract test for the verdicts the core reports about a run's factor character switches
// (app::FactorSwitchVerdictTally).
//
// WHAT IT IS FOR. The factor switch rule resets on Different, Empty and Unreadable alike, so a build whose switch
// reader always finds nothing, or always fails, resets exactly as often as a working one: records, `discarded` and
// `discarded_incomplete` do not move and every golden stays green. The per-verdict counts on the CLI's run summary
// are the only observable that differs, and native/test/integration/run.py asserts them against what a case
// declares. So what the tally itself must get right -- above all that the four verdicts are counted APART -- is
// pinned here rather than only end to end.
//
// Driven directly rather than through NativeApi, which umacapture_tests deliberately does not compile (see the
// target's comment in native/CMakeLists.txt); the tally is header-only for that reason, like
// RecordProductionCounter and ForwardedFrameGeometryObserver next to it.

#include <doctest/doctest.h>

#include <cstring>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "core/native_api.h"

namespace uma::app {
namespace {

using chara_detail::scraper_impl::FactorSwitchVerdict;
using chara_detail::scraper_impl::factorSwitchVerdictTag;
using chara_detail::scraper_impl::kFactorSwitchVerdicts;

TEST_CASE("a run that judged no switch reports zero for every verdict") {
    const FactorSwitchVerdictTally tally;
    const auto counts = tally.snapshot();
    for (const auto verdict : kFactorSwitchVerdicts) {
        CAPTURE(factorSwitchVerdictTag(verdict));
        CHECK(counts.of(verdict) == 0);
    }
}

TEST_CASE("each verdict is counted apart from the other three") {
    // A DIFFERENT number of notes per verdict, so a tally that counted one verdict under another's slot -- Empty
    // folded into Unreadable, say, which is the conflation this count exists to refuse -- or dropped one, cannot
    // reproduce all four numbers. Equal numbers would let a swap of two slots pass.
    FactorSwitchVerdictTally tally;
    tally.beginRun();
    for (int i = 0; i < 1; i++) {
        tally.note(FactorSwitchVerdict::Same);
    }
    for (int i = 0; i < 2; i++) {
        tally.note(FactorSwitchVerdict::Different);
    }
    for (int i = 0; i < 3; i++) {
        tally.note(FactorSwitchVerdict::Empty);
    }
    for (int i = 0; i < 4; i++) {
        tally.note(FactorSwitchVerdict::Unreadable);
    }
    const auto counts = tally.snapshot();
    CHECK(counts.of(FactorSwitchVerdict::Same) == 1);
    CHECK(counts.of(FactorSwitchVerdict::Different) == 2);
    CHECK(counts.of(FactorSwitchVerdict::Empty) == 3);
    CHECK(counts.of(FactorSwitchVerdict::Unreadable) == 4);
}

TEST_CASE("a new run starts every verdict from zero however the previous one ended") {
    FactorSwitchVerdictTally tally;
    for (const auto verdict : kFactorSwitchVerdicts) {
        tally.note(verdict);
    }
    tally.beginRun();
    const auto counts = tally.snapshot();
    for (const auto verdict : kFactorSwitchVerdicts) {
        CAPTURE(factorSwitchVerdictTag(verdict));
        CHECK(counts.of(verdict) == 0);
    }
}

TEST_CASE("every verdict has its own word, which is the key the run summary counts it under") {
    // The summary is keyed by these words (cli.cpp iterates kFactorSwitchVerdicts and asks for each word), so two
    // verdicts sharing a word would merge their counts on the line, and an empty word would be a key no harness
    // declares.
    std::set<std::string> words;
    for (const auto verdict : kFactorSwitchVerdicts) {
        const std::string word = factorSwitchVerdictTag(verdict);
        CHECK_FALSE(word.empty());
        words.insert(word);
    }
    CHECK(words.size() == kFactorSwitchVerdicts.size());
    CHECK(words == std::set<std::string>{"same", "different", "empty", "unreadable"});
}

TEST_CASE("counting is safe from the thread that notes and the thread that reads") {
    // The note runs on the scraper runner's thread and the read on the CLI's main thread after the drain. Not a race
    // detector -- a smoke test that concurrent notes do not lose one.
    FactorSwitchVerdictTally tally;
    std::vector<std::thread> threads;
    for (const auto verdict : kFactorSwitchVerdicts) {
        threads.emplace_back([&tally, verdict]() {
            for (int i = 0; i < 1000; i++) {
                tally.note(verdict);
            }
        });
    }
    for (auto &thread : threads) {
        thread.join();
    }
    const auto counts = tally.snapshot();
    for (const auto verdict : kFactorSwitchVerdicts) {
        CAPTURE(factorSwitchVerdictTag(verdict));
        CHECK(counts.of(verdict) == 1000);
    }
}

}  // namespace
}  // namespace uma::app
