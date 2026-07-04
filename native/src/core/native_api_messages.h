#pragma once

#include <string>
#include <vector>

#include "chara_detail/chara_detail_record.h"
#include "types/shape.h"
#include "util/json_util.h"

// Pure builders for the notification payloads NativeApi pushes across the FFI boundary to Dart.
//
// Each function returns the already-dumped JSON string that NativeApi::notify() forwards. They are kept
// free of any NativeApi/pipeline state on purpose: the wire contract these produce (the "type" tag plus the
// per-message keys, which the Dart side reads by string) is the load-bearing part, and pulling it out here
// lets it be unit-tested without linking the ONNX/WinRT-heavy NativeApi translation unit. NativeApi's notify*
// methods are thin wrappers that call these and hand the result to notify().
namespace uma::app::messages {

inline std::string screenshotTaken(const std::string &path, const std::string &result) {
    return json_util::Json{{"type", "onScreenshotTaken"}, {"path", path}, {"result", result}}.dump();
}

inline std::string error(const std::string &message) {
    return json_util::Json{{"type", "onError"}, {"message", message}}.dump();
}

inline std::string captureStarted() { return json_util::Json{{"type", "onCaptureStarted"}}.dump(); }

inline std::string captureStopped() { return json_util::Json{{"type", "onCaptureStopped"}}.dump(); }

inline std::string scrollReady(int index) {
    return json_util::Json{{"type", "onScrollReady"}, {"index", index}}.dump();
}

inline std::string scrollUpdated(int index, double progress) {
    return json_util::Json{{"type", "onScrollUpdated"}, {"index", index}, {"progress", progress}}.dump();
}

inline std::string scrollPosition(int index, bool at_top) {
    return json_util::Json{{"type", "onScrollPosition"}, {"index", index}, {"at_top", at_top}}.dump();
}

inline std::string pageReady(int index) {
    return json_util::Json{{"type", "onPageReady"}, {"index", index}}.dump();
}

inline std::string factorProbe(const std::vector<chara_detail::record::Factor> &factors, int record_type) {
    return json_util::Json{{"type", "onFactorProbe"}, {"factors", factors}, {"record_type", record_type}}.dump();
}

inline std::string charaDetailStarted() { return json_util::Json{{"type", "onCharaDetailStarted"}}.dump(); }

inline std::string charaDetailRestarted() { return json_util::Json{{"type", "onCharaDetailRestarted"}}.dump(); }

inline std::string charaDetailClosed() { return json_util::Json{{"type", "onCharaDetailClosed"}}.dump(); }

inline std::string charaDetailFinished(const std::string &record_id, bool success) {
    return json_util::Json{{"type", "onCharaDetailFinished"}, {"id", record_id}, {"success", success}}.dump();
}

inline std::string charaDetailUpdated(const std::string &record_id) {
    return json_util::Json{{"type", "onCharaDetailUpdated"}, {"id", record_id}}.dump();
}

inline std::string frameRateReported(double fps) {
    return json_util::Json{{"type", "onFrameRateReported"}, {"fps", fps}}.dump();
}

inline std::string frameSizeReported(const Size<int> &size) {
    return json_util::Json{{"type", "onFrameSizeReported"}, {"size", size}}.dump();
}

}  // namespace uma::app::messages
