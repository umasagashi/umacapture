// Contract test for the shared capture-session lifecycle policy.
//
// This is the policy both front ends relay -- windows/runner/native_controller.h and web/worker.js (through
// native/wasm/wasm_api.cpp) -- and it exists exactly once so the two cannot disagree about what a start request
// means. They used to: a start arriving while a capture was already running was re-acknowledged as a success on
// Windows and failed as an error on web. These cases pin the single answer.
//
// Nothing here builds a real recognition pipeline: CaptureSessionPolicy and ensureCaptureLoop both take their
// pipeline operations as callables, so the verdicts AND the adopt/rebuild/start disposition are driven from
// fakes that report success or a failure message.

#include <doctest/doctest.h>

#include <atomic>
#include <chrono>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "core/native_api.h"

namespace uma::app {

namespace {

// A stand-in for NativeApi's pipeline start: counts its invocations and reports whatever the test asked for.
struct FakePipelineStart {
    std::string error;
    int calls = 0;

    std::string operator()() {
        calls++;
        return error;
    }
};

TEST_CASE("a start request with no session open starts one") {
    CaptureSessionPolicy policy;
    FakePipelineStart start;

    const auto verdict = policy.start(CaptureSessionKind::Live, [&start]() { return start(); });

    CHECK(verdict.verdict == CaptureSessionVerdict::Started);
    CHECK(verdict.message.empty());
    CHECK(verdict.acknowledged());
    CHECK(verdict.opened());
    CHECK(start.calls == 1);
    CHECK(policy.isActive());
    CHECK(policy.activeKind() == CaptureSessionKind::Live);
}

TEST_CASE("a start request of the SAME kind while a session is open is acknowledged again, not restarted") {
    CaptureSessionPolicy policy;
    FakePipelineStart start;
    REQUIRE(policy.start(CaptureSessionKind::Live, [&start]() { return start(); }).verdict
            == CaptureSessionVerdict::Started);

    const auto verdict = policy.start(CaptureSessionKind::Live, [&start]() { return start(); });

    // The verdict Windows already produced (an idempotent re-acknowledgement) and the one web now produces too.
    CHECK(verdict.verdict == CaptureSessionVerdict::AlreadyStarted);
    CHECK(verdict.message.empty());
    // The front end still owes the caller an acknowledgement, but must NOT bring a second producer up.
    CHECK(verdict.acknowledged());
    CHECK_FALSE(verdict.opened());
    // The open session is left completely alone: nothing is rebuilt underneath it.
    CHECK(start.calls == 1);
    CHECK(policy.isActive());
    CHECK(policy.activeKind() == CaptureSessionKind::Live);
}

TEST_CASE("a start request of the OTHER kind while a session is open is refused, with a reason") {
    // The case the untyped claim answered AlreadyStarted: the import front end would have acknowledged success
    // and then pushed decoded frames into the live session's pipeline and its record storage.
    for (const auto held : {CaptureSessionKind::Live, CaptureSessionKind::VideoImport}) {
        const auto requested =
            held == CaptureSessionKind::Live ? CaptureSessionKind::VideoImport : CaptureSessionKind::Live;

        CaptureSessionPolicy policy;
        FakePipelineStart start;
        REQUIRE(policy.start(held, [&start]() { return start(); }).verdict == CaptureSessionVerdict::Started);

        FakePipelineStart intruder;
        const auto verdict = policy.start(requested, [&intruder]() { return intruder(); });

        CHECK(verdict.verdict == CaptureSessionVerdict::Refused);
        // Refused is the existing verdict and it already carries a message, so no new verdict is needed: both
        // front ends relay this string through their own error transport.
        CHECK(verdict.message == CaptureSessionPolicy::mutualExclusionMessage(held, requested));
        CHECK(verdict.message.find(captureSessionKindName(requested)) != std::string::npos);
        CHECK(verdict.message.find(captureSessionKindName(held)) != std::string::npos);
        CHECK_FALSE(verdict.acknowledged());
        CHECK_FALSE(verdict.opened());
        // The refusal must not touch the running session in any way -- in particular it must NOT run the
        // intruder's pipeline start, which would rebuild the loop underneath the session that owns it.
        CHECK(intruder.calls == 0);
        CHECK(start.calls == 1);
        CHECK(policy.isActive());
        CHECK(policy.activeKind() == held);
    }
}

TEST_CASE("a session ended by one kind can be reopened by the other") {
    CaptureSessionPolicy policy;
    FakePipelineStart live;
    REQUIRE(policy.start(CaptureSessionKind::Live, [&live]() { return live(); }).verdict
            == CaptureSessionVerdict::Started);
    policy.end(CaptureSessionKind::Live);

    FakePipelineStart import_start;
    const auto verdict = policy.start(CaptureSessionKind::VideoImport, [&import_start]() { return import_start(); });

    // Exclusion is about a HELD claim, not about a kind that once held it.
    CHECK(verdict.verdict == CaptureSessionVerdict::Started);
    CHECK(import_start.calls == 1);
    CHECK(policy.activeKind() == CaptureSessionKind::VideoImport);
}

TEST_CASE("a start request whose pipeline fails is refused and leaves no session behind") {
    CaptureSessionPolicy policy;
    FakePipelineStart start{"startEventLoop failed: model load"};

    const auto verdict = policy.start(CaptureSessionKind::Live, [&start]() { return start(); });

    CHECK(verdict.verdict == CaptureSessionVerdict::Refused);
    // Relayed verbatim by the front end, which is why the core does not report it itself.
    CHECK(verdict.message == "startEventLoop failed: model load");
    CHECK_FALSE(verdict.acknowledged());
    CHECK_FALSE(verdict.opened());
    CHECK_FALSE(policy.isActive());

    // A refusal must not look like an open session to the next request, or a retry would be answered with
    // AlreadyStarted for a session that never existed.
    FakePipelineStart retry;
    const auto retried = policy.start(CaptureSessionKind::Live, [&retry]() { return retry(); });
    CHECK(retried.verdict == CaptureSessionVerdict::Started);
    CHECK(retry.calls == 1);
    CHECK(policy.isActive());
}

TEST_CASE("ending a session lets the next request start a fresh one, and ending is idempotent") {
    CaptureSessionPolicy policy;
    FakePipelineStart start;
    REQUIRE(policy.start(CaptureSessionKind::Live, [&start]() { return start(); }).verdict
            == CaptureSessionVerdict::Started);

    policy.end(CaptureSessionKind::Live);
    CHECK_FALSE(policy.isActive());
    CHECK_FALSE(policy.activeKind().has_value());
    // Both front ends have overlapping teardown paths that each call this unconditionally.
    policy.end(CaptureSessionKind::Live);
    CHECK_FALSE(policy.isActive());

    const auto verdict = policy.start(CaptureSessionKind::Live, [&start]() { return start(); });
    CHECK(verdict.verdict == CaptureSessionVerdict::Started);
    CHECK(start.calls == 2);
    CHECK(policy.isActive());
}

TEST_CASE("a release by the WRONG kind is ignored, so a stop button cannot give away someone else's session") {
    // The first thing that breaks once a second kind exists: NativeController::joinEventLoop releases from the
    // Dart stop path. Released unconditionally, a UI "stop capture" would drop the IMPORT's claim, and the next
    // Live start would no longer be refused -- a refusal is only as strong as its weakest release site.
    for (const auto held : {CaptureSessionKind::Live, CaptureSessionKind::VideoImport}) {
        const auto other = held == CaptureSessionKind::Live ? CaptureSessionKind::VideoImport
                                                            : CaptureSessionKind::Live;
        CaptureSessionPolicy policy;
        FakePipelineStart start;
        REQUIRE(policy.start(held, [&start]() { return start(); }).verdict == CaptureSessionVerdict::Started);

        policy.end(other);

        CHECK(policy.isActive());
        CHECK(policy.activeKind() == held);
        // And the exclusion the ignored release would have destroyed is still enforced.
        FakePipelineStart intruder;
        const auto verdict = policy.start(other, [&intruder]() { return intruder(); });
        CHECK(verdict.verdict == CaptureSessionVerdict::Refused);
        CHECK(intruder.calls == 0);

        // The owner's own release still works, and is still idempotent.
        policy.end(held);
        CHECK_FALSE(policy.isActive());
        policy.end(held);
        CHECK_FALSE(policy.isActive());
    }
}

TEST_CASE("endAny releases whatever is held, for the teardowns that cannot name a kind") {
    // The web worker's release (it has already dropped its own local ownership) and NativeController's
    // destructor. A release that silently did nothing there would strand the claim forever.
    for (const auto held : {CaptureSessionKind::Live, CaptureSessionKind::VideoImport}) {
        CaptureSessionPolicy policy;
        FakePipelineStart start;
        REQUIRE(policy.start(held, [&start]() { return start(); }).verdict == CaptureSessionVerdict::Started);

        policy.endAny();

        CHECK_FALSE(policy.isActive());
        CHECK_FALSE(policy.activeKind().has_value());
        policy.endAny();
        CHECK_FALSE(policy.isActive());
    }
}

// --- the event-loop half: adopt / rebuild / start ---------------------------------------------------------
//
// The same fake-driven style: ensureCaptureLoop takes teardown and start as callables, so what it DOES (and in
// which order) is observable without a pipeline.

// Records the pipeline operations in the order they happen, which is the point: a rebuild must tear down BEFORE
// it starts, or startPipeline's `assert_(event_runners == nullptr)` would be building over live runners.
struct FakeLoop {
    std::vector<std::string> calls;
    std::string start_error;

