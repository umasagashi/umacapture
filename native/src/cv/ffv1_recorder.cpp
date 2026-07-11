#include <atomic>
#include <chrono>
#include <string>
#include <thread>

#include "cv/ffv1_avio.h"
#include "cv/ffv1_pixfmt.h"
#include "cv/ffv1_recorder.h"
#include "util/event_util.h"
#include "util/logger_util.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/dict.h>
#include <libavutil/opt.h>
}

namespace uma::video {

namespace {

std::string avError(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(code, buffer, sizeof(buffer));
    return buffer;
}

// Millisecond time base for both the codec and the informational metadata; matches the epoch-ms domain of
// Frame::timestamp() so PTS deltas reproduce the exact inter-frame gaps the recognition debounce keys off.
constexpr AVRational kMillisTimeBase = {1, 1000};

}  // namespace

struct Ffv1Recorder::Impl {
    Impl(const std::filesystem::path &path, const Size<int> &size, int fps_hint)
        : width(size.width())
        , height(size.height()) {
        try {
            initEncoder(path, fps_hint);
        } catch (...) {
            freeEncoder();
            throw;
        }

        encode_runner = event_util::makeSingleThreadRunner(event_util::QueueLimitMode::Block, nullptr, "ffv1");
        encode_conn = encode_runner->makeConnection<Frame>();
        encode_conn->listen([this](const Frame &frame) {
            encodeOne(frame);
            processed_count.fetch_add(1);
        });
        encode_runner->start();
    }

    ~Impl() {
        close();
        freeEncoder();
    }

    void push(const Frame &frame) {
        if (closed.load()) {
            return;
        }
        // Clone: Frame is a shallow cv::Mat handle, and the encode happens on another thread, so hand the
        // encoder an independently owned buffer (see the Frame ownership contract in frame.h). Block-mode
        // send() applies backpressure, so at most a few frames are ever in flight.
        encode_conn->send(frame.clone());
        pushed_count.fetch_add(1);
    }

    void close() {
        if (closed.exchange(true)) {
            return;
        }
        // Drain every pushed frame through the encode worker before touching libav on this thread. join()
        // stops the worker WITHOUT flushing its queue (processIf halts as soon as isRunning() is false), so
        // wait for the processed counter to catch up first. Bounded so a wedged encoder can't hang teardown.
        if (encode_runner != nullptr) {
            for (int i = 0; i < 30000 && processed_count.load() < pushed_count.load(); ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            if (processed_count.load() < pushed_count.load()) {
                log_warning(
                    "ffv1: encoder did not drain in time ({}/{} frames)", processed_count.load(), pushed_count.load());
            }
            encode_runner->join();
        }
        if (failed || !header_written) {
            if (!header_written) {
                log_warning("ffv1: no frames recorded; output file is empty");
            }
            return;
        }
        try {
            flushEncoder();
            const int ret = av_write_trailer(format_ctx);
            if (ret < 0) {
                log_error("ffv1: av_write_trailer failed: {}", avError(ret));
            } else {
                log_info("ffv1: finalized recording ({} frames)", frame_count);
            }
        } catch (const std::exception &e) {
            log_error("ffv1: finalize failed: {}", e.what());
        }
    }

private:
    void initEncoder(const std::filesystem::path &path, int fps_hint) {
        file_avio = std::make_unique<ffv1_detail::FileAvio>(path, /*write=*/true);

        int ret = avformat_alloc_output_context2(&format_ctx, nullptr, "matroska", nullptr);
        if (ret < 0 || format_ctx == nullptr) {
            throw std::runtime_error("ffv1: avformat_alloc_output_context2 failed: " + avError(ret));
        }
        format_ctx->pb = file_avio->context();
        // Tell libav the pb is caller-owned so nothing here frees our FileAvio's AVIOContext.
        format_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;

        const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_FFV1);
        if (codec == nullptr) {
            throw std::runtime_error("ffv1: FFV1 encoder not found in this ffmpeg build");
        }

        stream = avformat_new_stream(format_ctx, nullptr);
        if (stream == nullptr) {
            throw std::runtime_error("ffv1: avformat_new_stream failed");
        }

        codec_ctx = avcodec_alloc_context3(codec);
        if (codec_ctx == nullptr) {
            throw std::runtime_error("ffv1: avcodec_alloc_context3 failed");
        }
        codec_ctx->width = width;
        codec_ctx->height = height;
        codec_ctx->pix_fmt = ffv1_detail::kFrameFormat;  // bit-exact BGR round-trip (see ffv1_pixfmt.h)
        codec_ctx->color_range = AVCOL_RANGE_JPEG;  // full-range 0..255
        codec_ctx->time_base = kMillisTimeBase;
        codec_ctx->thread_count = 0;  // auto (one per core)
        // Slice-based parallelism so a 30fps stream of full frames keeps up on multiple cores. Only enabled
        // for reasonably large frames: FFV1 rejects a fine slice grid on tiny images (avcodec_open2 EINVAL),
        // and the parallelism is pointless there anyway.
        if (width >= 128 && height >= 128) {
            codec_ctx->slices = 16;  // a 4x4 grid
            codec_ctx->thread_type = FF_THREAD_SLICE;
        }
        // FFV1 private tuning; non-fatal if a build lacks an option.
        av_opt_set_int(codec_ctx->priv_data, "coder", 1, 0);  // range coder
        av_opt_set_int(codec_ctx->priv_data, "context", 1, 0);
        av_opt_set_int(codec_ctx->priv_data, "slicecrc", 1, 0);
        if ((format_ctx->oformat->flags & AVFMT_GLOBALHEADER) != 0) {
            codec_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        ret = avcodec_open2(codec_ctx, codec, nullptr);
        if (ret < 0) {
            throw std::runtime_error("ffv1: avcodec_open2 failed: " + avError(ret));
        }
        ret = avcodec_parameters_from_context(stream->codecpar, codec_ctx);
        if (ret < 0) {
            throw std::runtime_error("ffv1: avcodec_parameters_from_context failed: " + avError(ret));
        }
        stream->time_base = kMillisTimeBase;
        stream->avg_frame_rate = {fps_hint, 1};

        av_frame = av_frame_alloc();
        packet = av_packet_alloc();
        if (av_frame == nullptr || packet == nullptr) {
            throw std::runtime_error("ffv1: av_frame_alloc / av_packet_alloc failed");
        }
        av_frame->format = ffv1_detail::kFrameFormat;
        av_frame->width = width;
        av_frame->height = height;
        ret = av_frame_get_buffer(av_frame, 0);
        if (ret < 0) {
            throw std::runtime_error("ffv1: av_frame_get_buffer failed: " + avError(ret));
        }
    }

    void encodeOne(const Frame &frame) {
        if (failed) {
            return;
        }
        const cv::Mat &image = frame.data();
        if (image.cols != width || image.rows != height) {
            log_warning(
                "ffv1: dropping frame with mismatched size {}x{} (stream is {}x{})",
                image.cols,
                image.rows,
                width,
                height);
            return;
        }
        try {
            if (!header_written) {
                t0 = frame.timestamp();
                av_dict_set(&format_ctx->metadata, "UMA_EPOCH_MS_T0", std::to_string(t0).c_str(), 0);
                const int ret = avformat_write_header(format_ctx, nullptr);
                if (ret < 0) {
                    throw std::runtime_error("avformat_write_header failed: " + avError(ret));
                }
                header_written = true;
            }

            int64_t pts = static_cast<int64_t>(frame.timestamp()) - static_cast<int64_t>(t0);
            if (pts <= last_pts && frame_count > 0) {
                log_warning("ffv1: non-monotonic timestamp {} -> bumping pts to {}", frame.timestamp(), last_pts + 1);
                pts = last_pts + 1;
            }
            last_pts = pts;

            const int ret = av_frame_make_writable(av_frame);
            if (ret < 0) {
                throw std::runtime_error("av_frame_make_writable failed: " + avError(ret));
            }
            ffv1_detail::bgrToFrame(image, av_frame);
            av_frame->pts = pts;

            encodeAndWrite(av_frame);
            frame_count++;
        } catch (const std::exception &e) {
            // A mid-stream failure disables further encoding but never propagates out of the runner thread.
            failed = true;
            log_error("ffv1: encode failed, stopping recording: {}", e.what());
        }
    }

    void encodeAndWrite(AVFrame *frame) {
        int ret = avcodec_send_frame(codec_ctx, frame);
        if (ret < 0) {
            throw std::runtime_error("avcodec_send_frame failed: " + avError(ret));
        }
        for (;;) {
            ret = avcodec_receive_packet(codec_ctx, packet);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                break;
            }
            if (ret < 0) {
                throw std::runtime_error("avcodec_receive_packet failed: " + avError(ret));
            }
            av_packet_rescale_ts(packet, codec_ctx->time_base, stream->time_base);
            packet->stream_index = stream->index;
            ret = av_interleaved_write_frame(format_ctx, packet);  // consumes/unrefs the packet
            if (ret < 0) {
                throw std::runtime_error("av_interleaved_write_frame failed: " + avError(ret));
            }
        }
    }

