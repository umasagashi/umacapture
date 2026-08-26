#pragma once

// Telling a deliberate cancellation apart from a real failure, at the places that contain every exception.
//
// Several pipeline stages catch everything on purpose, because they run on an event-runner thread that has no
// try/catch of its own (see EventRunnerThread::run): an exception escaping there leaves the std::thread and
// calls std::terminate. Those handlers used to log every containment at error level, which is right for a
// genuine failure and wrong for a cancellation the app itself asked for. The concrete case is the Wasm build:
// stop() raises an inference abort by design (native/wasm/wasm_inference_bridge.h), the parked bridge wait
// throws, and the in-flight record is dropped. That is the successful stop path -- yet it read exactly like a
// broken frame, in the console and in the error telemetry fed from it.
//
// The distinction is carried by the exception TYPE, deliberately not by its message. A substring test would
// misclassify silently the first time a message is reworded, and it would have to separate the abort
// ("... aborted while waiting for an inference result") from the genuinely bad timeout ("... timed out while
// waiting for an inference result") on wording alone -- two strings that differ by one word and mean opposite
// things.

#include <exception>
#include <stdexcept>
#include <string>

namespace uma::error_util {

// Thrown when an in-flight operation is cancelled because the app asked the pipeline to stop. Expected, not a
// defect: whoever contains it is meant to abandon the work quietly.
//
// A real failure must NOT use this type. In particular a TIMEOUT is not an abort: it means the counterpart
// stopped answering on its own, which nobody asked for and which must stay visible as an error.
class OperationAborted : public std::runtime_error {
public:
    explicit OperationAborted(const std::string &message) : std::runtime_error(message) {}
};

// How a contained exception should be reported.
struct ContainedFailure {
    // True only for OperationAborted: report it as an expected event, not as an error.
    bool aborted = false;
    // what(), or "unknown exception" for a throwable that does not derive from std::exception (WinRT and ONNX
    // both throw such types).
    std::string message;
};

// Classifies the exception that is currently being handled.
//
// Call ONLY from inside a catch block: it rethrows the in-flight exception to type-match it, and a rethrow
// with no exception in flight calls std::terminate. Written this way so a containment site keeps a single
// `catch (...)` arm and the part that is easy to get subtly wrong -- the ordering of the catch arms, and
// remembering that non-std throwables need an arm at all -- lives in one place that is unit-tested.
inline ContainedFailure describeCurrentFailure() {
    try {
        throw;
    } catch (const OperationAborted &e) {
        return {true, e.what()};
    } catch (const std::exception &e) {
        return {false, e.what()};
    } catch (...) {
        return {false, "unknown exception"};
    }
}

}  // namespace uma::error_util
