#pragma once

#include "util/json_util.h"

#include "window_recorder.h"

namespace uma::windows::windows_config {

struct WindowsConfig {
    std::optional<WindowRecorder> window_recorder;

    EXTENDED_JSON_TYPE_NDC(WindowsConfig, window_recorder);
};

}  // namespace uma::windows::windows_config
