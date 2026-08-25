#pragma once

// Random-access FFV1 clip reader for the mimic player (stage S3).
//
// The player has to be *driven*: pause on a frame, step n frames, seek to a timestamp, replay a
// sub-range. All of that needs a PULL interface with random access. uma::video::Ffv1Reader is a
// PUSH interface -- one forward `run()` that emits every frame and returns at end-of-stream, with
// no rewind -- because that is exactly what `replay` wants. Bending it into a controllable player
// would mean either unwinding the decode loop with an exception on every command (S2 already had to
// do that just to probe the frame size) or re-opening the file and re-decoding from frame 0 for
// every backwards seek. Both are contortions, and both would push player-only machinery into a file
// that `replay` shares.
//
// So the seek logic lives here, in native/tool/, and Ffv1Reader is left untouched. What is NOT
// duplicated is the part where drift would actually hurt:
//
//   * ffv1_detail::FileAvio    -- the same wide-path AVIOContext bridge, so a non-ASCII clip path
//                                 opens identically.
//   * ffv1_detail::frameToBgr  -- the same BGR0 -> BGR mapping the recorder's encode side is pinned
//                                 against. The pixels this hands out are bit-identical to the ones
//                                 `replay` decodes from the same file, by construction.
//
// Both are header-only, so reusing them costs nothing and cannot fall out of sync. The remaining
// ~60 lines here are plain avformat/avcodec open boilerplate.
//
// Seeking is exact and cheap because FFV1 is intra-only: every packet is a keyframe, so
// av_seek_frame(AVSEEK_FLAG_BACKWARD) lands on the requested frame itself, not on some earlier GOP
// start that would have to be decoded through. An index of every packet's PTS is built once at open
// (a demux-only pass, no decoding), which also gives the exact frame count and the per-frame
// timestamps `seek <time>` resolves against.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "cv/ffv1_avio.h"
#include "cv/ffv1_pixfmt.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

namespace uma::mimic {

class ClipDecoder {
public:
    explicit ClipDecoder(const std::filesystem::path &path) {
        try {
            open(path);
        } catch (...) {
            close();
            throw;
        }
    }

    ~ClipDecoder() { close(); }

    ClipDecoder(const ClipDecoder &) = delete;
    ClipDecoder &operator=(const ClipDecoder &) = delete;

    [[nodiscard]] int frameCount() const { return static_cast<int>(pts_.size()); }

    // Milliseconds since the clip's first frame. This is the timeline `seek` and `range` speak in,
    // so a caller never has to know the recorder's absolute capture clock.
    [[nodiscard]] long long relativeMs(int index) const { return rawMs(index) - rawMs(0); }

    // The frame whose relative timestamp is nearest `seconds`. Ties resolve to the earlier frame, so
    // the mapping from a requested time to a source index is a pure function of the clip.
    [[nodiscard]] int nearestIndex(double seconds) const {
        const auto want = static_cast<long long>(std::llround(seconds * 1000.0));
        int best = 0;
        long long best_distance = std::numeric_limits<long long>::max();
        for (int index = 0; index < frameCount(); ++index) {
            const long long distance = std::llabs(relativeMs(index) - want);
            if (distance < best_distance) {
                best_distance = distance;
                best = index;
            }
        }
        return best;
    }

    // The clip's own typical frame interval, used as the cadence a paused player re-presents at.
    // Median rather than mean so one long gap in the recording cannot stretch it.
    [[nodiscard]] long long medianIntervalMs() const {
        if (frameCount() < 2) {
            return 33;
        }
        std::vector<long long> deltas;
        deltas.reserve(static_cast<size_t>(frameCount() - 1));
        for (int index = 1; index < frameCount(); ++index) {
            deltas.push_back(relativeMs(index) - relativeMs(index - 1));
        }
        const size_t middle = deltas.size() / 2;
        std::nth_element(deltas.begin(), deltas.begin() + static_cast<long long>(middle), deltas.end());
        return std::max<long long>(1, deltas[middle]);
    }