    void flushEncoder() { encodeAndWrite(nullptr); }

    void freeEncoder() {
        if (av_frame != nullptr) {
            av_frame_free(&av_frame);
        }
        if (packet != nullptr) {
            av_packet_free(&packet);
        }
        if (codec_ctx != nullptr) {
            avcodec_free_context(&codec_ctx);
        }
        if (format_ctx != nullptr) {
            // AVFMT_FLAG_CUSTOM_IO keeps avformat_free_context from touching our FileAvio's AVIOContext.
            avformat_free_context(format_ctx);
            format_ctx = nullptr;
        }
        file_avio.reset();
    }

    const int width;
    const int height;

    std::unique_ptr<ffv1_detail::FileAvio> file_avio;
    AVFormatContext *format_ctx = nullptr;
    AVStream *stream = nullptr;
    AVCodecContext *codec_ctx = nullptr;
    AVFrame *av_frame = nullptr;
    AVPacket *packet = nullptr;

    // Touched only on the encode runner thread (encodeOne) and, after join(), on the closing thread.
    uint64 t0 = 0;
    int64_t last_pts = 0;
    uint64 frame_count = 0;
    bool header_written = false;
    bool failed = false;

    std::atomic<bool> closed = false;
    // Drain accounting across the push (producer) and encode (worker) threads; see close().
    std::atomic<uint64> pushed_count = 0;
    std::atomic<uint64> processed_count = 0;

    event_util::SingleThreadMultiEventRunner encode_runner;
    event_util::Connection<Frame> encode_conn;
};

Ffv1Recorder::Ffv1Recorder(const std::filesystem::path &path, const Size<int> &size, int fps_hint)
    : impl_(std::make_unique<Impl>(path, size, fps_hint)) {
}

Ffv1Recorder::~Ffv1Recorder() = default;

void Ffv1Recorder::push(const Frame &frame) {
    impl_->push(frame);
}

void Ffv1Recorder::close() {
    impl_->close();
}

}  // namespace uma::video
