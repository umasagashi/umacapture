#pragma once

#include <clip/clip.h>

#include <opencv2/opencv.hpp>

inline bool copyToClipboardFromFile(const std::string &path) {
    const auto &src = cv::imread(path);
    cv::Mat mat;
    cv::cvtColor(src, mat, cv::COLOR_BGR2BGRA);

    const auto width = static_cast<unsigned long>(mat.size().width);
    const auto height = static_cast<unsigned long>(mat.size().height);
    clip::image_spec spec = {
        width,
        height,
        32,
        4 * width,
        0xff0000,
        0x00ff00,
        0x0000ff,
        0xff000000,
        16,
        8,
        0,
        24,
    };

    const auto &image = clip::image(mat.data, spec);
    return clip::set_image(image);
}
