#pragma once

// Shared builders for the hand-crafted CV_8UC3 mats that the pixel-level tests drive Frame through.
//
// Several test TUs (test_frame, test_cv_rule, the scraper/stitcher tests) each need a solid-color
// square or a two-tone split image. They used to carry private copies of these helpers; collecting
// them here keeps a single definition and lets new tests reuse the same conventions (OpenCV stores
// BGR, so the Scalar is built from the reordered channels).

#include <algorithm>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include "types/color.h"

namespace uma::testutil {

// A solid CV_8UC3 image of the given RGB color (OpenCV stores BGR, hence the reordered Scalar).
inline cv::Mat solid(int width, int height, const Color &color) {
    return cv::Mat(height, width, CV_8UC3, cv::Scalar(color.b(), color.g(), color.r()));
}

// A solid square CV_8UC3 image of the given RGB color.
inline cv::Mat solid(int size, const Color &color) {
    return solid(size, size, color);
}

// A square image split into a black left region [0, boundary) and a white right region
// [boundary, size). The vertical boundary lets a horizontal line measure a colored run whose
// length is set by `boundary`.
inline cv::Mat splitH(int size, int boundary) {
    cv::Mat image(size, size, CV_8UC3, cv::Scalar(0, 0, 0));
    image(cv::Rect(boundary, 0, size - boundary, size)).setTo(cv::Scalar(255, 255, 255));
    return image;
}

// A square image split into a top band [0, boundary) of `top` and a bottom band [boundary, size)
// of `bottom`. A vertical scan line then crosses a colored run whose length is set by `boundary`;
// used to synthesize scroll-bar-like columns for the offset estimators.
inline cv::Mat splitV(int size, int boundary, const Color &top, const Color &bottom) {
    cv::Mat image(size, size, CV_8UC3, cv::Scalar(top.b(), top.g(), top.r()));
    image(cv::Rect(0, boundary, size, size - boundary)).setTo(cv::Scalar(bottom.b(), bottom.g(), bottom.r()));
    return image;
}

}  // namespace uma::testutil
