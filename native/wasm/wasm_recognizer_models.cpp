// Wasm definition of recognizer_impl::makePredictor (declared in chara_detail/recognizer_prediction.h), and the
// shared-memory inference channel it runs on.
//
// Why this is per platform: the Wasm module links no onnxruntime -- models run in onnxruntime-web on the JS
// thread -- and predict() runs on a pipeline pthread, which may not call JS. So a predictor here is a JS bridge
// rather than recognizer::Model (the desktop definition, chara_detail_recognizer_models.cpp, is excluded from
// this build), and a model is identified by its relative module_path, the key the JS side built its sessions
// under, so no model file is read from the module directory. (The directory itself is still used: the shared
// recognizer reads version_info.json from it, which web/worker.js mounts there.) Everything else -- the
// constructors that call makePredictor and the decoders that read its outputs -- is the shared code in
// chara_detail_recognizer.cpp.
//
// Threading model (mirrors the notes in wasm_api.cpp, in reverse):
//   * Predictor construction runs on the module main thread (inside Module.init -> startPipeline), where JS
//     calls via emscripten::val ARE allowed. Each WasmPredictor resolves its model id, input H/W and output count
//     there by calling the JS-side umaOrtResolve(key).
//   * predict() runs on a pipeline pthread -- the recognizer's runner, or the scene scraper's for the factor rows
//     its character-switch rule reads -- where arbitrary JS calls are NOT allowed. So inference is a
//     shared-memory request/response over the (SharedArrayBuffer-backed) Wasm heap: the pthread writes the
//     resized NHWC uint8 input + model id into a control block, futex-waits, and the JS main-thread pump
//     (web/worker.js) runs ORT and writes the outputs back, each with its element type and element count, then
//     Atomics.notify wakes us.
//
// This is a PoC bridge: one in-flight request at a time, whichever pthread issues it (the channel admits callers
// in arrival order, see InferenceChannel), element 0 of each output carried back as a double, and a fixed-size
// request buffer. Product code would batch and avoid the per-call round trip. That each output really is the
// scalar the decoder reads is not assumed: the pump reports every output's type and element count, and every read
// passes through requireScalarOutput (cv/prediction_check.h), the check desktop runs on its onnxruntime tensors.
//
// The one thing that is NOT PoC-grade, because getting it wrong hangs the whole worker: the wait. This thread
// waits on a pump that runs on the JS thread, so anything that occupies the JS thread stalls it -- and stop()
// occupies the JS thread by design, to join this very pthread. So every wait here is bounded by a deadline AND
// cancellable via beginInferenceAbort() (wasm_inference_bridge.h). The worst outcome of a pump that stops
// answering is a dropped record with a log line; it is never a stalled recognizer, and never a stop() that
// cannot return.

#include <array>
#include <atomic>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>

#include <emscripten/bind.h>
#include <emscripten/em_js.h>
#include <emscripten/threading.h>
#include <emscripten/val.h>

#include <opencv2/imgproc.hpp>

#include "chara_detail/recognizer_prediction.h"
#include "cv/frame.h"
#include "cv/prediction_check.h"
#include "cv/predictor.h"
#include "types/shape.h"
#include "util/error_util.h"
#include "util/logger_util.h"
#include "util/thread_util.h"

#include "wasm_inference_bridge.h"

