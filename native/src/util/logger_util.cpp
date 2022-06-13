#include "core/native_api.h"

#include "logger_util.h"

namespace uma::logger_util {

template<typename Mutex>
void CallbackSink<Mutex>::sink_it_(const spdlog::details::log_msg &msg) {
    spdlog::memory_buf_t formatted;
    spdlog::sinks::base_sink<Mutex>::formatter_->format(msg, formatted);

    app::NativeApi::instance().log(fmt::to_string(formatted));
}

template class CallbackSink<std::mutex>;
template class CallbackSink<spdlog::details::null_mutex>;

}  // namespace uma::logger_util
