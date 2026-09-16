#pragma once

// THE DECODE BACKEND A VIDEO-READING CASE PRESUPPOSES, checked before it decodes.
//
// cv::VideoCapture::open with no API preference tries every backend OpenCV can load, in priority order, and says
// nothing about which one answered. The product decodes through the FFmpeg plugin (the CLI's `video`, the Windows
// video import), so a case here that reads a clip is a statement about FFmpeg's pixels and FFmpeg's buffer
// handling. When the plugin is not next to the test executable, OpenCV quietly opens the same file through Media
// Foundation instead, and the measured outcome was never a named failure: an FFV1 .mkv decoded to zero frames and
// failed on an empty result with no cause, while an .mp4 decoded to DIFFERENT pixels that still passed
// (test_factor_header_band.cpp's header_min 0.582 on FFmpeg read 0.502 on MSMF, against a 0.5 threshold).
//
// So the check is made on the path the case is about to decode, through the same no-preference open and the same
// narrow path VideoLoader and VideoFrameGrabber use: "the plugin loaded" alone would not catch FFmpeg declining
// one particular file and another backend picking it up.

#include <filesystem>
#include <string>

#include <doctest/doctest.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#include <opencv2/videoio/registry.hpp>
#pragma clang diagnostic pop

#include "cv/video_loader.h"

#ifndef TEST_OPENCV_FFMPEG_PLUGIN
#error "TEST_OPENCV_FFMPEG_PLUGIN must be defined by the build (see native/CMakeLists.txt)."
#endif

namespace uma::testutil {

inline void requireFfmpegDecodes(const std::filesystem::path &clip) {
    // hasBackend loads a plugin backend on first use, so false here means the DLL was not found.
    REQUIRE_MESSAGE(cv::videoio_registry::hasBackend(cv::CAP_FFMPEG),
                    "OpenCV's FFmpeg videoio plugin did not load: " TEST_OPENCV_FFMPEG_PLUGIN
                    " is not next to this test executable. This case decodes video and states what FFmpeg decodes; "
                    "without the plugin OpenCV silently uses another backend. The umacapture_tests POST_BUILD step "
                    "copies it (native/CMakeLists.txt) -- rebuild the target, or check the OpenCV prebuilt under "
                    "windows/opencv.");
    const std::string clip_name = clip.filename().generic_string();
    cv::VideoCapture cap;
    REQUIRE_MESSAGE(cap.open(video::capturePathString(clip)), "no backend opened " << clip_name);
    const std::string backend = cap.getBackendName();
    REQUIRE_MESSAGE(backend == "FFMPEG",
                    "the FFmpeg plugin is loaded but did not open " << clip_name << "; " << backend
                                                                    << " did, so this case would measure pixels the "
                                                                       "product never decodes");
}

}  // namespace uma::testutil
