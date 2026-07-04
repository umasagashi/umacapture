#include <chrono>

#include "core/native_api.h"

#include "logger_util.h"

namespace uma::logger_util {

void init() {
    const auto logger_name = "uma::log";

#if defined(__ANDROID__)
    spdlog::sinks_init_list sinks = {
        std::make_shared<spdlog::sinks::android_sink_mt>("native"),
    };
    spdlog::set_default_logger(std::make_shared<spdlog::logger>(logger_name, sinks));
    spdlog::set_pattern("%^%L%$ %T.%f [%t] [%!:%#] %v");
#elif defined(__APPLE__)
    spdlog::sinks_init_list sinks = {
        std::make_shared<CallbackSinkMt>(),
    };
    spdlog::set_default_logger(std::make_shared<spdlog::logger>(logger_name, sinks));
    spdlog::set_pattern("[%n] %^%L%$ %T.%f [%t] [%!:%#] %v");
#else
    spdlog::sinks_init_list sinks = {
        std::make_shared<spdlog::sinks::stdout_color_sink_mt>(),
//        std::make_shared<spdlog::sinks::basic_file_sink_mt>("./sandbox/log.txt", true),  // TODO: Path.
    };
    spdlog::set_default_logger(std::make_shared<spdlog::logger>(logger_name, sinks));
    spdlog::set_pattern("%^%L%$ %T.%f [%t] [%!:%#] %v");
    spdlog::flush_on(spdlog::level::warn);
    spdlog::flush_every(std::chrono::seconds(5));
#endif

    spdlog::set_level(spdlog::level::trace);  // Do not change this. Change the macro defined on top.
}

template<typename Mutex>
void CallbackSink<Mutex>::sink_it_(const spdlog::details::log_msg &msg) {
    spdlog::memory_buf_t formatted;
    spdlog::sinks::base_sink<Mutex>::formatter_->format(msg, formatted);

    app::NativeApi::instance().log(fmt::to_string(formatted));
}

template class CallbackSink<std::mutex>;
template class CallbackSink<spdlog::details::null_mutex>;

}  // namespace uma::logger_util