// NO JS CALL MADE FROM C++ MAY BE ALLOWED TO THROW. This is the rule for every emscripten::val call in this
// module, and it is not a style preference -- it is the only containment there is.
//
// THE PLATFORM CONSTRAINT: a JavaScript exception is not a C++ exception and does not unwind C++ frames. The
// build uses -fexceptions (native/wasm/build.sh), whose invoke_* trampolines end in
// `catch(e){stackRestore(sp); if(!(e instanceof EmscriptenEH)) throw e; ...}` -- readable in the pinned glue,
// web/wasm/umacapture_core.js -- so a plain JS Error is re-thrown with no landing pad entered. embind adds no
// containment either: the emval invoker is a generated function body with no try. No destructor runs, no
// catch(...) arm matches, and the throw leaves wasm through whichever Module.* entry point is on the stack.
//
// WHY THAT IS FATAL HERE: resolveModel below runs inside predictor construction, i.e. inside
// NativeApi::startPipeline, which is called with BOTH pipeline_mutex and CaptureSessionPolicy::mutex held by
// lock_guards (core/native_api.cpp, native_api.h). A JS throw would therefore skip both unlock()s and skip
// startEventLoopReportingError's rollback, and the next endCaptureSession() would block on a mutex nothing can
// ever release -- a worker wedged until the page is reloaded.
//
// THE FIX: the try/catch lives in JAVASCRIPT, where it works. This EM_JS installs a wrapper that calls the
// resolver, and returns `{error}` instead of throwing; C++ turns that into a std::runtime_error, which is a
// real C++ exception that unwinds normally and lands in startEventLoopReportingError's existing
// catch (const std::exception &) -- releasing both mutexes and reporting a clean onError. The wrapper body
// uses no Emscripten runtime helper (no UTF8ToString, no HEAP views, no Emval): the key travels in and the
// result travels out as ordinary embind values, so nothing about it depends on which runtime methods the link
// step happens to keep.
EM_JS(void, umaInstallOrtResolveGuard, (), {
    if (typeof globalThis.umaOrtResolveGuarded === 'function') {
        return;
    }
    globalThis.umaOrtResolveGuarded = function(key) {
        try {
            const resolver = globalThis.umaOrtResolve;
            if (typeof resolver !== 'function') {
                return {error: 'umaOrtResolve is not registered (the JS side must build ORT sessions first)'};
            }
            const info = resolver(key);
            if (info === undefined || info === null) {
                return {error: 'umaOrtResolve returned nothing for model: ' + key};
            }
            // Read the fields here too: a resolver that answers with an exotic object (a getter that throws,
            // a Proxy) must fail inside this try like every other JS misbehaviour, not at the embind read.
            return {id: info.id | 0, h: info.h | 0, w: info.w | 0, c: info.c | 0, outputs: info.outputs | 0};
        } catch (e) {
            const detail = (e && e.message) ? e.message : String(e);
            return {error: 'umaOrtResolve failed for model ' + key + ': ' + detail};
        }
    };
});