    [[nodiscard]] std::function<void()> teardown() {
        return [this]() { calls.emplace_back("teardown"); };
    }
    [[nodiscard]] std::function<std::string()> start() {
        return [this]() {
            calls.emplace_back("start");
            return start_error;
        };
    }
};

const std::vector<std::string> started_only{"start"};
const std::vector<std::string> torn_down_then_started{"teardown", "start"};

constexpr bool running = true;
constexpr bool not_running = false;

// A start config carrying every key CapturePipelineIdentity reads, plus keys it deliberately does not.
std::string configText(const std::string &video_mode,
                       const std::string &storage_dir,
                       const std::string &temp_dir,
                       const std::string &modules_dir,
                       const std::string &trainer_id,
                       const std::string &calibration) {
    return R"({"video_mode": )" + video_mode + R"(, "trainer_id": ")" + trainer_id
           + R"(", "directory": {"storage_dir": ")" + storage_dir + R"(", "temp_dir": ")" + temp_dir
           + R"(", "modules_dir": ")" + modules_dir + R"("}, "detail_crop_calibration": )" + calibration
           + R"(, "chara_detail": {"scene_scraper": {"anything": 1}}})";
}

std::string baseConfigText() {
    return configText("false", "/store/live", "/temp/live", "/modules", "trainer-a", "true");
}

