#pragma once

// #define SPDLOG_ACTIVE_LEVEL SPDLOG_LEVEL_TRACE
#define SPDLOG_ACTIVE_LEVEL SPDLOG_LEVEL_DEBUG

#include <mutex>

#include <nlohmann/json.hpp>
#include <spdlog/details/null_mutex.h>
#include <spdlog/sinks/base_sink.h>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/spdlog.h>

#if defined(__ANDROID__)
#include <spdlog/sinks/android_sink.h>
#endif

namespace uma::logger_util {

template<typename Mutex>
class CallbackSink : public spdlog::sinks::base_sink<Mutex> {
protected:
    void sink_it_(const spdlog::details::log_msg &msg) override;
    void flush_() override {}
};

using CallbackSinkMt = CallbackSink<std::mutex>;
using CallbackSinkSt = CallbackSink<spdlog::details::null_mutex>;

// Configures the default spdlog logger (sinks, pattern, level). Defined in logger_util.cpp.
void init();

}  // namespace uma::logger_util

#define INTERNAL_EXPAND_NAME(var) #var "={}, "
#define INTERNAL_VLOG(...) NLOHMANN_JSON_EXPAND(NLOHMANN_JSON_PASTE(INTERNAL_EXPAND_NAME, __VA_ARGS__)), __VA_ARGS__

#pragma clang diagnostic push
#pragma ide diagnostic ignored "OCUnusedMacroInspection"

#define vlog_trace(...) SPDLOG_TRACE(INTERNAL_VLOG(__VA_ARGS__))
#define vlog_debug(...) SPDLOG_DEBUG(INTERNAL_VLOG(__VA_ARGS__))
#define vlog_info(...) SPDLOG_INFO(INTERNAL_VLOG(__VA_ARGS__))
#define vlog_warning(...) SPDLOG_WARN(INTERNAL_VLOG(__VA_ARGS__))
#define vlog_error(...) SPDLOG_ERROR(INTERNAL_VLOG(__VA_ARGS__))
#define vlog_fatal(...) SPDLOG_CRITICAL(INTERNAL_VLOG(__VA_ARGS__))

#define log_trace(...) SPDLOG_TRACE(__VA_ARGS__)
#define log_debug(...) SPDLOG_DEBUG(__VA_ARGS__)
#define log_info(...) SPDLOG_INFO(__VA_ARGS__)
#define log_warning(...) SPDLOG_WARN(__VA_ARGS__)
#define log_error(...) SPDLOG_ERROR(__VA_ARGS__)
#define log_fatal(...) SPDLOG_CRITICAL(__VA_ARGS__)

#pragma clang diagnostic pop