namespace {

// --- Shared control block layout (Int32 words at the start of the control buffer) ------------------------
enum ControlWord : int {
    kState = 0,       // ProtocolState, the handshake word both sides futex/Atomics on
    kModelId = 1,     // session index the JS pump should run
    kInputH = 2,      // resized input rows
    kInputW = 3,      // resized input cols
    kInputC = 4,      // resized input channels (3, BGR)
    kOutputCount = 5, // number of scalar outputs the decoder needs (== Decoder::kOutputCount)
    kControlWords = 16,
};

enum ProtocolState : int32_t {
    kIdle = 0,
    kRequest = 1,  // C++ -> JS: input is staged, run inference
    kDone = 2,     // JS -> C++: outputs are staged
    kError = 3,    // JS -> C++: session.run threw
};

constexpr std::size_t kRequestCapacity = 4u * 1024u * 1024u;  // resized crops are small; this is generous
constexpr std::size_t kResponseCapacity = 32u;                // outputs; max head count here is 10

// --- Wait bounds -----------------------------------------------------------------------------------------
// Every wait here is on the JS pump, i.e. on a thread this one does not control, so all three bounds exist to
// make sure a pump that stops answering degrades to a dropped record with a log line rather than to a stalled
// recognizer (which would additionally wedge the next stop(); see wasm_inference_bridge.h).
//
// kWaitSliceMs is the futex slice, NOT a failure bound: it is how long an abort raised while this thread is
// parked can go unnoticed in the worst case. beginInferenceAbort() also wakes the wait, and the abort flag
// deliberately does not touch the protocol word (the pump must still be able to finish a request it already
// picked up), so a wake that lands in the microseconds between the state load and entering the wait is lost
// and the slice is what covers it. Short enough that stop() is not visibly delayed by it.
constexpr double kWaitSliceMs = 250.0;

// Total budget for one inference. Generous: a first inference on a cold ORT session on a loaded machine is
// slow, and a false timeout costs a record.
constexpr double kInferenceDeadlineMs = 30000.0;

// Budget for collecting a response that was abandoned by an abort or a timeout. Short on purpose: either the
// pump resumes on its next event-loop turn and answers immediately, or it is dead and every subsequent record
// pays this once (rather than the full inference budget) before failing.
constexpr double kReclaimDeadlineMs = 2000.0;

// A single global inference channel with one in-flight slot, used by EVERY pipeline pthread that runs a
// prediction. Two do today: the recognizer's runner, and the scene scraper's runner, which reads the factor rows
// of the frame its character-switch rule judges (chara_detail::recognizer_impl::FactorRowReader).
//
// `admission` is what makes the slot single-flight: it covers reclaim -> publish -> wait -> kIdle for one request.
// A FIFO rather than a std::mutex, because the recognizer issues predictions back to back for a whole record and
// a std::mutex promises no order -- a waiting scraper could lose every re-acquisition race for the length of that
// record. Admitted in arrival order, a caller waits for the requests queued ahead of it and no longer.
struct InferenceChannel {
    volatile int32_t *control = nullptr;
    std::uint8_t *request = nullptr;
    // kResponseCapacity entries each, indexed by output: element 0 as a double, the element count, and the element
    // type as a uma::recognizer::ScalarKind value.
    double *response = nullptr;
    std::int32_t *response_element_counts = nullptr;
    std::int32_t *response_kinds = nullptr;
    uma::thread_util::FifoAdmission admission;
};

InferenceChannel &channel() {
    static InferenceChannel instance;
    return instance;
}

// Raised by beginInferenceAbort() while the JS thread is inside Module.stop(). Read by every bridge wait.
std::atomic<bool> g_inference_aborting{false};

// Set when a published request is walked away from (abort or timeout) while the JS pump may still be holding
// it. The pump has no idea the waiter left: when its `await session.run(...)` continuation eventually resumes
// it stores kDone into the protocol word regardless. If that landed on top of a LATER request it would be read
// as that request's answer over stale response bytes, so the stray completion is collected -- once, before the
// channel is reused -- by reclaimAbandonedResponse(). Module lifetime, like the channel: an abort during one
// session must still be cleaned up by the next one.
std::atomic<bool> g_abandoned_response_pending{false};

// Allocates the shared buffers on the Wasm heap and hands their pointers to JS. Called once from the module
// main thread (web/worker.js) before Module.init(). The buffers live on the pthread-shared heap, so every
// pipeline pthread and the JS main thread address the same bytes.
emscripten::val setupInferenceBridge() {
    auto &ch = channel();
    if (ch.control == nullptr) {
        ch.control = static_cast<volatile int32_t *>(std::calloc(kControlWords, sizeof(int32_t)));
        ch.request = static_cast<std::uint8_t *>(std::malloc(kRequestCapacity));
        ch.response = static_cast<double *>(std::malloc(kResponseCapacity * sizeof(double)));
        ch.response_element_counts = static_cast<std::int32_t *>(std::calloc(kResponseCapacity, sizeof(std::int32_t)));
        ch.response_kinds = static_cast<std::int32_t *>(std::calloc(kResponseCapacity, sizeof(std::int32_t)));
    }
    auto info = emscripten::val::object();
    info.set("controlPtr", static_cast<int>(reinterpret_cast<std::intptr_t>(ch.control)));
    info.set("requestPtr", static_cast<int>(reinterpret_cast<std::intptr_t>(ch.request)));
    info.set("requestCapacity", static_cast<int>(kRequestCapacity));
    info.set("responsePtr", static_cast<int>(reinterpret_cast<std::intptr_t>(ch.response)));
    info.set("responseCapacity", static_cast<int>(kResponseCapacity));
    info.set("responseElementCountsPtr", static_cast<int>(reinterpret_cast<std::intptr_t>(ch.response_element_counts)));
    info.set("responseKindsPtr", static_cast<int>(reinterpret_cast<std::intptr_t>(ch.response_kinds)));
    // The onnxruntime-web tensor type strings a decoder can read, and the ScalarKind value the pump writes for each;
    // any other type is written as `otherKind`. Handed over rather than restated in JS, so the two sides cannot
    // disagree on the values. This is the web counterpart of Prediction::kindOf in cv/model.h.
    auto kinds = emscripten::val::object();
    kinds.set("int64", static_cast<int>(uma::recognizer::ScalarKind::kInt64));
    kinds.set("float32", static_cast<int>(uma::recognizer::ScalarKind::kFloat));
    info.set("kindsByTensorType", kinds);
    info.set("otherKind", static_cast<int>(uma::recognizer::ScalarKind::kOther));
    info.set("stateIndex", static_cast<int>(kState));
    return info;
}

struct ModelHandle {
    int id = -1;
    int height = 0;
    int width = 0;
    int channels = 0;
    int outputs = 0;  // the session's output count
};

// Resolves a model key (its config module_path, e.g. "skill/prediction.onnx") to a session id, static input
// shape and output count via the JS side. Runs on the module main thread during predictor construction.
//
// Never calls umaOrtResolve directly: it throws on an unknown key (the JS side answers the module set actually
// present in OPFS, which can drift from recognizer.json), and a JS throw crossing this boundary would strand
// two held mutexes forever. It goes through the non-throwing guard installed above instead, so EVERY failure
// arrives here as a value and leaves as a C++ exception. See the EM_JS block for the full reasoning.
ModelHandle resolveModel(const std::string &key) {
    umaInstallOrtResolveGuard();
    emscripten::val resolver = emscripten::val::global("umaOrtResolveGuarded");
    if (resolver.isUndefined() || resolver.isNull()) {
        throw std::runtime_error("umaOrtResolveGuarded was not installed");
    }
    emscripten::val info = resolver(key);
    if (info.isUndefined() || info.isNull()) {
        throw std::runtime_error("umaOrtResolveGuarded returned nothing for model: " + key);
    }
    const emscripten::val error = info["error"];
    if (!error.isUndefined() && !error.isNull()) {
        throw std::runtime_error(error.as<std::string>());
    }
    return {info["id"].as<int>(), info["h"].as<int>(), info["w"].as<int>(), info["c"].as<int>(),
        info["outputs"].as<int>()};
}

// Waits for the JS pump to move the protocol word off kRequest, and returns the terminal state it published.
// Throws instead of returning when the abort flag is raised or `deadline_ms` elapses; in both cases the
// request stays published and is marked abandoned, because the pump may still be holding it (see
// g_abandoned_response_pending). Runs on a pipeline pthread only, never on the JS thread -- futex_wait is not
// allowed there, and blocking that thread is precisely what this whole mechanism exists to survive.
int32_t awaitBridgeResponse(InferenceChannel &ch, double deadline_ms, const char *what) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(static_cast<long long>(deadline_ms));
    for (;;) {
        const int32_t state = __atomic_load_n(&ch.control[kState], __ATOMIC_SEQ_CST);
        if (state == kDone || state == kError) {
            return state;
        }
        if (g_inference_aborting.load(std::memory_order_acquire)) {
            g_abandoned_response_pending.store(true, std::memory_order_release);
            // OperationAborted, not runtime_error: this is stop() cancelling on purpose, and the recognizer's
            // containment (chara_detail_recognizer.cpp) reports it as an expected drop instead of an error.
            throw uma::error_util::OperationAborted(std::string("inference bridge aborted while ") + what);
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            g_abandoned_response_pending.store(true, std::memory_order_release);
            // Deliberately NOT OperationAborted: nobody asked for this. The pump stopped answering on its own,
            // which is a real defect and must stay an error downstream.
            log_warning("inference bridge timed out after {} ms while {}", deadline_ms, what);
            throw std::runtime_error(std::string("inference bridge timed out while ") + what);
        }
        emscripten_futex_wait(const_cast<int32_t *>(&ch.control[kState]), kRequest, kWaitSliceMs);
    }
}

