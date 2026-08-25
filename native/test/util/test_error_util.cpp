// Behavioral tests for the contained-exception classifier.
//
// The classifier is the whole point of the abort/failure split: the recognizer's containment sites
// (chara_detail_recognizer.cpp probe/recognize) keep a single `catch (...)` arm and ask this function whether
// what they caught was a deliberate cancellation or a real failure. The distinction decides a log level, and
// with it whether a routine stop shows up as an error in the console and in error telemetry.
//
// The pairs below are the ones that actually collide in production: the Wasm inference bridge
// (native/wasm/wasm_recognizer_models.cpp) throws an abort and a timeout whose messages differ by one word,
// and they must classify oppositely. That is exactly what a message substring test could not be trusted to do.

#include <doctest/doctest.h>

#include <functional>
#include <stdexcept>
#include <string>

#include "util/error_util.h"

namespace uma::error_util {
namespace {

// Mirrors a containment site: one catch-all arm that delegates the classification.
ContainedFailure classify(const std::function<void()> &body) {
    try {
        body();
    } catch (...) {
        return describeCurrentFailure();
    }
    FAIL("body did not throw");
    return {};
}

TEST_CASE("an OperationAborted is reported as an abort, not a failure") {
    const auto failure = classify([] { throw OperationAborted("inference bridge aborted while waiting"); });
    CHECK(failure.aborted);
    CHECK(failure.message == "inference bridge aborted while waiting");
}

TEST_CASE("a bridge timeout is reported as a failure even though its message reads like the abort") {
    // One word apart from the abort above, and the opposite meaning: nobody asked for a timeout, so it must
    // stay an error. This is the case a substring test would be most likely to sweep in with the abort.
    const auto failure = classify([] { throw std::runtime_error("inference bridge timed out while waiting"); });
    CHECK_FALSE(failure.aborted);
    CHECK(failure.message == "inference bridge timed out while waiting");
}

TEST_CASE("an ordinary std::exception is reported as a failure") {
    const auto failure = classify([] { throw std::logic_error("predictFactor requires ScreenStart-anchored rects"); });
    CHECK_FALSE(failure.aborted);
    CHECK(failure.message == "predictFactor requires ScreenStart-anchored rects");
}

TEST_CASE("a non-std throwable is reported as a failure with the unknown-exception message") {
    // WinRT and ONNX both throw types that do not derive from std::exception; the containment sites rely on
    // this arm existing at all, and on it never being mistaken for an abort.
    const auto failure = classify([] { throw 42; });
    CHECK_FALSE(failure.aborted);
    CHECK(failure.message == "unknown exception");
}

TEST_CASE("a class derived from OperationAborted still classifies as an abort") {
    // The arm matches by type, so future, more specific cancellations inherit the behaviour rather than
    // needing the classifier (or any containment site) to be edited.
    struct DerivedAbort : OperationAborted {
        DerivedAbort() : OperationAborted("stopping") {}
    };
    const auto failure = classify([] { throw DerivedAbort(); });
    CHECK(failure.aborted);
    CHECK(failure.message == "stopping");
}

}  // namespace
}  // namespace uma::error_util