CapturePipelineIdentity identityOf(const std::string &config, const std::optional<bool> &video_mode_override) {
    return capturePipelineIdentity(json_util::Json::parse(config), video_mode_override);
}

TEST_CASE("the pipeline identity is read off the config, with the session's video_mode winning") {
    const auto identity = identityOf(baseConfigText(), std::nullopt);
    CHECK_FALSE(identity.video_mode);
    CHECK(identity.storage_dir == "/store/live");
    CHECK(identity.temp_dir == "/temp/live");
    CHECK(identity.modules_dir == "/modules");
    CHECK(identity.trainer_id == "trainer-a");

    // An engaged override is what a session start passes (videoModeOf(kind)); it wins over the config in BOTH
    // directions, which is the whole reason the front ends keep sending the key they send today.
    CHECK(identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::VideoImport)).video_mode);
    const auto video_config = configText("true", "/store/live", "/temp/live", "/modules", "trainer-a", "true");
    CHECK(identityOf(video_config, std::nullopt).video_mode);
    CHECK_FALSE(identityOf(video_config, videoModeOf(CaptureSessionKind::Live)).video_mode);

    // A config missing a key it needs fails loudly rather than defaulting silently -- and it does so here,
    // before anything is torn down.
    CHECK_THROWS(identityOf(R"({"video_mode": false})", std::nullopt));
}