// Collects the completion of a request that was abandoned earlier, and returns the channel to kIdle. Called
// with the channel's admission pass held, before a new request is published, so a stray kDone can never be
// mistaken for the answer
// to the request that follows it. Throws (leaving the channel still marked abandoned) when the stray
// completion does not arrive within kReclaimDeadlineMs.
void reclaimAbandonedResponse(InferenceChannel &ch) {
    if (!g_abandoned_response_pending.load(std::memory_order_acquire)) {
        return;
    }
    awaitBridgeResponse(ch, kReclaimDeadlineMs, "reclaiming an abandoned inference response");
    __atomic_store_n(&ch.control[kState], kIdle, __ATOMIC_SEQ_CST);
    g_abandoned_response_pending.store(false, std::memory_order_release);
    log_debug("inference bridge: reclaimed an abandoned response, channel is idle again");
}

// The outputs of one inference, as the JS pump wrote them back. All labels here are small class indices (or an
// 8-digit date) that round-trip exactly through a double, so element 0 of every output is carried as a double
// across the JS boundary, next to what the pump observed of that output: its element type and element count.
class BridgeOutputs final : public uma::recognizer::PredictionOutputs {
public:
    [[nodiscard]] std::int64_t int64At(int index) const override {
        return static_cast<std::int64_t>(std::llround(values[checked(index, uma::recognizer::ScalarKind::kInt64)]));
    }