    // Decoded pixels of source frame `index`, BGR, owned by this decoder until the next call.
    //
    // Sequential access (index == current + 1) is a single decode. Anything else -- a backwards
    // step, a seek, a multi-frame step -- goes through av_seek_frame, which on an intra-only stream
    // costs one decode as well. There is therefore no fast/slow path to reason about at the call
    // site: every frame is one decode away.
    const cv::Mat &frameAt(int index) {
        if (index < 0 || index >= frameCount()) {
            throw std::runtime_error("mimic: frame index out of range: " + std::to_string(index));
        }
        if (index == cached_index_ && !cache_.empty()) {
            return cache_;
        }
        if (index != cached_index_ + 1) {
            seekTo(index);
        }
        while (cached_index_ != index) {
            if (!advance()) {
                throw std::runtime_error("mimic: end of stream while decoding frame " + std::to_string(index));
            }
        }
        return cache_;
    }

private:
    static std::string avErr(int code) {
        char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
        av_strerror(code, buffer, sizeof(buffer));
        return buffer;
    }

    [[nodiscard]] long long rawMs(int index) const {
        const AVRational millis{1, 1000};
        return av_rescale_q(pts_[static_cast<size_t>(index)], stream_->time_base, millis);
    }

    void open(const std::filesystem::path &path) {
        avio_ = std::make_unique<video::ffv1_detail::FileAvio>(path, /*write=*/false);

        format_ = avformat_alloc_context();
        if (format_ == nullptr) {
            throw std::runtime_error("mimic: avformat_alloc_context failed");
        }
        format_->pb = avio_->context();
        // Caller-owned pb: avformat_close_input must not free the FileAvio's AVIOContext.
        format_->flags |= AVFMT_FLAG_CUSTOM_IO;

        int ret = avformat_open_input(&format_, nullptr, nullptr, nullptr);
        if (ret < 0) {
            format_ = nullptr;  // freed and nulled by avformat_open_input on failure
            throw std::runtime_error("mimic: avformat_open_input failed: " + avErr(ret));
        }
        ret = avformat_find_stream_info(format_, nullptr);
        if (ret < 0) {
            throw std::runtime_error("mimic: avformat_find_stream_info failed: " + avErr(ret));
        }

        const AVCodec *codec = nullptr;
        stream_index_ = av_find_best_stream(format_, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
        if (stream_index_ < 0) {
            throw std::runtime_error("mimic: no video stream found");
        }
        stream_ = format_->streams[stream_index_];
        if (stream_->codecpar->codec_id != AV_CODEC_ID_FFV1) {
            throw std::runtime_error("mimic: stream is not FFV1");
        }

        decoder_ = avcodec_alloc_context3(codec);
        if (decoder_ == nullptr) {
            throw std::runtime_error("mimic: avcodec_alloc_context3 failed");
        }
        ret = avcodec_parameters_to_context(decoder_, stream_->codecpar);
        if (ret < 0) {
            throw std::runtime_error("mimic: avcodec_parameters_to_context failed: " + avErr(ret));
        }
        // One decode thread per core. Single-threaded FFV1 decode of a full-size client frame runs at
        // ~12 fps here, well under the ~26 fps the clip's own timestamps demand, so the player could
        // not honour them at all. 0 is "one thread per core", the ffmpeg CLI's default.
        decoder_->thread_count = 0;
        ret = avcodec_open2(decoder_, codec, nullptr);
        if (ret < 0) {
            throw std::runtime_error("mimic: avcodec_open2 failed: " + avErr(ret));
        }

        packet_ = av_packet_alloc();
        av_frame_ = av_frame_alloc();
        if (packet_ == nullptr || av_frame_ == nullptr) {
            throw std::runtime_error("mimic: av_packet_alloc / av_frame_alloc failed");
        }

        scanIndex();
        seekTo(0);
    }

    // Demux-only pass over the whole file, recording every video packet's PTS. FFV1 has no B-frames
    // and no inter-frame prediction, so packets and frames correspond one to one and packet order is
    // presentation order -- the index is therefore exact without decoding anything.
    void scanIndex() {
        while (av_read_frame(format_, packet_) >= 0) {
            if (packet_->stream_index == stream_index_) {
                pts_.push_back(packet_->pts == AV_NOPTS_VALUE ? (pts_.empty() ? 0 : pts_.back() + 1) : packet_->pts);
            }
            av_packet_unref(packet_);
        }
        if (pts_.empty()) {
            throw std::runtime_error("mimic: the recording contains no frames");
        }
        for (size_t i = 1; i < pts_.size(); ++i) {
            if (pts_[i] <= pts_[i - 1]) {
                // Seeking resolves a target frame by PTS, so a non-increasing timeline would make the
                // mapping ambiguous. The recorder writes strictly increasing capture timestamps; a clip
                // that violates that was produced by something else and is rejected rather than
                // silently mis-seeked.
                throw std::runtime_error(
                    "mimic: the recording's timestamps are not strictly increasing at frame " + std::to_string(i));
            }
        }
    }

    void seekTo(int index) {
        const int ret = av_seek_frame(format_, stream_index_, pts_[static_cast<size_t>(index)], AVSEEK_FLAG_BACKWARD);
        if (ret < 0) {
            throw std::runtime_error("mimic: av_seek_frame failed: " + avErr(ret));
        }
        avcodec_flush_buffers(decoder_);
        eof_sent_ = false;
        pending_target_ = index;
        cached_index_ = -1;
        cache_.release();
    }

    // Decodes the next frame in presentation order into `cache_`, updating `cached_index_`. After a
    // seek the demuxer may hand back a frame at or before the target (AVSEEK_FLAG_BACKWARD), so
    // frames before the target PTS are decoded and dropped; on an intra-only stream that is at most
    // one wasted decode in practice.
    bool advance() {
        for (;;) {
            if (!decodeOne()) {
                return false;
            }
            const int64_t pts = (av_frame_->pts == AV_NOPTS_VALUE) ? 0 : av_frame_->pts;
            if (pending_target_ >= 0) {
                if (pts < pts_[static_cast<size_t>(pending_target_)]) {
                    av_frame_unref(av_frame_);
                    continue;
                }
                cached_index_ = pending_target_;
                pending_target_ = -1;
            } else {
                cached_index_ += 1;
            }
            cache_ = video::ffv1_detail::frameToBgr(av_frame_);
            av_frame_unref(av_frame_);
            return true;
        }
    }

    bool decodeOne() {
        for (;;) {
            int ret = avcodec_receive_frame(decoder_, av_frame_);
            if (ret == 0) {
                return true;
            }
            if (ret == AVERROR_EOF) {
                return false;
            }
            if (ret != AVERROR(EAGAIN)) {
                throw std::runtime_error("mimic: avcodec_receive_frame failed: " + avErr(ret));
            }
            if (eof_sent_) {
                return false;
            }
            ret = av_read_frame(format_, packet_);
            if (ret < 0) {
                avcodec_send_packet(decoder_, nullptr);  // flush
                eof_sent_ = true;
                continue;
            }
            if (packet_->stream_index == stream_index_) {
                const int sent = avcodec_send_packet(decoder_, packet_);
                if (sent < 0) {
                    av_packet_unref(packet_);
                    throw std::runtime_error("mimic: avcodec_send_packet failed: " + avErr(sent));
                }
            }
            av_packet_unref(packet_);
        }
    }

    void close() {
        if (av_frame_ != nullptr) {
            av_frame_free(&av_frame_);
        }
        if (packet_ != nullptr) {
            av_packet_free(&packet_);
        }
        if (decoder_ != nullptr) {
            avcodec_free_context(&decoder_);
        }
        if (format_ != nullptr) {
            avformat_close_input(&format_);
        }
        avio_.reset();
    }

    std::unique_ptr<video::ffv1_detail::FileAvio> avio_;
    AVFormatContext *format_ = nullptr;
    AVStream *stream_ = nullptr;
    AVCodecContext *decoder_ = nullptr;
    AVPacket *packet_ = nullptr;
    AVFrame *av_frame_ = nullptr;
    int stream_index_ = -1;

    std::vector<int64_t> pts_;
    cv::Mat cache_;
    int cached_index_ = -1;
    int pending_target_ = -1;
    bool eof_sent_ = false;
};

}  // namespace uma::mimic
