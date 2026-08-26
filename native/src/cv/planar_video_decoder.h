#pragma once

#include <cstdint>
#include <cstring>
#include <filesystem>
#include <functional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/pixdesc.h>
}

// A DIAGNOSTIC decode backend for cv/video_loader.h: the same clips the `video` subcommand reads, decoded
// through libav so the caller receives the decoder's own 4:2:0 PLANES instead of the BGR bytes swscale
// already converted for it.
//
// WHY IT EXISTS. swscale converts YUV -> RGB with BT.601 limited range regardless of a stream's colour tags,
// so cv::VideoCapture gives exactly one colour interpretation of a clip and there is no way to ask it for
// another. A browser decoding the same file converts with BT.709 -- not by honouring a tag, but as its default
// for the untagged clips this project has; see cv/decoded_frame_to_bgr.h -- and so produces a different one,
// measured about 7 mean / 37 max out of 255 across the RGB cube. Several thresholds in the pipeline are
// absolute colour tests. Whether those thresholds survive that shift is a property of the pipeline that
// nothing could measure while the CLI had a single decoder. This header is the second interpretation: hand
// the planes to cv/decoded_frame_to_bgr.h and let the caller name the matrix.
//
// NOT A PRODUCER, and not a fifth entry in .claude/rules/platform-parity.md's list. It decodes and nothing
// else: no Frame, no anchor, no pane decision, no timestamp policy. VideoLoader owns all of that and emits
// frames from this backend through exactly the code path it emits cv::VideoCapture's through, which is the
// point -- a difference between the two runs has to come from the pixels.
//
// SCOPE, stated plainly. Only planar 8-bit 4:2:0 (`yuv420p`) is accepted, because that is what the clips the
// golden suite drives are, and because every other layout would need a colour decision this header has no
// business making. Full-range `yuvj420p` in particular is REFUSED rather than converted: its luma ramp is not
// the limited-range one cv/decoded_frame_to_bgr.h expands, so accepting it would silently produce a third
// interpretation that is neither of the two under test.
namespace uma::video::planar {

namespace {

inline std::string planarAvError(int code) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(code, buffer, sizeof(buffer));
    return buffer;
}

}  // namespace

// One decoded frame, repacked tightly so it can be handed straight to color::decodedFrameToBgr as I420.
struct PlanarFrame {
    const uint8_t *data = nullptr;  // Y plane, then Cb, then Cr; valid only for the duration of the callback.
    size_t size = 0;
    int width = 0;
    int height = 0;
    // Presentation time in milliseconds, computed the way OpenCV's FFmpeg backend computes
    // CAP_PROP_POS_MSEC: (best_effort_timestamp - stream start_time) * time_base * 1000. VideoLoader feeds
    // this to the same MonotonicMediaClock it feeds cv::VideoCapture's value to, so the two backends stamp a
    // clip identically and a record difference cannot be blamed on the clock.
    double pos_ms = 0.0;
};

using PlanarFrameSink = std::function<void(const PlanarFrame &)>;