    [[nodiscard]] float floatAt(int index) const override {
        return static_cast<float>(values[checked(index, uma::recognizer::ScalarKind::kFloat)]);
    }

    std::size_t count = 0;  // outputs written back
    std::array<double, kResponseCapacity> values{};
    std::array<std::int32_t, kResponseCapacity> element_counts{};
    std::array<std::int32_t, kResponseCapacity> kinds{};

private:
    [[nodiscard]] static uma::recognizer::ScalarKind kindOf(std::int32_t wire) {
        using uma::recognizer::ScalarKind;
        switch (wire) {
            case static_cast<std::int32_t>(ScalarKind::kInt64): return ScalarKind::kInt64;
            case static_cast<std::int32_t>(ScalarKind::kFloat): return ScalarKind::kFloat;
            default: return ScalarKind::kOther;
        }
    }

    [[nodiscard]] std::size_t checked(int index, uma::recognizer::ScalarKind expected) const {
        uma::recognizer::requireScalarOutput(index, count, expected, [this](std::size_t i) {
            return uma::recognizer::OutputDescription{
                kindOf(kinds[i]), static_cast<std::size_t>(element_counts[i] < 0 ? 0 : element_counts[i])};
        });
        return static_cast<std::size_t>(index);
    }
};

// Runs one inference on the calling pipeline pthread by handing the request to the JS pump and futex-waiting.
void runInferenceOnBridge(int model_id, const std::uint8_t *input, int height, int width, int channels,
    int output_count, BridgeOutputs &output) {
    auto &ch = channel();
    if (ch.control == nullptr) {
        throw std::runtime_error("inference bridge is not set up");
    }
    // Fail fast rather than park: while the abort is up the JS thread is joining this very pthread, so no
    // request can be serviced and publishing one would only cost a wait slice. This mirrors what the runner's
    // own join() already does for queued connections (EventRunner::join calls processor->abort() to release
    // producers blocked in a Block-mode send before joining); the bridge is the one wait that had no such
    // release, which is why it is the one that deadlocked.
    if (g_inference_aborting.load(std::memory_order_acquire)) {
        throw uma::error_util::OperationAborted("inference bridge is stopping");
    }
    const std::size_t byte_count = static_cast<std::size_t>(height) * width * channels;
    if (byte_count > kRequestCapacity) {
        throw std::runtime_error("inference input exceeds the shared request buffer");
    }
    if (static_cast<std::size_t>(output_count) > kResponseCapacity) {
        throw std::runtime_error("inference output count exceeds the shared response buffer");
    }

    const auto pass = ch.admission.admit();
    // Re-checked with the pass held: the abort may have been raised while this caller was queued behind another
    // request, and publishing now would only cost a wait slice before throwing (FifoAdmission leaves abort to
    // the caller by contract).
    if (g_inference_aborting.load(std::memory_order_acquire)) {
        throw uma::error_util::OperationAborted("inference bridge is stopping");
    }
    reclaimAbandonedResponse(ch);
    std::memcpy(ch.request, input, byte_count);
    ch.control[kModelId] = model_id;
    ch.control[kInputH] = height;
    ch.control[kInputW] = width;
    ch.control[kInputC] = channels;
    ch.control[kOutputCount] = output_count;

    // Publish the request (release), then wait until the JS pump publishes a result. futex_wait re-checks the
    // word atomically, so a wake that lands between the store and the wait is not lost.
    __atomic_store_n(&ch.control[kState], kRequest, __ATOMIC_SEQ_CST);
    const int32_t final_state = awaitBridgeResponse(ch, kInferenceDeadlineMs, "waiting for an inference result");
    if (final_state == kError) {
        __atomic_store_n(&ch.control[kState], kIdle, __ATOMIC_SEQ_CST);
        throw std::runtime_error("onnxruntime-web inference failed (see console)");
    }
    for (int i = 0; i < output_count; ++i) {
        output.values[i] = ch.response[i];
        output.element_counts[i] = ch.response_element_counts[i];
        output.kinds[i] = ch.response_kinds[i];
    }
    output.count = static_cast<std::size_t>(output_count);
    __atomic_store_n(&ch.control[kState], kIdle, __ATOMIC_SEQ_CST);
}

