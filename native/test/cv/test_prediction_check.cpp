// The inference-output check both platforms run before a decoder reads a model's outputs (cv/prediction_check.h).
//
// Desktop (cv/model.h) and web (native/wasm/wasm_recognizer_models.cpp) only describe their outputs; whether the
// description satisfies the decoder's head layout is decided here. Neither adapter is compiled by this target
// (one needs onnxruntime, the other Emscripten), so these cases pin down the decision itself: which layouts pass,
// which are refused, and with which exception type, because the two exception types reach the recognizer's
// containment as the same dropped record but read differently in its log.

#include <doctest/doctest.h>

#include <cstddef>
#include <stdexcept>
#include <string>

#include "cv/prediction_check.h"

namespace uma::recognizer {
namespace {

// A describe callback over a fixed description, counting how often the check asked for it.
struct FixedOutput {
    OutputDescription description;
    mutable int calls = 0;

    OutputDescription operator()(std::size_t) const {
        ++calls;
        return description;
    }
};

std::string messageOf(const std::exception &e) { return e.what(); }

}  // namespace

TEST_CASE("requireOutputCount accepts a session with at least the decoder's outputs") {
    CHECK_NOTHROW(requireOutputCount("skill", 2, 2));
    CHECK_NOTHROW(requireOutputCount("skill", 5, 2));
}

TEST_CASE("requireOutputCount refuses a session one output short, naming the model") {
    try {
        requireOutputCount("chara", 9, 10);
        FAIL("a session with 9 outputs was accepted for a decoder that reads 10");
    } catch (const std::runtime_error &e) {
        const auto message = messageOf(e);
        CHECK(message.find("chara") != std::string::npos);
        CHECK(message.find("10") != std::string::npos);
        CHECK(message.find("9") != std::string::npos);
    }
    CHECK_THROWS_AS(requireOutputCount("chara", 0, 1), std::runtime_error);
}

TEST_CASE("requireScalarOutput accepts a single element of the kind the decoder reads") {
    CHECK_NOTHROW(requireScalarOutput(0, 2, ScalarKind::kInt64, FixedOutput{{ScalarKind::kInt64, 1}}));
    CHECK_NOTHROW(requireScalarOutput(1, 2, ScalarKind::kFloat, FixedOutput{{ScalarKind::kFloat, 1}}));
}

TEST_CASE("requireScalarOutput refuses an output of another kind") {
    // A float confidence where the decoder reads an int64 label, and the reverse.
    CHECK_THROWS_AS(
        requireScalarOutput(0, 2, ScalarKind::kInt64, FixedOutput{{ScalarKind::kFloat, 1}}), std::invalid_argument);
    CHECK_THROWS_AS(
        requireScalarOutput(1, 2, ScalarKind::kFloat, FixedOutput{{ScalarKind::kInt64, 1}}), std::invalid_argument);
    // A type neither read accepts (a bool or double head, say), whichever read asks for it.
    CHECK_THROWS_AS(
        requireScalarOutput(0, 2, ScalarKind::kInt64, FixedOutput{{ScalarKind::kOther, 1}}), std::invalid_argument);
    CHECK_THROWS_AS(
        requireScalarOutput(1, 2, ScalarKind::kFloat, FixedOutput{{ScalarKind::kOther, 1}}), std::invalid_argument);
}

TEST_CASE("requireScalarOutput refuses a vector output") {
    CHECK_THROWS_AS(
        requireScalarOutput(0, 2, ScalarKind::kInt64, FixedOutput{{ScalarKind::kInt64, 3}}), std::invalid_argument);
}

TEST_CASE("requireScalarOutput refuses an empty output as out of range, before judging its kind") {
    CHECK_THROWS_AS(
        requireScalarOutput(0, 2, ScalarKind::kInt64, FixedOutput{{ScalarKind::kInt64, 0}}), std::out_of_range);
    CHECK_THROWS_AS(
        requireScalarOutput(0, 2, ScalarKind::kInt64, FixedOutput{{ScalarKind::kFloat, 0}}), std::out_of_range);
}

TEST_CASE("requireScalarOutput refuses an index outside the outputs without describing it") {
    // describe is not called: a platform indexes its own storage with the index it is handed.
    const FixedOutput past_end{{ScalarKind::kInt64, 1}};
    CHECK_THROWS_AS(requireScalarOutput(2, 2, ScalarKind::kInt64, past_end), std::out_of_range);
    CHECK(past_end.calls == 0);

    const FixedOutput negative{{ScalarKind::kInt64, 1}};
    CHECK_THROWS_AS(requireScalarOutput(-1, 2, ScalarKind::kInt64, negative), std::out_of_range);
    CHECK(negative.calls == 0);

    const FixedOutput in_range{{ScalarKind::kInt64, 1}};
    CHECK_NOTHROW(requireScalarOutput(1, 2, ScalarKind::kInt64, in_range));
    CHECK(in_range.calls == 1);
}

}  // namespace uma::recognizer
