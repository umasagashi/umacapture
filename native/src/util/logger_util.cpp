#include "logger_util.h"

#include "native_api.h"

namespace logger_util {

template<typename Mutex>
void CallbackSink<Mutex>::sink_it_(const spdlog::details::log_msg &msg) {
    spdlog::memory_buf_t formatted;
    spdlog::sinks::base_sink<Mutex>::formatter_->format(msg, formatted);

    NativeApi::instance().log(fmt::to_string(formatted));
}

template class CallbackSink<std::mutex>;
template class CallbackSink<spdlog::details::null_mutex>;

}  // namespace logger_util
