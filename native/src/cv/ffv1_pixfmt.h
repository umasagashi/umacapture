#pragma once

#include <cstring>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

// Bit-exact BGR <-> FFV1 conversion, defined once so the recorder's encode mapping and the reader's decode
// mapping can never drift apart. FFV1 is stored as AV_PIX_FMT_BGR0: packed 8-bit B,G,R plus an ignored 4th
// byte, full resolution, no chroma subsampling and no YUV matrix -- so the B/G/R samples survive untouched,
// unlike yuv420p/yuv444p which apply a lossy RGB->YUV transform. (This ffmpeg build's FFV1 encoder does not
// accept the 8-bit planar gbrp format; bgr0 is its lossless 8-bit RGB path.) A cv::Mat BGR image maps
// directly: BGR -> BGRA (padding the ignored channel) on the way in, BGRA -> BGR on the way out. Every copy
// is row-by-row honoring AVFrame::linesize (SIMD-padded, generally != cv::Mat::step).
namespace uma::video::ffv1_detail {

constexpr AVPixelFormat kFrameFormat = AV_PIX_FMT_BGR0;

// Write a CV_8UC3 BGR image into a writable BGR0 AVFrame of matching size.
inline void bgrToFrame(const cv::Mat &bgr, AVFrame *frame) {
    cv::Mat bgra;
    cv::cvtColor(bgr, bgra, cv::COLOR_BGR2BGRA);  // 4th channel is ignored by bgr0; value is irrelevant
    const int height = bgra.rows;
    const size_t row_bytes = static_cast<size_t>(bgra.cols) * 4;
    for (int y = 0; y < height; ++y) {
        std::memcpy(frame->data[0] + static_cast<size_t>(y) * frame->linesize[0], bgra.ptr(y), row_bytes);
    }
}

// Read a BGR0 AVFrame back into a fresh CV_8UC3 BGR image.
inline cv::Mat frameToBgr(const AVFrame *frame) {
    const cv::Mat bgra(frame->height, frame->width, CV_8UC4, frame->data[0], static_cast<size_t>(frame->linesize[0]));
    cv::Mat bgr;
    cv::cvtColor(bgra, bgr, cv::COLOR_BGRA2BGR);  // drops the ignored 4th channel; B/G/R are exact
    return bgr;
}

}  // namespace uma::video::ffv1_detail