// Decodes `path` and calls `sink` once per frame, in presentation order. Throws std::runtime_error when the
// file cannot be opened, carries no video stream, or is not planar 8-bit 4:2:0.
inline void decodePlanarFrames(const std::filesystem::path &path, const PlanarFrameSink &sink) {
    AVFormatContext *format_ctx = nullptr;
    AVCodecContext *codec_ctx = nullptr;
    AVPacket *packet = nullptr;
    AVFrame *frame = nullptr;
    std::vector<uint8_t> packed;

    const auto cleanup = [&]() {
        if (frame != nullptr) {
            av_frame_free(&frame);
        }
        if (packet != nullptr) {
            av_packet_free(&packet);
        }
        if (codec_ctx != nullptr) {
            avcodec_free_context(&codec_ctx);
        }
        if (format_ctx != nullptr) {
            avformat_close_input(&format_ctx);
        }
    };
    const auto fail = [&](const std::string &message) {
        cleanup();
        throw std::runtime_error("planar decode: " + message);
    };

    // avformat_open_input takes a UTF-8 path; std::filesystem::path::string() is the ACP on Windows, so go
    // through u8string(). (Ffv1Reader needs a custom AVIO for the same reason; here the plain open is enough
    // because the clips this backend reads are named by the test harness.)
    const auto utf8 = path.u8string();
    const std::string url(utf8.begin(), utf8.end());
    int ret = avformat_open_input(&format_ctx, url.c_str(), nullptr, nullptr);
    if (ret < 0) {
        format_ctx = nullptr;
        fail("avformat_open_input failed for " + url + ": " + planarAvError(ret));
    }
    ret = avformat_find_stream_info(format_ctx, nullptr);
    if (ret < 0) {
        fail("avformat_find_stream_info failed: " + planarAvError(ret));
    }

    const AVCodec *codec = nullptr;
    const int stream_index = av_find_best_stream(format_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (stream_index < 0) {
        fail("no video stream found");
    }
    AVStream *stream = format_ctx->streams[stream_index];

    codec_ctx = avcodec_alloc_context3(codec);
    if (codec_ctx == nullptr) {
        fail("avcodec_alloc_context3 failed");
    }
    ret = avcodec_parameters_to_context(codec_ctx, stream->codecpar);
    if (ret < 0) {
        fail("avcodec_parameters_to_context failed: " + planarAvError(ret));
    }
    // One thread per core. Frames still come out of avcodec_receive_frame in presentation order, so this is
    // throughput only -- the same reasoning Ffv1Reader states for the identical setting.
    codec_ctx->thread_count = 0;
    ret = avcodec_open2(codec_ctx, codec, nullptr);
    if (ret < 0) {
        fail("avcodec_open2 failed: " + planarAvError(ret));
    }

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (packet == nullptr || frame == nullptr) {
        fail("av_packet_alloc / av_frame_alloc failed");
    }

    // OpenCV treats an absent stream start_time as 0 before subtracting it; match that exactly.
    const int64_t start_time = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
    const double time_base = av_q2d(stream->time_base);

    const auto emit = [&]() {
        if (frame->format != AV_PIX_FMT_YUV420P) {
            const char *name = av_get_pix_fmt_name(static_cast<AVPixelFormat>(frame->format));
            fail((std::ostringstream() << "unsupported pixel format " << (name == nullptr ? "?" : name)
                                       << "; only yuv420p is accepted")
                     .str());
        }
        const int width = frame->width;
        const int height = frame->height;
        const int chroma_width = (width + 1) / 2;
        const int chroma_height = (height + 1) / 2;
        const size_t luma_bytes = static_cast<size_t>(width) * static_cast<size_t>(height);
        const size_t chroma_bytes = static_cast<size_t>(chroma_width) * static_cast<size_t>(chroma_height);
        packed.resize(luma_bytes + 2 * chroma_bytes);

        // Copy row by row: an AVFrame's linesize is padded for SIMD and is NOT the row width.
        uint8_t *out = packed.data();
        for (int y = 0; y < height; ++y) {
            std::memcpy(out, frame->data[0] + static_cast<size_t>(y) * frame->linesize[0], width);
            out += width;
        }
        for (int plane = 1; plane <= 2; ++plane) {
            for (int y = 0; y < chroma_height; ++y) {
                std::memcpy(out, frame->data[plane] + static_cast<size_t>(y) * frame->linesize[plane],
                            chroma_width);
                out += chroma_width;
            }
        }

        const int64_t pts = frame->best_effort_timestamp == AV_NOPTS_VALUE ? frame->pts
                                                                          : frame->best_effort_timestamp;
        const double pos_ms =
            pts == AV_NOPTS_VALUE ? 0.0 : static_cast<double>(pts - start_time) * time_base * 1000.0;
        sink(PlanarFrame{packed.data(), packed.size(), width, height, pos_ms});
    };

    const auto drain = [&](AVPacket *input) {
        int send = avcodec_send_packet(codec_ctx, input);
        if (send < 0 && send != AVERROR_EOF) {
            fail("avcodec_send_packet failed: " + planarAvError(send));
        }
        for (;;) {
            const int received = avcodec_receive_frame(codec_ctx, frame);
            if (received == AVERROR(EAGAIN) || received == AVERROR_EOF) {
                break;
            }
            if (received < 0) {
                fail("avcodec_receive_frame failed: " + planarAvError(received));
            }
            emit();
            av_frame_unref(frame);
        }
    };

    try {
        while (av_read_frame(format_ctx, packet) >= 0) {
            if (packet->stream_index == stream_index) {
                drain(packet);
            }
            av_packet_unref(packet);
        }
        drain(nullptr);  // flush
    } catch (...) {
        cleanup();
        throw;
    }
    cleanup();
}

}  // namespace uma::video::planar
