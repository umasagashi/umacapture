#ifndef RUNNER_WINDOWS_CONFIG_H
#define RUNNER_WINDOWS_CONFIG_H

#include "../../native/src/util/json_utils.h"

#include "window_recorder.h"

namespace config {

struct WindowsConfig {
    std::optional<config::WindowRecorder> window_recorder;

    EXTENDED_JSON_TYPE_NDC(WindowsConfig, window_recorder);
};

}  // namespace config

#endif  //RUNNER_WINDOWS_CONFIG_H