TEST_CASE("identity covers destination, owner and frame handling -- and nothing else") {
    const auto base = identityOf(baseConfigText(), std::nullopt);

    // IN: every value that is baked into the pipeline and decides where a session's records land, whose they
    // are, which models produced them, or how frames are queued.
    CHECK(!(base == identityOf(configText("true", "/store/live", "/temp/live", "/modules", "trainer-a", "true"),
                               std::nullopt)));
    CHECK(!(base
            == identityOf(configText("false", "/store/import-42", "/temp/live", "/modules", "trainer-a", "true"),
                          std::nullopt)));
    CHECK(!(base
            == identityOf(configText("false", "/store/live", "/temp/import-42", "/modules", "trainer-a", "true"),
                          std::nullopt)));
    CHECK(!(base
            == identityOf(configText("false", "/store/live", "/temp/live", "/modules-b", "trainer-a", "true"),
                          std::nullopt)));
    CHECK(!(base
            == identityOf(configText("false", "/store/live", "/temp/live", "/modules", "trainer-b", "true"),
                          std::nullopt)));

    // OUT: tuning. A record regeneration legitimately rides a loop started with a slightly different config, and
    // rebuilding on a difference like this one would tear the pipeline out from under it.
    CHECK(base
          == identityOf(configText("false", "/store/live", "/temp/live", "/modules", "trainer-a", "false"),
                        std::nullopt));
}

TEST_CASE("the running identity is recorded by a start and cleared by a teardown") {
    RunningPipelineIdentity running_pipeline;
    CHECK_FALSE(running_pipeline.identity().has_value());

    const auto live = identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::Live));
    running_pipeline.noteStarted(live);
    REQUIRE(running_pipeline.identity().has_value());
    CHECK(*running_pipeline.identity() == live);

    // A rebuild replaces rather than accumulates.
    const auto import_identity =
        identityOf(configText("false", "/store/import-42", "/temp/import-42", "/modules", "trainer-a", "true"),
                   videoModeOf(CaptureSessionKind::VideoImport));
    running_pipeline.noteStarted(import_identity);
    CHECK(*running_pipeline.identity() == import_identity);

    running_pipeline.noteStopped();
    CHECK_FALSE(running_pipeline.identity().has_value());
    running_pipeline.noteStopped();
    CHECK_FALSE(running_pipeline.identity().has_value());
}

TEST_CASE("with no loop running, a request starts one") {
    FakeLoop loop;
    const auto live = identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::Live));

    const auto result = ensureCaptureLoop(not_running, std::nullopt, live, loop.teardown(), loop.start());

    CHECK(result.disposition == CaptureLoopDisposition::Started);
    CHECK(result.error.empty());
    CHECK(loop.calls == started_only);
}

TEST_CASE("whether a loop runs is the runners' answer, not the remembered identity's") {
    // The remembered identity is a shadow copy, and what used to keep it in step with the runners was an
    // assert_, which compiles out under NDEBUG -- i.e. in both build directories and every shipped build. So an
    // identity left behind by a teardown that failed to clear it must not be able to decide anything: with the
    // runners saying "nothing is running", this is a plain start.
    FakeLoop loop;
    const auto stale = identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::Live));

    const auto result = ensureCaptureLoop(not_running, stale, stale, loop.teardown(), loop.start());

    CHECK(result.disposition == CaptureLoopDisposition::Started);
    CHECK(loop.calls == started_only);
}

TEST_CASE("a running loop of the same pipeline identity is adopted, untouched") {
    FakeLoop loop;
    const auto live = identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::Live));

    const auto result = ensureCaptureLoop(running, live, live, loop.teardown(), loop.start());

    CHECK(result.disposition == CaptureLoopDisposition::Adopted);
    CHECK(result.error.empty());
    // Neither torn down nor rebuilt: this is the adoption a record regeneration's loop relies on.
    CHECK(loop.calls.empty());
}

