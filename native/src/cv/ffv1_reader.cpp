#include <string>
#include <utility>

#include "cv/ffv1_avio.h"
#include "cv/ffv1_pixfmt.h"
#include "cv/ffv1_reader.h"
#include "cv/frame_shaper.h"
#include "util/logger_util.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

namespace uma::video {

namespace {

std::string avError(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(code, buffer, sizeof(buffer));
    return buffer;
}

constexpr AVRational kMillisTimeBase = {1, 1000};

}  // namespace

struct Ffv1Reader::Impl {
    Impl(const std::filesystem::path &path, const event_util::Sender<Frame, Size<int>> &on_frame_captured)
        : on_frame_captured(on_frame_captured) {
        try {
            open(path);
        } catch (...) {
            freeDecoder();
            throw;
        }
    }

    ~Impl() { freeDecoder(); }

    void run() const {
        AVPacket *packet = av_packet_alloc();
        AVFrame *frame = av_frame_alloc();
        if (packet == nullptr || frame == nullptr) {
            if (packet != nullptr) {
                av_packet_free(&packet);
            }
            if (frame != nullptr) {
                av_frame_free(&frame);
            }
            throw std::runtime_error("ffv1: av_packet_alloc / av_frame_alloc failed");
        }

        try {
            while (av_read_frame(format_ctx, packet) >= 0) {
                if (packet->stream_index == stream_index) {
                    decodePacket(packet, frame);
                }
                av_packet_unref(packet);
            }
            decodePacket(nullptr, frame);  // flush
        } catch (...) {
            av_packet_free(&packet);
            av_frame_free(&frame);
            throw;
        }
        av_packet_free(&packet);
        av_frame_free(&frame);
    }

private:
    void open(const std::filesystem::path &path) {
        file_avio = std::make_unique<ffv1_detail::FileAvio>(path, /*write=*/false);

        format_ctx = avformat_alloc_context();
        if (format_ctx == nullptr) {
            throw std::runtime_error("ffv1: avformat_alloc_context failed");
        }
        format_ctx->pb = file_avio->context();
        // Tell libav the pb is caller-owned so close_input never frees our FileAvio's AVIOContext.
        format_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;

        int ret = avformat_open_input(&format_ctx, nullptr, nullptr, nullptr);
        if (ret < 0) {
            // On failure avformat_open_input frees format_ctx and nulls it; drop our dangling pb reference.
            format_ctx = nullptr;
            throw std::runtime_error("ffv1: avformat_open_input failed: " + avError(ret));
        }
        ret = avformat_find_stream_info(format_ctx, nullptr);
        if (ret < 0) {
            throw std::runtime_error("ffv1: avformat_find_stream_info failed: " + avError(ret));
        }

        const AVCodec *codec = nullptr;
        stream_index = av_find_best_stream(format_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
        if (stream_index < 0) {
            throw std::runtime_error("ffv1: no video stream found");
        }
        stream = format_ctx->streams[stream_index];
        if (stream->codecpar->codec_id != AV_CODEC_ID_FFV1) {
            throw std::runtime_error("ffv1: stream is not FFV1");
        }

        codec_ctx = avcodec_alloc_context3(codec);
        if (codec_ctx == nullptr) {
            throw std::runtime_error("ffv1: avcodec_alloc_context3 failed");
        }
        ret = avcodec_parameters_to_context(codec_ctx, stream->codecpar);
        if (ret < 0) {
            throw std::runtime_error("ffv1: avcodec_parameters_to_context failed: " + avError(ret));
        }
        // Decode on all cores. avcodec_parameters_to_context leaves thread_count at 1, and single-threaded
        // FFV1 decode of a full-size client frame measures ~12 fps here -- below the ~24 fps the recordings
        // were captured at, so any consumer that has to keep up with the clip's own timestamps (the mimic
        // player) cannot. 0 means "one thread per core", the same default the ffmpeg CLI uses (~157 fps on
        // the same clip). Decoding is lossless and avcodec_receive_frame still returns frames in
        // presentation order, so this changes throughput only: replay sees the identical frame sequence,
        // just sooner, and is still paced by its Block-mode downstream queue rather than by the decoder.
        codec_ctx->thread_count = 0;
        ret = avcodec_open2(codec_ctx, codec, nullptr);
        if (ret < 0) {
            throw std::runtime_error("ffv1: avcodec_open2 failed: " + avError(ret));
        }
    }

    void decodePacket(AVPacket *packet, AVFrame *frame) const {
        int ret = avcodec_send_packet(codec_ctx, packet);
        if (ret < 0 && ret != AVERROR_EOF) {
            throw std::runtime_error("ffv1: avcodec_send_packet failed: " + avError(ret));
        }
        for (;;) {
            ret = avcodec_receive_frame(codec_ctx, frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                break;
            }
            if (ret < 0) {
                throw std::runtime_error("ffv1: avcodec_receive_frame failed: " + avError(ret));
            }
            emitFrame(frame);
            av_frame_unref(frame);
        }
    }

    void emitFrame(const AVFrame *frame) const {
        const int64_t pts = (frame->pts == AV_NOPTS_VALUE) ? 0 : frame->pts;
        const int64_t ts_ms = av_rescale_q(pts, stream->time_base, kMillisTimeBase);
        cv::Mat bgr = ffv1_detail::frameToBgr(frame);
        const Size<int> full_size = bgr.size();
        // No pane snapshot and no re-validation selector: this producer resolves nothing (see ffv1_reader.h),
        // so there is no decision that could go stale across a copy. AnchorOnly forwards `bgr` by shallow
        // cv::Mat copy rather than duplicating it, which is sound because frameToBgr allocates a fresh Mat per
        // frame -- and that is no longer left to this sentence: shapeCapturedFrame refuses any non-CropPixels
        // mode whose image fails frame_shaper::ownsPixelsSolely, by throwing. If frameToBgr ever started
        // handing back a wrapper over avcodec's own buffer, or an alias the decoder keeps, the throw would say
        // so instead of the pipeline quietly reading pixels the next decode overwrote.
        const auto shaped = frame_shaper::shapeCapturedFrame(
            bgr, static_cast<uint64>(ts_ms < 0 ? 0 : ts_ms), std::nullopt, frame_shaper::ShapingMode::AnchorOnly);
        if (!shaped.ok()) {
            log_debug("ffv1 replay dropped a frame: {}", frame_shaper::describe(shaped.status));
            return;
        }
        on_frame_captured->send(shaped.frame, full_size);
    }

    void freeDecoder() {
        if (codec_ctx != nullptr) {
            avcodec_free_context(&codec_ctx);
        }
        if (format_ctx != nullptr) {
            // AVFMT_FLAG_CUSTOM_IO keeps this from freeing our FileAvio's AVIOContext.
            avformat_close_input(&format_ctx);
        }
        file_avio.reset();
    }

    const event_util::Sender<Frame, Size<int>> on_frame_captured;

    std::unique_ptr<ffv1_detail::FileAvio> file_avio;
    AVFormatContext *format_ctx = nullptr;
    AVStream *stream = nullptr;
    AVCodecContext *codec_ctx = nullptr;
    int stream_index = -1;
};

Ffv1Reader::Ffv1Reader(
    const std::filesystem::path &path, const event_util::Sender<Frame, Size<int>> &on_frame_captured)
    : impl_(std::make_unique<Impl>(path, on_frame_captured)) {
}

Ffv1Reader::~Ffv1Reader() = default;

void Ffv1Reader::run() const {
    impl_->run();
}

}  // namespace uma::video