// A Predictor whose predict() resizes exactly like recognizer::Model (INTER_LINEAR, NHWC uint8) and runs the
// inference over the JS bridge. Decoder (chara_detail/recognizer_prediction.h) selects the head layout and
// the Result type.
template<typename Decoder>
class WasmPredictor : public uma::recognizer::Predictor<typename Decoder::Result> {
public:
    using Result = typename Decoder::Result;

    WasmPredictor(const std::string &key, std::string name) : model_name(std::move(name)) {
        handle = resolveModel(key);
        uma::recognizer::requireOutputCount(
            model_name, static_cast<std::size_t>(handle.outputs < 0 ? 0 : handle.outputs), Decoder::kOutputCount);
        input_size = {handle.width, handle.height};
        log_debug("WasmPredictor '{}' -> id={} input={}x{}x{} outputs={}", model_name, handle.id, handle.width,
            handle.height, handle.channels, handle.outputs);
    }

    [[nodiscard]] uma::recognizer::Predicted<Result> predict(const uma::Frame &frame) const override {
        cv::Mat image;
        cv::resize(frame.data(), image, input_size.toCVSize(), 0, 0, cv::INTER_LINEAR);
        if (!image.isContinuous()) {
            image = image.clone();
        }
        BridgeOutputs out;
        runInferenceOnBridge(handle.id, image.data, image.rows, image.cols, image.channels(),
            static_cast<int>(Decoder::kOutputCount), out);
        return Decoder::decode(out);
    }

    [[nodiscard]] const std::string &name() const override { return model_name; }

private:
    std::string model_name;
    ModelHandle handle;
    uma::Size<int> input_size;
};

}  // namespace

namespace uma::wasm {

// See wasm_inference_bridge.h for why this exists. Runs on the JS thread, from stop(), just before it joins
// the pipeline pthreads.
void beginInferenceAbort() {
    g_inference_aborting.store(true, std::memory_order_release);
    auto &ch = channel();
    if (ch.control == nullptr) {
        return;
    }
    // Wake the parked waiter. Atomics.notify is non-blocking, so this is safe from the JS thread. The protocol
    // word is deliberately left at kRequest: the pump may already have picked this request up, and it must
    // remain able to complete it (reclaimAbandonedResponse collects that completion). A wake is lost only if
    // it races the waiter entering the wait, which kWaitSliceMs covers.
    emscripten_futex_wake(const_cast<int32_t *>(&ch.control[kState]), INT_MAX);
}

void endInferenceAbort() {
    g_inference_aborting.store(false, std::memory_order_release);
}

}  // namespace uma::wasm

EMSCRIPTEN_BINDINGS(umacapture_recognizer) {
    emscripten::function("setupInferenceBridge", &setupInferenceBridge);
}

namespace uma::chara_detail::recognizer_impl {

// module_root_dir is unused here: the JS side loaded the models from OPFS and keyed its sessions by module_path,
// so the relative module_path is the bridge key and no model file is read from the MEMFS module directory. The
// recognizer that calls this still reads version_info.json from that directory.
template<typename Decoder>
PredictorFor<Decoder> makePredictor(
    const std::filesystem::path &module_root_dir, const std::string &module_path, const std::string &name) {
    (void) module_root_dir;
    return std::make_unique<WasmPredictor<Decoder>>(module_path, name);
}

template PredictorFor<IndexDecoder> makePredictor<IndexDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
template PredictorFor<CharaDecoder> makePredictor<CharaDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
template PredictorFor<RacePlaceDecoder> makePredictor<RacePlaceDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);
template PredictorFor<DateTimeDecoder> makePredictor<DateTimeDecoder>(
    const std::filesystem::path &, const std::string &, const std::string &);

}  // namespace uma::chara_detail::recognizer_impl
