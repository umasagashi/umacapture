#pragma once

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#include <opencv2/opencv.hpp>
#pragma clang diagnostic pop

#include <filesystem>
#include <vector>

#include "chara_detail/chara_detail_config.h"
#include "chara_detail/record_info.h"
#include "util/event_util.h"
#include "util/misc.h"

namespace uma {
// Used only by const reference in CharaDetailSceneStitcher::stitchTab; the full definition
// (cv/frame.h) is pulled in by the implementation, not by consumers of this header.
class Frame;
}  // namespace uma

namespace uma::chara_detail {

namespace stitcher_impl {

class ScrollAreaStitcher {
public:
    [[nodiscard]] cv::Mat stitch(const std::filesystem::path &input_dir) const;

private:
    [[nodiscard]] std::vector<std::filesystem::path> imagePaths(const std::filesystem::path &dir) const;
};

}  // namespace stitcher_impl

class CharaDetailSceneStitcher {
public:
    CharaDetailSceneStitcher(
        const std::filesystem::path &scraping_dir,
        const std::filesystem::path &stitching_dir,
        const event_util::Listener<RecordInfo> &on_stitch_ready,
        const event_util::Sender<RecordInfo> &on_stitch_completed,
        const stitcher_config::CharaDetailSceneStitcherConfig &config,
        const io_util::DirectoryHooks &directory_hooks);

    void stitch(const RecordInfo &info) const;

private:
    void stitchTab(
        const Frame &base_image,
        const std::filesystem::path &input_dir,
        const std::filesystem::path &output_dir,
        const PathEntry &path_entry) const;

    [[nodiscard]] static cv::Mat createDummyImage(const Size<int> &size);

    const stitcher_config::CharaDetailSceneStitcherConfig config;
    const std::filesystem::path scraping_root_dir;
    const std::filesystem::path stitching_root_dir;
    const stitcher_impl::ScrollAreaStitcher scroll_area_stitcher;
    const io_util::DirectoryHooks directory_hooks;

    const event_util::Listener<RecordInfo> on_stitch_ready;
    const event_util::Sender<RecordInfo> on_stitch_completed;
};

}  // namespace uma::chara_detail