TEST_CASE("a running loop of a DIFFERENT pipeline identity is rebuilt, not silently adopted") {
    // The half of the second-kind problem the typed claim does NOT solve: the claim is free (the previous owner
    // released it, or it was an unowned regeneration loop), so nothing refuses the request -- but the running
    // loop was built for something else. Adopting it would hand this session the other one's frame handling,
    // record root, staging dir, model set or trainer id, silently.
    const auto live = identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::Live));
    const std::vector<CapturePipelineIdentity> differing{
        // A session scoped to its own storage root -- the same KIND as the running one, which is exactly the
        // case a video_mode-only comparison adopted, sending this session's records into the other's root.
        identityOf(configText("false", "/store/import-43", "/temp/import-43", "/modules", "trainer-a", "true"),
                   videoModeOf(CaptureSessionKind::Live)),
        // The other kind.
        identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::VideoImport)),
        // Another trainer.
        identityOf(configText("false", "/store/live", "/temp/live", "/modules", "trainer-b", "true"),
                   videoModeOf(CaptureSessionKind::Live)),
    };
    for (const auto &required : differing) {
        FakeLoop loop;
        const auto result = ensureCaptureLoop(running, live, required, loop.teardown(), loop.start());

        CHECK(result.disposition == CaptureLoopDisposition::Rebuilt);
        CHECK(result.error.empty());
        CHECK(loop.calls == torn_down_then_started);
    }

    // A loop that is running with NOTHING recorded resolves the same way: rebuild what might have suited rather
    // than adopt what might not.
    FakeLoop unknown;
    const auto result = ensureCaptureLoop(running, std::nullopt, live, unknown.teardown(), unknown.start());
    CHECK(result.disposition == CaptureLoopDisposition::Rebuilt);
    CHECK(unknown.calls == torn_down_then_started);
}

TEST_CASE("a caller with no requirement adopts whatever runs, whatever it was built for") {
    // Plain startEventLoop: a record regeneration and the CLI's offline subcommands. They ride the running loop
    // exactly as they always have, so the second kind adds no rebuild to a path that never asked for one.
    const std::vector<std::string> anything{
        baseConfigText(),
        configText("true", "/store/import-42", "/temp/import-42", "/modules-b", "trainer-b", "false"),
    };
    for (const auto &config : anything) {
        FakeLoop loop;
        const auto result =
            ensureCaptureLoop(running, identityOf(config, std::nullopt), std::nullopt, loop.teardown(),
                              loop.start());
        CHECK(result.disposition == CaptureLoopDisposition::Adopted);
        CHECK(loop.calls.empty());
    }

    // With nothing running it still builds -- with the config's own video_mode, which is what nullopt means
    // downstream in startPipeline.
    FakeLoop cold;
    const auto cold_result =
        ensureCaptureLoop(not_running, std::nullopt, std::nullopt, cold.teardown(), cold.start());
    CHECK(cold_result.disposition == CaptureLoopDisposition::Started);
    CHECK(cold.calls == started_only);
}

TEST_CASE("a failed (re)build reports its message, so the session start can refuse with it") {
    // Started/Rebuilt say the build was ATTEMPTED, not that it succeeded; the error field is what distinguishes
    // them, and there is no loop left either way.
    const auto live = identityOf(baseConfigText(), videoModeOf(CaptureSessionKind::Live));
    const auto import_identity =
        identityOf(configText("false", "/store/import-42", "/temp/import-42", "/modules", "trainer-a", "true"),
                   videoModeOf(CaptureSessionKind::VideoImport));

    FakeLoop cold;
    cold.start_error = "startEventLoop failed: model load";
    const auto started = ensureCaptureLoop(not_running, std::nullopt, live, cold.teardown(), cold.start());
    CHECK(started.disposition == CaptureLoopDisposition::Started);
    CHECK(started.error == "startEventLoop failed: model load");

    FakeLoop mismatched;
    mismatched.start_error = "startEventLoop failed: model load";
    const auto rebuilt =
        ensureCaptureLoop(running, live, import_identity, mismatched.teardown(), mismatched.start());
    CHECK(rebuilt.disposition == CaptureLoopDisposition::Rebuilt);
    CHECK(rebuilt.error == "startEventLoop failed: model load");
    // The old loop is gone either way: a failed rebuild must not leave the previous pipeline half-alive.
    CHECK(mismatched.calls == torn_down_then_started);
}

TEST_CASE("video mode is a property of the session kind, not of the config") {
    CHECK_FALSE(videoModeOf(CaptureSessionKind::Live));
    CHECK(videoModeOf(CaptureSessionKind::VideoImport));
}

