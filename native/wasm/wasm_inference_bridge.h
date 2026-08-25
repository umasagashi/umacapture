// Abort protocol for the JS-serviced inference bridge. Declared separately from the bridge itself
// (wasm_recognizer_models.cpp) because the only caller is wasm_api.cpp's stop().
//
// Why an abort exists at all: the recognizer's predict() runs on a pthread and is serviced by a pump on the
// worker's JS thread. Anything that blocks the JS thread therefore blocks every in-flight inference. stop()
// does exactly that -- it joins the recognizer pthread synchronously -- so without a way to cancel the wait,
// stopping while a recognition or a factor probe is in flight wedges the worker permanently: the pthread waits
// for a pump that cannot run, and the pump's thread waits for that pthread to exit.

#pragma once

namespace uma::wasm {

// Raises the abort flag and wakes a parked bridge wait, so an in-flight predict() throws instead of waiting for
// a JS pump that cannot run. Every request published while the flag is up fails immediately. Call BEFORE
// joining the pipeline; it is the join's precondition, not a courtesy.
//
// What it throws is part of the contract: uma::error_util::OperationAborted (native/src/util/error_util.h), so
// the recognizer's containment reports the dropped record as an expected stop rather than as an error. A bridge
// TIMEOUT is a plain std::runtime_error precisely so it does NOT get that treatment -- see error_util.h.
void beginInferenceAbort();

// Clears the abort flag. Call only once every pipeline thread is joined, i.e. once nothing can be inside the
// bridge, so the next session starts from a usable channel.
void endInferenceAbort();

}  // namespace uma::wasm