// ---------------------------------------------------------------------------
// The lock span, and the join hazard that rests on it.
//
// CaptureSessionPolicy::start holds `mutex` ACROSS the injected `start_pipeline` -- deliberately, so two
// concurrent requests cannot both observe "no session" and both build a pipeline. In production that callable
// is NativeApi::startCaptureSession's lambda, which reaches ensureCaptureLoop's teardown() and therefore JOINS
// the event runners. So the lock span carries a precondition nothing states: no thread joined from inside
// start_pipeline may call back into the policy, because `mutex` is a plain std::mutex and the joining thread
// is already holding it. It is not hypothetical -- activeKind() is already read from a publisher path
// (NativeApi::isVideoImportSessionActive).
//
// The violation cannot be exercised: it IS a deadlock, so a case that performed one would hang rather than
// fail. What these cases assert is the fact the precondition rests on, as data rather than as a comment:
// while start_pipeline runs, a call into the policy from another thread cannot come back. Anything joined
// from there is therefore a deadlock, and a narrowed lock, a second mutex or a per-call one changes that
// answer and turns the first case below red.
//
// The waits are failure paths, not pacing. The probe thread is released only once start_pipeline is already
// running, and the only work left in it is one uncontended mutex acquisition; kProbeWindow is the window in
// which an UNLOCKED policy is observed to answer -- both positive controls below measure exactly that -- so
// it is orders of magnitude of slack, and only the case that legitimately observes nothing pays it.
// ---------------------------------------------------------------------------

constexpr auto kProbeWindow = std::chrono::milliseconds(250);
constexpr auto kRendezvousLimit = std::chrono::milliseconds(5000);
constexpr auto kPollInterval = std::chrono::milliseconds(1);

template<typename Predicate>
bool waitUntil(const Predicate &predicate, const std::chrono::milliseconds limit) {
    const auto deadline = std::chrono::steady_clock::now() + limit;
    while (!predicate()) {
        if (std::chrono::steady_clock::now() >= deadline) {
            return predicate();
        }
        std::this_thread::sleep_for(kPollInterval);
    }
    return true;
}

struct ProbeOutcome {
    int pipeline_calls = 0;
    // The probe was released and announced its call (the rendezvous itself worked).
    bool reached = false;
    // It also RETURNED from that call while start_pipeline was still running.
    bool answered_during_start_pipeline = false;
    // It returned at all, once start() had given the lock back.
    bool answered_eventually = false;
    // How long the answer took, when there was one. Reported so the window above is a measured margin.
    long long answer_delay_ms = -1;
    CaptureSessionVerdict verdict = CaptureSessionVerdict::Refused;
};

// Runs `probe` on another thread while `policy.start()` is inside its injected pipeline start, and reports
// whether the probe got an answer in there. The probe is held until start_pipeline is entered, so the
// ordering under test is established rather than raced for.
template<typename Policy, typename Probe>
ProbeOutcome probeDuringStartPipeline(Policy &policy, const Probe &probe) {
    std::atomic<bool> in_pipeline{false};
    std::atomic<bool> announced{false};
    std::atomic<bool> answered{false};
    ProbeOutcome outcome;

    std::thread prober([&]() {
        if (!waitUntil([&]() { return in_pipeline.load(); }, kRendezvousLimit)) {
            return;  // `reached` stays false and the case fails there, rather than on a silence it caused.
        }
        announced.store(true);
        probe(policy);
        answered.store(true);
    });

    const auto start = policy.start(CaptureSessionKind::Live, [&]() -> std::string {
        outcome.pipeline_calls++;
        in_pipeline.store(true);
        outcome.reached = waitUntil([&]() { return announced.load(); }, kRendezvousLimit);
        const auto asked = std::chrono::steady_clock::now();
        outcome.answered_during_start_pipeline = waitUntil([&]() { return answered.load(); }, kProbeWindow);
        if (outcome.answered_during_start_pipeline) {
            outcome.answer_delay_ms =
                std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - asked)
                    .count();
        }
        return {};
    });
    prober.join();

    outcome.verdict = start.verdict;
    outcome.answered_eventually = answered.load();
    return outcome;
}

struct NamedProbe {
    const char *name;
    std::function<void(CaptureSessionPolicy &)> action;
};

// The positive control for the measurement: the same shape as CaptureSessionPolicy, except that it gives the
// lock back BEFORE calling start_pipeline. That is the narrowing which would make a join from inside it safe
// and the mutual exclusion the real one promises unsound. Nothing in production uses this; it exists so that
// "the probe got no answer" is shown to be a property of the policy rather than of the harness.
class NarrowedLockPolicyStandIn {
public:
    CaptureSessionStart start(const CaptureSessionKind kind, const std::function<std::string()> &start_pipeline) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (active_kind.has_value()) {
                return {CaptureSessionVerdict::AlreadyStarted, {}};
            }
        }
        const std::string error = start_pipeline();
        if (!error.empty()) {
            return {CaptureSessionVerdict::Refused, error};
        }
        std::lock_guard<std::mutex> lock(mutex);
        active_kind = kind;
        return {CaptureSessionVerdict::Started, {}};
    }

    [[nodiscard]] bool isActive() const {
        std::lock_guard<std::mutex> lock(mutex);
        return active_kind.has_value();
    }

private:
    mutable std::mutex mutex;
    std::optional<CaptureSessionKind> active_kind;
};

TEST_CASE("no policy call from another thread returns while start_pipeline runs, so joining one would deadlock") {
    // Every non-static public member of CaptureSessionPolicy except start() itself, which is the one holding
    // the lock. All four take `mutex`. The list is hand-written and that is its weakness: a new lock-taking
    // member that is not added here leaves this case passing while saying nothing about it. The one public
    // member deliberately absent is mutualExclusionMessage -- static, no lock -- and the next case pins that,
    // so its absence is asserted rather than assumed.
    const std::vector<NamedProbe> probes = {
        {"isActive", [](CaptureSessionPolicy &policy) { (void) policy.isActive(); }},
        {"activeKind", [](CaptureSessionPolicy &policy) { (void) policy.activeKind(); }},
        {"end", [](CaptureSessionPolicy &policy) { policy.end(CaptureSessionKind::Live); }},
        {"endAny", [](CaptureSessionPolicy &policy) { policy.endAny(); }},
    };

    for (const auto &probe : probes) {
        CAPTURE(probe.name);
        CaptureSessionPolicy policy;
        const auto outcome = probeDuringStartPipeline(policy, probe.action);

        REQUIRE(outcome.pipeline_calls == 1);
        REQUIRE(outcome.reached);
        // THE INVARIANT: it was still waiting for the lock for as long as start_pipeline held it. A production
        // start_pipeline that joined this thread would wait for it forever, with the app frozen and silent.
        CHECK_FALSE(outcome.answered_during_start_pipeline);
        // And it was waiting, not lost: start() returning is what let it through.
        CHECK(outcome.answered_eventually);
        CHECK(outcome.verdict == CaptureSessionVerdict::Started);
    }
}

TEST_CASE("the same measurement DOES see an answer from a policy call that takes no lock") {
    // First positive control, and it runs against the real policy: mutualExclusionMessage is static and touches
    // no state, so it must come back from inside start_pipeline. Without it, the silence above would be equally
    // consistent with a harness in which no probe can ever answer.
    CaptureSessionPolicy policy;
    const auto outcome = probeDuringStartPipeline(policy, [](CaptureSessionPolicy &) {
        (void) CaptureSessionPolicy::mutualExclusionMessage(CaptureSessionKind::VideoImport,
                                                            CaptureSessionKind::Live);
    });

    REQUIRE(outcome.reached);
    CAPTURE(outcome.answer_delay_ms);
    CHECK(outcome.answered_during_start_pipeline);
}

TEST_CASE("the same measurement DOES see an answer once the lock stops spanning start_pipeline") {
    // Second positive control, and the one that matters: same probe, same window, same harness, against a
    // policy whose ONLY difference is that it releases the lock before start_pipeline. It answers -- so the
    // first case's silence is the lock span itself, and narrowing that span turns it red instead of passing
    // unnoticed. The measured delay is what makes kProbeWindow a margin rather than a guess.
    NarrowedLockPolicyStandIn narrowed;
    const auto outcome =
        probeDuringStartPipeline(narrowed, [](NarrowedLockPolicyStandIn &policy) { (void) policy.isActive(); });

    REQUIRE(outcome.reached);
    CAPTURE(outcome.answer_delay_ms);
    CHECK(outcome.answered_during_start_pipeline);
    CHECK(outcome.verdict == CaptureSessionVerdict::Started);
}

}  // namespace

}  // namespace uma::app
